# herdr with tmux keybindings + pi/claude integrations — design

**Date:** 2026-09-09
**Status:** config, Brewfile/bootstrap wiring and zsh completions are
implemented and committed (see "Config file" and "Repo wiring"). Both agent
integrations are installed; `herdr integration status` reports `pi: current`
and `claude: current`. A pane-close confirmation popup was added afterward
(see "Config file") to close a gap found during use: herdr 0.9.0 has no
config option for it at all, not just a default that needed changing.

Interactive verification is partial. CONFIRMED by pressing keys:
`prefix+percent` splits side by side, and `prefix+"` splits stacked — herdr's
vertical/horizontal naming does invert tmux's `-v`/`-h` flag letters, as the
"Config file" comment states. The original binding, `prefix+quote`, was
WRONG: `quote` parses and `herdr config check` accepted it, but it actually
matches the apostrophe key, not `"`. Root cause: `herdr config check`
validates that a key name parses, not which physical key it matches — only
pressing the binding proves that. NOT yet exercised: `d`, `,`, `&`, `s`,
`shift+s`, `;`, `[` copy mode, and the new pane-close popup.

## Goal

Make `herdr` — a terminal workspace manager for AI coding agents, brew
formula `herdr`, currently 0.9.0 — usable without relearning a multiplexer,
by mapping its keybindings onto the tmux bindings already in
`tmux/.config/tmux/tmux.conf`. Wire its `pi` and `claude` integrations so
agent lifecycle state reaches the sidebar and the OS notification service.
Manage all of it from this repo under the existing stow convention.

## Context: herdr is being trialled, not adopted

The user has not decided whether herdr replaces tmux. Both stay installed.
This decision shapes the prefix choice below and means the config must stay
small enough to abandon cheaply.

## Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Prefix | `ctrl+space` — same as tmux | 1:1 muscle memory. Chosen over non-colliding alternatives (`ctrl+a`, `ctrl+g`, `ctrl+s`, `F12`) with the nesting cost understood and accepted. |
| Mapping scope | Minimal delta | Change only bindings that actively contradict tmux; leave herdr-native actions alone. |
| Packaging | Full stow package + Brewfile + bootstrap | Matches the convention established for tmux/wezterm/zsh/lazygit/starship. |
| Theme | herdr default, left unset | Considered `dracula` for consistency with wezterm's `color_scheme` and the `dracula/tmux` plugin; declined. |
| Extras | OS toasts, zsh completions | `lazygit` popup binding considered and declined. |

### The prefix collision is deliberate

herdr and tmux now share `ctrl+space`. The outer one swallows it unless
pressed twice — `tmux.conf` binds `C-Space send-prefix`, so a second press
passes the chord through to a nested herdr. This is acceptable because the
intent is to run one *or* the other, not both at once. If that changes, the
fix is one line — `prefix` in `config.toml`.

`herdr config check` only validates that a key name *parses*. It does not
catch a binding that collides with another action's default — `detach =
"prefix+z"` against the default `zoom = "prefix+z"` still returns `config:
ok` — and it does not prove a name matches the physical key it appears to:
`quote` parses, but interactive testing showed it binds `'`, not `"` (see
"Key-name syntax" below). Only pressing a binding confirms it does what its
name suggests.

## Vocabulary

herdr's nouns do not line up with tmux's, and the mapping below depends on
this correspondence:

| tmux | herdr |
|---|---|
| session | workspace |
| window | tab |
| pane | pane |

herdr additionally has *worktrees* (git worktree helpers) and an agent
sidebar, neither of which has a tmux analogue.

## Keybinding mapping

Already identical to tmux at herdr's defaults, so **not** set in the config:
`prefix h/j/k/l` (focus pane), `z` (zoom), `x` (close pane), `c` (new tab),
`n`/`p` (next/prev tab), `1-9` (switch tab), `?` (help). `new_cwd = "follow"`
is also already the default, which reproduces tmux's
`split-window -c "#{pane_current_path}"`.

Changed, because herdr's default contradicts tmux:

