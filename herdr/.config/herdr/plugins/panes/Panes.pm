package Panes;
# What display-panes.pl and copy-mode.pl share: both open a full-size popup
# that repaints the panes underneath it, cell for cell, and draws on top.
# This is the socket API, the focused tab's layout, the drawing of a pane as
# herdr draws it (text, scrollbar, border), and opening the popup without a
# blank frame. Why it works is in the header of display-panes.pl.
#
# Only light modules: until the popup opens, a key typed after the binding
# goes to the focused pane, so every ms of startup counts.
use strict;
use warnings;
use utf8;
use Exporter 'import';
use IO::Select;
use Socket qw(AF_UNIX SOCK_STREAM pack_sockaddr_un);
use Time::HiRes qw(time);

our @EXPORT = qw(
  %PALETTE layout scrollbar_thumb frame_start pane_lines pane_chrome frame_end
  api fence marker drop_marker marked wait_marker pane_text open_after_render
  make_state remove_state write_file read_lines json
);

my $JSON = eval { require JSON::XS; JSON::XS->new->utf8 }
  // do { require JSON::PP; JSON::PP->new->utf8 };

# The JSON coder api uses: UTF-8 bytes in and out.
sub json { $JSON }

use constant {
    PLUGIN_ID      => 'dotfiles.panes',
    SOURCE         => 'dotfiles:panes',
    FENCE_EVERY_MS => 2,
    MARKER_MAX_MS  => 200,    # first record normally in 15-40 ms
};

# herdr's one-dark palette (config.toml [theme], src/app/state.rs): pane
# borders are overlay0, the focused one accent; the scrollbar uses the rest.
our %PALETTE = (
    accent      => '97;175;239',
    overlay0    => '92;99;112',
    overlay1    => '115;122;135',
    surface_dim => '40;44;52',
);

# --- pure layer -------------------------------------------------------------

