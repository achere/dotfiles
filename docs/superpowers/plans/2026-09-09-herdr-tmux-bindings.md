# herdr with tmux keybindings — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `herdr` usable with the tmux muscle memory already encoded in `tmux/.config/tmux/tmux.conf`, managed reproducibly from this repo under the existing stow convention.

**Architecture:** One new stow package (`herdr/.config/herdr/config.toml`) holding only the bindings that contradict herdr's defaults, plus wiring in `Brewfile`, `bootstrap.sh` and `zsh/.zshrc`. The pi and claude integrations are installed by command, not by symlink, because they write into gitignored machine-local directories.

**Tech Stack:** GNU Stow, Homebrew Bundle, TOML, zsh, herdr 0.9.0.

**Spec:** `docs/superpowers/specs/2026-09-09-herdr-tmux-bindings-design.md`

## Global Constraints

- **No defensive guards.** No `[ -f ]` before `source`, no `command -v` before `eval`, no `|| true`. Established in the 2026-08-16 spec and reaffirmed here. Where a command would fail on a fresh machine, fix the precondition with an unconditional `mkdir -p` instead.
- **Never let stow fold a directory.** `~/.config/herdr` must exist before `stow` runs so stow descends into it and links only `config.toml`. Folding would put `herdr.sock`, `herdr-client.sock`, `session.json` and `.plugins.lock` into a public repo.
- **Repo lives at `~/dotfiles`**, so stow's default target is `$HOME`. Never pass `-t`.
- **`stow -n -v` dry run before every real `stow`.**
- Comments in config files explain *why*, matching the density of the surrounding files.
- Branch is `herdr-tmux-bindings`. The spec is already committed there as `f5066ea`.

---

### Task 1: The herdr stow package

**Files:**
- Create: `herdr/.config/herdr/config.toml`
- Migrate: `~/.config/herdr/config.toml` (currently a real file containing `onboarding = false`; must be moved aside before stow can link)

**Interfaces:**
- Consumes: nothing.
- Produces: `~/.config/herdr/config.toml` as a symlink into the repo. Task 2 adds the bootstrap lines that reproduce this on a new machine.

- [ ] **Step 1: Create the package file**

```bash
mkdir -p ~/dotfiles/herdr/.config/herdr
```

Write `herdr/.config/herdr/config.toml` with exactly this content:

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

# NAVIGATE mode splits movement into two separate bindings: these move
# through the workspace/session list, while navigate_pane_left/down/up/right
# (left at their defaults, h/j/k/l) move between panes. The list ones
# default to the arrow keys, which is why j/k looked dead in NAVIGATE mode -
# they were bound to pane movement the whole time, which does nothing while
# focus is on the list. Putting the list on vim keys matches the vi-mode
# used throughout this setup (.zshrc's `bindkey -v`, tmux.conf's
# `mode-keys vi`). Left unrecorded on purpose: navigate_pane_down/up are
# still j/k by default too, so the same two keys are now named by two
# bindings, and which one wins in a given context has not been checked -
# only that this parses and reloads. Re-check pane movement in NAVIGATE mode
# if list navigation starts behaving oddly.
navigate_workspace_up   = "k"
navigate_workspace_down = "j"

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

# herdr's keybinds screen lists "focus agent 1-9" - this is that entry,
# bound to alt+1 through alt+9 behind the prefix chord. Jumps straight to
# agent N in the sidebar. Numbering follows sidebar order, which
# ui.agent_panel_sort controls: default "spaces" groups agents by workspace,
# "priority" instead orders by which agent wants attention - either way N
# shifts as workspaces come and go, it isn't pinned to one agent.
focus_agent = "prefix+alt+1..9"

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

- [ ] **Step 2: Prove the migration is needed (the failing check)**

Run: `cd ~/dotfiles && stow -n -v herdr`

Expected: FAILURE — stow reports an existing target, e.g.
`WARNING! stowing herdr would cause conflicts: * existing target is neither a link nor a directory: .config/herdr/config.toml`

