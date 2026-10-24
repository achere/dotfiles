#!/usr/bin/perl
# tmux display-panes for herdr, bound to prefix+q (see config.toml): a big
# digit on every pane of the focused tab; a bare digit 1-9 focuses that pane,
# any other key or 3 seconds of nothing closes it. `show` is the plugin
# action; `pick` runs inside the popup.
#
# herdr can only take a bare key through a popup (bindings on unmodified
# printable keys are always disabled, src/config/keybinds.rs), so this is a
# full-size popup that repaints the panes underneath, cell for cell, with the
# digits on top. A 100% popup covers exactly the tab's pane area with a
# 1-cell border of its own (src/popup_size.rs), and every pane has a full
# 1-cell border (ui.pane_gaps defaults to true), so a pane's text lands on the
# cells it occupies underneath.
#
# Keeping the popup from flashing blank when it opens:
# - `show` builds the whole frame before the popup exists; the popup's
#   command prints it before anything else (herdr-plugin.toml).
# - The server renders at most every 16 ms (MIN_RENDER_INTERVAL,
#   src/app/mod.rs). Opened at a random moment, the popup's first render can
#   come before the frame has arrived: one blank frame. Opened right after a
#   render, its first render is ~16 ms away and the frame is there in time.
#   A fresh `herdr terminal session observe` locates one: its first record
#   comes at the first render after it attaches, ~1.5 ms after the client's
#   frame. Later records cannot be used - they skip renders that only patch
#   a pane in place, like an agent's spinner. Fences - requests flagged
#   changes_ui (src/api/schema/operations.rs) that change nothing - make
#   sure a render comes when nothing else is drawing.
#
# Perl, not bash: this needs sub-second waits, which macOS bash 3.2 cannot
# do, and it is ~4x faster - no jq or CLI process per step. Until the popup
# opens, a digit typed after prefix+q goes to the focused pane, so `show` is
# kept quick to start: only light modules (File::Temp, File::Path,
# IO::Socket::UNIX and POSIX would add ~12 ms).
#
# See docs/superpowers/specs/2026-10-24-herdr-display-panes-design.md

