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
#    ~/.config/lazygit would put lazygit's state into a public repo.
mkdir -p "$HOME/.config/tmux" "$HOME/.config/wezterm" "$HOME/.config/lazygit"

# 4. link the packages
cd "$DOTFILES"
stow -n -v tmux wezterm zsh lazygit starship   # dry run first, always
stow -v tmux wezterm zsh lazygit starship

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