| tmux | herdr default | set to |
|---|---|---|
| `C-Space` prefix | `ctrl+b` | `ctrl+space` |
| `"` split stacked | `split_horizontal = "prefix+minus"` | `` prefix+" `` |
| `%` split side-by-side | `split_vertical = "prefix+v"` | `prefix+percent` |
| `d` detach | `detach = "prefix+q"` | `prefix+d` |
| `,` rename-window | `rename_tab = "prefix+shift+t"` | `prefix+comma` |
| `&` kill-window, with confirmation | `close_tab = "prefix+shift+x"`, no confirmation | `close_tab = ""`; `prefix+ampersand` rebound to a confirming popup (see "Config file") |
| `s` choose-session | `settings = "prefix+s"` | `workspace_picker = "prefix+s"`; `settings` moves to `prefix+shift+s` |
| `;` last-pane | `last_pane` unset | `prefix+semicolon` |
| `x` kill-pane, with confirmation | `close_pane = "prefix+x"`, no confirmation | `close_pane = ""`; `prefix+x` rebound to a confirming popup (see "Config file") |
| `q` display-panes | `goto = "prefix+g"`, no equivalent binding | `goto` also bound at `prefix+q`, alongside the default `prefix+g` — see note below |

herdr 0.9.0 has no equivalent of tmux's kill-pane confirmation as a config
option: `confirm_close_pane`, `confirm_pane_close`, `pane_confirm_close` and
`confirm_kill_pane` were all probed and all fail `herdr config check` with
`unknown config key`. `ui.confirm_close` does exist and defaults to `true`,
but it guards workspace closure only — it does not stop `prefix x` from
closing a pane unasked. The popup command bound above reconstructs the
missing confirmation from outside herdr's config surface, since there is
nothing to turn on inside it.

herdr's `close_tab` has the identical gap: there is no tab-scoped confirm
setting either, and `ui.confirm_close` still only guards workspace closure.
The popup bound to `prefix+ampersand` reconstructs tmux's `&` prompt the
same way the pane-close popup does, and additionally reports the tab's
label and how many panes will close with it — more than tmux's own prompt
shows.

tmux's `prefix q` is display-panes: it numbers the panes and jumps to
whichever one is pressed next. herdr has no per-pane numbering to match —
it numbers *agents* in its sidebar, not panes — so there is no exact
equivalent, only a nearest one: NAVIGATE mode, reached via `goto`, an
overlay moved with `h/j/k/l` and the arrows, with `1`-`9` reserved for
selection and `esc` to back out. Bound here as a second chord for `goto`,
`prefix+q`; herdr's default `prefix+g` stays bound as well, so the action
now answers to both.

Deliberately left at herdr defaults — herdr-native actions with no tmux
equivalent, so there is no muscle memory to honour: `prefix+b` sidebar,
`prefix+r` resize mode, `prefix+e` scrollback into `$EDITOR`,
`prefix+shift+g` new worktree, `prefix+o` notification jump,
`prefix+shift+n` new workspace, `prefix+shift+r` reload config.

### Key-name syntax, verified empirically

`herdr config check` validates both action names (`unknown config key ...;
ignoring key`) and key names (`invalid keybinding: ...; disabling binding`),
so these were confirmed rather than assumed:

- `quote` parses — but interactive testing showed it names the apostrophe
  `'`, not `"` as the word suggests. `prefix+"` also parses, and is the
  binding that actually produces the double-quote chord. `prefix+'`,
  `prefix+doublequote` and `prefix+apostrophe` are all rejected by the
  parser, even though `'` is the physical key `quote` matches — parsing and
  matching are different guarantees; see "The prefix collision is
  deliberate" above.
- `percent` is `%`. `prefix+%` and `prefix+shift+5` also parse.
- `ctrl+space`, `comma`, `ampersand`, `semicolon`, `minus` all parse.

Neither form is inherently safer: both named spellings and literal
punctuation parse fine and both bind real keys, but a name parsing
successfully says nothing about which physical key it matches — only
pressing it does. Literal punctuation at least states the intended key
outright; use a TOML literal string (`'prefix+"'`) when the character would
otherwise need escaping.

### copy-mode: supported, but easy to miss

herdr does have an equivalent of tmux's `prefix [`: `copy_mode` is a real
action, bound here to `prefix+[` to match tmux, and herdr's copy mode has the
same vi-style motions built in. This was missed on a first pass because
`copy_mode` does not appear in `herdr --default-config` output — the action
exists, but that command's listing doesn't surface it, which makes it look
unsupported when it isn't.

Selection is also mouse-driven, independently of copy mode: `mouse_capture`
and `copy_on_select` are both on by default. `prefix+e`, which dumps the pane
scrollback into `$EDITOR`, is a third, unrelated route to the same content.

## Config file

`herdr/.config/herdr/config.toml`:

