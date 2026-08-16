# Portable dotfiles via GNU Stow — design

**Date:** 2026-08-16
**Status:** approved, pending implementation plan

## Goal

Make the tmux, wezterm, zsh, and lazygit configs reproducible on a new
machine from a single public git repo, using GNU Stow for symlink
management and a Homebrew `Brewfile` to declare the software those configs
depend on.

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
  `/Users/achere/`). Its MacPorts `PATH` block was removed as part of the
  MacPorts teardown below. It stays uncommitted and machine-local.
- **Defensive guards.** Explicitly rejected by the user: no `[ -f ]` guards
  before `source`, no `command -v` guards before `eval`, no multi-prefix
  Homebrew probe. The stated constraint is "I'm not going to try to run it
  with no brew." The one surviving `[ -f ]` is on `~/.zshrc.local`, which is
  structural — that file is *expected* not to exist on a fresh machine.
- **MacPorts migration.** Superseded — MacPorts is being *removed* rather
  than migrated. See "lazygit" below.

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

### Stow folding behavior (important)

`~/.config` and `~/.config/tmux` already exist as real directories. Stow
therefore *descends* into them and links individual files rather than
folding (symlinking) the whole directory. This is the behavior we want:

- Only `tmux.conf` becomes a symlink.
- `~/.config/tmux/plugins/` and `~/.config/tmux/tmux-*.log` stay as real
  paths outside the repo, so tpm keeps writing outside version control and
  the 1.4 MB `tmux-server-4282.log` can never be committed by accident.

Had `~/.config/tmux` been folded, tpm would write plugins straight into the
repo. Verify with `stow -n -v <pkg>` before every real `stow`.

**This rule applies to all four packages, not just tmux.** Stow folds a
directory only when the target directory does not already exist. So the
invariant to preserve during migration is:

> Remove the four migrated **files**. Never remove their parent
> directories.

`~/.config/lazygit` is the case where this bites hardest. Delete the
directory rather than just `config.yml`, and stow will fold it — making
`~/.config/lazygit` a symlink into the repo, so any file lazygit writes
there lands in a **public** git repo. Lazygit's state currently goes to
`~/Library/Application Support/lazygit/state.yml`, but that path is
version- and XDG-dependent and is not something to rely on.

## zsh

### Split

`zsh/.zshrc` is committed. `~/.zshrc.local` is **not** — it is the
machine-local extension point, sourced at the very end.

As of the 2026-08-15 14:00 edit of `.zshrc`, every remaining line is
portable, so **`~/.zshrc.local` starts empty**. It exists for future
machine-specific additions, not because anything needs it today.

(Lines that previously would have gone there — Docker completions `fpath`,
LM Studio `PATH` — were removed from `.zshrc` by the user before this design
was finalized. The Heroku `NODE_EXTRA_CA_CERTS` line stays portable; see
below.)

### Changes to `.zshrc`

Order is load-bearing in this file. The only reordering is the one the user
explicitly requested (`compinit` above the plugins). Everything else keeps
its current position.

| Current line | Change | Rationale |
|---|---|---|
| 1 | `/Users/achere/.local/bin` → `$HOME/.local/bin` | username differs on another machine |
| 1 | drop `/opt/homebrew/bin` from the list | verified no-op — see below |
| 24 | `$(brew --prefix)` → `$HOMEBREW_PREFIX` | ~12 ms fork removed per shell start |
| 26 | `$(brew --prefix)` → `$HOMEBREW_PREFIX` | same |
| 28–31 | move `compinit` above the two plugin `source` lines | user request; upstream recommends loading fast-syntax-highlighting after `compinit` |
| 35 | delete `alias kvi='NVIM_APPNAME="nvim-kickstart_mod" nvim'` | points at `~/.config/nvim-kickstart_mod`, out of scope, absent on a new machine |
| 20 | `\. "$NVM_DIR/nvm.sh"` → `\. "$HOMEBREW_PREFIX/opt/nvm/nvm.sh"` | **fixes a silent fresh-machine failure**, see below |
| 21 | `"$NVM_DIR/bash_completion"` → `"$HOMEBREW_PREFIX/opt/nvm/etc/bash_completion.d/nvm"` | current path does not exist — dead line today |
| 39 | cert path → `"$HOMEBREW_PREFIX/etc/ca-certificates/cert.pem"` | verified identical file (same device:inode) — `/System/Volumes/Data/opt/homebrew` is the macOS firmlink for `/opt/homebrew` |
| end | add `[ -f ~/.zshrc.local ] && source ~/.zshrc.local` | machine-local extension point |

