#!/usr/bin/perl
# Checks prefix+h/j/k/l's pure layer in Panes.pm: which pane a direction
# picks, the call that focuses it, and the focus records. No herdr server
# involved. Run: perl focus.t
use strict;
use warnings;
use FindBin;
use File::Temp ();
use lib $FindBin::Bin;
use Test::More;
use Panes;

# A session.snapshot's focused tab, panes in layout order. Rects are
# [x, y, width, height].
sub tab {
    my (%a) = @_;
    my @panes = @{ $a{panes} };
    return layout({
        focused_tab_id  => 'w1:t1',
        focused_pane_id => $panes[0][0],
        layouts => [{
            tab_id => 'w1:t1', zoomed => $a{zoomed} // 0,
            area   => { x => 0, y => 0, width => 165, height => 48 },
            panes  => [ map { +{ pane_id => $_->[0], focused => 0,
                rect => { x => $_->[1], y => $_->[2], width => $_->[3], height => $_->[4] } } } @panes ],
        }],
    }, 1);
}

# 1 on the left, 2 top right, 3 bottom right (the tab this was built for).
my $cols = tab(panes => [['p1', 0, 0, 83, 48], ['p2', 83, 0, 82, 24], ['p3', 83, 24, 82, 24]]);
# 4 on top, 5 bottom left, 6 bottom right.
my $rows = tab(panes => [['p4', 0, 0, 165, 24], ['p5', 0, 24, 83, 24], ['p6', 83, 24, 82, 24]]);
# a | b over c | d: three columns, the middle one split.
my $three = tab(panes => [['a', 0, 0, 55, 48], ['b', 55, 0, 55, 24], ['c', 55, 24, 55, 24], ['d', 110, 0, 55, 48]]);
my $zoomed = tab(zoomed => 1, panes => [['p1', 0, 0, 83, 48], ['p2', 83, 0, 82, 24], ['p3', 83, 24, 82, 24]]);

for my $t (
    [$cols, 'p1', 'right', { p3 => 2, p2 => 1 }, 'p3',  '[3] h -> [1] l goes back to 3'],
    [$cols, 'p1', 'right', { p2 => 2, p3 => 1 }, 'p2',  '[2] h -> [1] l goes back to 2'],
    [$cols, 'p1', 'right', {},                   undef, 'no records: herdr decides'],
    [$cols, 'p1', 'right', { p3 => 1 },          'p3',  'a pane without a record loses to one with a record'],
    [$cols, 'p1', 'right', { p2 => 5, p3 => 5 }, 'p2',  'equal records: first in layout order'],
    [$cols, 'p1', 'right', { p1 => 9 },          undef, "the focused pane's own record does not count"],
    [$cols, 'p3', 'left',  { p1 => 1 },          undef, 'one neighbour: herdr decides'],
    [$cols, 'p2', 'down',  { p3 => 1 },          undef, '... also across a stacked split'],
    [$cols, 'p1', 'left',  { p2 => 1 },          undef, 'nothing that way: herdr decides'],
    [$cols, 'p1', 'up',    { p2 => 1 },          undef, '... nor up'],
    [$rows, 'p4', 'down',  { p6 => 2, p5 => 1 }, 'p6',  'down to the more recent of two'],
    [$rows, 'p4', 'down',  { p5 => 2, p6 => 1 }, 'p5',  '... either one'],
    [$rows, 'p5', 'up',    { p4 => 1 },          undef, 'up to a single pane: herdr decides'],
    [$three, 'a', 'right', { d => 9, c => 2, b => 1 }, 'c', 'a nearer column beats a more recent one further away'],
    [$three, 'a', 'right', { d => 9 },           undef, '... even when only the far column has a record'],
    [$three, 'd', 'left',  { b => 2, c => 1 },   'b',   'left to the more recent of two'],
    [$zoomed, 'p1', 'right', { p3 => 2, p2 => 1 }, undef, 'zoomed tab: herdr decides'],
    [$cols, 'gone', 'right', { p3 => 1 },        undef, 'a pane not in the layout: herdr decides'],
) {
    my ($lay, $from, $dir, $stamps, $want, $name) = @$t;
    is direction_target($lay, $from, $dir, $stamps), $want, $name;
}

is_deeply focus_call($cols, 'p1', 'right', { p3 => 2, p2 => 1 }), ['pane.focus', { pane_id => 'p3' }],
  'a picked pane is focused by id';
is_deeply focus_call($cols, 'p1', 'right', {}), ['pane.focus_direction', { pane_id => 'p1', direction => 'right' }],
  'otherwise herdr moves focus itself';

# --- focus records ----------------------------------------------------------

{
    my $old = { a => 1, b => 2, gone => 3 };
    is_deeply stamps_after($old, { a => 1, b => 1, c => 1 }, 100, 'b', 'c'), { a => 1, b => 100, c => 100.001 },
      'records the panes in the order given, and drops panes that closed';
    is_deeply $old, { a => 1, b => 2, gone => 3 }, '... leaving the old records alone';
}

{
    local $ENV{HERDR_PLUGIN_STATE_DIR} = File::Temp::tempdir(CLEANUP => 1);
    local $ENV{HERDR_SOCKET_PATH} = '/tmp/x/herdr.sock';
    is_deeply read_stamps(), {}, 'no records yet';
    stamp({ p1 => 1, p2 => 1 }, 'p1', 'p2');
    my $r = read_stamps();
    is_deeply [sort keys %$r], ['p1', 'p2'], 'records survive a round trip';
    cmp_ok $r->{p2}, '>', $r->{p1}, '... the later pane later';
    stamp({ p2 => 1, p3 => 1 }, 'p3');
    $r = read_stamps();
    is_deeply [sort keys %$r], ['p2', 'p3'], 'the next write drops a closed pane';
    ok -e "$ENV{HERDR_PLUGIN_STATE_DIR}/_tmp_x_herdr.sock/stamps", 'kept per socket, next to copy mode\'s files';
}

done_testing;
