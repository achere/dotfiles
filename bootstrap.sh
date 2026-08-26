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

# 6. NVM_DIR must exist. Brew's nvm.sh wrapper creates it on load, so this is
#    belt-and-braces rather than strictly required.
mkdir -p "$HOME/.nvm"

# 7. tmux plugins: tmux.conf clones tpm itself on first launch. If the
#    plugins do not appear, press prefix + I once.
