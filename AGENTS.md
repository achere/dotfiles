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
- Shell startup is ~70 ms; time it with `zsh -i -c exit`. Before adding a
  `source <(tool completion zsh)` line, check for
  `$HOMEBREW_PREFIX/share/zsh/site-functions/_<tool>`: most formulae install
  one, which compinit already loads on first Tab. `.zshrc` caches
  `brew shellenv` output in `~/.cache/zsh`; delete that folder to rebuild it.
- `apps/` holds macOS apps that bootstrap builds from source; it is not a
  stow package, and a built `.app` never goes into git.
  `apps/aerc-mailto/build.sh` makes `~/Applications/Aerc Mailto.app` the
  `mailto:` handler; the logic is in `aerc/.config/aerc/mailto-aerc` (log:
  `~/Library/Logs/aerc-mailto.log`). Keep its query-key allowlist: aerc's
  `template=` takes a file path and aerc templates can run commands. It sets
  `XDG_CONFIG_HOME` for aerc; without it aerc writes default config into
  `~/Library/Preferences/aerc`.
- Design history: `docs/superpowers/`.