# The focused tab from a session snapshot: whether it is zoomed, the focused
# pane, its area, the popup's inner size, and panes 1-9 in layout order (with
# $all, every pane). A pane's col/row are the 1-based popup cell where its
# text starts - one cell inside its border, and the popup's origin is one
# cell inside the area, so the two cancel to rect - area + 1. w/h are its
# text area inside the border. The popup's inner size is the area less its
# border and one reserved column (src/popup_size.rs). max/off/vp are its
# scroll metrics, for the scrollbar.
sub layout {
    my ($s, $all) = @_;
    my ($l) = grep { $_->{tab_id} eq $s->{focused_tab_id} } @{ $s->{layouts} };
    my %scroll = map { $_->{pane_id} => ($_->{scroll} // {}) } @{ $s->{panes} // [] };
    my @panes = @{ $l->{panes} };
    splice @panes, 9 if @panes > 9 && !$all;
    my ($ax, $ay) = @{ $l->{area} }{qw(x y)};
    my $n = 0;
    return {
        zoomed  => $l->{zoomed} ? 1 : 0,
        focused => $s->{focused_pane_id},
        area    => $l->{area},
        rows    => $l->{area}{height} - 2,
        cols    => $l->{area}{width} - 3,
        panes   => [
            map {
                my ($r, $m) = ($_->{rect}, $scroll{ $_->{pane_id} } // {});
                +{
                    n       => ++$n,
                    id      => $_->{pane_id},
                    col     => $r->{x} - $ax + 1,
                    row     => $r->{y} - $ay + 1,
                    w       => $r->{width} - 2,
                    h       => $r->{height} - 2,
                    focused => $_->{focused} ? 1 : 0,
                    max     => $m->{max_offset_from_bottom} // 0,
                    off     => $m->{offset_from_bottom} // 0,
                    vp      => $m->{viewport_rows} // 0,
                };
            } @panes
        ],
    };
}

# The scrollbar thumb as (top, length) in track rows, or () when the pane
# has no scrollback - herdr's scrollbar_thumb (src/ui/scrollbar.rs).
sub scrollbar_thumb {
    my ($max, $off, $vp, $h) = @_;
    return if $max <= 0 || $h <= 0;
    my $len = int($vp * $h / ($max + $vp) + 0.5);
    $len = 1  if $len < 1;
    $len = $h if $len > $h;
    my $max_top = $h - $len;
    my $top = $max_top > 0 ? int(($max - $off) * $max_top / $max + 0.5) : 0;
    $top = $max_top if $top > $max_top;
    return ($top, $len);
}

# A popup frame is frame_start, then each pane's lines and chrome, then
# whatever the caller draws on top, then frame_end. Synchronized output
# (DEC 2026): herdr applies the frame as one update.
sub frame_start { "\e[?2026h\e[?25l\e[?7l\e[2J" }
sub frame_end   { "\e[?2026l" }

# A pane's text at its own cells. $text is pane.read's ANSI text.
sub pane_lines {
    my ($p, $lay, $text) = @_;
    my ($col, $row, $h) = @{$p}{qw(col row h)};
    my $out = '';
    my @lines = split /\r?\n/, $text // '';
    for my $i (0 .. $#lines) {
        last if $i >= $h || $row + $i > $lay->{rows};
        $out .= "\e[" . ($row + $i) . ";${col}H\e[0m$lines[$i]\e[0m";
    }
    return $out;
}

# A pane's scrollbar and border as herdr draws them. Cells outside the popup
# are dropped, which is how the outermost pane borders vanish under the
# popup's own border.
sub pane_chrome {
    my ($p, $lay) = @_;
    my ($rows, $cols) = @{$lay}{qw(rows cols)};
    my ($col, $row, $w, $h) = @{$p}{qw(col row w h)};
    my $in  = sub { $_[0] >= 1 && $_[0] <= $rows && $_[1] >= 1 && $_[1] <= $cols };
    my $fg  = sub { "\e[0;38;2;$PALETTE{$_[0]}m" };
    my $out = '';

    # herdr's pane scrollbar (render_pane_scrollbar_buffer,
    # src/ui/scrollbar.rs): down the last text column, only with
    # scrollback.
    if (my ($top, $len) = scrollbar_thumb(@{$p}{qw(max off vp)}, $h)) {
        my $c = $col + $w - 1;
        my ($track, $thumb, $symbol) =
          $p->{focused} ? ('overlay0', 'overlay1', '▐') : ('surface_dim', 'overlay0', '▕');
        for my $r (0 .. $h - 1) {
            next unless $in->($row + $r, $c);
            my $on = $r >= $top && $r < $top + $len;
            $out .= "\e[" . ($row + $r) . ";${c}H" . $fg->($on ? $thumb : $track)
              . ($on ? $symbol : '▕') . "\e[0m";
        }
    }

    $out .= $fg->($p->{focused} ? 'accent' : 'overlay0');
    for my $edge ([$row - 1, '┌', '┐'], [$row + $h, '└', '┘']) {
        my ($r, $left, $right) = @$edge;
        next unless $r >= 1 && $r <= $rows;
        my $line = '';
        my $start;
        for my $c ($col - 1 .. $col + $w) {
            next unless $in->($r, $c);
            $start //= $c;
            $line .= $c == $col - 1 ? $left : $c == $col + $w ? $right : '─';
        }
        $out .= "\e[$r;${start}H$line" if defined $start;
    }
    for my $c ($col - 1, $col + $w) {
        $out .= "\e[" . ($row + $_) . ";${c}H│" for grep { $in->($row + $_, $c) } 0 .. $h - 1;
    }
    return $out . "\e[0m";
}

# --- side effects -----------------------------------------------------------

my $SOCKET = $ENV{HERDR_SOCKET_PATH} // "$ENV{HOME}/.config/herdr/herdr.sock";

# api <method> <params>: one socket request; its result, or undef on error.
# In list context also the error, for callers that tell errors apart.
sub api {
    my ($method, $params) = @_;
    my $s;
    socket($s, AF_UNIX, SOCK_STREAM, 0) && connect($s, pack_sockaddr_un($SOCKET))
      or die "panes: connect $SOCKET: $!\n";
    syswrite $s, $JSON->encode({ id => 'panes', method => $method, params => $params }) . "\n";
    my $reply = <$s>;
    close $s;
    my $r = eval { $JSON->decode($reply // '') } // {};
    return wantarray ? ($r->{result}, $r->{error}) : $r->{result};
}

# Clearing a token that was never set: changes nothing, still renders.
sub fence {
    api('pane.report_metadata', { pane_id => $_[0], source => SOURCE, tokens => { panes_fence => undef } });
}

# marker <pane>: a fresh observer whose first record will mark a render.
# Observers never exit by themselves, and perl waits for a piped child when
# it closes the handle, so every one started is killed at exit too. A marker
# started early, before this module loaded, is adopted with marker(undef,
# $early).
my @observers;
sub marker {
    my ($pane, $early) = @_;
    my ($fh, $pid);
    if ($early) {
        ($fh, $pid) = @{$early}{qw(fh pid)};
    } else {
        my $herdr = $ENV{HERDR_BIN_PATH} // 'herdr';
        $pid = open($fh, '-|', $herdr, 'terminal', 'session', 'observe', $pane) or return;
    }
    push @observers, $pid;
    return { fh => $fh, pid => $pid, sel => IO::Select->new($fh) };
}
END { kill 'TERM', @observers if @observers }

sub drop_marker { kill 'TERM', $_[0]{pid} if $_[0] }

# Whether the marker has already recorded a render.
sub marked { $_[0] && $_[0]{sel}->can_read(0) }

# Wait for the marker's first record, fencing every FENCE_EVERY_MS so that a
# render comes even when nothing is drawing. 1 once it arrives, 0 at the cap.
sub wait_marker {
    my ($m, $pane) = @_;
    return 0 unless $m;
    my $deadline = time + MARKER_MAX_MS / 1000;
    while (time < $deadline) {
        return 1 if $m->{sel}->can_read(FENCE_EVERY_MS / 1000);
        fence($pane);
    }
    return 0;
}

sub pane_text {
    my $r = api('pane.read', { pane_id => $_[0], source => 'visible', format => 'ansi' });
    return $r ? $r->{read}{text} : '';
}

# Open this plugin's popup pane $entry right after a render (see the header
# of display-panes.pl), with %$env in its environment. $m is a marker
# started early, so it attached while the frame was built; if a render
# already used up its first record, start a fresh one.
sub open_after_render {
    my ($m, $pane, $entry, $env) = @_;
    if (!$m || marked($m)) {
        drop_marker($m);
        $m = marker($pane);
    }
    # No record (the observer failed): open after a fence and hope.
    fence($pane) unless wait_marker($m, $pane);
    drop_marker($m);
    return api('plugin.pane.open', { plugin_id => PLUGIN_ID, entrypoint => $entry, env => $env });
}

# A state dir for one run, and its removal.
sub make_state {
    my $state = ($ENV{HERDR_PLUGIN_STATE_DIR} // $ENV{TMPDIR} // '/tmp') . "/frame.$$";
    mkdir $state, 0700 or die "panes: $state: $!\n";
    return $state;
}

sub remove_state {
    my ($state) = @_;
    unlink glob "$state/*";
    rmdir $state;
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die "panes: $path: $!\n";
    print {$fh} $content;
    close $fh;
}

sub read_lines {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or return;
    chomp(my @lines = <$fh>);
    return @lines;
}

1;
