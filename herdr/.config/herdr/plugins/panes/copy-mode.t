#!/usr/bin/perl
# Checks copy-mode.pl's pure layer: rows in, cells, motions, search,
# selection, keys, prefix bindings, pausing and drawing out. No herdr server
# involved. Run: perl copy-mode.t
use strict;
use warnings;
use utf8;
use FindBin;
use Test::More;

require "$FindBin::Bin/copy-mode.pl";

# --- rows -------------------------------------------------------------------

my $row = parse_row("\e[0m\e[38;5;1mred\e[0m x");
is_deeply [map { $_->[0] } @{ $row->{cells} }], ['r', 'e', 'd', ' ', 'x'], 'characters, escapes dropped';
is $row->{cells}[0][1], "\e[38;5;1m", 'a cell keeps the SGR in force';
is $row->{cells}[3][1], '',           '... and a reset clears it';
is $row->{text}, 'red x', 'plain text';

is parse_row("\e[1m\e[38;2;1;2;3mA")->{cells}[0][1], "\e[1m\e[38;2;1;2;3m", 'SGRs since the last reset add up';
is parse_row("\e[31m\e[0;32mA")->{cells}[0][1], "\e[32m", 'a leading 0 resets first';
is parse_row("\e]8;;http://x\e\\link\e]8;;\e\\")->{text}, 'link', 'OSC hyperlinks dropped';

# Columns as herdr 0.9.5 (Ghostty) reports them through pane.selection.read:
# emoji with VS16 and ZWJ sequences are one 2-cell character, ☸ ✓ → are 1.
my $wide = parse_row("a☸b🐍c❤️d👨‍👩‍👧e中f文gé̀hスi✓j→k");
my %col = map { my $c = $wide->{cells}[$_]; $c ? ($c->[0] => $_) : () } 0 .. $#{ $wide->{cells} };
is_deeply [@col{ 'a', '☸', 'b', '🐍', 'c', '❤️', 'd', '👨‍👩‍👧', 'e', '中', 'f', '文', 'g', "é̀", 'h', 'ス', 'i', '✓', 'j', '→', 'k' }],
  [0, 1, 2, 3, 5, 6, 8, 9, 11, 12, 14, 15, 17, 18, 19, 20, 22, 23, 24, 25, 26],
  'character columns match herdr';
ok !defined $wide->{cells}[4], 'a wide character leaves a continuation cell';
is $wide->{col_of}[index $wide->{text}, 'k'], 26, 'text offset to column';

is last_col(parse_row('ab  ')), 1,  'last non-blank column';
is last_col(parse_row('')),     -1, '... none in an empty row';
is last_col(parse_row('a中')),  1,  '... a wide character counts at its first cell';

# --- number column ----------------------------------------------------------

is gutter_width(42),   3, 'number column at least 3 wide';
is gutter_width(3000), 5, '... digits of the row count + 1';
is gutter_text(10, 12, 4), '  2 ', 'other rows: distance from the cursor row';
is gutter_text(12, 12, 4), ' 13 ', 'cursor row: its absolute number, from 1';

# --- drawing a row ----------------------------------------------------------

is render_row(parse_row("\e[31mab\e[0mc"), 0, 5), "\e[0m\e[31mab\e[0mc  \e[0m",
  'a row keeps its SGR, written only when it changes, padded to the width';