# The render marker (see open_after_render) starts before anything else
# loads: an observer takes ~20 ms to attach, and this way that overlaps with
# perl's own startup and the frame. HERDR_PANE_ID is the focused pane.
our $EARLY_MARKER;
BEGIN {
    if (($ARGV[0] // '') eq 'show' && $ENV{HERDR_PANE_ID}) {
        my $pid = open(my $fh, '-|', $ENV{HERDR_BIN_PATH} // 'herdr',
            'terminal', 'session', 'observe', $ENV{HERDR_PANE_ID});
        $EARLY_MARKER = { fh => $fh, pid => $pid } if $pid;
    }
}

use strict;
use warnings;
use utf8;
use IO::Select;
use Socket qw(AF_UNIX SOCK_STREAM pack_sockaddr_un);
use Time::HiRes qw(sleep time);

my $JSON = eval { require JSON::XS; JSON::XS->new->utf8 }
  // do { require JSON::PP; JSON::PP->new->utf8 };

use constant {
    TIMEOUT_SECONDS    => 3,      # tmux.conf: display-panes-time 3000
    ACTIVE_COLOUR      => 41,     # tmux display-panes-active-colour red (bg)
    OTHER_COLOUR       => 44,     # tmux display-panes-colour blue (bg)
    PLUGIN_ID          => 'dotfiles.display-panes',
    SOURCE             => 'dotfiles:display-panes',
    FENCE_EVERY_MS     => 2,
    MARKER_MAX_MS      => 200,    # first record normally in 15-40 ms
    SETTLE_RESIZE_MS   => 20,     # one render interval and a little
    SETTLE_STABLE_MS   => 40,     # unzoomed pane redrawn: text unchanged this long
    SETTLE_REDRAW_MS   => 100,    # ... or this long after the resize, if it never is
};

# herdr's one-dark palette (config.toml [theme], src/app/state.rs): pane
# borders are overlay0, the focused one accent; the scrollbar uses the rest.
my %PALETTE = (
    accent      => '97;175;239',
    overlay0    => '92;99;112',
    overlay1    => '115;122;135',
    surface_dim => '40;44;52',
);

# Five rows of five cells, '#' filled.
my %GLYPH = (
    1 => ['  #  ', ' ##  ', '  #  ', '  #  ', ' ### '],
    2 => ['#####', '    #', '#####', '#    ', '#####'],
    3 => ['#####', '    #', '#####', '    #', '#####'],
    4 => ['#   #', '#   #', '#####', '    #', '    #'],
    5 => ['#####', '#    ', '#####', '    #', '#####'],
    6 => ['#####', '#    ', '#####', '#   #', '#####'],
    7 => ['#####', '    #', '    #', '    #', '    #'],
    8 => ['#####', '#   #', '#####', '#   #', '#####'],
    9 => ['#####', '#   #', '#####', '    #', '#####'],
);

# --- pure layer -------------------------------------------------------------

# The focused tab from a session snapshot: whether it is zoomed, the focused
# pane, the popup's inner size, and panes 1-9 in layout order. A pane's
# col/row are the 1-based popup cell where its text starts - one cell inside
# its border, and the popup's origin is one cell inside the area, so the two
# cancel to rect - area + 1. w/h are its text area inside the border. The
# popup's inner size is the area less its border and one reserved column
# (src/popup_size.rs). max/off/vp are its scroll metrics, for the scrollbar.
sub layout {
    my ($s) = @_;
    my ($l) = grep { $_->{tab_id} eq $s->{focused_tab_id} } @{ $s->{layouts} };
    my %scroll = map { $_->{pane_id} => ($_->{scroll} // {}) } @{ $s->{panes} // [] };
    my @panes = @{ $l->{panes} };
    splice @panes, 9 if @panes > 9;
    my ($ax, $ay) = @{ $l->{area} }{qw(x y)};
    my $n = 0;
    return {
        zoomed  => $l->{zoomed} ? 1 : 0,
        focused => $s->{focused_pane_id},
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

# The pane ID for a pressed key, or undef. Only 1-9 select.
sub pane_for_key {
    my ($key, $panes) = @_;
    return unless defined $key && $key =~ /\A[1-9]\z/;
    my ($p) = grep { $_->{n} == $key } @$panes;
    return $p && $p->{id};
}

# The popup's whole screen: each pane's text at its own cells, its scrollbar
# and border as herdr draws them, and its digit. $text maps pane id to
# pane.read's ANSI text. Cells outside the popup are dropped, which is how
# the outermost pane borders vanish under the popup's own border.
sub frame {
    my ($lay, $text) = @_;
    my ($rows, $cols) = @{$lay}{qw(rows cols)};
    my $in  = sub { $_[0] >= 1 && $_[0] <= $rows && $_[1] >= 1 && $_[1] <= $cols };
    my $fg  = sub { "\e[0;38;2;$PALETTE{$_[0]}m" };
    # Synchronized output (DEC 2026): herdr applies the frame as one update.
    my $out = "\e[?2026h\e[?25l\e[?7l\e[2J";
    for my $p (@{ $lay->{panes} }) {
        my ($col, $row, $w, $h) = @{$p}{qw(col row w h)};

        my @lines = split /\r?\n/, $text->{ $p->{id} } // '';
        for my $i (0 .. $#lines) {
            last if $i >= $h || $row + $i > $rows;
            $out .= "\e[" . ($row + $i) . ";${col}H\e[0m$lines[$i]\e[0m";
        }

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
        $out .= "\e[0m";

        my $colour = $p->{focused} ? ACTIVE_COLOUR : OTHER_COLOUR;
        if ($w < 5 || $h < 5) {
            # Too small for the glyph: a single coloured digit, as tmux does.
            $out .= "\e[" . ($row + int($h / 2)) . ';' . ($col + int($w / 2)) . "H\e[${colour}m$p->{n}\e[0m";
            next;
        }
        my ($gr, $gc) = ($row + int(($h - 5) / 2), $col + int(($w - 5) / 2));
        for my $i (0 .. 4) {
            # Unfilled cells step over the pane text instead of blanking it.
            $out .= "\e[" . ($gr + $i) . ";${gc}H"
              . join '', map { $_ eq '#' ? "\e[${colour}m \e[0m" : "\e[1C" } split //, $GLYPH{ $p->{n} }[$i];
        }
    }
    return $out . "\e[?2026l";
}

# --- side effects -----------------------------------------------------------

my $SOCKET = $ENV{HERDR_SOCKET_PATH} // "$ENV{HOME}/.config/herdr/herdr.sock";

# api <method> <params>: one socket request; its result, or undef on error.
sub api {
    my ($method, $params) = @_;
    my $s;
    socket($s, AF_UNIX, SOCK_STREAM, 0) && connect($s, pack_sockaddr_un($SOCKET))
      or die "display-panes: connect $SOCKET: $!\n";
    syswrite $s, $JSON->encode({ id => 'display-panes', method => $method, params => $params }) . "\n";
    my $reply = <$s>;
    close $s;
    my $r = eval { $JSON->decode($reply // '') } // {};
    return $r->{result};
}

# Clearing a token that was never set: changes nothing, still renders.
sub fence {
    api('pane.report_metadata', { pane_id => $_[0], source => SOURCE, tokens => { display_panes_fence => undef } });
}

# marker <pane>: a fresh observer whose first record will mark a render.
# Observers never exit by themselves, and perl waits for a piped child when
# it closes the handle, so every one started is killed at exit too.
my @observers;
sub marker {
    my $herdr = $ENV{HERDR_BIN_PATH} // 'herdr';
    my $pid = open(my $fh, '-|', $herdr, 'terminal', 'session', 'observe', $_[0]) or return;
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

# settle <pane>: after unzooming, wait for the pane to be resized - at the
# server's next render, so within one interval - then for its app to redraw
# at the new size: until its text has not changed for SETTLE_STABLE_MS, or
# SETTLE_REDRAW_MS after the resize for a pane that never stops changing,
# like a working agent. Polls, because nothing reports an in-place redraw;
# nor does the API expose a pane's width to wait on instead.
sub settle {
    my ($pane) = @_;
    sleep SETTLE_RESIZE_MS / 1000;
    my $resized = time;
    my ($last, $since) = ('', $resized);
    while (time - $resized < SETTLE_REDRAW_MS / 1000) {
        my $text = pane_text($pane);
        ($last, $since) = ($text, time) if $text ne $last;
        last if time - $since >= SETTLE_STABLE_MS / 1000;
        sleep 0.01;
    }
}

# Open the popup right after a render (see the header). $m is a marker
# started early, so it attached while the frame was built; if a render
# already used up its first record, start a fresh one.
sub open_after_render {
    my ($m, $pane, $state) = @_;
    if (!$m || marked($m)) {
        drop_marker($m);
        $m = marker($pane);
    }
    # No record (the observer failed): open after a fence and hope.
    fence($pane) unless wait_marker($m, $pane);
    drop_marker($m);
    return api('plugin.pane.open',
        { plugin_id => PLUGIN_ID, entrypoint => 'picker', env => { DISPLAY_PANES_STATE => $state } });
}

# A state dir for one run, and its removal.
sub make_state {
    my $state = ($ENV{HERDR_PLUGIN_STATE_DIR} // $ENV{TMPDIR} // '/tmp') . "/frame.$$";
    mkdir $state, 0700 or die "display-panes: $state: $!\n";
    return $state;
}

sub remove_state {
    my ($state) = @_;
    unlink glob "$state/*";
    rmdir $state;
}

sub write_file {
    my ($path, $content) = @_;
    open my $fh, '>:encoding(UTF-8)', $path or die "display-panes: $path: $!\n";
    print {$fh} $content;
    close $fh;
}

sub read_lines {
    my ($path) = @_;
    open my $fh, '<:encoding(UTF-8)', $path or return;
    chomp(my @lines = <$fh>);
    return @lines;
}

# The plugin action: unzoom if needed, build the frame, open the popup.
# Everything the popup needs goes through a state dir.
sub show {
    my $s = (api('session.snapshot', {}) // die "display-panes: no snapshot\n")->{snapshot};
    my $lay = layout($s);
    my $m = $EARLY_MARKER ? { %$EARLY_MARKER, sel => IO::Select->new($EARLY_MARKER->{fh}) }
                          : marker($lay->{panes}[0]{id});
    push @observers, $m->{pid} if $EARLY_MARKER;
    my $zoomed = $lay->{zoomed} ? $lay->{focused} : '';
    my $state;
    my $ok = eval {
        # A zoomed tab shows one pane; unzoom so every pane gets a number.
        # pick restores the zoom unless a different pane is chosen.
        if ($zoomed) {
            api('pane.zoom', { pane_id => $zoomed, mode => 'off' });
            settle($zoomed);
            $lay = layout(api('session.snapshot', {})->{snapshot});
        }
        my %text = map { ($_->{id} => pane_text($_->{id})) } @{ $lay->{panes} };

        $state = make_state();
        write_file("$state/frame", frame($lay, \%text));
        write_file("$state/panes", join '', map { "$_->{n} $_->{id} $_->{focused}\n" } @{ $lay->{panes} });
        write_file("$state/zoomed", $zoomed);
        # e.g. ui_busy while Copy mode or Settings is open
        open_after_render($m, $lay->{panes}[0]{id}, $state) or die "display-panes: popup refused\n";
        1;
    };
    return 1 if $ok;
    remove_state($state) if $state;
    api('pane.zoom', { pane_id => $zoomed, mode => 'on' }) if $zoomed;
    die $@;
}

# One keypress from the popup's terminal, or '' after the timeout.
sub read_key {
    my ($timeout) = @_;
    require POSIX;
    my $t = POSIX::Termios->new;
    if ($t->getattr(0)) {
        $t->setlflag($t->getlflag & ~(POSIX::ECHO() | POSIX::ICANON()));
        $t->setcc(POSIX::VMIN(), 1);
        $t->setcc(POSIX::VTIME(), 0);
        $t->setattr(0, POSIX::TCSANOW());
    }
    return '' unless IO::Select->new(\*STDIN)->can_read($timeout);
    sysread(STDIN, my $buf, 64) or return '';
    return substr $buf, 0, 1;
}

# Inside the popup, after herdr-plugin.toml's command printed the frame:
# wait for one key, act, exit (which closes the popup). Focus and zoom change
# while the popup still covers the panes, so the screen it uncovers is
# already the final one.
sub pick {
    my $state = $ENV{DISPLAY_PANES_STATE} // die "display-panes: DISPLAY_PANES_STATE unset\n";
    my @panes = map { my ($n, $id, $f) = split ' '; +{ n => $n, id => $id, focused => $f } } read_lines("$state/panes");
    my ($zoomed) = read_lines("$state/zoomed");
    remove_state($state);
    my ($focused) = map { $_->{id} } grep { $_->{focused} } @panes;

    my $target = pane_for_key(read_key(TIMEOUT_SECONDS), \@panes);
    if (defined $target && $target ne ($zoomed || $focused // '')) {
        api('pane.focus', { pane_id => $target });
    } elsif ($zoomed) {
        api('pane.zoom', { pane_id => $zoomed, mode => 'on' });
    }
}

unless (caller) {
    my $mode = shift // '';
    if    ($mode eq 'show') { show() }
    elsif ($mode eq 'pick') { pick() }
    else                    { die "usage: display-panes.pl show|pick\n" }
}
1;
