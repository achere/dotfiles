#!/usr/bin/perl
# A copy mode with vim-style relative line numbers, bound to prefix+] (see
# config.toml); herdr's own copy mode stays on prefix+[. `open` is the plugin
# action; `run` is the viewer, inside the popup.
#
# herdr's own copy mode cannot be extended from outside: its state, keys and
# drawing live in the client (src/client/shell/copy_mode.rs), and herdr
# refuses popups while it is open. So this is display-panes' trick again: a
# full-size popup repaints the panes underneath, cell for cell (Panes.pm),
# and the focused pane is drawn by the viewer - its rows with their own
# colours, a number column over their first cells, a cursor, a selection and
# search matches. The number column pushes the text right, as in vim; the
# view shifts sideways when the cursor goes past its right edge. Nothing
# moves the real pane except the history read below, and the popup covers
# that.
#
# History is read once, when the viewer starts, and stays frozen:
# - up to 1000 rows: one pane.read --source recent. It returns at most 1000
#   rows (src/app/api_helpers.rs) and ends at the last row with content or
#   the cursor (ghostty_recent_read_range, src/pane/terminal.rs), so its row
#   i is absolute row i only while it starts at row 0;
# - longer: screen by screen, pane.scroll then pane.read --source visible,
#   ~0.3 ms a screen; the pane is scrolled back right after;
# - an alternate-screen pane (Claude, pi, less) has no history in herdr; the
#   screen read when copy mode opened is all there is.
#
# Copying: v and V ask herdr (pane.selection.read), which joins wrapped
# rows, unless that text differs from the frozen rows (output arrived since);
# a rectangle, and anything on the alternate screen, comes from the frozen
# rows.
#
# herdr gives the popup every key, its prefix too. prefix+<key> runs that
# binding through the API and pauses copy mode; a pane.focused hook reopens
# it when the pane gets focus back (see plan_binding and on_focused).
#
# See docs/superpowers/specs/2026-10-25-herdr-copy-mode-design.md

