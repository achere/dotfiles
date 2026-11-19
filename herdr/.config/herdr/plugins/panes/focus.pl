#!/usr/bin/perl
# prefix+h/j/k/l the tmux way, bound in config.toml: when two or more panes
# are next to the focused one that way, go to the one focused last, not the
# first in layout order as herdr does. The pick is direction_target in
# Panes.pm. Its focus records come from here and from copy-mode.pl's
# pane.focused hook, which also counts focus moved by the mouse, prefix+q
# and the rest.
#
# See docs/superpowers/specs/2026-11-19-herdr-pane-focus-memory-design.md
use strict;
use warnings;
BEGIN { unshift @INC, __FILE__ =~ m{^(.*)/} ? $1 : '.' }
use Panes;

my ($dir) = grep { /\A(?:left|down|up|right)\z/ } $ARGV[0] // '';
die "usage: focus.pl left|down|up|right\n" unless $dir;
my $s = (api('session.snapshot', {}) // die "focus: no snapshot\n")->{snapshot};
my $from = $s->{focused_pane_id} // die "focus: no focused pane\n";
my $call = focus_call(layout($s, 1), $from, $dir, read_stamps());
my $r = api(@$call) // exit 1;

# The pane left, then the pane landed on, in one write: the first press
# after install already counts where it came from, and a fast next press
# does not wait for the hook.
my $to = $call->[0] eq 'pane.focus' ? $call->[1]{pane_id} : $r->{focus}{focused_pane_id} // $from;
my %live = map { $_->{pane_id} => 1 } map { @{ $_->{panes} } } @{ $s->{layouts} };
stamp(\%live, $from, $to ne $from ? $to : ());
