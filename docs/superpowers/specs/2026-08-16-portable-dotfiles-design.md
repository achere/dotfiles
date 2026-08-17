# Portable dotfiles via GNU Stow — design

**Date:** 2026-08-16
**Status:** implemented — packages stowed and verified on this machine 2026-08-17

## Goal

Make the tmux, wezterm, zsh, and lazygit configs reproducible on a new
machine from a single public git repo, using GNU Stow for symlink
management and a Homebrew `Brewfile` to declare the software those configs
depend on.

## Already done — not covered here

The per-config portability edits are finished and verified in place. This
document covers only what remains: moving the files into stow packages and
linking them. The files below are ready to be copied into the repo **as-is**;
they need no further editing.

| Config | State |
|---|---|
| `~/.zshrc` | edited in place, verified. Backup at `~/.zshrc.pre-portable.bak` |
| `~/.config/tmux/tmux.conf` | edited in place, verified. Backup at `~/.config/tmux/tmux.conf.pre-portable.bak` |
| `~/.config/wezterm/wezterm.lua` | already portable, no edits were needed |
| `~/.config/lazygit/config.yml` | portable as-is; lazygit is now brew 0.64.1 and MacPorts is fully removed |

Rationale for those edits lives in this file's git history. The one exception
is the nvm/`compinit` ordering constraint, which was found after the last
commit and is documented in the comment above that block in `.zshrc` — do not
move the NVM block back above `compinit`.

## Scope

**In:** `tmux`, `wezterm`, `zsh`, `lazygit`, `Brewfile`, `Brewfile.extras`,
`bootstrap.sh`, `.gitignore`.

**Out, deliberately:**

- **nvim** — `~/.config/nvim` is already its own repo
  (`git@github.com:achere/kickstart-modular.nvim.git`, a fork of
  `dam9000/kickstart-modular.nvim` with `upstream` tracking). It stays
  independent. Not a stow package, not a submodule, not cloned by
  `bootstrap.sh`. Clone it by hand when setting up a machine.
- **cmux, ghostty, git configs** — considered and excluded.
- **`~/.zprofile`** — excluded by explicit decision, not oversight. It is a
  login-shell startup file containing only installer-generated,
  machine-specific lines (a JetBrains Toolbox `PATH` entry with a hardcoded
  `/Users/achere/`). It stays uncommitted and machine-local.
- **Defensive guards.** Explicitly rejected by the user: no `[ -f ]` guards
  before `source`, no `command -v` guards before `eval`, no multi-prefix
  Homebrew probe. The stated constraint is "I'm not going to try to run it
  with no brew."

## Repo layout

```
~/dotfiles/
├── .gitignore
├── Brewfile                 # core: what these dotfiles need
├── Brewfile.extras          # everything else; bootstrap does NOT install it
├── bootstrap.sh
├── docs/superpowers/specs/  # this file
├── lazygit/.config/lazygit/config.yml
├── tmux/.config/tmux/tmux.conf
├── wezterm/.config/wezterm/wezterm.lua
└── zsh/.zshrc
```

Repo lives at `~/dotfiles` so that Stow's default target — the parent of the
stow directory — is `$HOME`. No `-t` flag needed on any invocation.

Repo is **public**, matching the existing public nvim fork.

### Stow folding behavior (the one thing to get right)

`~/.config` and `~/.config/tmux` already exist as real directories. Stow
therefore *descends* into them and links individual files rather than
folding (symlinking) the whole directory. This is the behavior we want:

- Only `tmux.conf` becomes a symlink.
- `~/.config/tmux/plugins/` and `~/.config/tmux/tmux-*.log` stay as real
  paths outside the repo, so tpm keeps writing outside version control and
  the 1.4 MB `tmux-server-4282.log` can never be committed by accident.

Had `~/.config/tmux` been folded, tpm would write plugins straight into the
repo. Verify with `stow -n -v <pkg>` before every real `stow`.

**This rule applies to all four packages.** Stow folds a directory only when
the target directory does not already exist. So the invariant to preserve
during migration is:

> Remove the four migrated **files**. Never remove their parent
> directories.

`~/.config/lazygit` is the case where this bites hardest. Delete the
directory rather than just `config.yml`, and stow will fold it — making
`~/.config/lazygit` a symlink into the repo, so any file lazygit writes
there lands in a **public** git repo. Lazygit's state currently goes to
`~/Library/Application Support/lazygit/state.yml`, but that path is
version- and XDG-dependent and is not something to rely on.

## Brewfile

Curated — one line per thing these dotfiles actually need, each traceable to
a config that references it.