is render_row(parse_row('abcdef'), 2, 3), "\e[0mcde\e[0m", 'columns from the view\'s left edge';
my $rev = render_row(parse_row("a\e[7mb"), 0, 2, sub { { rev => 1 } });
like $rev, qr/\e\[0m\e\[7ma/,           'selected cell: reverse video';
like $rev, qr/\e\[0m\e\[7m\e\[27mb/,    '... and a reversed one turned back';
is render_row(parse_row('中x'), 1, 2), "\e[0m x\e[0m", 'a wide character cut at the left edge becomes a space';
is render_row(parse_row('x中'), 0, 2), "\e[0mx \e[0m", '... and at the right edge';
like render_row(parse_row("\e[31mab"), 0, 2, sub { $_[0] == 1 ? { sgr => "\e[44m" } : undef }),
  qr/\e\[0m\e\[31ma\e\[0m\e\[44mb/, 'a search match replaces the cell style';

# --- motions ----------------------------------------------------------------

my @fixture = (
    'alpha beta-gamma  delta',    # 0
    '',                           # 1
    '  indented line',            # 2
    'foo.bar(baz)',               # 3
    '',                           # 4
    'Last line here',             # 5
);
sub fresh {
    my (%a) = @_;
    my $st = new_state(raw => [@fixture], total => scalar @fixture, tw => 30, h => 4, top => 0);
    $st->{cur} = $a{cur} // [0, 0];
    $st->{top} = $a{top} // 0;
    return $st;
}
sub at {
    my ($motion, $from, $count, %a) = @_;
    my $st = fresh(cur => $from, %a);
    move($st, $motion, $count);
    return "@{ $st->{cur} }";
}

is at('w', [0, 0]),  '0 6',  'w: next word';
is at('w', [0, 6]),  '0 10', 'w: punctuation is its own word';
is at('w', [0, 10]), '0 11', 'w: then the word after it';
is at('w', [0, 11]), '0 18', 'w: over two blanks';
is at('w', [0, 18]), '1 0',  'w: an empty row stops it';
is at('w', [1, 0]),  '2 2',  'w: blanks at the start of a row skipped';
is at('w', [0, 0], 3), '0 11', 'w with a count';
is at('W', [0, 6]),  '0 18', 'W: blank-separated';
is at('e', [0, 0]),  '0 4',  'e: end of word';
is at('E', [0, 6]),  '0 15', 'E: end of blank-separated word';
is at('b', [0, 11]), '0 10', 'b: back to punctuation';
is at('B', [0, 18]), '0 6',  'B: back over blank-separated word';
is at('b', [2, 2]),  '1 0',  'b: an empty row stops it too';

is at('$', [0, 0]),  '0 22', '$: last non-blank';
is at('^', [2, 9]),  '2 2',  '^: first non-blank';
is at('0', [2, 9]),  '2 0',  '0: column 0';
is at('l', [0, 0], 5),  '0 5', 'l with a count';
is at('l', [0, 28], 5), '0 29', 'l stops at the last column';
is at('h', [0, 2], 5),  '0 0',  'h stops at column 0';
{
    my $st = fresh(cur => [0, 0]);
    move($st, '$');
    move($st, 'j');
    is "@{ $st->{cur} }", '1 0', 'after $, j onto an empty row';
    move($st, 'j');
    is "@{ $st->{cur} }", '2 14', '... and to the end of the next row';
    move($st, 'k', 2);
    is "@{ $st->{cur} }", '0 22', 'k with a count keeps the end';
}
{
    my $st = fresh(cur => [0, 9]);
    move($st, 'j', 3);
    is "@{ $st->{cur} }", '3 9', 'j keeps the column';
    is $st->{top}, 0, '... still in view';
}
{
    # 30 text columns, 3 of them taken by the number column: 27 in view.
    my $st = fresh(cur => [0, 0]);
    is $st->{left}, 0, 'the view starts at column 0';
    move($st, 'l', 26);
    is $st->{left}, 0, '... and stays there while the cursor is in view';
    move($st, 'l', 2);
    is "$st->{cur}[1] $st->{left}", '28 2', 'past the right edge the view shifts left';
    move($st, '0');
    is $st->{left}, 0, '... and back';
}

is at('}', [0, 5]), '1 0', '}: next empty row';
is at('}', [1, 0]), '4 0', '}: from an empty row, past the paragraph';
is at('}', [4, 0]), '5 0', '}: the last row when no empty row follows';
is at('{', [5, 3]), '4 0', '{: previous empty row';
is at('gg', [5, 3]),    '0 0', 'gg: first row';
is at('G', [0, 0]),     '5 0', 'G: last row';
is at('G', [0, 0], 3),  '2 2', 'NG: row N, at its first non-blank';
is at('H', [5, 0], undef, top => 1), '1 0', 'H: top of the view';
is at('M', [5, 0], undef, top => 1), '2 2', 'M: middle of the view';
is at('L', [1, 0], undef, top => 1), '4 0', 'L: bottom of the view';
is at('L', [1, 0], 2, top => 1),     '3 0', 'L with a count: from the bottom';

{
    my $st = fresh(cur => [5, 0]);
    follow($st);
    is $st->{top}, 2, 'the view follows the cursor down, with no margin';
    $st->{cur} = [0, 0];
    follow($st);
    is $st->{top}, 0, '... and up';
}
{
    my $st = fresh(cur => [0, 0]);
    move($st, 'C-e');
    is "$st->{top} @{ $st->{cur} }", '1 1 0', 'C-e: view down a row, cursor kept in view';
    move($st, 'C-y');
    is "$st->{top} @{ $st->{cur} }", '0 1 0', 'C-y: view up a row, cursor stays';
    move($st, 'C-d');
    is "$st->{top} @{ $st->{cur} }", '2 3 0', 'C-d: half a page, view and cursor';
    move($st, 'C-f');
    is $st->{top}, 2, 'C-f: no further than the last page';
    move($st, 'C-b');
    is $st->{top}, 0, 'C-b: page up';
}

is "@{ start_cursor(fresh(), 0, 4) }", '3 0', 'start: last non-empty row of the view';

# --- search -----------------------------------------------------------------

{
    my $st = fresh(cur => [0, 0]);
    is_deeply search_next($st, 'gamma', 1), [0, 11, 15], '/: next match, its columns';
    is_deeply search_next($st, 'line', 1), [2, 11, 14], '/: lower case matches any case ...';
    $st->{cur} = [2, 11];
    is_deeply search_next($st, 'line', 1), [5, 5, 8], '... in later rows too';
    is search_next($st, 'LINE', 1), undef, 'a capital makes it case-sensitive';
    is_deeply search_next($st, 'Last', 1), [5, 0, 3], '... and it matches the capital';
    $st->{cur} = [5, 0];
    is_deeply search_next($st, 'alpha', 1), [0, 0, 4], '/ wraps at the end';
    is_deeply search_next($st, 'line', -1), [2, 11, 14], '?: backward';
    $st->{cur} = [0, 0];
    is_deeply search_next($st, 'here', -1), [5, 10, 13], '? wraps at the start';
    is_deeply [row_matches(parse_row('中文 abc a'), qr/a/)], [[5, 5], [9, 9]], 'match columns after wide characters';
    is_deeply [row_matches(parse_row('x中文'), qr/中/)], [[1, 2]], 'a wide match covers both cells';
}

# --- selection --------------------------------------------------------------

{
    my $st = fresh(cur => [2, 9]);
    $st->{sel} = { mode => 'v', anchor => [0, 6] };
    ok selected($st, 0, 6) && selected($st, 1, 0) && selected($st, 2, 9), 'v: from the anchor to the cursor';
    ok !selected($st, 0, 5) && !selected($st, 2, 10), '... and nothing outside';
    is_deeply selection_request($st), { anchor => { row => 0, col => 6 }, cursor => { row => 2, col => 9 } },
      'v: the pane.selection.read request';
    is local_text($st), "beta-gamma  delta\n\n  indented", 'v: the text, row by row';

    $st->{cur} = [2, 20];
    is selection_request($st)->{cursor}{col}, 14, 'the end column is clamped to the end of its row';
    $st->{cur} = [0, 0];
    $st->{sel}{anchor} = [0, 9];
    is_deeply selection_request($st), { anchor => { row => 0, col => 0 }, cursor => { row => 0, col => 9 } },
      'ends ordered';
    $st->{cur} = [0, 26];
    $st->{sel}{anchor} = [0, 24];
    is selection_request($st), undef, 'a selection past the end of its row selects nothing';

    $st->{sel} = { mode => 'V', anchor => [2, 5] };
    $st->{cur} = [1, 3];
    is_deeply selection_request($st), { anchor => { row => 1, col => 0 }, cursor => { row => 2, col => 14 } },
      'V: whole rows';
    $st->{cur} = [0, 3];
    $st->{sel}{anchor} = [1, 0];
    is selection_request($st)->{cursor}{col}, 0, 'V: an empty last row ends at column 0';

    $st->{sel} = { mode => 'B', anchor => [0, 0] };
    $st->{cur} = [3, 4];
    ok selected($st, 2, 4) && !selected($st, 2, 5), 'C-v: a rectangle';
    is local_text($st), "alpha\n\n  ind\nfoo.b", 'C-v: the same columns of each row';
}
ok same_text("aaa bbb\nccc", "aaa\nbbb\nccc  "), 'herdr text and the frozen rows agree';
ok !same_text("aaa bbb", "aaa bbX"), '... unless the characters differ';

# --- keys -------------------------------------------------------------------

sub keys_of { my ($k, $rest) = parse_keys($_[0]); return join(',', @$k) . "|$rest" }
is keys_of('jk'), 'j,k|', 'printable keys';
is keys_of("\e[A\e[B\eOC\e[5~\e[6~\e[H\e[F\e[Z"), 'Up,Down,Right,PgUp,PgDn,Home,End,S-Tab|', 'escape sequences';
is keys_of("\x16\x19\x05\r\n\x7f\x03\x00\t"), 'C-v,C-y,C-e,Enter,Enter,BS,C-c,C-Space,Tab|', 'control keys';
is keys_of("j\e"), "j|\e",     'a lone Esc waits for what follows';
is keys_of("\e["), "|\e[",     '... and so does an unfinished sequence';
is keys_of("\eq"), 'Esc,q|',   'Esc followed by a key';
is keys_of("\xc3\xa9"), 'é|',  'UTF-8 decoded';
is keys_of("\xc3"), "|\xc3",   '... a partial one waits';

sub press {
    my ($st, @keys) = @_;
    my @r = map { handle_key($st, $_) } @keys;
    return $r[-1];
}
{
    my $st = fresh(cur => [5, 0]);
    press($st, qw(3 k));
    is $st->{cur}[0], 2, 'a count before a motion';
    press($st, qw(1 0 l));
    is $st->{cur}[1], 10, 'a count of two digits';
    press($st, '0');
    is $st->{cur}[1], 0, '0 with no count is a motion';
    press($st, qw(4 G));
    is $st->{cur}[0], 3, 'NG';
    press($st, qw(g g));
    is $st->{cur}[0], 0, 'gg';
    press($st, qw(G 2 g g));
    is $st->{cur}[0], 1, 'Ngg';
    press($st, '/', 'g', 'a', 'BS', 'a', 'm', 'Enter');
    is "@{ $st->{cur} }", '0 11', 'a / search typed, with a correction';
    press($st, qw(g g n));
    is "@{ $st->{cur} }", '0 11', 'n repeats it';
    press($st, 'N');
    is "@{ $st->{cur} }", '0 11', 'N goes back, wrapping to the only match';
    is press($st, 'y'), 'exit', 'y with no selection exits';
    press($st, 'v', 'e');
    is_deeply $st->{sel}, { mode => 'v', anchor => [0, 11] }, 'v starts a selection at the cursor';
    press($st, 'o');
    is "@{ $st->{cur} } @{ $st->{sel}{anchor} }", '0 11 0 15', 'o swaps the ends';
    press($st, 'C-v');
    is $st->{sel}{mode}, 'B', 'C-v makes it a rectangle';
    press($st, 'C-v');
    is $st->{sel}{mode}, 'v', '... and back';
    is press($st, 'Enter'), 'copy', 'Enter copies a selection';
    is press($st, 'Esc'), 'redraw', 'Esc clears a selection';
    ok !$st->{sel}, '... which is gone';
    is press($st, 'Esc'), 'exit', 'Esc with no selection exits';
    is press($st, 'q'), 'exit', 'q exits';
    is press($st, 'C-c'), 'exit', 'C-c exits';
    press($st, '/', 'x', 'Esc');
    ok !$st->{prompt}, 'Esc cancels the search prompt';

    $st->{prefix} = 'C-Space';
    my $before = "@{ $st->{cur} }";
    is press($st, 'C-Space'), 'none', 'the prefix waits for its key';
    is press($st, 'h'), 'prefix h', '... and hands the pair to the caller';
    is "@{ $st->{cur} }", $before, '... without moving the cursor';
    is press($st, 'C-Space', 'C-Space'), 'none', 'the prefix twice cancels it';
    is press($st, 'h'), 'redraw', '... so the next h is a motion again';
    is press($st, 'C-Space', 'Esc'), 'none', 'Esc cancels the prefix';
    is press($st, '/', 'C-Space', 'a', 'Enter'), 'redraw', 'no prefix while typing a search';
}

# --- prefix bindings --------------------------------------------------------

my $defaults = <<'EOF';
[keys]
# prefix = "ctrl+b"
# detach = "prefix+q"
# focus_pane_left = "prefix+h"
# switch_tab = "prefix+1..9"
# split_vertical = "prefix+v"
# zoom = "prefix+z"       # legacy alias: fullscreen
# cycle_pane_previous = "prefix+shift+tab"
# settings = "prefix+s"
# clear_pane = ""                  # unbound; e.g. "prefix+ctrl+k"
[ui]
# not_a_key = "prefix+y"
EOF
my $config = <<'EOF';
[keys]
prefix = "ctrl+space"
split_horizontal = 'prefix+"'
split_vertical   = "prefix+percent"
detach     = "prefix+d"          # tmux d
settings   = "prefix+shift+s"
close_pane = ""
switch_workspace = "prefix+shift+1..9"
focus_agent = "prefix+alt+1..9"
copy_mode = "prefix+["

[ui]
pane_borders = "always"

[[keys.command]]
key = "prefix+x"
type = "popup"
command = '''bash -c 'echo "hi"' '''

[[keys.command]]
key = "prefix+q"
type = "plugin_action"
command = "dotfiles.panes.display-panes"
description = "display panes"
EOF
my $b = parse_bindings($defaults, $config);
is $b->{prefix}, 'C-Space', 'the prefix from config.toml';
is_deeply $b->{keys}{h}, { action => 'focus_pane_left' }, 'a default binding';
is_deeply $b->{keys}{'"'}, { action => 'split_horizontal' }, 'a literal key';
is_deeply $b->{keys}{'%'}, { action => 'split_vertical' }, 'a named key wins over shift+5';
ok !$b->{keys}{v}, 'a binding config.toml moved is gone from its default key';
is_deeply $b->{keys}{S}, { action => 'settings' }, 'shift+letter';
is_deeply $b->{keys}{3}, { action => 'switch_tab', index => 3 }, 'a range';
is_deeply $b->{keys}{'@'}, { action => 'switch_workspace', index => 2 }, 'shift+digit as the shifted symbol';
is_deeply $b->{keys}{'S-Tab'}, { action => 'cycle_pane_previous' }, 'shift+tab';
is_deeply $b->{keys}{x}, { type => 'popup', command => q{bash -c 'echo "hi"' } }, 'a custom popup command';
is_deeply $b->{keys}{q}, { type => 'plugin_action', command => 'dotfiles.panes.display-panes' },
  'a custom command replaces the default on its key';
is_deeply $b->{keys}{d}, { action => 'detach' }, 'detach where config.toml put it';
ok !grep({ /^M-/ } keys %{ $b->{keys} }), 'alt bindings left out';
is parse_bindings($defaults, '')->{prefix}, 'C-b', "herdr's default prefix";

my $ctx = {
    pane => 'w1:p2', tab => 'w1:t1', workspace => 'w1', cwd => '/w',
    tab_panes  => [qw(w1:p1 w1:p2 w1:p3)],
    tabs       => [{ id => 'w1:t1', number => 1 }, { id => 'w1:t2', number => 2 }],
    workspaces => [{ id => 'w1', number => 1 }, { id => 'w2', number => 2 }],
    last_pane  => 'w1:p3',
};
sub plan_of { plan_binding($_[0], $_[1] // $ctx) }
is_deeply plan_of({ action => 'focus_pane_left' }), { calls => [['pane.focus_direction', { pane_id => 'w1:p2', direction => 'left' }]] },
  'focus a neighbour';
is_deeply plan_of({ action => 'cycle_pane_next' }), { calls => [['pane.focus', { pane_id => 'w1:p3' }]] }, 'next pane';
is_deeply plan_of({ action => 'cycle_pane_next' }, { %$ctx, pane => 'w1:p3' }), { calls => [['pane.focus', { pane_id => 'w1:p1' }]] },
  '... wrapping';
is_deeply plan_of({ action => 'cycle_pane_previous' }), { calls => [['pane.focus', { pane_id => 'w1:p1' }]] }, 'previous pane';
is_deeply plan_of({ action => 'last_pane' }), { calls => [['pane.focus', { pane_id => 'w1:p3' }]] }, 'last pane';
is_deeply plan_of({ action => 'last_pane' }, { %$ctx, last_pane => undef }), { pause => 1 }, '... none known: only pause';
is_deeply plan_of({ action => 'zoom' }), { calls => [['pane.zoom', { pane_id => 'w1:p2', mode => 'toggle' }]], stay => 1 },
  'zoom keeps the pane';
is_deeply plan_of({ action => 'fullscreen' }), plan_of({ action => 'zoom' }), 'fullscreen is zoom';
is_deeply plan_of({ action => 'split_vertical' }),
  { calls => [['pane.split', { target_pane_id => 'w1:p2', direction => 'right', focus => \1, cwd => '/w' }]] },
  'split_vertical: side by side';
is plan_of({ action => 'split_horizontal' })->{calls}[0][1]{direction}, 'down', 'split_horizontal: stacked';
is_deeply plan_of({ action => 'new_tab' }), { calls => [['tab.create', { workspace_id => 'w1', cwd => '/w', focus => \1 }]] },
  'new tab';
is_deeply plan_of({ action => 'next_tab' }), { calls => [['tab.focus', { tab_id => 'w1:t2' }]] }, 'next tab';
is_deeply plan_of({ action => 'previous_tab' }), { calls => [['tab.focus', { tab_id => 'w1:t2' }]] }, 'previous tab, wrapping';
is_deeply plan_of({ action => 'switch_tab', index => 2 }), { calls => [['tab.focus', { tab_id => 'w1:t2' }]] }, 'tab N';
is_deeply plan_of({ action => 'switch_tab', index => 5 }), { pause => 1 }, '... no such tab';
is_deeply plan_of({ action => 'switch_workspace', index => 2 }), { calls => [['workspace.focus', { workspace_id => 'w2' }]] },
  'workspace N';
is_deeply plan_of({ action => 'edit_scrollback' }), { calls => [['pane.edit_scrollback', { pane_id => 'w1:p2' }]] },
  'edit scrollback';
is_deeply plan_of({ action => 'reload_config' }), { calls => [['server.reload_config', {}]], stay => 1 }, 'reload config';
is_deeply plan_of({ action => 'close_pane' }), { calls => [['pane.close', { pane_id => 'w1:p2' }]], end => 1 },
  'closing the pane ends copy mode';
is_deeply plan_of({ action => 'close_tab' }), { calls => [['tab.close', { tab_id => 'w1:t1' }]], end => 1 }, 'closing the tab too';
is_deeply plan_of({ action => 'settings' }), { pause => 1 }, 'a binding only herdr can run: pause';
is_deeply plan_of({ type => 'popup', command => 'x' }), { run => 'x' }, 'a custom popup: run in this popup';
is_deeply plan_of({ type => 'plugin_action', command => 'dotfiles.panes.display-panes' }),
  { plugin => ['dotfiles.panes', 'display-panes'] }, 'a plugin action';
is_deeply plan_of({ type => 'plugin_action', command => 'dotfiles.panes.copy-mode' }), { self => 1 }, 'prefix+] itself';
is_deeply plan_of({ type => 'pane', command => 'x' }), { pause => 1 }, 'other custom commands: pause';

# --- pausing ----------------------------------------------------------------

{
    my $st = fresh(cur => [2, 9], top => 1);
    $st->{left} = 2;
    $st->{sel} = { mode => 'v', anchor => [0, 6] };
    $st->{search} = { query => 'line', dir => -1 };
    my $meta = { pane => 'w1:p2', w => 31, h => 4, total => 6 };
    my $rec = pause_record($st, $meta);
    my $back = resume_state($rec);
    is_deeply [@{$back}{qw(top left)}, @{ $back->{cur} }], [1, 2, 2, 9], 'a paused view comes back as it was';
    is_deeply $back->{sel}, $st->{sel}, '... with its selection';
    is_deeply $back->{search}, $st->{search}, '... and search';
    is $back->{raw}[5], 'Last line here', '... and its frozen rows';
    ok resume_fits($rec, { w => 31, h => 4 }), 'it fits a pane of the same size';
    ok !resume_fits($rec, { w => 61, h => 4 }), '... and not a resized one';
}
is_deeply focus_moved(['a', 'b'], 'c'), ['c', 'a'], 'focus history: the new pane, then the one before';
is_deeply focus_moved(['a', 'b'], 'a'), ['a', 'b'], '... the same pane again changes nothing';
ok returned_to(['b', 'a'], 'a'), 'focus came back to a pane from another';
ok !returned_to(['a', 'b'], 'a'), '... not when it never left';

# --- reading history --------------------------------------------------------

is_deeply [page_tops(10, 4)], [0, 4, 6], 'screens that cover every row, the last one at the bottom';
is_deeply [page_tops(4, 4)],  [0],       'one screen';
is restore_offset(0, 100, 150),  0,  'a pane at the bottom stays there';
is restore_offset(20, 100, 150), 70, 'a scrolled pane keeps its rows in view after output';

# --- drawing the view -------------------------------------------------------

{
    my $st = fresh(cur => [2, 5], top => 1);
    my $out = draw_view($st, { col => 3, row => 2 });
    like $out, qr/\e\[2;3H\e\[0m\e\[38;2;92;99;112m 1 \e\[0m {27}/, 'first view row at the pane, distance 1';
    like $out, qr/\e\[3;3H\e\[0m\e\[38;2;97;175;239m 3 \e\[0m  indented line/,
      'cursor row: its absolute number in accent, the text pushed right of it';
    like $out, qr/\e\[3;11H\e\[2 q\e\[\?25h\z/, 'the terminal cursor on the cursor cell, after the number column';
    $st->{cur} = [0, 28];
    follow($st);
    like draw_view($st, { col => 3, row => 2 }), qr/\e\[2;3H\e\[0m\e\[38;2;97;175;239m 1 \e\[0mpha beta-gamma  delta/,
      'shifted sideways: the row from the view\'s left edge';
    $st->{prompt} = { dir => 1, text => 'ab' };
    like draw_view($st, { col => 3, row => 2 }), qr/\e\[5;3H\e\[0m\/ab {27}\e\[5;6H/, 'the search prompt on the bottom row';
}

done_testing;