This confirms the live file must be moved before linking. If stow instead reports success, the live file is already gone — skip to Step 4.

- [ ] **Step 3: Move the live config aside**

```bash
mv ~/.config/herdr/config.toml ~/.config/herdr/config.toml.pre-stow.bak
```

Do **not** remove `~/.config/herdr` itself. Removing the directory would make stow fold it, which is the failure this plan exists to prevent.

- [ ] **Step 4: Re-run the dry run and read it carefully**

Run: `cd ~/dotfiles && stow -n -v herdr`

Expected: PASS, and the output must show a link being made for the **file**, not the directory:
`LINK: .config/herdr/config.toml => ../../dotfiles/herdr/.config/herdr/config.toml`

If the output instead says `LINK: .config/herdr => ...`, stop — the directory is being folded. Recreate `~/.config/herdr` and retry.

- [ ] **Step 5: Link it**

```bash
cd ~/dotfiles && stow -v herdr
```

- [ ] **Step 6: Verify the link and validate the config**

```bash
ls -l ~/.config/herdr/config.toml
herdr config check
```

Expected: `config.toml` is a symlink into `~/dotfiles/herdr/`, and `herdr config check` prints no `issues found`, no `invalid keybinding`, and no `unknown config key`.

`herdr config check` validates both action names and key names, so any typo in the TOML above surfaces here rather than silently disabling a binding.

- [ ] **Step 7: Apply to the running server**

```bash
herdr server reload-config
```

A herdr server is already running; without this the new bindings only take effect on the next server start.

- [ ] **Step 8: Commit**

```bash
cd ~/dotfiles
git add herdr/.config/herdr/config.toml
git commit -m "Add herdr stow package with tmux-mapped keybindings"
```

---

### Task 2: Brewfile and bootstrap wiring

**Files:**
- Modify: `Brewfile:14-17` (the *referenced by the other configs* block)
- Modify: `bootstrap.sh:14-19` (step 3 comment and `mkdir -p`)
- Modify: `bootstrap.sh:23-24` (both stow lines)
- Modify: `bootstrap.sh:55-57` (append a new step 9 after the step 8 comment block)

**Interfaces:**
- Consumes: the `herdr` package directory created in Task 1.
- Produces: a `bootstrap.sh` that reproduces Task 1's result plus both agent integrations on a fresh machine.

- [ ] **Step 1: Add herdr to the Brewfile**

In `Brewfile`, under `# --- referenced by the other configs ---`, add after the `brew "go"` line:

```ruby
brew "herdr"                        # herdr/.config/herdr/config.toml
```

Do **not** add `pi-coding-agent` or `claude-code`. They are the agents herdr manages, not dependencies of these configs, and the Brewfile is curated as one line per thing these dotfiles actually need.

- [ ] **Step 2: Add ~/.config/herdr to the pre-stow mkdir**

In `bootstrap.sh`, extend the step 3 comment block (currently lines 14-18) and its `mkdir -p` (line 19). Replace:

```sh
#    ~/.config/lazygit would put lazygit's state into a public repo.
mkdir -p "$HOME/.config/tmux" "$HOME/.config/wezterm" "$HOME/.config/lazygit"
```

with:

```sh
#    ~/.config/lazygit would put lazygit's state into a public repo. The same
#    applies to ~/.config/herdr, which holds herdr.sock, herdr-client.sock,
#    session.json and .plugins.lock - live sockets and session state.
mkdir -p "$HOME/.config/tmux" "$HOME/.config/wezterm" "$HOME/.config/lazygit" \
         "$HOME/.config/herdr"
```

- [ ] **Step 3: Add herdr to both stow lines**

In `bootstrap.sh`, replace lines 23-24:

```sh
stow -n -v tmux wezterm zsh lazygit starship   # dry run first, always
stow -v tmux wezterm zsh lazygit starship
```

with:

```sh
stow -n -v tmux wezterm zsh lazygit starship herdr   # dry run first, always
stow -v tmux wezterm zsh lazygit starship herdr
```