Untouched: `XDG_CONFIG_HOME`, the `bindkey` lines, `fzf`/`starship`/`zoxide`
init, `export NVM_DIR`, `KUBE_EDITOR`, `alias lg`, `ENABLE_LSP_TOOL`, and the
entire vi-mode widget block.

#### NVM: the one genuine portability bug in the current file

Lines 19–21 work on this machine by accident and would fail **silently** on
a new one.

Homebrew's `nvm` formula does not install into `~/.nvm`. Its caveats say to
`mkdir ~/.nvm` and source from the opt path. What makes it work here is a
symlink created by hand on **2023-11-15**:

```
~/.nvm/nvm.sh -> /opt/homebrew/opt/nvm/libexec/nvm.sh
```

On a fresh machine `brew install nvm` never creates that symlink, so
`[ -s "$NVM_DIR/nvm.sh" ]` is false, the `&&` short-circuits, and nvm simply
never loads. No error — `nvm` is just missing.

Line 21 is worse: `~/.nvm/bash_completion` **does not exist on this machine
either**, so nvm completion has never actually loaded. Verified by `ls`.
Brew's real path is `$HOMEBREW_PREFIX/opt/nvm/etc/bash_completion.d/nvm`
(2299 bytes, present).

Corrected block, matching brew's own caveats:

```zsh
export NVM_DIR="$HOME/.nvm"
[ -s "$HOMEBREW_PREFIX/opt/nvm/nvm.sh" ] && \. "$HOMEBREW_PREFIX/opt/nvm/nvm.sh"
[ -s "$HOMEBREW_PREFIX/opt/nvm/etc/bash_completion.d/nvm" ] && \. "$HOMEBREW_PREFIX/opt/nvm/etc/bash_completion.d/nvm"
```

`NVM_DIR` stays `$HOME/.nvm` — brew's caveats warn that leaving it at the
Cellar path destroys nvm-installed Node versions on upgrade. `bootstrap.sh`
must therefore `mkdir -p "$HOME/.nvm"`.

Note on the guard policy: these two `[ -s ]` guards are **pre-existing** in
the user's file, not additions. Keeping them changes nothing about the
rejected-failsafe decision — the fix is to the paths they test, not to the
presence of the test. `~/.nvm/versions/node/` is currently empty, so no
installed Node versions are at risk during migration.

#### Why dropping `/opt/homebrew/bin` from line 1 is safe

Modern `brew shellenv` does not export `PATH` directly. It emits:

```zsh
export HOMEBREW_PREFIX="/opt/homebrew";
export HOMEBREW_CELLAR="/opt/homebrew/Cellar";
export HOMEBREW_REPOSITORY="/opt/homebrew";
fpath[1,0]="/opt/homebrew/share/zsh/site-functions";
export FPATH;
eval "$(/usr/bin/env PATH_HELPER_ROOT="/opt/homebrew" /usr/libexec/path_helper -s)"
```

PATH construction is delegated to macOS `path_helper` with
`PATH_HELPER_ROOT`, which places `$ROOT/bin` and `$ROOT/sbin` at the front
**and deduplicates**. That is why the live `PATH` has no duplicate
`/opt/homebrew/bin` today despite lines 1 and 4 both nominally adding it —
line 1's copy is silently discarded four lines later.

Verified in a sandboxed zsh (`ZDOTDIR` pointing at a scratch dir). Leading
`PATH` entries, current vs. proposed:

