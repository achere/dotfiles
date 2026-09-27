# ~/dotfiles

Shell, terminal, tmux, herdr, lazygit… config, linked into `$HOME` with GNU
Stow — one package per top-level directory. `bootstrap.sh` sets up a fresh
machine and doubles as the update path (restow, `brew bundle`). `Brewfile`
holds only what these configs reference; `Brewfile.extras` is optional apps.

- Before stowing a new package whose `~/.config/<dir>` gets runtime state,
  add that dir to bootstrap's `mkdir -p` step, or stow folds it into the repo.
- Stay agent-agnostic: coding-agent config, its tools and its hook installers
  live in a separate repo that depends on this one, never the reverse. Don't
  add agent-only formulae, setup steps or pointers to that repo here.
- Design history: `docs/superpowers/`.