# The render marker (open_after_render, Panes.pm) starts before anything else
# loads, as in display-panes.pl.
# The pane.focused hook runs on every focus change, so it starts one only
# for a pane with a paused copy mode to reopen.
our $EARLY_MARKER;
BEGIN {
    my $mode = $ARGV[0] // '';
    my $pane = $ENV{HERDR_PANE_ID};
    if ($mode eq 'focused') {
        ($pane) = ($ENV{HERDR_PLUGIN_EVENT_JSON} // '') =~ /"pane_id"\s*:\s*"([^"]+)"/;
        (my $name = $pane // '') =~ s/[^\w.-]/_/g;
        (my $key = $ENV{HERDR_SOCKET_PATH} // 'default') =~ s/[^\w.-]/_/g;
        undef $pane unless $pane && -e "$ENV{HERDR_PLUGIN_STATE_DIR}/$key/paused/$name.json";
    }
    if (($mode eq 'open' || $mode eq 'focused') && $pane) {
        my $pid = open(my $fh, '-|', $ENV{HERDR_BIN_PATH} // 'herdr',
            'terminal', 'session', 'observe', $pane);
        $EARLY_MARKER = { fh => $fh, pid => $pid } if $pid;
    }
}

use strict;
use warnings;
use utf8;
use IO::Select;
use Time::HiRes qw(sleep);
BEGIN { unshift @INC, __FILE__ =~ m{^(.*)/} ? $1 : '.' }
use Panes;

use constant {
    RECENT_MAX  => 1000,     # pane.read's row limit, lines.min(1000)
    ESC_WAIT    => 0.025,    # a lone Esc is Esc when nothing follows it this soon
    MIN_GUTTER  => 3,
    END_OF_ROW  => 1e9,      # the column j/k keep after $
};

my %STYLE = (
    number   => "\e[38;2;$PALETTE{overlay0}m",
    current  => "\e[38;2;$PALETTE{accent}m",
    match    => "\e[38;2;40;44;52;48;2;229;192;123m",    # one-dark yellow
    curmatch => "\e[38;2;40;44;52;48;2;209;154;102m",    # one-dark orange
);

# --- rows -------------------------------------------------------------------

# One ANSI row as cells: [character, SGR in force] for the first cell of a
# character, undef for the second cell of a wide one. SGR is kept as the
# escapes since the last reset, so it is written back unchanged. A character
# is a grapheme cluster, two cells wide when it starts East Asian wide or
# fullwidth or carries VS16 - Ghostty's widths, as pane.selection.read
# reports them for emoji, ZWJ sequences, CJK and combining marks. text is
# the plain characters; col_of maps an offset in text to its column.
sub parse_row {
    my ($s) = @_;
    $s //= '';
    my (@cells, @col_of);
    my ($text, $sgr) = ('', '');
    pos($s) = 0;
    while (pos($s) < length $s) {
        if ($s =~ /\G\e\[([0-9;:]*)m/gc) {
            my $p = $1;
            if    ($p eq '' || $p eq '0') { $sgr = '' }
            elsif ($p =~ s/\A0;//)        { $sgr = "\e[${p}m" }
            else                          { $sgr .= "\e[${p}m" }
        }
        elsif ($s =~ /\G\e\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]/gc) { }    # other CSI
        elsif ($s =~ /\G\e\].*?(?:\a|\e\\)/gcs)                       { }    # OSC, e.g. links
        elsif ($s =~ /\G\e./gcs)                                       { }
        elsif ($s =~ /\G[\x00-\x1f\x7f]/gc)                            { }
        elsif ($s =~ /\G(\X)/gc) {
            my $g = $1;
            push @col_of, (scalar @cells) x length $g;
            $text .= $g;
            push @cells, [$g, $sgr];
            push @cells, undef if $g =~ /\A[\p{Ea=W}\p{Ea=F}]/ || $g =~ /\x{FE0F}/;
        }
        else { last }
    }
    return { cells => \@cells, text => $text, col_of => \@col_of };
}

my $EMPTY_ROW = parse_row('');

# The plain characters of an ANSI row, faster than parse_row: for search.
sub plain {
    my ($s) = @_;
    ($s //= '') =~ s/\e\[[\x30-\x3f]*[\x20-\x2f]*[\x40-\x7e]|\e\].*?(?:\a|\e\\)|\e.|[\x00-\x1f\x7f]//gs;
    return $s;
}

# The last non-blank column (the first cell of its character), or -1.
sub last_col {
    my ($row) = @_;
    my $cells = $row->{cells};
    for (my $c = $#$cells; $c >= 0; $c--) {
        return $c if $cells->[$c] && $cells->[$c][0] =~ /\S/;
    }
    return -1;
}

# Columns lead..lead of the characters that start in [a, b], trailing
# blanks dropped.
sub cells_text {
    my ($row, $a, $b) = @_;
    my $cells = $row->{cells};
    $b = $#$cells if $b > $#$cells;
    my $t = join '', map { $cells->[$_] ? $cells->[$_][0] : '' } $a .. $b;
    $t =~ s/\s+\z//;
    return $t;
}

# Whether an SGR string leaves reverse video on.
sub reversed {
    my ($sgr) = @_;
    my $on = 0;
    while ($sgr =~ /\e\[([0-9;:]*)m/g) {
        my @p = split /;/, $1;
        while (@p) {
            my $x = shift @p;
            if    ($x eq '38' || $x eq '48' || $x eq '58') { splice @p, 0, (($p[0] // '') eq '5' ? 2 : 4) }
            elsif ($x eq '7')  { $on = 1 }
            elsif ($x eq '27') { $on = 0 }
        }
    }
    return $on;
}

# --- number column ----------------------------------------------------------

sub gutter_width {
    my ($total) = @_;
    my $w = length($total) + 1;
    return $w < MIN_GUTTER ? MIN_GUTTER : $w;
}

# The cursor row shows its absolute number, from 1; the others their
# distance from it - vim's number + relativenumber.
sub gutter_text {
    my ($r, $cur, $gw) = @_;
    return sprintf '%*d ', $gw - 1, $r == $cur ? $r + 1 : abs($r - $cur);
}

# --- drawing ----------------------------------------------------------------

# Columns $from .. $from+$width-1 of a row. $overlay->($col) may return
# {sgr} (a search match: replaces the cell's style) or {rev} (selected:
# reverse video on top of its style). Style is written only when it
# changes, always from a reset. A wide character cut by either edge becomes
# a space.
sub render_row {
    my ($row, $from, $width, $overlay) = @_;
    my $cells = $row->{cells};
    my ($out, $prev) = ('', undef);
    my $put = sub {
        my ($ch, $style) = @_;
        $out .= $style if !defined $prev || $style ne $prev;
        $prev = $style;
        $out .= $ch;
    };
    my $style = sub {
        my ($sgr, $o) = @_;
        return "\e[0m$sgr" unless $o;
        return "\e[0m$o->{sgr}" if defined $o->{sgr};
        return "\e[0m$sgr" . (reversed($sgr) ? "\e[27m" : "\e[7m");
    };
    my $end = $from + $width;
    my $c = $from;
    while ($c < $end) {
        my $o = $overlay ? $overlay->($c) : undef;
        my $cell = $c <= $#$cells ? $cells->[$c] : [' ', ''];
        my $wide = $cell && $c + 1 <= $#$cells && !$cells->[ $c + 1 ];
        if (!$cell || ($wide && $c + 1 >= $end)) {
            $put->(' ', $style->(($cell // $cells->[ $c - 1 ])->[1], $o));
            $c++;
            next;
        }
        $put->($cell->[0], $style->($cell->[1], $o));
        $c += $wide ? 2 : 1;
    }
    return $out . "\e[0m";
}

# The overlay for absolute row $r: search matches, selection.
sub overlay {
    my ($st, $r, $row) = @_;
    my @m = $st->{search} ? row_matches($row, search_re($st->{search}{query})) : ();
    my $hit = $st->{hit};
    return sub {
        my ($c) = @_;
        for (@m) {
            next if $c < $_->[0] || $c > $_->[1];
            my $current = $hit && $hit->[0] == $r && $hit->[1] == $_->[0];
            return { sgr => $current ? $STYLE{curmatch} : $STYLE{match} };
        }
        return { rev => 1 } if selected($st, $r, $c);
        return;
    };
}

# The focused pane's view at popup cell $p->{row};$p->{col}: each row's
# number, then its text pushed right of it, from the view's left edge; the
# search prompt on the bottom row; then the terminal cursor - the popup's
# cursor is drawn by herdr (blit_pane_surface, src/client/shell.rs).
sub draw_view {
    my ($st, $p) = @_;
    my ($h, $tw, $gw, $left) = @{$st}{qw(h tw gw left)};
    my ($cr, $cc) = @{ $st->{cur} };
    my $out = '';
    my $prompt = $st->{prompt};
    for my $i (0 .. $h - 1) {
        my $r = $st->{top} + $i;
        $out .= "\e[" . ($p->{row} + $i) . ";$p->{col}H";
        if ($prompt && $i == $h - 1) {
            my $line = ($prompt->{dir} > 0 ? '/' : '?') . $prompt->{text};
            $out .= "\e[0m" . substr($line . ' ' x $tw, 0, $tw);
            next;
        }
        my $row = $r < $st->{total} ? rowp($st, $r) : $EMPTY_ROW;
        $out .= "\e[0m" . ($r == $cr ? $STYLE{current} : $STYLE{number})
          . ($r < $st->{total} ? gutter_text($r, $cr, $gw) : ' ' x $gw);
        $out .= render_row($row, $left, $tw - $gw, overlay($st, $r, $row));
    }
    my ($y, $x) = $prompt
      ? ($h - 1, 1 + length $prompt->{text})
      : ($cr - $st->{top}, $gw + $cc - $left);
    return $out . "\e[" . ($p->{row} + $y) . ';' . ($p->{col} + $x) . "H\e[2 q\e[?25h";
}

# --- state and motions ------------------------------------------------------

# raw: the ANSI rows by absolute row (undef is blank); total: the history's
# rows; tw/h: the pane's text width and height; top: the view's first row.
sub new_state {
    my (%a) = @_;
    my $st = {
        raw    => $a{raw},
        parsed => {},
        total  => $a{total},
        tw     => $a{tw},
        h      => $a{h},
        top    => $a{top} // 0,
        gw     => gutter_width($a{total}),
        left   => 0,     # the view's first text column: it shifts sideways
        count  => '',
        want   => undef,    # the column j/k keep; undef: the cursor's own
    };
    $st->{cur} = start_cursor($st, $st->{top}, $st->{h});
    return $st;
}

sub rowp {
    my ($st, $r) = @_;
    return $st->{parsed}{$r} //= parse_row($st->{raw}[$r]);
}

# The last non-empty row of the view, column 0.
sub start_cursor {
    my ($st, $top, $h) = @_;
    my $bottom = $top + $h - 1;
    $bottom = $st->{total} - 1 if $bottom > $st->{total} - 1;
    my $r = $bottom;
    $r-- while $r > $top && last_col(rowp($st, $r)) < 0;
    return [$r, 0];
}

sub clamp {
    my ($x, $lo, $hi) = @_;
    return $x < $lo ? $lo : $x > $hi ? $hi : $x;
}

sub max_top { my ($st) = @_; my $m = $st->{total} - $st->{h}; return $m > 0 ? $m : 0 }

# Keep the cursor in view with no margin (tmux), down and across. The
# number column takes gw of the pane's tw columns, so the view shows tw - gw
# of a row's and shifts sideways - at most gw - when the cursor goes past
# its edge, as vim does without wrap.
sub follow {
    my ($st) = @_;
    my ($r, $c) = @{ $st->{cur} };
    $st->{top} = $r if $r < $st->{top};
    $st->{top} = $r - $st->{h} + 1 if $r > $st->{top} + $st->{h} - 1;
    $st->{top} = clamp($st->{top}, 0, max_top($st));
    my $vw = $st->{tw} - $st->{gw};
    $st->{left} = $c if $c < $st->{left};
    $st->{left} = $c - $vw + 1 if $c > $st->{left} + $vw - 1;
    $st->{left} = clamp($st->{left}, 0, $st->{gw});
}

# Off the second half of a wide character, onto its first.
sub snap {
    my ($st, $r, $c) = @_;
    my $cells = rowp($st, $r)->{cells};
    $c-- while $c > 0 && $c <= $#$cells && !$cells->[$c];
    return $c;
}

# A column the cursor can take on row $r: inside the text width, on the
# first half of a wide character.
sub fit {
    my ($st, $r, $c) = @_;
    return snap($st, $r, clamp($c, 0, $st->{tw} - 1));
}

# The first non-blank column, or 0.
sub first_text_col {
    my ($st, $r) = @_;
    my $cells = rowp($st, $r)->{cells};
    for my $c (0 .. $#$cells) {
        return $c if $cells->[$c] && $cells->[$c][0] =~ /\S/;
    }
    return 0;
}

# The cursor's column on another row: the one kept from the last
# horizontal move, or the end after $.
sub column_on {
    my ($st, $r) = @_;
    my $want = $st->{want} //= $st->{cur}[1];
    return fit($st, $r, $want == END_OF_ROW ? last_col(rowp($st, $r)) : $want);
}

# Word motions see the history as one stream of cells: a row break is a
# blank, an empty row is a word of its own (vim). class: empty, blank, word
# or punct; with $big, blank or nonblank.
sub row_len { my ($st, $r) = @_; return last_col(rowp($st, $r)) + 1 }

sub class_at {
    my ($st, $r, $c, $big) = @_;
    my $len = row_len($st, $r);
    return 'empty' if $len == 0;
    return 'blank' if $c >= $len;
    my $cells = rowp($st, $r)->{cells};
    my $cell = $cells->[ snap($st, $r, $c) ];
    my $ch = $cell ? $cell->[0] : ' ';
    return 'blank' if $ch =~ /\A\s/;
    return 'nonblank' if $big;
    return $ch =~ /\A\w/ ? 'word' : 'punct';
}

# The next or previous character: (row, col, crossed a row break), or ()
# at the ends of the history.
sub step {
    my ($st, $r, $c, $d) = @_;
    if ($d > 0) {
        my $cells = rowp($st, $r)->{cells};
        my $n = $c + 1;
        $n++ while $n <= $#$cells && !$cells->[$n];
        return ($r, $n, 0) if $n < row_len($st, $r);
        return if $r + 1 >= $st->{total};
        return ($r + 1, 0, 1);
    }
    my $len = row_len($st, $r);
    return ($r, snap($st, $r, $c - 1 < $len ? $c - 1 : $len - 1), 0) if $c > 0 && $len > 0;
    return if $r == 0;
    my $plen = row_len($st, $r - 1);
    return ($r - 1, $plen ? snap($st, $r - 1, $plen - 1) : 0, 1);
}

sub word_forward {
    my ($st, $r, $c, $big) = @_;
    my $cls = class_at($st, $r, $c, $big);
    while (1) {
        my ($nr, $nc, $crossed) = step($st, $r, $c, 1) or return ($r, $c);
        ($r, $c) = ($nr, $nc);
        last if $crossed || $cls eq 'empty' || class_at($st, $r, $c, $big) ne $cls;
    }
    while (class_at($st, $r, $c, $big) eq 'blank') {
        my ($nr, $nc) = step($st, $r, $c, 1) or return ($r, $c);
        ($r, $c) = ($nr, $nc);
    }
    return ($r, $c);
}

sub word_end {
    my ($st, $r, $c, $big) = @_;
    my ($nr, $nc) = step($st, $r, $c, 1) or return ($r, $c);
    ($r, $c) = ($nr, $nc);
    while (class_at($st, $r, $c, $big) =~ /\A(?:blank|empty)\z/) {
        ($nr, $nc) = step($st, $r, $c, 1) or return ($r, $c);
        ($r, $c) = ($nr, $nc);
    }
    my $cls = class_at($st, $r, $c, $big);
    while (my ($mr, $mc, $crossed) = step($st, $r, $c, 1)) {
        last if $crossed || class_at($st, $mr, $mc, $big) ne $cls;
        ($r, $c) = ($mr, $mc);
    }
    return ($r, $c);
}

sub word_back {
    my ($st, $r, $c, $big) = @_;
    my ($nr, $nc) = step($st, $r, $c, -1) or return ($r, $c);
    ($r, $c) = ($nr, $nc);
    while (class_at($st, $r, $c, $big) eq 'blank') {
        ($nr, $nc) = step($st, $r, $c, -1) or return ($r, $c);
        ($r, $c) = ($nr, $nc);
    }
    my $cls = class_at($st, $r, $c, $big);
    return ($r, $c) if $cls eq 'empty';
    while (my ($mr, $mc, $crossed) = step($st, $r, $c, -1)) {
        last if $crossed || class_at($st, $mr, $mc, $big) ne $cls;
        ($r, $c) = ($mr, $mc);
    }
    return ($r, $c);
}

sub blank_row { my ($st, $r) = @_; return row_len($st, $r) == 0 }

# Move the cursor by one motion; $count is undef when none was typed (G
# and gg tell the two apart).
sub move {
    my ($st, $m, $count) = @_;
    my $n = $count // 1;
    my ($r, $c) = @{ $st->{cur} };
    my $last = $st->{total} - 1;
    my $h = $st->{h};
    my $vertical = sub {
        my ($to) = @_;
        $r = clamp($to, 0, $last);
        $c = column_on($st, $r);
    };
    my $line = sub {
        my ($to) = @_;
        $r = clamp($to, 0, $last);
        $c = first_text_col($st, $r);
        $st->{want} = $c;
    };
    my $scroll = sub {    # view and cursor by $d rows
        my ($d, $cursor_too) = @_;
        $st->{top} = clamp($st->{top} + $d, 0, max_top($st));
        $r = clamp($r + $d, 0, $last) if $cursor_too;
        my $bottom = $st->{top} + $h - 1;
        $r = clamp($r, $st->{top}, $bottom < $last ? $bottom : $last);
        $c = column_on($st, $r);
    };

    if    ($m eq 'h') { $c = fit($st, $r, $c - $n); $st->{want} = $c }
    elsif ($m eq 'l') {
        my $cells = rowp($st, $r)->{cells};
        for (1 .. $n) {
            my $next = $c + 1;
            $next++ while $next <= $#$cells && !$cells->[$next];
            last if $next > $st->{tw} - 1;
            $c = $next;
        }
        $c = fit($st, $r, $c);
        $st->{want} = $c;
    }
    elsif ($m eq 'j') { $vertical->($r + $n) }
    elsif ($m eq 'k') { $vertical->($r - $n) }
    elsif ($m =~ /\A[wbeWBE]\z/) {
        my $f = { w => \&word_forward, e => \&word_end, b => \&word_back }->{ lc $m };
        ($r, $c) = $f->($st, $r, $c, scalar $m =~ /[A-Z]/) for 1 .. $n;
        $st->{want} = $c;
    }
    elsif ($m eq '0') { $c = 0;                         $st->{want} = 0 }
    elsif ($m eq '^') { $c = first_text_col($st, $r);   $st->{want} = $c }
    elsif ($m eq '$') {
        $r = clamp($r + $n - 1, 0, $last);
        $c = fit($st, $r, last_col(rowp($st, $r)));
        $st->{want} = END_OF_ROW;
    }
    elsif ($m eq '}') {
        for (1 .. $n) {
            $r++ while $r < $last && blank_row($st, $r);
            $r++ while $r < $last && !blank_row($st, $r);
        }
        $c = 0;
        $st->{want} = 0;
    }
    elsif ($m eq '{') {
        for (1 .. $n) {
            $r-- while $r > 0 && blank_row($st, $r);
            $r-- while $r > 0 && !blank_row($st, $r);
        }
        $c = 0;
        $st->{want} = 0;
    }
    elsif ($m eq 'gg') { $line->(defined $count ? $count - 1 : 0) }
    elsif ($m eq 'G')  { $line->(defined $count ? $count - 1 : $last) }
    elsif ($m =~ /\A[HML]\z/) {
        my $top = $st->{top};
        my $bottom = clamp($top + $h - 1, 0, $last);
        $line->(
              $m eq 'H' ? clamp($top + $n - 1, $top, $bottom)
            : $m eq 'L' ? clamp($bottom - $n + 1, $top, $bottom)
            :             $top + int(($bottom - $top) / 2));
    }
    elsif ($m eq 'C-d') { $scroll->(int($h / 2) * $n, 1) }
    elsif ($m eq 'C-u') { $scroll->(-int($h / 2) * $n, 1) }
    elsif ($m eq 'C-f') { $scroll->($h * $n, 1) }
    elsif ($m eq 'C-b') { $scroll->(-$h * $n, 1) }
    elsif ($m eq 'C-e') { $scroll->($n, 0) }
    elsif ($m eq 'C-y') { $scroll->(-$n, 0) }
    else                { return }
    $st->{cur} = [$r, fit($st, $r, $c)];
    follow($st);
}

# --- search -----------------------------------------------------------------

# Smartcase, as herdr's own search: a capital makes it case-sensitive.
sub search_re {
    my ($q) = @_;
    return $q =~ /\p{Lu}/ ? qr/\Q$q\E/ : qr/\Q$q\E/i;
}

# A row's matches as [first column, last column].
sub row_matches {
    my ($row, $re) = @_;
    my @m;
    my ($text, $col_of, $cells) = @{$row}{qw(text col_of cells)};
    while ($text =~ /$re/g) {
        my ($s, $e) = ($-[0], $+[0] - 1);
        last if $e < $s;
        my ($c1, $c2) = ($col_of->[$s], $col_of->[$e]);
        $c2++ if $c2 + 1 <= $#$cells && !$cells->[ $c2 + 1 ];
        push @m, [$c1, $c2];
    }
    return @m;
}

# The next match from the cursor in direction $dir, wrapping at the ends:
# [row, first column, last column], or undef. A match lies within one row.
sub search_next {
    my ($st, $q, $dir) = @_;
    return if $q eq '';
    my $re = search_re($q);
    my ($cr, $cc) = @{ $st->{cur} };
    my $n = $st->{total};
    for my $i (0 .. $n) {
        my $r = ($cr + $dir * $i) % $n;
        next unless plain($st->{raw}[$r]) =~ $re;
        my @m = row_matches(rowp($st, $r), $re);
        if ($i == 0)  { @m = grep { $dir > 0 ? $_->[0] > $cc : $_->[0] < $cc } @m }
        if ($i == $n) { @m = grep { $dir > 0 ? $_->[0] <= $cc : $_->[0] >= $cc } @m }
        next unless @m;
        return [$r, @{ $dir > 0 ? $m[0] : $m[-1] }];
    }
    return;
}

sub search_move {
    my ($st, $n, $flip) = @_;
    my $s = $st->{search} or return;
    for (1 .. $n) {
        my $hit = search_next($st, $s->{query}, $s->{dir} * $flip) or last;
        $st->{hit} = $hit;
        $st->{cur} = [ $hit->[0], $hit->[1] ];
    }
    $st->{want} = $st->{cur}[1];
    follow($st);
}

# --- selection --------------------------------------------------------------

# The selection's ends in order: ([row, col], [row, col]).
sub sel_ends {
    my ($st) = @_;
    my ($a, $b) = ($st->{sel}{anchor}, $st->{cur});
    return ($a->[0] < $b->[0] || ($a->[0] == $b->[0] && $a->[1] <= $b->[1])) ? ($a, $b) : ($b, $a);
}

sub selected {
    my ($st, $r, $c) = @_;
    my $sel = $st->{sel} or return 0;
    my ($s, $e) = sel_ends($st);
    return 0 if $r < $s->[0] || $r > $e->[0];
    return 1 if $sel->{mode} eq 'V';
    if ($sel->{mode} eq 'B') {
        my ($c1, $c2) = sort { $a <=> $b } $sel->{anchor}[1], $st->{cur}[1];
        return $c >= $c1 && $c <= $c2;
    }
    return 0 if $r == $s->[0] && $c < $s->[1];
    return 0 if $r == $e->[0] && $c > $e->[1];
    return 1;
}

# The pane.selection.read request for v or V: absolute rows, ends in order,
# the end column inclusive and clamped to the end of its row's text (herdr
# refuses a column at the terminal's edge). undef when nothing is selected.
sub selection_request {
    my ($st) = @_;
    my ($s, $e) = sel_ends($st);
    my $lc = last_col(rowp($st, $e->[0]));
    $lc = 0 if $lc < 0;
    my ($ac, $ec) = ($s->[1], $e->[1] < $lc ? $e->[1] : $lc);
    if ($st->{sel}{mode} eq 'V') {
        ($ac, $ec) = (0, $lc);
    } elsif ($s->[0] == $e->[0] && $ec < $ac) {
        return;
    }
    return { anchor => { row => $s->[0], col => $ac }, cursor => { row => $e->[0], col => $ec } };
}

# The selection's text from the frozen rows: one line per row, trailing
# blanks dropped, wrapped rows not joined.
sub local_text {
    my ($st) = @_;
    my ($s, $e) = sel_ends($st);
    my $mode = $st->{sel}{mode};
    my $end = $st->{tw} - 1;
    my ($c1, $c2) = sort { $a <=> $b } $st->{sel}{anchor}[1], $st->{cur}[1];
    my @lines;
    for my $r ($s->[0] .. $e->[0]) {
        my ($a, $b) =
            $mode eq 'B' ? ($c1, $c2)
          : $mode eq 'V' ? (0, $end)
          : ($r == $s->[0] ? $s->[1] : 0, $r == $e->[0] ? $e->[1] : $end);
        push @lines, cells_text(rowp($st, $r), $a, $b);
    }
    return join "\n", @lines;
}

# Whether herdr's text is the frozen rows' text, ignoring where it put line
# breaks and blanks.
sub same_text {
    my ($x, $y) = @_;
    s/\s+//g for $x, $y;
    return $x eq $y;
}

# --- keys -------------------------------------------------------------------

my %SEQ = (
    A => 'Up', B => 'Down', C => 'Right', D => 'Left', H => 'Home', F => 'End',
    '1~' => 'Home', '4~' => 'End', '7~' => 'Home', '8~' => 'End', '5~' => 'PgUp', '6~' => 'PgDn',
    Z => 'S-Tab',
);

# Bytes from the popup's terminal to key names, and what is left over: a
# lone Esc or an unfinished sequence, which the caller makes Esc after
# ESC_WAIT, or a partial UTF-8 character.
sub parse_keys {
    my ($buf) = @_;
    my @keys;
    while (length $buf) {
        if ($buf =~ s/\A\e(?:\[|O)([ABCDHF])//) { push @keys, $SEQ{$1}; next }
        if ($buf =~ s/\A\e\[([0-9;]*[~A-Za-z])//) { push @keys, $SEQ{$1} if $SEQ{$1}; next }
        last if $buf =~ /\A\e(?:\[[0-9;]*|O)?\z/;
        if ($buf =~ s/\A\e//)          { push @keys, 'Esc';   next }
        if ($buf =~ s/\A[\r\n]//)      { push @keys, 'Enter'; next }
        if ($buf =~ s/\A[\x7f\x08]//)  { push @keys, 'BS';    next }
        if ($buf =~ s/\A\t//)          { push @keys, 'Tab';   next }
        if ($buf =~ s/\A\x00//)         { push @keys, 'C-Space'; next }
        if ($buf =~ s/\A([\x00-\x1f])//) { push @keys, 'C-' . chr(ord($1) + 96); next }
        if ($buf =~ s/\A([\x20-\x7e])//) { push @keys, $1; next }
        if ($buf =~ s/\A([\xc2-\xdf][\x80-\xbf]|[\xe0-\xef][\x80-\xbf]{2}|[\xf0-\xf4][\x80-\xbf]{3})//) {
            my $ch = $1;
            utf8::decode($ch);
            push @keys, $ch;
            next;
        }
        last if $buf =~ /\A[\xc2-\xf4][\x80-\xbf]*\z/;
        substr($buf, 0, 1, '');
    }
    return (\@keys, $buf);
}

my %MOTION = (
    h => 'h', Left => 'h', BS => 'h', l => 'l', Right => 'l', ' ' => 'l',
    j => 'j', Down => 'j', 'C-n' => 'j', k => 'k', Up => 'k', 'C-p' => 'k',
    (map { $_ => $_ } qw(w b e W B E 0 ^ $ { } G H M L C-u C-d C-b C-f C-y C-e)),
    Home => '0', End => '$', PgUp => 'C-b', PgDn => 'C-f',
);

# One key: 'exit', 'copy' (the caller copies, then exits), 'redraw', 'none',
# or 'prefix <key>' for herdr's prefix ($st->{prefix}) and the key after it,
# which the caller runs as herdr would (see plan_binding). herdr gives a
# popup every key, its prefix included (route_key_press,
# src/client/shell/input.rs). The prefix twice, or Esc, cancels it.
sub handle_key {
    my ($st, $k) = @_;
    if (my $p = $st->{prompt}) {
        if ($k eq 'Enter') {
            delete $st->{prompt};
            return 'redraw' if $p->{text} eq '';
            $st->{search} = { query => $p->{text}, dir => $p->{dir} };
            search_move($st, 1, 1);
        }
        elsif ($k eq 'Esc' || $k eq 'C-c') { delete $st->{prompt} }
        elsif ($k eq 'BS') { $p->{text} eq '' ? delete $st->{prompt} : chop $p->{text} }
        elsif (length $k == 1) { $p->{text} .= $k }
        return 'redraw';
    }

    if (defined(my $prefix = $st->{prefix})) {
        if (delete $st->{prefix_armed}) {
            return 'none' if $k eq $prefix || $k eq 'Esc';
            return "prefix $k";
        }
        if ($k eq $prefix) {
            $st->{prefix_armed} = 1;
            $st->{count} = '';
            delete $st->{pending};
            return 'none';
        }
    }

    my $count = $st->{count};
    if ($k =~ /\A[1-9]\z/ || ($k eq '0' && $count ne '')) {
        $st->{count} .= $k;
        return 'none';
    }
    $st->{count} = '';
    my $n = $count eq '' ? 1 : $count;
    my $typed = $count eq '' ? undef : $count;

    if (defined(my $pending = delete $st->{pending})) {
        return 'none' unless $k eq 'g';
        move($st, 'gg', $pending eq '' ? undef : $pending);
        return 'redraw';
    }
    if ($k eq 'g') { $st->{pending} = $count; return 'none' }

    if (defined(my $m = $MOTION{$k})) { move($st, $m, $typed); return 'redraw' }
    if ($k eq '/' || $k eq '?') { $st->{prompt} = { dir => $k eq '/' ? 1 : -1, text => '' }; return 'redraw' }
    if ($k eq 'n' || $k eq 'N') { search_move($st, $n, $k eq 'n' ? 1 : -1); return 'redraw' }

    my $sel = $st->{sel};
    if ($k eq 'v' || $k eq 'V') {
        if ($sel && $sel->{mode} eq $k) { delete $st->{sel} }
        elsif ($sel)                    { $sel->{mode} = $k }
        else                            { $st->{sel} = { mode => $k, anchor => [ @{ $st->{cur} } ] } }
        return 'redraw';
    }
    if ($k eq 'C-v') {
        if ($sel) { $sel->{mode} = $sel->{mode} eq 'B' ? 'v' : 'B' }
        else      { $st->{sel} = { mode => 'B', anchor => [ @{ $st->{cur} } ] } }
        return 'redraw';
    }
    if ($k eq 'o' && $sel) {
        ($sel->{anchor}, $st->{cur}) = ($st->{cur}, $sel->{anchor});
        $st->{want} = $st->{cur}[1];
        follow($st);
        return 'redraw';
    }
    return $sel ? 'copy' : 'exit' if $k eq 'y' || $k eq 'Enter';
    if ($k eq 'Esc') {
        return 'exit' unless $sel;
        delete $st->{sel};
        return 'redraw';
    }
    return 'exit' if $k eq 'q' || $k eq 'C-c';
    return 'none';
}

# --- prefix bindings --------------------------------------------------------

# The quoted strings of a TOML value, up to a comment: one, or an array of
# them. "..." (with escapes), '...' and '''...''' on one line.
sub toml_strings {
    my ($v) = @_;
    my @s;
    while (length $v) {
        if    ($v =~ s/\A'''(.*?)'''//)        { push @s, $1 }
        elsif ($v =~ s/\A"((?:[^"\\]|\\.)*)"//) { (my $x = $1) =~ s/\\(.)/$1/g; push @s, $x }
        elsif ($v =~ s/\A'([^']*)'//)           { push @s, $1 }
        elsif ($v =~ s/\A[\s,\[]+//)            { }
        else                                    { last }    # ], a comment, or anything else
    }
    return @s;
}

# herdr's names for keys (parse_key_combo, src/config/keybinds.rs), as the
# characters a popup receives.
my %KEY_NAME = (
    space => ' ', minus => '-', comma => ',', period => '.', slash => '/', backslash => '\\',
    quote => "'", double_quote => '"', 'double-quote' => '"', semicolon => ';', colon => ':',
    percent => '%', ampersand => '&', backtick => '`', plus => '+',
    tab => 'Tab', enter => 'Enter', return => 'Enter', esc => 'Esc', escape => 'Esc',
    backspace => 'BS', bs => 'BS', left => 'Left', right => 'Right', up => 'Up', down => 'Down',
);
my @SHIFTED_DIGIT = split //, '!@#$%^&*(';    # US layout, as herdr's shifted_number_symbol

# The keys a prefix binding answers to after the prefix, as parse_keys names
# them: ([key, index], ...), index for a 1..9 range. Not a prefix binding,
# alt, or a key a popup cannot tell apart: ().
sub binding_keys {
    my ($bind) = @_;
    return unless $bind =~ /\Aprefix\+(.+)\z/;
    my $rest = $1;
    my %mod;
    $mod{ lc $1 } = 1 while $rest =~ s/\A(shift|ctrl|alt)\+(?=.)//i;
    return if $mod{alt};
    if ($rest eq '1..9') {
        return map { [ $mod{shift} ? $SHIFTED_DIGIT[ $_ - 1 ] : "$_", $_ ] } 1 .. 9;
    }
    my $key = $KEY_NAME{ lc $rest } // (length $rest == 1 ? $rest : return);
    if ($key eq 'Tab' && $mod{shift}) { $key = 'S-Tab' }
    elsif ($mod{ctrl})  { return unless $key =~ /\A[a-z]\z/i; $key = 'C-' . lc $key }
    elsif ($mod{shift}) { $key = $key =~ /\A[1-9]\z/ ? $SHIFTED_DIGIT[ $key - 1 ] : uc $key }
    return [$key];
}

# herdr's prefix in parse_keys' names: ctrl+space or ctrl+<letter>.
sub prefix_key {
    my ($bind) = @_;
    return 'C-Space' if $bind =~ /\Actrl\+space\z/i;
    return 'C-' . lc $1 if $bind =~ /\Actrl\+([a-z])\z/i;
    return;
}

# The prefix and what each key after it is bound to, from herdr's default
# config (`herdr --default-config`, its bindings commented out) and
# config.toml (which replaces an action's default keys). {keys}{key} is
# {action, index} or a [[keys.command]]'s {type, command}. A key bound by
# name beats the same character from a shift+digit range: a popup gets '%'
# for both prefix+percent and prefix+shift+5. Custom commands come last.
sub parse_bindings {
    my ($defaults, $config) = @_;
    my (%action, @commands);
    my $prefix = 'ctrl+b';
    for my $src ([$defaults, 1], [$config, 0]) {
        my ($text, $commented) = @$src;
        my ($section, $cmd) = ('');
        for my $line (split /\n/, $text // '') {
            if ($line =~ /\A\s*\[\[\s*keys\.command\s*\]\]/) {
                push @commands, $cmd = {};
                $section = 'command';
                next;
            }
            if ($line =~ /\A\s*\[([^\]]+)\]/) { ($section, $cmd) = ($1, undef); next }
            my $body = $line;
            if ($commented) {
                next unless $body =~ s/\A\s*#\s?//;
                if ($body =~ /\A\s*\[/) { $section = 'example'; next }
            } elsif ($body =~ /\A\s*#/) {
                next;
            }
            next unless $body =~ /\A\s*([\w-]+)\s*=\s*(.*)\z/;
            my ($k, $v) = ($1, $2);
            if ($section eq 'command') { ($cmd->{$k}) = toml_strings($v) if $cmd; next }
            next unless $section eq 'keys';
            if ($k eq 'prefix') { ($prefix) = toml_strings($v); next }
            $action{$k} = [ toml_strings($v) ];
        }
    }
    my (%keys, @named);
    for my $act (sort keys %action) {
        for my $bind (@{ $action{$act} }) {
            for my $kb (binding_keys($bind)) {
                my ($key, $index) = @$kb;
                my $entry = defined $index ? { action => $act, index => $index } : { action => $act };
                if ($bind =~ /\+shift\+1\.\.9\z/) { $keys{$key} = $entry } else { push @named, [$key, $entry] }
            }
        }
    }
    $keys{ $_->[0] } = $_->[1] for @named;
    for my $c (@commands) {
        next unless defined $c->{key};
        $keys{ $_->[0] } = { type => $c->{type} // '', command => $c->{command} // '' } for binding_keys($c->{key});
    }
    return { prefix => prefix_key($prefix // '') // 'C-b', keys => \%keys };
}

# How copy mode runs a prefix binding through herdr's API, in $ctx's pane
# (pane, tab, workspace, cwd, tab_panes in layout order, tabs and workspaces
# as {id, number}, last_pane). The plan is one of:
#   {calls => [[method, params], ...]} - focus goes elsewhere;
#   ... with stay => 1 - the same pane stays focused, copy mode reopens;
#   ... with end => 1  - the pane or tab goes away, copy mode with it;
#   {run => command}   - a [[keys.command]] popup, run in this popup;
#   {plugin => [id, action]}, {self => 1} (prefix+] itself);
#   {pause => 1}       - only herdr can run it: pause, it is pressed again.
sub plan_binding {
    my ($bind, $ctx) = @_;
    my ($pane, $tab, $ws) = @{$ctx}{qw(pane tab workspace)};
    if (defined $bind->{type}) {
        return { run => $bind->{command} } if $bind->{type} eq 'popup';
        if ($bind->{type} eq 'plugin_action' && $bind->{command} =~ /\A(.+)\.([^.]+)\z/) {
            return { self => 1 } if $1 eq Panes::PLUGIN_ID && $2 eq 'copy-mode';
            return { plugin => [$1, $2] };
        }
        return { pause => 1 };
    }
    my $act = $bind->{action};
    my $go = sub { { calls => [@_] } };
    my $around = sub {    # the item $d after $cur in @$list, wrapping
        my ($list, $cur, $d) = @_;
        my ($i) = grep { $list->[$_] eq $cur } 0 .. $#$list;
        return defined $i ? $list->[ ($i + $d) % @$list ] : undef;
    };
    my @tabs = map { $_->{id} } sort { $a->{number} <=> $b->{number} } @{ $ctx->{tabs} };
    if ($act =~ /\Afocus_pane_(left|right|up|down)\z/) {
        return $go->(['pane.focus_direction', { pane_id => $pane, direction => $1 }]);
    }
    if ($act =~ /\Acycle_pane_(next|previous)\z/) {
        my $to = $around->($ctx->{tab_panes}, $pane, $1 eq 'next' ? 1 : -1) // return { pause => 1 };
        return $go->(['pane.focus', { pane_id => $to }]);
    }
    if ($act eq 'last_pane') {
        my $to = $ctx->{last_pane} // return { pause => 1 };
        return $go->(['pane.focus', { pane_id => $to }]);
    }
    if ($act eq 'zoom' || $act eq 'fullscreen') {
        return { calls => [['pane.zoom', { pane_id => $pane, mode => 'toggle' }]], stay => 1 };
    }
    if ($act =~ /\Asplit_(vertical|horizontal)\z/) {
        return $go->(['pane.split', { target_pane_id => $pane, direction => $1 eq 'vertical' ? 'right' : 'down',
            focus => \1, cwd => $ctx->{cwd} }]);
    }
    return $go->(['tab.create', { workspace_id => $ws, cwd => $ctx->{cwd}, focus => \1 }]) if $act eq 'new_tab';
    if ($act =~ /\A(next|previous)_tab\z/) {
        my $to = $around->(\@tabs, $tab, $1 eq 'next' ? 1 : -1) // return { pause => 1 };
        return $go->(['tab.focus', { tab_id => $to }]);
    }
    if ($act eq 'switch_tab' || $act eq 'switch_workspace') {
        my $list = $act eq 'switch_tab' ? $ctx->{tabs} : $ctx->{workspaces};
        my ($to) = map { $_->{id} } grep { $_->{number} == $bind->{index} } @$list;
        return { pause => 1 } unless defined $to;
        return $go->($act eq 'switch_tab' ? ['tab.focus', { tab_id => $to }] : ['workspace.focus', { workspace_id => $to }]);
    }
    return $go->(['pane.edit_scrollback', { pane_id => $pane }]) if $act eq 'edit_scrollback';
    return { calls => [['server.reload_config', {}]], stay => 1 } if $act eq 'reload_config';
    return { calls => [['pane.close', { pane_id => $pane }]], end => 1 } if $act eq 'close_pane';
    return { calls => [['tab.close', { tab_id => $tab }]], end => 1 } if $act eq 'close_tab';
    return { pause => 1 };
}

# --- pausing ----------------------------------------------------------------

# A paused copy mode, as saved to resume it: the view's state and the
# frozen rows, with the meta it was opened with.
sub pause_record {
    my ($st, $meta) = @_;
    return { meta => $meta, raw => $st->{raw}, map { ($_ => $st->{$_}) } qw(cur want top left sel search hit) };
}

sub resume_state {
    my ($rec) = @_;
    my $m = $rec->{meta};
    my $st = new_state(raw => $rec->{raw}, total => $m->{total}, tw => $m->{tw} // $m->{w} - 1, h => $m->{h},
        top => $rec->{top});
    $st->{$_} = $rec->{$_} for grep { defined $rec->{$_} } qw(cur want left sel search hit);
    return $st;
}

# A paused view resumes only on a pane of the size it was frozen at: after a
# zoom or resize the pane's rows are laid out again.
sub resume_fits {
    my ($rec, $f) = @_;
    return $rec->{meta}{w} == $f->{w} && $rec->{meta}{h} == $f->{h};
}

# Focus history [current, previous] after $pane is focused.
sub focus_moved {
    my ($hist, $pane) = @_;
    return $hist if ($hist->[0] // '') eq $pane;
    return [$pane, $hist->[0]];
}

# Whether focus came to $pane from another one, by the history before it.
sub returned_to {
    my ($hist, $pane) = @_;
    return ($hist->[0] // '') ne $pane;
}

# --- reading history --------------------------------------------------------

# The tops of the screens that cover rows 0..total-1, top to bottom; the
# last one ends at the bottom.
sub page_tops {
    my ($total, $vp) = @_;
    my $max = $total - $vp;
    my @tops;
    for (my $t = 0; ; $t += $vp) {
        push @tops, $t < $max ? $t : $max > 0 ? $max : 0;
        last if $t + $vp >= $total;
    }
    return @tops;
}

# The offset that shows the same rows as $off0 did, after the history grew
# from $max0 to $max_now rows above the screen. A pane at the bottom stays
# there.
sub restore_offset {
    my ($off0, $max0, $max_now) = @_;
    return 0 if $off0 == 0;
    return $off0 + $max_now - $max0;
}

# --- side effects -----------------------------------------------------------

sub metrics {
    my ($pane) = @_;
    my $r = api('pane.get', { pane_id => $pane }) or return;
    return $r->{pane}{scroll};
}

sub split_rows { return [ split /\r?\n/, $_[0] // '' ] }

# The rows of a history of at most RECENT_MAX rows, or undef when it grew
# past that while being read.
sub read_recent {
    my ($pane) = @_;
    my $before = metrics($pane) or return;
    my $r = api('pane.read', { pane_id => $pane, source => 'recent', format => 'ansi', lines => RECENT_MAX });
    my $after = metrics($pane) or return;
    for ($before, $after) {
        return if $_->{max_offset_from_bottom} + $_->{viewport_rows} > RECENT_MAX;
    }
    return $r && split_rows($r->{read}{text});
}

# Scroll back to where the pane was, if a read left it elsewhere: right
# after the read, and from END if the viewer dies during it.
our $RESTORE;
sub restore_scroll {
    my $r = $RESTORE or return;
    undef $RESTORE;
    my $now = metrics($r->{pane}) or return;
    api('pane.scroll', { pane_id => $r->{pane},
        offset_from_bottom => restore_offset($r->{off}, $r->{max}, $now->{max_offset_from_bottom}) });
}
END { restore_scroll() }

# Every row, screen by screen. A screen's top comes from the pane.scroll
# reply, since output moves the offset; one read while the history grew is
# read again.
sub read_pages {
    my ($pane, $meta) = @_;
    my @raw;
    my $max = $meta->{max};
    $RESTORE = { pane => $pane, off => $meta->{off}, max => $meta->{max} };
    for my $top (page_tops($meta->{total}, $meta->{vp})) {
        for (1 .. 3) {
            my $off = $max - $top;
            my $r = api('pane.scroll', { pane_id => $pane, offset_from_bottom => $off < 0 ? 0 : $off }) or last;
            my $sc = $r->{pane}{scroll};
            my $t = $sc->{max_offset_from_bottom} - $sc->{offset_from_bottom};
            my $v = api('pane.read', { pane_id => $pane, source => 'visible', format => 'ansi' });
            my $after = metrics($pane) or last;
            $max = $after->{max_offset_from_bottom};
            next if $max != $sc->{max_offset_from_bottom};
            my $rows = split_rows($v && $v->{read}{text});
            @raw[ $t .. $t + $#$rows ] = @$rows;
            last;
        }
    }
    restore_scroll();
    return \@raw;
}

# The frozen history: rows by absolute row, the open-time view on top.
sub load_history {
    my ($meta, $visible) = @_;
    my $pane = $meta->{pane};
    my $raw = [];
    if ($meta->{max} > 0) {
        $raw = ($meta->{total} <= RECENT_MAX && read_recent($pane)) || read_pages($pane, $meta);
    }
    @$raw[ $meta->{top} .. $meta->{top} + $#$visible ] = @$visible;
    splice @$raw, $meta->{total} if @$raw > $meta->{total};
    return $raw;
}

# The focused pane, where the viewer draws: in a zoomed tab it covers the
# whole area (the snapshot keeps the unzoomed rects).
sub focused_pane {
    my ($lay) = @_;
    my ($f) = grep { $_->{id} eq $lay->{focused} } @{ $lay->{panes} } or return;
    return $f unless $lay->{zoomed};
    return { %$f, col => 1, row => 1, w => $lay->{area}{width} - 2, h => $lay->{area}{height} - 2 };
}

# The focused pane's chrome with the scrollbar at the view's place.
sub chrome {
    my ($st, $f, $lay) = @_;
    my $max = $st->{total} - $st->{h};
    $max = 0 if $max < 0;
    return pane_chrome({ %$f, focused => 1, max => $max, off => $max - $st->{top}, vp => $st->{h} }, $lay);
}

sub geometry_lay { my ($m) = @_; return { rows => $m->{lay_rows}, cols => $m->{lay_cols} } }

# --- pausing: files ---------------------------------------------------------

# Paused views and the focus history are kept per herdr session, by its
# socket: the plugin's state dir is one for all sessions
# (plugin_state_dir, src/plugin_paths.rs), and pane ids repeat across them.
my $SESSION_DIR = do {
    (my $key = $ENV{HERDR_SOCKET_PATH} // 'default') =~ s/[^\w.-]/_/g;
    ($ENV{HERDR_PLUGIN_STATE_DIR} // $ENV{TMPDIR} // '/tmp') . "/$key";
};

sub paused_path {
    my ($pane) = @_;
    (my $name = $pane) =~ s/[^\w.-]/_/g;
    return "$SESSION_DIR/paused/$name.json";
}

sub write_bytes {
    my ($path, $bytes) = @_;
    open my $fh, '>:raw', "$path.tmp" or die "copy-mode: $path: $!\n";
    print {$fh} $bytes;
    close $fh;
    rename "$path.tmp", $path or die "copy-mode: $path: $!\n";
}

sub read_bytes {
    my ($path) = @_;
    open my $fh, '<:raw', $path or return;
    local $/;
    return scalar <$fh>;
}

sub save_paused {
    my ($st, $meta) = @_;
    mkdir $_, 0700 for $SESSION_DIR, "$SESSION_DIR/paused";
    write_bytes(paused_path($meta->{pane}), json()->encode(pause_record($st, $meta)));
}

sub load_paused {
    my ($pane) = @_;
    my $bytes = read_bytes(paused_path($pane)) // return;
    return eval { json()->decode($bytes) };
}

sub drop_paused { unlink paused_path($_[0]) }

# Focus history [current, previous], kept by the pane.focused hook: for
# last_pane, and to tell a return to a paused pane from staying on it.
sub read_focus { my @l = read_lines("$SESSION_DIR/focus"); return [ @l[0, 1] ] }
sub write_focus {
    mkdir $SESSION_DIR, 0700;
    write_file("$SESSION_DIR/focus", join '', map { ($_ // '') . "\n" } @{ $_[0] });
}

# --- opening ----------------------------------------------------------------

sub current_layout {
    return layout((api('session.snapshot', {}) // die "copy-mode: no snapshot\n")->{snapshot}, 1);
}

sub write_meta {
    my ($path, $meta) = @_;
    write_file($path, join '', map { "$_=$meta->{$_}\n" } sort keys %$meta);
}

# Build the first frame - the other panes as they are, the focused one from
# $st - and open the popup on it. %$files go into the state dir for run, as
# bytes.
sub open_view {
    my ($m, $lay, $f, $st, $meta, $files) = @_;
    my @others = $lay->{zoomed} ? () : grep { $_->{id} ne $f->{id} } @{ $lay->{panes} };
    my $frame = frame_start();
    $frame .= pane_lines($_, $lay, pane_text($_->{id})) . pane_chrome($_, $lay) for @others;
    $frame .= chrome($st, $f, $lay) . draw_view($st, $f) . frame_end();

    my $state = make_state();
    my $ok = eval {
        write_file("$state/frame", $frame);
        write_meta("$state/meta", $meta);
        write_bytes("$state/$_", $files->{$_}) for keys %$files;
        $m //= marker($f->{id});
        # e.g. ui_busy while herdr's Copy mode, Settings or another popup is open
        open_after_render($m, $f->{id}, 'copy', { COPY_MODE_STATE => $state })
          or die "copy-mode: popup refused\n";
        1;
    };
    return 1 if $ok;
    remove_state($state);
    die $@;
}

# A new copy mode on the focused pane. A visible read and its scroll numbers
# must belong together, so it is read again if the history grew in between.
sub fresh_view {
    my ($m, $lay, $f) = @_;
    my ($sc, $text);
    for (1 .. 3) {
        my $before = metrics($f->{id}) or die "copy-mode: no pane $f->{id}\n";
        $text = pane_text($f->{id});
        $sc = metrics($f->{id}) or die "copy-mode: no pane $f->{id}\n";
        last if $sc->{max_offset_from_bottom} == $before->{max_offset_from_bottom};
    }
    my %meta = (
        pane => $f->{id}, col => $f->{col}, row => $f->{row}, w => $f->{w}, h => $f->{h},
        tw => $f->{w} - 1,    # the terminal leaves the last column to the scrollbar
        max => $sc->{max_offset_from_bottom}, off => $sc->{offset_from_bottom}, vp => $sc->{viewport_rows},
        lay_rows => $lay->{rows}, lay_cols => $lay->{cols},
    );
    $meta{total} = $meta{max} + $meta{vp};
    $meta{top}   = $meta{max} - $meta{off};
    my $visible = split_rows($text);
    my @raw;
    @raw[ $meta{top} .. $meta{top} + $#$visible ] = @$visible;
    my $st = new_state(raw => \@raw, total => $meta{total}, tw => $meta{tw}, h => $meta{h}, top => $meta{top});
    @meta{qw(cur_row cur_col)} = @{ $st->{cur} };
    my $bytes = $text;
    utf8::encode($bytes);
    return open_view($m, $lay, $f, $st, \%meta, { visible => $bytes });
}

# A paused copy mode back on its pane, where the pane is now on screen.
sub resume_view {
    my ($m, $lay, $f, $rec) = @_;
    my $st = resume_state($rec);
    my %meta = (%{ $rec->{meta} }, col => $f->{col}, row => $f->{row},
        lay_rows => $lay->{rows}, lay_cols => $lay->{cols});
    return open_view($m, $lay, $f, $st, \%meta, { resume => json()->encode($rec) });
}

# Copy mode on the focused pane: its paused one if it has one that still
# fits, else a new one. The paused one is dropped once the popup is open.
sub open_on_focused {
    my ($m) = @_;
    my $lay = current_layout();
    my $f = focused_pane($lay) or die "copy-mode: no focused pane\n";
    my $rec = load_paused($f->{id});
    $rec && resume_fits($rec, $f) ? resume_view($m, $lay, $f, $rec) : fresh_view($m, $lay, $f);
    drop_paused($f->{id});
    return $f->{id};
}

# The plugin action, prefix+].
sub open_copy {
    open_on_focused($EARLY_MARKER ? marker(undef, $EARLY_MARKER) : undef);
}

# The pane.focused hook: keep the focus history, and when focus comes back
# to a paused pane from another one, reopen its copy mode. A popup's own
# pane is not in any layout and is left out. Paused panes that are gone are
# forgotten.
sub on_focused {
    my ($pane) = ($ENV{HERDR_PLUGIN_EVENT_JSON} // '') =~ /"pane_id"\s*:\s*"([^"]+)"/;
    $pane //= $ENV{HERDR_PANE_ID} // return;
    my $s = (api('session.snapshot', {}) // return)->{snapshot};
    my %live = map { $_->{pane_id} => 1 } map { @{ $_->{panes} } } @{ $s->{layouts} };
    return unless $live{$pane};
    my %live_file = map { paused_path($_) => 1 } keys %live;
    unlink grep { !$live_file{$_} } glob "$SESSION_DIR/paused/*.json";

    my $hist = read_focus();
    my $now = focus_moved($hist, $pane);
    write_focus($now) if $now != $hist;
    return unless -e paused_path($pane) && returned_to($hist, $pane) && $s->{focused_pane_id} eq $pane;
    open_on_focused($EARLY_MARKER ? marker(undef, $EARLY_MARKER) : undef);
}

# --- running prefix bindings ------------------------------------------------

sub config_text {
    my $path = $ENV{HERDR_CONFIG_PATH} // "$ENV{HOME}/.config/herdr/config.toml";
    my $bytes = read_bytes($path) // '';
    utf8::decode($bytes);
    return $bytes;
}

my $BINDINGS;
sub bindings {
    return $BINDINGS //= do {
        my $herdr = $ENV{HERDR_BIN_PATH} // 'herdr';
        my $defaults = `"$herdr" --default-config 2>/dev/null`;
        utf8::decode($defaults);
        parse_bindings($defaults, config_text());
    };
}

# What plan_binding needs to know about $pane, from a snapshot.
sub context {
    my ($pane) = @_;
    my $s = (api('session.snapshot', {}) // {})->{snapshot} // {};
    my ($p) = grep { $_->{pane_id} eq $pane } @{ $s->{panes} // [] };
    $p //= {};
    my ($l) = grep { $_->{tab_id} eq ($p->{tab_id} // '') } @{ $s->{layouts} // [] };
    my $last = read_focus()->[1];
    return {
        pane => $pane, tab => $p->{tab_id}, workspace => $p->{workspace_id}, cwd => $p->{cwd},
        tab_panes  => [ map { $_->{pane_id} } @{ $l->{panes} // [] } ],
        tabs       => [ map { +{ id => $_->{tab_id}, number => $_->{number} } }
                        grep { $_->{workspace_id} eq ($p->{workspace_id} // '') } @{ $s->{tabs} // [] } ],
        workspaces => [ map { +{ id => $_->{workspace_id}, number => $_->{number} } } @{ $s->{workspaces} // [] } ],
        last_pane  => defined $last && $last ne '' && $last ne $pane ? $last : undef,
    };
}

# Run copy-mode.pl later <this pid> @args once this viewer has exited:
# detached, so herdr closing the popup does not take it along.
sub after_exit {
    my (@args) = @_;
    my $parent = $$;
    defined(my $pid = fork) or return;
    return if $pid;
    require POSIX;
    POSIX::setsid();
    open STDIN, '<', '/dev/null';
    open STDOUT, '>', '/dev/null';
    open STDERR, '>', '/dev/null';
    exec('perl', $0, 'later', $parent, @args) or POSIX::_exit(1);
}

# After the viewer that started it has exited and herdr has closed its
# popup: reopen copy mode on a pane that kept focus (retried while herdr
# still refuses popups), or run a plugin action.
sub later {
    my ($parent, $what, @a) = @_;
    for (1 .. 200) { last unless kill 0, $parent; sleep 0.005 }
    sleep 0.03;
    if ($what eq 'plugin') {
        api('plugin.action.invoke', { plugin_id => $a[0], action_id => $a[1] });
        return;
    }
    my ($pane) = @a;
    for (1 .. 25) {
        my $lay = eval { current_layout() } or last;
        return unless $lay->{focused} eq $pane && -e paused_path($pane);
        return if eval { open_on_focused(undef); 1 };
        sleep 0.04;
    }
}

# A [[keys.command]] popup command, in this popup: cooked mode back, the
# screen cleared, then the command, as herdr would run it in its own popup.
sub run_command {
    my ($cmd) = @_;
    print "\e[0m\e[2J\e[H\e[?25h";
    system 'stty', 'sane';
    system '/bin/sh', '-c', $cmd;
}

# prefix+$key from inside copy mode: 1 when copy mode is done here (paused,
# or ended with its pane), 0 to carry on (unbound, or prefix+] itself).
sub run_prefix {
    my ($st, $meta, $key) = @_;
    my $bind = bindings()->{keys}{$key} or return 0;    # unbound: herdr does nothing either
    my $pane = $meta->{pane};
    my $plan = plan_binding($bind, context($pane));
    return 0 if $plan->{self};
    if ($plan->{end}) {
        api(@$_) for @{ $plan->{calls} };
        return 1;
    }
    save_paused($st, $meta);
    if (defined $plan->{run}) {
        run_command($plan->{run});
        after_exit('resume', $pane);
    } elsif ($plan->{plugin}) {
        after_exit('plugin', @{ $plan->{plugin} });
    } else {
        # Applied while the popup still covers the panes, so the screen it
        # uncovers is the final one.
        api(@$_) for @{ $plan->{calls} // [] };
        after_exit('resume', $pane) if $plan->{stay};
    }
    return 1;
}

# --- the viewer -------------------------------------------------------------

sub raw_mode {
    require POSIX;
    my $t = POSIX::Termios->new;
    return unless $t->getattr(0);
    $t->setlflag($t->getlflag & ~(POSIX::ECHO() | POSIX::ICANON() | POSIX::ISIG() | POSIX::IEXTEN()));
    $t->setiflag($t->getiflag & ~(POSIX::IXON() | POSIX::ICRNL()));
    $t->setcc(POSIX::VMIN(), 1);
    $t->setcc(POSIX::VTIME(), 0);
    $t->setattr(0, POSIX::TCSANOW());
}

# An empty selection leaves the clipboard as it was.
sub pbcopy {
    my ($text) = @_;
    return if $text eq '';
    local $ENV{LANG} = 'en_US.UTF-8';    # pbcopy decodes its input by the locale
    open my $pb, '|-', 'pbcopy' or return;
    binmode $pb, ':encoding(UTF-8)';
    print {$pb} $text;
    close $pb;
}

sub copy_text {
    my ($st, $meta) = @_;
    my $local = local_text($st);
    return $local if $st->{sel}{mode} eq 'B' || $meta->{max} == 0;
    my $req = selection_request($st) or return '';
    my $r = api('pane.selection.read', { pane_id => $meta->{pane}, %$req });
    my $herdr = $r ? $r->{text} : '';
    return same_text($herdr, $local) ? $herdr : $local;
}

# Inside the popup, after herdr-plugin.toml's command printed the first
# frame: read the history (or take the paused view back), then keys until
# exit. Keys typed while the history loads wait in the terminal.
sub run_copy {
    my $state = $ENV{COPY_MODE_STATE} // die "copy-mode: COPY_MODE_STATE unset\n";
    my %meta = map { /\A(\w+)=(.*)\z/ ? ($1, $2) : () } read_lines("$state/meta");
    my $resume = read_bytes("$state/resume");
    my $visible = read_bytes("$state/visible") // '';
    utf8::decode($visible);
    remove_state($state);
    $SIG{HUP} = $SIG{TERM} = sub { exit 1 };    # so END restores the scroll
    raw_mode();
    binmode STDOUT, ':encoding(UTF-8)';
    $| = 1;

    my $st;
    if (defined $resume) {
        $st = resume_state(json()->decode($resume));
    } else {
        $st = new_state(raw => load_history(\%meta, split_rows($visible)),
            total => $meta{total}, tw => $meta{tw}, h => $meta{h}, top => $meta{top});
        $st->{cur} = [ @meta{qw(cur_row cur_col)} ];
    }
    $st->{prefix} = parse_bindings('', config_text())->{prefix};
    my $f = { map { $_ => $meta{$_} } qw(col row w h) };
    my $lay = geometry_lay(\%meta);

    my $in = IO::Select->new(\*STDIN);
    my $buf = '';
    while (1) {
        my @keys;
        if ($in->can_read(length $buf ? ESC_WAIT : undef)) {
            sysread(STDIN, my $bytes, 4096) or return;
            $buf .= $bytes;
        } elsif ($buf =~ s/\A\e//) {
            push @keys, 'Esc';    # nothing followed it in time
        } else {
            $buf = '';            # a partial character that never finished
        }
        my ($more, $rest) = parse_keys($buf);
        $buf = $rest;
        my $redraw = 0;
        for my $k (@keys, @$more) {
            my $a = handle_key($st, $k);
            return if $a eq 'exit';
            if ($a eq 'copy') { pbcopy(copy_text($st, \%meta)); return }
            if ($a =~ /\Aprefix (.+)\z/s) { return if run_prefix($st, \%meta, $1); next }
            $redraw ||= $a eq 'redraw';
        }
        print "\e[?2026h" . chrome($st, $f, $lay) . draw_view($st, $f) . "\e[?2026l" if $redraw;
    }
}

unless (caller) {
    my $mode = shift // '';
    if    ($mode eq 'open')    { open_copy() }
    elsif ($mode eq 'run')     { run_copy() }
    elsif ($mode eq 'focused') { on_focused() }
    elsif ($mode eq 'later')   { later(@ARGV) }
    else                       { die "usage: copy-mode.pl open|run|focused|later\n" }
}
1;