```ruby
# --- referenced by .zshrc ---
brew "fzf"
brew "starship"
brew "zoxide"
brew "nvm"
brew "kubernetes-cli"               # provides kubectl
brew "neovim"                       # KUBE_EDITOR='nvim'
brew "lazygit"                      # alias lg
brew "ca-certificates"              # provides etc/ca-certificates/cert.pem
brew "zsh-autosuggestions"
brew "zsh-fast-syntax-highlighting"

# --- referenced by the other configs ---
brew "tmux"                         # tmux.conf
brew "git"                          # tpm auto-clone + cloning this repo
brew "stow"                         # bootstrap

# --- explicitly requested ---
brew "ripgrep"
brew "tree-sitter-cli"

cask "wezterm"                      # wezterm.lua
cask "font-fira-code-nerd-font"     # wezterm.lua font
```

`wezterm.lua` also uses `Roboto` in `window_frame`, which needs no formula —
wezterm bundles it. `FiraCode Nerd Font Mono` is the one that must be
declared.

Naming traps confirmed against the live machine:

- `kubectl` is **not** a formula — it ships in `kubernetes-cli` (1.36.3).
  `brew "kubectl"` fails.
- Both `tree-sitter` and `tree-sitter-cli` (0.26.12) are installed;
  `tree-sitter-cli` is the one in `brew leaves`, i.e. the explicit install,
  and it pulls the library in as a dependency.

Deliberately absent:

- `tpm` — `tmux.conf` now clones and runs tpm from
  `~/.config/tmux/plugins/tpm`, so the formula is dead weight. It is still
  installed on this machine; `brew uninstall tpm` is safe cleanup.
- `zsh-syntax-highlighting` — installed but never sourced; only the `fast`
  variant is used.
- `zsh-completions` — the `FPATH` line that used it was removed from
  `.zshrc`; the removal is intentional.

## Brewfile.extras

Produced by `brew bundle dump` with everything in the core `Brewfile`
removed. Roughly 39 further formulae (`gh`, `go`, `jq`, `terraform`,
`ollama`, `heroku`, `bun`, `minikube`, …) and ~40 casks (`obsidian`,
`dbeaver-community`, `discord`, `iterm2`, `vlc`, …).

**Keep the `tap` lines that `brew bundle dump` emits.** This is a filtered
dump, not a hand-written list — some entries are unreachable without their
tap and would fail only on a fresh machine: `heroku` needs `heroku/brew`,
`ntfs-3g-mac` needs `gromgit/fuse`. The core `Brewfile` needs no taps;
verified that `font-fira-code-nerd-font` resolves to `homebrew/cask`, not
the deprecated `homebrew/cask-fonts`.

`bootstrap.sh` does **not** install this file. Install deliberately with
`brew bundle install --file=Brewfile.extras`.

**Noted and accepted:** on a public repo this file publishes a complete
inventory of installed software. The user chose curated+extras with the
public repo decision already made.

`brew bundle dump` also emits 42 `vscode "…"` extension lines. Those are
excluded: this file is scoped to formulae and casks, and
`brew bundle install --file=Brewfile.extras` would otherwise try to drive a
`code` CLI that the Brewfile does not install. Regenerate with them by
dropping the `vscode` filter if that changes.

Actual counts as generated: 4 taps, 47 formulae, 38 casks. `git`,
`ca-certificates`, and `kubernetes-cli` are in the core `Brewfile` but absent
from the dump because they are installed as dependencies rather than as
leaves — `brew bundle dump` lists only leaves. They are correctly declared in
core regardless; a fresh machine needs them named explicitly.

## bootstrap.sh

Order matters because of a circularity: `.zshrc` is what configures brew,
but brew is what provides stow, and stow is what places `.zshrc`. Bootstrap
must therefore set up brew and stow on its own, before stowing anything.

```bash
#!/usr/bin/env bash
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

# 1. Homebrew
command -v brew >/dev/null || \
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"

# 2. stow, before anything can be linked
brew install stow

# 3. These directories must exist BEFORE stow runs. See below.
mkdir -p "$HOME/.config/tmux" "$HOME/.config/wezterm" "$HOME/.config/lazygit"

# 4. link the packages
cd "$DOTFILES"
stow -n -v tmux wezterm zsh lazygit   # dry run first, always
stow -v tmux wezterm zsh lazygit

# 5. everything the configs depend on
brew bundle install --file="$DOTFILES/Brewfile"

# 6. NVM_DIR must exist. Brew's nvm.sh wrapper creates it on load, so this is
#    belt-and-braces rather than strictly required.
mkdir -p "$HOME/.nvm"

# 7. tmux plugins: tmux.conf clones tpm itself on first launch. If the
#    plugins do not appear, press prefix + I once.
```

**Why step 3 exists.** The folding rule above holds only because
`~/.config/tmux` and friends already exist on *this* machine. On a genuinely
fresh one they do not, so stow would fold each package — putting tpm's
plugins and its multi-megabyte logs inside the repo, and lazygit's state
inside a public repo. That is precisely the failure the folding section calls
"the one thing to get right", so bootstrap has to create the directories
first. This is not one of the rejected defensive guards: those were `[ -f ]`
and `command -v` probes around a possibly-absent brew. This is the mechanism
the folding rule depends on.