```toml
# herdr - terminal workspace manager for AI coding agents.
#
# Keybindings mirror tmux/.config/tmux/tmux.conf so muscle memory carries
# over. Only bindings that CONTRADICT tmux are set here; herdr's defaults
# already match tmux for h/j/k/l, z, x, c, n, p, 1-9 and ?, and
# new_cwd = "follow" already reproduces tmux's `-c "#{pane_current_path}"`.
#
# Vocabulary: a herdr *workspace* is a tmux session, a herdr *tab* is a tmux
# window, panes are panes.

onboarding = false

[keys]
# tmux does `unbind C-b; set -g prefix C-Space`. Same chord, so herdr and
# tmux share a prefix: the outer one swallows it unless pressed twice -
# tmux.conf binds `C-Space send-prefix`, so a second press passes the chord
# through to a nested herdr. Deliberate - the intent is to run one or the
# other, not both.
prefix = "ctrl+space"

# tmux `"` splits stacked, `%` splits side by side. Confirmed by observation:
# prefix+percent (split_vertical) produces the side-by-side split, so
# herdr's vertical/horizontal naming does invert tmux's split-window -v/-h
# flags, as suspected - split_horizontal therefore produces the stacked
# split, matching tmux's `"`. herdr's `quote` names the apostrophe `'`, not
# `"`, so the literal double-quote is required here. Lesson: `herdr config
# check` only validates that a key name parses - it does not prove which
# physical key it matches. Only pressing the key does.
split_horizontal = 'prefix+"'
split_vertical   = "prefix+percent"

detach     = "prefix+d"          # tmux d; herdr's default prefix+q goes unbound
rename_tab = "prefix+comma"      # tmux , rename-window

# tmux's `&` (kill-window) prompts before closing; herdr's close_tab does
# not, and ui.confirm_close only guards workspaces, not tabs - the same gap
# close_pane has below, with no tab-scoped confirm setting to flip either.
# Unbind here; prefix+ampersand is rebound to a confirming popup at the end
# of this file, alongside the pane-close one it mirrors.
close_tab  = ""

# tmux `prefix q` is display-panes: numbers the panes, press one to jump.
# herdr's nearest equivalent is NAVIGATE mode, reached via goto - an overlay
# moved with h/j/k/l and the arrows, 1-9 reserved for selection, esc to back
# out. Not an exact match: herdr numbers agents in its sidebar, not panes,
# so this is the closest equivalent in access pattern rather than the same
# thing. prefix+q was free because detach moved to prefix+d above; herdr's
# default prefix+g stays bound too, so goto now answers to both.
goto = "prefix+q"

# tmux s is choose-session, and a workspace is herdr's nearest equivalent.
# Settings moves aside to make room.
workspace_picker = "prefix+s"    # herdr's default prefix+w goes unbound
settings         = "prefix+shift+s"

last_pane = "prefix+semicolon"   # tmux ; last-pane; unset in herdr by default

# tmux `prefix [` enters copy mode; herdr's copy mode has the same vi-style
# motions built in. Easy to miss: this action is absent from herdr
# --default-config output, which makes it look unsupported when it isn't.
# Literal `[` is required here, as with split_horizontal's `"` above:
# `bracketleft`, `leftbracket`, `lbracket` and `openbracket` are all
# rejected as invalid keybindings - named spellings don't cover every key.
copy_mode = "prefix+["

# herdr 0.9.0 has no pane-close confirmation of its own - confirm_close_pane,
# confirm_pane_close, pane_confirm_close and confirm_kill_pane all fail
# `herdr config check` with "unknown config key", and ui.confirm_close (see
# below) only guards workspaces, not panes. tmux's `prefix x` does prompt, so
# this is a real gap against muscle memory, not a missing tmux mapping.
# Unbind herdr's silent default and replace it with a popup that asks.
close_pane = ""

# herdr has no sidebar-specific border setting - the full [ui] key list has
# nothing border-related besides these two, so this is the mechanism for a
# dividing line against the workspace sidebar. The default pane_borders =
# "auto" only frames *split* panes, so a workspace showing a single pane
# gets no frame and therefore no line against the sidebar; "always" frames
# a lone pane too, which is what produces the line. pane_outer_borders draws
# the outside edge of the pane area - it's what that left-hand line actually
# is - and already defaults to true, but "always" only takes effect while
# it's enabled, so it's set here explicitly to record the dependency rather
# than leave the behaviour resting on an unstated default. If the line
# renders too dim, ui.accent is documented as the colour for "highlights,
# borders, and navigation UI".
[ui]
pane_borders = "always"
pane_outer_borders = true