Note the ordering constraint this creates: stow must run before herdr is first launched on a new machine, because herdr writes its own `config.toml` on first run and stow refuses to link over a real file. bootstrap already satisfies this — step 4 stows, and nothing launches herdr.

- [ ] **Step 4: Add the integrations step**

Append to the end of `bootstrap.sh`, after the existing step 8 comment:

```sh

# 9. herdr's agent integrations report pi/claude lifecycle state to the herdr
#    sidebar and OS notifications. They are not symlinked: both write into
#    gitignored machine-local directories, and claude's install also appends a
#    hooks key to ~/.claude/settings.json. Both commands exit 1 when the target
#    directory is missing ("install pi first"), which would abort this script
#    under `set -e` on a machine where neither agent has been run yet - hence
#    the mkdir, which makes them succeed unconditionally and keeps this file
#    free of `command -v` guards.
mkdir -p "$HOME/.claude" "$HOME/.pi/agent/extensions"
herdr integration install pi
herdr integration install claude
```

- [ ] **Step 5: Syntax-check the script**

Run: `bash -n ~/dotfiles/bootstrap.sh`

Expected: PASS, no output. This catches the line-continuation backslash in Step 2 being malformed.

- [ ] **Step 6: Verify the Brewfile resolves**

Run: `cd ~/dotfiles && brew bundle check --file=Brewfile --verbose`

Expected: either `The Brewfile's dependencies are satisfied.` or a list naming only formulae unrelated to this change. `herdr` must **not** appear as missing — it is already installed at 0.9.0.

Per the 2026-08-16 spec, this check goes red on its own as formulae drift a patch behind, so a failure naming only other packages is not a regression from this task.

- [ ] **Step 7: Verify the stow line is idempotent**

Run: `cd ~/dotfiles && stow -n -v tmux wezterm zsh lazygit starship herdr`

Expected: PASS with no conflicts. Task 1 already linked `herdr`, so re-stowing must be a no-op rather than an error.

- [ ] **Step 8: Commit**

```bash
cd ~/dotfiles
git add Brewfile bootstrap.sh
git commit -m "Bootstrap herdr: brew formula, pre-stow mkdir, agent integrations"
```

---

### Task 3: zsh completions

**Files:**
- Modify: `zsh/.zshrc:29`

**Interfaces:**
- Consumes: `brew "herdr"` from Task 2, which puts `herdr` on `PATH`.
- Produces: `herdr <TAB>` subcommand completion in new shells.

- [ ] **Step 1: Add the completion line**

In `zsh/.zshrc`, replace line 29:

```sh
source <(kubectl completion zsh)
```

with:

```sh
source <(kubectl completion zsh)
source <(herdr completion zsh)
```

Unguarded, matching the kubectl line directly above it and the repo's rejection of defensive guards. It must stay below `compinit` (line 20) — the same constraint the nvm block documents.

- [ ] **Step 2: Verify the completion script is valid zsh**

Run: `herdr completion zsh | zsh -n`

Expected: PASS, no output. This checks the generated script parses before it is sourced into every future shell — a broken one would print errors on every shell start.

- [ ] **Step 3: Verify it loads in a real shell**

Run: `zsh -i -c 'echo ok' 2>&1 | tail -5`

Expected: `ok`, with no errors mentioning `herdr` or `compdef`.

- [ ] **Step 4: Commit**

```bash
cd ~/dotfiles
git add zsh/.zshrc
git commit -m "Load herdr zsh completions"
```

---

### Task 4: Verify the bindings, and fix split orientation if inverted

**Files:**
- Possibly modify: `herdr/.config/herdr/config.toml` (only if Step 2 shows the splits are backwards)
- Modify: `docs/superpowers/specs/2026-09-09-herdr-tmux-bindings-design.md` (Status line)

**Interfaces:**
- Consumes: everything from Tasks 1-3.
- Produces: a verified configuration and an accurate spec Status line.

