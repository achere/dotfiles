# herdr with tmux keybindings + pi/claude integrations — design

**Date:** 2026-09-09
**Status:** design approved; integrations already installed (see
"Integrations"), config and repo wiring not yet written.

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

herdr and tmux now share `ctrl+space`. Whichever is nested inside the other
never sees the prefix. This is acceptable because the intent is to run one
*or* the other, not both at once. If that changes, the fix is one line —
`prefix` in `config.toml`. `herdr config check` validates key names, so a bad
value is caught immediately rather than silently disabling the binding.

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
| `"` split stacked | `split_horizontal = "prefix+minus"` | `prefix+quote` |
| `%` split side-by-side | `split_vertical = "prefix+v"` | `prefix+percent` |
| `d` detach | `detach = "prefix+q"` | `prefix+d` |
| `,` rename-window | `rename_tab = "prefix+shift+t"` | `prefix+comma` |
| `&` kill-window | `close_tab = "prefix+shift+x"` | `prefix+ampersand` |
| `s` choose-session | `settings = "prefix+s"` | `workspace_picker = "prefix+s"`; `settings` moves to `prefix+shift+s` |
| `;` last-pane | `last_pane` unset | `prefix+semicolon` |

Deliberately left at herdr defaults — herdr-native actions with no tmux
equivalent, so there is no muscle memory to honour: `prefix+b` sidebar,
`prefix+g` goto, `prefix+r` resize mode, `prefix+e` scrollback into
`$EDITOR`, `prefix+shift+g` new worktree, `prefix+o` notification jump,
`prefix+shift+n` new workspace, `prefix+shift+r` reload config.

### Key-name syntax, verified empirically

`herdr config check` validates both action names (`unknown config key ...;
ignoring key`) and key names (`invalid keybinding: ...; disabling binding`),
so these were confirmed rather than assumed:

- `quote` is `"`, not `'`. `prefix+"` also parses; `prefix+'`,
  `prefix+doublequote` and `prefix+apostrophe` are all rejected. The
  apostrophe appears not to be bindable at all.
- `percent` is `%`. `prefix+%` and `prefix+shift+5` also parse.
- `ctrl+space`, `comma`, `ampersand`, `semicolon`, `minus` all parse.

Prefer the named spellings over the literal punctuation — they avoid TOML
quoting problems (`split_vertical = "prefix+"..."` is a parse error).

### Known gap: no copy-mode

herdr has no equivalent of tmux's `prefix [` with vi selection, `v` and `y`.
Selection is mouse-driven via `mouse_capture` and `copy_on_select`, both on
by default. The nearest thing to copy-mode is `prefix+e`, which dumps the
pane scrollback into `$EDITOR`. This is not being worked around; it is
recorded so the absence is not mistaken for a misconfiguration.

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
# tmux share a prefix: whichever one is nested inside the other never sees
# it. Deliberate - the intent is to run one or the other, not both.
prefix = "ctrl+space"

# tmux `"` splits stacked, `%` splits side by side. herdr names splits after
# the divider, which inverts tmux's split-window -v/-h flags - these follow
# the visual result, not the flag letter. `quote` is the double quote; the
# apostrophe is not bindable.
split_horizontal = "prefix+quote"
split_vertical   = "prefix+percent"

detach     = "prefix+d"          # tmux d; herdr's default prefix+q goes unbound
rename_tab = "prefix+comma"      # tmux , rename-window
close_tab  = "prefix+ampersand"  # tmux & kill-window

# tmux s is choose-session, and a workspace is herdr's nearest equivalent.
# Settings moves aside to make room.
workspace_picker = "prefix+s"
settings         = "prefix+shift+s"

last_pane = "prefix+semicolon"   # tmux ; last-pane; unset in herdr by default

[ui.toast]
# Ping the OS when a pi or claude pane finishes or needs input. Off by
# default; this is what the agent integrations actually buy.
delivery = "system"
```

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
   prefix, `"`, `%`, `d`, `,`, `&`, `s`, `;`.
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