[ui.toast]
# Ping the OS when a pi or claude pane finishes or needs input. Off by
# default; this is what the agent integrations actually buy.
delivery = "system"

[experimental]
# herdr already restores workspaces, tabs, panes, layout, and cwd from
# ~/.config/herdr/session.json across a server restart, and
# session.resume_agents_on_restore (on by default) resumes pi/claude panes
# into their native conversation sessions - none of that needs configuring
# here. What it does not restore by default is each pane's screen history,
# so a restored pane comes back blank even though the agent session behind
# it is intact. pane_history closes that specific gap. It lives under
# [experimental] because saved history costs disk, which is why herdr ships
# it off - the rough equivalent of what tmux-resurrect does for the tmux
# setup above, except herdr's covers agent conversations too.
pane_history = true

# Reconstructs the confirmation tmux gives on `prefix x` but herdr's own
# close_pane does not. `herdr pane close` takes an explicit pane id rather
# than acting on "the current pane", so the script asks the running server
# for one via `herdr api snapshot`'s focused_pane_id. The prompt deliberately
# echoes that id and its cwd: if the popup is ever slow to update focus and
# this resolves to a pane other than the one the user meant to close, that
# mismatch is visible in the prompt and declinable, instead of silently
# closing the wrong pane. Runs under `bash`, not `sh`: `read -n 1` accepts a
# single keypress without waiting for Enter, and that flag is a bashism -
# `sh -c` would not support it. Only `y`/`Y` closes the pane; `n`, `q`, and a
# bare Enter (empty input) all fall through to the default and decline.
[[keys.command]]
key = "prefix+x"
type = "popup"
width = "50%"
height = "20%"
command = '''bash -c 'p=$(herdr api snapshot | jq -r .result.snapshot.focused_pane_id); c=$(herdr pane get "$p" | jq -r .result.pane.cwd); printf "Close pane %s (%s)? [y/N] " "$p" "$c"; read -n 1 -r a; echo; case "$a" in [yY]) herdr pane close "$p" ;; esac' '''