| # | current | proposed |
|---|---|---|
| 1 | `/opt/homebrew/bin` | `/opt/homebrew/bin` |
| 2 | `/opt/homebrew/sbin` | `/opt/homebrew/sbin` |
| 3 | `/Users/achere/.local/bin` | `/Users/achere/.local/bin` |
| 4 | `/Users/achere/go/bin` | `/Users/achere/go/bin` |

Identical. Line 1 must still run *before* the `shellenv` eval — that
ordering is what keeps brew's bin ahead of `~/.local/bin`.

#### Homebrew prefix is hardcoded, on purpose

`eval "$(/opt/homebrew/bin/brew shellenv)"` stays as-is, hardcoded to the
Apple Silicon prefix. The multi-prefix probe was rejected. Net effect is
still an improvement: the prefix is hardcoded in **one** place instead of
two, and it is the single line to change for an Intel Mac (`/usr/local`) or
Linux (`/home/linuxbrew/.linuxbrew`).

#### Plugin sourcing form

Inline, unguarded, quoted:

```zsh
source "$HOMEBREW_PREFIX/opt/zsh-autosuggestions/share/zsh-autosuggestions/zsh-autosuggestions.zsh"
source "$HOMEBREW_PREFIX/opt/zsh-fast-syntax-highlighting/share/zsh-fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"
```

A `_src()` helper-function form was tested and rejected. It works — both
plugins use `typeset -g` correctly, so the zsh function-scope hazard (where
unqualified assignments inside a sourced-in-function file become local and
vanish) does not bite them; verified identical `_zsh_autosuggest_start`,
`ZSH_AUTOSUGGEST_STRATEGY`, `FAST_HIGHLIGHT`, `FAST_BASE_DIR`, and `precmd`
hooks under both forms. With only two call sites the helper saves nothing
and keeps the hazard live for any future plugin that is less well-behaved.

### Resulting file order

1. `PATH` (`.local/bin`, `go/bin`)
2. `brew shellenv` → exports `$HOMEBREW_PREFIX`
3. `XDG_CONFIG_HOME`
4. `bindkey -v` + viins `^P`/`^N`
5. `fzf` / `starship` / `zoxide`
6. NVM
7. `compinit`  *(moved up)*
8. `kubectl` completion
9. `zsh-autosuggestions`  *(moved down)*
10. `zsh-fast-syntax-highlighting`  *(moved down)*
11. `KUBE_EDITOR`, `alias lg`, `NODE_EXTRA_CA_CERTS`, `ENABLE_LSP_TOOL`
12. vi-mode widget block  *(unchanged)*
13. `source ~/.zshrc.local`

The user's invariant from the vi-mode block's own comment — "it has to load
after fzf/autosuggestions/fast-syntax-highlighting so nothing rebinds these
keys afterwards" — holds: 12 follows 5, 9, and 10.

`~/.zshrc.local` is sourced at 13, after the vi-mode block, so a local
override can win. Approved by the user.

## tmux

One change. Line 74 currently reads:

```tmux
run '/opt/homebrew/opt/tpm/share/tpm/tpm'
```

This is not merely a hardcoded prefix — it loads **stale software**. The
brew-installed tpm is dated **Jan 2023**, while a current tpm clone from
**Jan 2026** already sits unused at `~/.config/tmux/plugins/tpm` (tpm cloned
itself there because `tmux.conf:41` lists `@plugin 'tmux-plugins/tpm'`).

Replace with the upstream-standard self-managing form:

```tmux
# auto-install tpm on a fresh machine
if "test ! -d ~/.config/tmux/plugins/tpm" \
   "run 'git clone https://github.com/tmux-plugins/tpm ~/.config/tmux/plugins/tpm && \
         ~/.config/tmux/plugins/tpm/bin/install_plugins'"

run '~/.config/tmux/plugins/tpm/tpm'
```

`run-shell` and `if-shell` execute via `/bin/sh`, so `~` expands. Effects:
no hardcoded prefix, works on Linux, self-heals on a fresh machine, uses
current tpm, and `tpm` drops out of the `Brewfile`.

