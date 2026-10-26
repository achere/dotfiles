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
# The pieces copy-mode.pl uses too are in Panes.pm.
#
# See docs/superpowers/specs/2026-10-24-herdr-display-panes-design.md

# The render marker (open_after_render, Panes.pm) starts before anything else
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
use Time::HiRes qw(sleep time);
BEGIN { unshift @INC, __FILE__ =~ m{^(.*)/} ? $1 : '.' }
use Panes;

use constant {
    TIMEOUT_SECONDS    => 3,      # tmux.conf: display-panes-time 3000
    ACTIVE_COLOUR      => 41,     # tmux display-panes-active-colour red (bg)
    OTHER_COLOUR       => 44,     # tmux display-panes-colour blue (bg)
    SETTLE_RESIZE_MS   => 20,     # one render interval and a little
    SETTLE_STABLE_MS   => 40,     # unzoomed pane redrawn: text unchanged this long
    SETTLE_REDRAW_MS   => 100,    # ... or this long after the resize, if it never is
};

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

# The pane ID for a pressed key, or undef. Only 1-9 select.
sub pane_for_key {
    my ($key, $panes) = @_;
    return unless defined $key && $key =~ /\A[1-9]\z/;
    my ($p) = grep { $_->{n} == $key } @$panes;
    return $p && $p->{id};
}

# The popup's whole screen: each pane's text at its own cells, its scrollbar
# and border as herdr draws them (Panes.pm), and its digit. $text maps pane
# id to pane.read's ANSI text.
sub frame {
    my ($lay, $text) = @_;
    my $out = frame_start();
    for my $p (@{ $lay->{panes} }) {
        my ($col, $row, $w, $h) = @{$p}{qw(col row w h)};
        $out .= pane_lines($p, $lay, $text->{ $p->{id} }) . pane_chrome($p, $lay);

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
    return $out . frame_end();
}

# --- side effects -----------------------------------------------------------

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

# The plugin action: unzoom if needed, build the frame, open the popup.
# Everything the popup needs goes through a state dir.
sub show {
    my $s = (api('session.snapshot', {}) // die "display-panes: no snapshot\n")->{snapshot};
    my $lay = layout($s);
    my $m = $EARLY_MARKER ? marker(undef, $EARLY_MARKER) : marker($lay->{panes}[0]{id});
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
        open_after_render($m, $lay->{panes}[0]{id}, 'picker', { DISPLAY_PANES_STATE => $state })
          or die "display-panes: popup refused\n";
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