# Reconstructs the confirmation tmux gives on `&` (kill-window), which
# herdr's close_tab does not have - see close_tab above, and there is no
# tab-scoped confirm setting to enable instead. Rebuilds it from outside the
# config surface, the same way the pane-close popup above does. `herdr tab
# close` takes an explicit tab id, so the script resolves the focused one
# via `herdr api snapshot`'s focused_tab_id, then shows its label AND how
# many panes go with it - more than tmux's own prompt tells you. Runs under
# `bash`, not `sh`, for the same reason as the pane-close popup: `read -n 1`
# takes a single keypress without waiting for Enter, and that flag is a
# bashism. Only `y`/`Y` closes the tab; anything else, including a bare
# Enter, declines.
[[keys.command]]
key = "prefix+ampersand"
type = "popup"
width = "50%"
height = "20%"
command = '''bash -c 't=$(herdr api snapshot | jq -r .result.snapshot.focused_tab_id); l=$(herdr tab get "$t" | jq -r .result.tab.label); n=$(herdr pane list | jq -r "[.result.panes[]|select(.tab_id==\"$t\")]|length"); printf "Close tab %s (%s panes)? [y/N] " "$l" "$n"; read -n 1 -r a; echo; case "$a" in [yY]) herdr tab close "$t" ;; esac' '''
```

The `[ui]` block was added afterward, for a visible border between the
sidebar and the pane area: herdr exposes no sidebar-border setting, so
`pane_borders = "always"` plus `pane_outer_borders` is the mechanism —
`"always"` frames a pane even when it isn't split, and the outer-border flag
is what draws that frame's outside edge, the side facing the sidebar.

Session restore across a server restart is native and needed no
configuration beyond `[experimental] pane_history` (see "Config file"
above) — workspaces, tabs, panes, layout, cwd and, via
`session.resume_agents_on_restore`, the agent conversations themselves all
come back on their own. A related option was considered and declined:
herdr ships a launchd service, `sh.brew.herdr.plist`, with `RunAtLoad` and
`KeepAlive`, which would start the server at login. Not enabled — it only
matters for agents resuming before a terminal is opened, and a
launchd-started server inherits launchd's environment rather than the
user's shell, so panes could see a different `PATH`. Deliberately absent
from the `Brewfile` for the same reason.

## Repo wiring

### Stow folding — the same trap as tmux and lazygit

`~/.config/herdr` holds `herdr.sock`, `herdr-client.sock`, `session.json`,
`.plugins.lock` and server/client logs. If stow folded that directory, live
sockets and session state would be written into a **public** repo. The
existing invariant applies unchanged:

> The parent directory must exist before `stow` runs, so stow descends into
> it and links only `config.toml`.

`.gitignore` already covers `*.log`, but that protects only the logs, not
`session.json` or the sockets. The `mkdir -p` is the real guard.

### Changes

- **`Brewfile`** — `brew "herdr"` under *referenced by the other configs*.
- **`bootstrap.sh` step 3** — add `"$HOME/.config/herdr"` to the existing
  `mkdir -p`, with a comment naming the sockets and `session.json`.
- **`bootstrap.sh` step 4** — add `herdr` to both the `stow -n -v` dry run
  and the real `stow`.
- **`bootstrap.sh`, new step** — agent integrations (below).
- **`zsh/.zshrc`** — `source <(herdr completion zsh)` beside the existing
  `source <(kubectl completion zsh)` at line 29, below `compinit`. Unguarded,
  matching the kubectl line and the repo's rejection of defensive guards.

### Ordering constraint

Stow the `herdr` package **before** herdr is first launched on a new
machine. herdr writes its own `config.toml` on first run, and stow refuses to
link over an existing real file.

## Integrations

Already installed on this machine; `herdr integration status` reports
`pi: current (v8)` and `claude: current (v9)`.

| Agent | Installs | Brew name |
|---|---|---|
| pi | `~/.pi/agent/extensions/herdr-agent-state.ts` | formula `pi-coding-agent` |
| claude | `~/.claude/hooks/herdr-agent-state.sh` + a `hooks` key in `~/.claude/settings.json` | cask `claude-code` |

The claude install is additive — it appended one `hooks` key registering a
`SessionStart` command and left the rest of `settings.json` untouched. The
registered path is absolute and machine-specific, which is fine: `.claude/`
is gitignored here and never enters the repo. Neither integration is a
symlink, so bootstrap installs them by command rather than by stow.

### Why no guard around the integration installs

Both commands **exit 1** when the agent's directory is absent
(`pi extension directory not found ... install pi first`), which would abort
`bootstrap.sh` under `set -euo pipefail` on a fresh machine. The
2026-08-16 spec records that defensive guards were explicitly rejected — no
`[ -f ]` before `source`, no `command -v` before `eval`.

The two constraints are reconcilable because the failure is *directory not
found*, not *binary not found*. Verified against an empty `HOME`: creating
`~/.claude` and `~/.pi/agent/extensions` first makes both installs succeed
with exit 0, with no conditional and no `|| true`. bootstrap already does
exactly this kind of unconditional `mkdir -p` in step 3.

So the new step is:

```sh
mkdir -p "$HOME/.claude" "$HOME/.pi/agent/extensions"
herdr integration install pi
herdr integration install claude
```

`pi-coding-agent` and `claude-code` are **not** added to the `Brewfile`.
They are the agents herdr manages, not dependencies of these configs, and
the Brewfile is curated as "one line per thing these dotfiles actually
need". The `mkdir -p` above makes the integration step work whether or not
they are installed.

## Verification

1. `herdr config check` reports no issues.
2. `stow -n -v herdr` shows only `config.toml` being linked — no folded
   directory. This is the check that matters most.
3. `herdr server reload-config`, then exercise each changed binding:
   prefix, `"`, `%`, `d`, `,`, `&`, `s`, `;`, `[`.
4. **Confirm split orientation.** That `split_horizontal` stacks and
   `split_vertical` splits side by side is inferred from herdr's naming and
   its `pane split --direction right|down` CLI, not read from documentation.
   If pressing `prefix "` splits side by side, swap the two values.
5. `herdr integration status` shows pi and claude `current`.
6. A pi or claude pane finishing in a background workspace raises an OS
   notification.
7. `herdr <TAB>` completes subcommands in a new shell.

## Out of scope

- **Replacing tmux.** The tmux package stays exactly as it is. This spec
  does not remove, deprecate, or edit `tmux.conf`.
- **A `claude` or `pi` stow package.** `.claude/` is gitignored; their
  configs stay machine-local.
- **The other 15 herdr integrations** (codex, copilot, droid, …). Only pi
  and claude were asked for.
- **Remote/SSH herdr, worktree workflows, custom themes, sounds, the
  `lazygit` popup binding.** Available, not configured.