**Verification:** `tmux kill-server; tmux` — the dracula status bar
rendering is the observable that proves tpm actually ran. Do not assume it
loaded; tmux quoting is easy to get subtly wrong.

## wezterm

`wezterm.lua` is already fully portable — no absolute paths, no
username. Moved into the stow package unchanged.

Its font dependencies are currently undeclared, which is a real portability
gap: `FiraCode Nerd Font Mono` must come from the Brewfile. `Roboto` (used
in `window_frame`) needs nothing — wezterm bundles it.

## lazygit

`config.yml` (710 B, two `customCommands`) is portable as-is.

The binary is not: it is currently a **MacPorts** install at
`/opt/local/bin/lazygit`, so a brew-only machine would get the config and no
program.

### Switch to Homebrew, then remove MacPorts entirely

`port` cannot run at all (platform mismatch: `darwin 25` vs expected
`darwin 23`). Migration was considered and rejected — it would rebuild
lazygit 0.43.1, the exact package being replaced.

The decisive fact: **MacPorts had exactly one package installed.**
`/opt/local/var/macports/software/` contained only `lazygit`; of the seven
binaries in `/opt/local/bin`, six were MacPorts' own machinery (`port`,
`portf`, `portindex`, `portmirror`, `port-tclsh`, `daemondo`). Nothing else
on the system depended on it.

Order matters — brew's lazygit must be installed **before** MacPorts is
removed, or there is a window with no lazygit at all:

1. Back up both lazygit config locations to a timestamped tarball.
2. `brew install lazygit` — 0.64.1 shadows MacPorts' 0.43.1 immediately
   (`/opt/homebrew/bin` is PATH #1, `/opt/local/bin` was #5).
3. Verify brew's binary resolves and parses the config.
4. Remove the MacPorts `PATH` block from `~/.zprofile`.
5. `sudo rm -rf /opt/local /var/db/receipts/org.macports.MacPorts.bom
   /var/db/receipts/org.macports.MacPorts.plist` — the complete footprint;
   `/Applications/MacPorts`, `/Library/Tcl/macports1.0`, and the MacPorts
   LaunchDaemons plist were all verified absent. Frees ~555 MB.
6. Re-verify lazygit.

### Backup first

Two locations, one of which is a decoy:

- `~/.config/lazygit/config.yml` — 710 B, the real config. **This is the one
  that matters.**
- `~/Library/Application Support/lazygit/` — legacy, from before
  `XDG_CONFIG_HOME` was set. `config.yml` there is **0 bytes**; `state.yml`
  (1.5 KB) is recent-repos state, not config.

Neither `brew install` nor any future `port uninstall` writes to either
path, so risk is low — but tar both to a timestamped archive before
touching anything, as requested.

**Verification.** `lazygit -c` prints the *default* config, not the merged
one, so it proves nothing. The working check is `lazygit -ucf <file>` with a
deliberately malformed YAML file as a control: the control must fail with a
parse error while the real config gets past parsing. Plus `command -v
lazygit` → `/opt/homebrew/bin/lazygit`, and both custom commands (`b`
bulk-delete gone branches, `F` fix worktree) visible in the UI.

## Brewfile

Curated — one line per thing these dotfiles actually need, each traceable to
a config that references it.

```ruby
# --- referenced by .zshrc ---
brew "fzf"                          # :13
brew "starship"                     # :15
brew "zoxide"                       # :17
brew "nvm"                          # :19-21
brew "kubernetes-cli"               # :31  provides kubectl
brew "neovim"                       # :33  KUBE_EDITOR='nvim'
brew "lazygit"                      # :36  alias lg
brew "ca-certificates"              # :39  provides etc/ca-certificates/cert.pem
brew "zsh-autosuggestions"          # :24
brew "zsh-fast-syntax-highlighting" # :26

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

Naming traps confirmed against the live machine:

- `kubectl` is **not** a formula — it ships in `kubernetes-cli` (1.36.3).
  `brew "kubectl"` fails.
- Both `tree-sitter` and `tree-sitter-cli` (0.26.12) are installed;
  `tree-sitter-cli` is the one in `brew leaves`, i.e. the explicit install,
  and it pulls the library in as a dependency.

Deliberately absent:

- `tpm` — de-brewed, see tmux above.
- `zsh-syntax-highlighting` — installed but never sourced; only the `fast`
  variant is used.
- `zsh-completions` — the `FPATH` line that used it was removed from
  `.zshrc` on 2026-08-15; user confirmed the removal is intentional.

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

# 3. link the packages
cd "$DOTFILES"
stow -n -v tmux wezterm zsh lazygit   # dry run first, always
stow -v tmux wezterm zsh lazygit

# 4. everything the configs depend on
brew bundle install --file="$DOTFILES/Brewfile"

# 5. NVM_DIR must exist; brew's nvm formula does not create it
mkdir -p "$HOME/.nvm"

# 6. tmux plugins install themselves on first `tmux` launch (see tmux above)
```

`bootstrap.sh` is the only place the Apple Silicon brew path appears outside
`.zshrc`.

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

Out-of-scope secrets — `~/.netrc` (mode 600), `~/.aws/`, `~/.kube/`,
`~/.gnupg/`, `~/.docker/config.json` — are never referenced by any stow
package and must stay that way. This is a public repo.

## Migration on this machine

Distinct from fresh-machine bootstrap. For each package: `git add` and
commit the file into the repo **before** removing the original, then
`stow -n -v` to preview, then `stow`.

0. Set a repo-local git identity once —
   `git -C ~/dotfiles config user.name/user.email`. The global `.gitconfig`
   has both **commented out**, so commits otherwise fail or get attributed
   to `achere@Alexanders-MacBook-Pro.local`.
1. Copy `~/.zshrc`, `~/.config/tmux/tmux.conf`,
   `~/.config/wezterm/wezterm.lua`, `~/.config/lazygit/config.yml` into
   their package paths; apply the edits above.
2. Commit.
3. Back up lazygit (both locations) to a timestamped tarball.
4. Remove the four original **files** — not their parent directories. See
   the folding rule above; deleting `~/.config/lazygit/` as a directory
   would cause stow to fold it.
5. `stow -n -v tmux wezterm zsh lazygit`, inspect, then `stow` for real.
6. `brew install lazygit`.
7. Verify.

## Verification checklist

Evidence, not assertion — each item has a command and an observable:

- `stow -n -v <pkg>` shows only the intended links, no folded directories.
- `ls -l ~/.zshrc ~/.config/tmux/tmux.conf ~/.config/wezterm/wezterm.lua
  ~/.config/lazygit/config.yml` — all four are symlinks into `~/dotfiles`.
- A new zsh starts clean, no errors; `echo $HOMEBREW_PREFIX` is non-empty;
  `print -l $path | head -4` matches the table above.
- `command -v nvm` reports `nvm` as a shell function, **and** `nvm --version`
  succeeds. This is the check that would have caught the fresh-machine bug;
  the old form fails it silently, so absence of an error proves nothing.
- Stow created no folded directories:
  `find ~/.config -maxdepth 1 -type l` returns nothing for `tmux`,
  `wezterm`, or `lazygit`.
- vi-mode still works: `j`/`k` move within a multi-line command, `Ctrl-P` /
  `Ctrl-N` reach history, a trailing `\` grows the buffer instead of
  submitting.
- `tmux kill-server; tmux` — dracula status bar renders (proves tpm ran).
- `command -v lazygit` → `/opt/homebrew/bin/lazygit`; both custom commands
  present in the UI.
- `git -C ~/dotfiles status --porcelain` — no `.log`, no `.DS_Store`, no
  `plugins/`, no `.zshrc.local`.
- `brew bundle check --file=Brewfile` passes.

## Open assumptions

- "and go" in the approval was read as the go-ahead, not a request to add
  the Go toolchain. `go` remains in `Brewfile.extras`.
- Target machines are Apple Silicon Macs (justifies the hardcoded prefix).
- `fast-syntax-highlighting` loading *before* `compinit` in the current file
  was flagged as an upstream-recommendation deviation; the user chose to fix
  it, which is why `compinit` moves up.