`bootstrap.sh` is the only place the Apple Silicon brew path appears outside
`.zshrc`. It is the single line to change for an Intel Mac (`/usr/local`) or
Linux (`/home/linuxbrew/.linuxbrew`).

**Conflict handling.** If a target already exists as a real file — most
likely `~/.zshrc`, which some installers create — stow refuses and reports
the conflict rather than clobbering it. That refusal is correct behavior and
must not be worked around with `--adopt`, which would silently overwrite the
repo's copy with the machine's. Resolve by inspecting the existing file,
then moving it aside, then re-running stow.

## .gitignore

Defensive rather than relying on the stow layout to keep junk out:

```gitignore
.DS_Store
*.log
.claude/
.zshrc.local
Brewfile.lock.json
```

Motivated by what is actually sitting in these directories today: a
`.DS_Store` in `~/.config`, three `tmux-*.log` files (the server log is
1.4 MB), and stray `.claude/` directories inside both `~/.config/tmux` and
`~/.config/nvim`.

`~/.zshrc.local` is the machine-local extension point, sourced at the end of
`.zshrc`. It is deliberately **not** committed, and does not exist on this
machine today.

Out-of-scope secrets — `~/.netrc` (mode 600), `~/.aws/`, `~/.kube/`,
`~/.gnupg/`, `~/.docker/config.json` — are never referenced by any stow
package and must stay that way. This is a public repo.

## Migration on this machine

Distinct from fresh-machine bootstrap. Commit each file into the repo
**before** removing the original, so a mistake is always recoverable.

0. Set a repo-local git identity once —
   `git -C ~/dotfiles config user.name/user.email`. The global `.gitconfig`
   has both **commented out**, so commits otherwise fail or get attributed
   to `achere@Alexanders-MacBook-Pro.local`.
1. Copy the four files into their package paths, unchanged — the edits are
   already applied in place:
   - `~/.zshrc` → `zsh/.zshrc`
   - `~/.config/tmux/tmux.conf` → `tmux/.config/tmux/tmux.conf`
   - `~/.config/wezterm/wezterm.lua` → `wezterm/.config/wezterm/wezterm.lua`
   - `~/.config/lazygit/config.yml` → `lazygit/.config/lazygit/config.yml`
2. Add `Brewfile`, `Brewfile.extras`, `bootstrap.sh`, `.gitignore`.
3. Commit.
4. Remove the four original **files** — not their parent directories. See
   the folding rule above; deleting `~/.config/lazygit/` as a directory
   would cause stow to fold it.
5. `stow -n -v tmux wezterm zsh lazygit`, inspect the output, then `stow` for
   real.
6. Verify.

The `.pre-portable.bak` files can be deleted once the migration is verified.

## Verification checklist

Evidence, not assertion — each item has a command and an observable.

**Stow placed things correctly:**

- `stow -n -v <pkg>` shows only the intended links, no folded directories.
- `ls -l ~/.zshrc ~/.config/tmux/tmux.conf ~/.config/wezterm/wezterm.lua
  ~/.config/lazygit/config.yml` — all four are symlinks into `~/dotfiles`.
- No folded directories: `find ~/.config -maxdepth 1 -type l` returns
  nothing for `tmux`, `wezterm`, or `lazygit`.
- `git -C ~/dotfiles status --porcelain` — no `.log`, no `.DS_Store`, no
  `plugins/`, no `.zshrc.local`.
- `brew bundle check --file=Brewfile` passes.

**Nothing broke in the process.** These all pass today, so any failure here
is caused by the migration itself:

- A new zsh starts clean, no errors; `echo $HOMEBREW_PREFIX` is non-empty;
  `nvm --version` succeeds.
- tmux: start a server on a scratch socket rather than killing the live one —
  `tmux -L test -f ~/.config/tmux/tmux.conf new-session -d`, then
  `tmux -L test show-options -gv status-right` contains
  `plugins/tmux/scripts/cpu_info.sh` (proves tpm ran and dracula loaded).
  `tmux -L test kill-server` when done.
- `command -v lazygit` → `/opt/homebrew/bin/lazygit`; both custom commands
  (`b` bulk-delete gone branches, `F` fix worktree) present in the UI.
- wezterm still renders in `FiraCode Nerd Font Mono`.

## Open assumptions

- "and go" in the approval was read as the go-ahead, not a request to add
  the Go toolchain. `go` remains in `Brewfile.extras`.
- Target machines are Apple Silicon Macs (justifies the hardcoded prefix).
- tpm's auto-clone branch was verified to fire and clone tpm correctly in an
  isolated `HOME` — that covers the `if-shell` quoting, which is the part
  easy to get wrong. The chained `install_plugins` populating *every* plugin
  on a genuinely fresh machine is **unverified**: tpm resolves
  `TMUX_PLUGIN_MANAGER_PATH` through environment this machine cannot fully
  fake (it kept resolving to the real `~/.config/tmux/plugins/` even with
  `HOME` and `XDG_CONFIG_HOME` overridden), so a faithful test needs a real
  fresh machine or a container. `prefix + I` is the fallback either way.