This task is mostly interactive — it requires a human at a terminal pressing keys. Do not mark steps complete without actually running herdr.

- [ ] **Step 1: Try to resolve split orientation without guessing**

Run: `herdr api --help` and look for a keymap or action-metadata subcommand that reports what `split_horizontal` does.

If one exists, use it. If not, fall through to Step 2. This step exists because the orientation is the one claim in the spec that was inferred from herdr's naming and its `pane split --direction right|down` CLI rather than read from documentation.

- [ ] **Step 2: Confirm orientation by pressing the keys**

Launch `herdr`, then press `ctrl+space` followed by `"`.

Expected: the pane splits **stacked** (new pane below), matching tmux's `"`.

Then press `ctrl+space` followed by `%`.

Expected: the pane splits **side by side** (new pane to the right), matching tmux's `%`.

- [ ] **Step 3: Swap the values only if Step 2 was inverted**

If `"` split side by side and `%` split stacked, swap the two values in `herdr/.config/herdr/config.toml`:

```toml
split_horizontal = "prefix+percent"
split_vertical   = "prefix+quote"
```

Then update the comment directly above them, which currently claims herdr's naming inverts tmux's flags, to state the observed behaviour instead. Run `herdr server reload-config` and repeat Step 2.

If Step 2 passed, skip this step and change nothing.

- [ ] **Step 4: Exercise the remaining changed bindings**

With herdr running, confirm each of these does what tmux does:

| Press | Expected |
|---|---|
| `ctrl+space` `d` | detaches, leaving the server running |
| `ctrl+space` `,` | prompts to rename the current tab |
| `ctrl+space` `&` | closes the current tab |
| `ctrl+space` `s` | opens the workspace picker, not settings |
| `ctrl+space` `shift+s` | opens settings |
| `ctrl+space` `;` | jumps to the last pane |

Also confirm the unchanged defaults still behave: `h/j/k/l` focus panes, `z` zooms, `x` closes a pane, `c` makes a tab, `n`/`p` cycle tabs, `1`-`9` switch tabs.

- [ ] **Step 5: Verify the integrations end to end**

```bash
herdr integration status | grep -E '^(pi|claude):'
```

Expected: both report `current`.

Then, in a herdr pane, run a short `claude` or `pi` prompt, switch to a different workspace, and confirm an OS notification fires when it finishes. This is the payoff of `ui.toast.delivery = "system"` — if nothing appears, check macOS notification permissions for the terminal app before suspecting the config.

- [ ] **Step 6: Confirm nothing leaked into the repo**

```bash
cd ~/dotfiles && git status --porcelain && git ls-files herdr/
```

Expected: `git ls-files herdr/` lists exactly one path, `herdr/.config/herdr/config.toml`. No `.sock`, no `session.json`, no `.plugins.lock`, no logs. This is the check that proves the folding guard worked.

- [ ] **Step 7: Update the spec Status line**

In `docs/superpowers/specs/2026-09-09-herdr-tmux-bindings-design.md`, replace the Status line:

```markdown
**Status:** design approved; integrations already installed (see
"Integrations"), config and repo wiring not yet written.
```

with a line recording the outcome — implemented date, whether the split orientation held or was swapped, and anything that did not work. Record what actually happened, including failures; the 2026-08-16 spec's Status section is the model.

- [ ] **Step 8: Commit**

```bash
cd ~/dotfiles
git add docs/superpowers/specs/2026-09-09-herdr-tmux-bindings-design.md herdr/
git commit -m "Verify herdr bindings; record outcome in the spec"
```

---

## Cleanup, once verified

`~/.config/herdr/config.toml.pre-stow.bak` from Task 1 Step 3 holds only `onboarding = false`, which the new config preserves. Delete it after Task 4 passes. Leave it in place if anything in Task 4 is still unresolved.

## Not in scope

Removing or editing the tmux package; a `claude` or `pi` stow package; herdr's other 15 integrations; remote/SSH herdr; worktree workflows; custom themes; sounds; the lazygit popup binding.
