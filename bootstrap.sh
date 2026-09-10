#!/usr/bin/env bash
set -euo pipefail

DOTFILES="${DOTFILES:-$HOME/dotfiles}"

# 1. Homebrew
command -v brew >/dev/null || \
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
eval "$(/opt/homebrew/bin/brew shellenv)"

# 2. stow, before anything can be linked
brew install stow

# 3. These directories must exist BEFORE stow runs. Stow folds a directory -
#    symlinks the whole thing into the repo - only when the target does not
#    already exist. A folded ~/.config/tmux would make tpm write plugins and
#    multi-megabyte logs straight into version control, and a folded
#    ~/.config/lazygit would put lazygit's state into a public repo. The same
#    applies to ~/.config/herdr, which holds herdr.sock, herdr-client.sock,
#    session.json and .plugins.lock - live sockets and session state.
mkdir -p "$HOME/.config/tmux" "$HOME/.config/wezterm" "$HOME/.config/lazygit" \
         "$HOME/.config/herdr"

# 4. link the packages
cd "$DOTFILES"
#    -R (restow = unstow, then stow) rather than a plain stow, so this script
#    doubles as the update path. Plain stow only ever adds links: a config file
#    renamed or deleted in this repo since the last run leaves its old symlink
#    behind in ~/.config, dangling and invisible. -R clears those orphans. On a
#    machine that has never been stowed the unstow half is a no-op, so this is
#    also correct on a fresh install.
stow -n -R -v tmux wezterm zsh lazygit starship herdr   # dry run first, always
stow -R -v tmux wezterm zsh lazygit starship herdr

# 5. everything the configs depend on
brew bundle install --file="$DOTFILES/Brewfile"

# 6. Go tools for nvim's gopher.nvim (lua/custom/plugins/gopher.lua in the
#    kickstart-modular.nvim repo). The plugin installs these itself, but only
#    from a PackChanged autocmd that fires on plugin install/update - a machine
#    that has the plugin already will never re-run it, and the call is wrapped
#    in pcall + `silent!`, so a failure leaves no trace. Installing them here
#    makes bootstrap the source of truth. None of these are in Homebrew except
#    gomodifytags, gotests and delve; installing that subset with brew would put
#    a second copy in /opt/homebrew/bin that ~/go/bin shadows anyway, since
#    .zshrc puts $HOME/go/bin first on PATH. So: one mechanism, go install.
go_tools=(
  github.com/koron/iferr@latest
  github.com/josharian/impl@latest
  github.com/fatih/gomodifytags@latest
  github.com/cweill/gotests/...@develop
  olexsmir.xyz/json2go/cmd/json2go@latest
  github.com/go-delve/delve/cmd/dlv@latest
)
for tool in "${go_tools[@]}"; do
  echo "go install $tool"
  go install "$tool"
done

# 7. NVM_DIR must exist. Brew's nvm.sh wrapper creates it on load, so this is
#    belt-and-braces rather than strictly required.
mkdir -p "$HOME/.nvm"

# 8. tmux plugins: tmux.conf clones tpm itself on first launch. If the
#    plugins do not appear, press prefix + I once.

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
