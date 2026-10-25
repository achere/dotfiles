# Nested shells (herdr, tmux panes) re-run this file; keep each PATH entry once.
typeset -U path

# setup brew env. The output of `brew shellenv` is cached, since running brew
# costs ~20 ms per shell. The cache is rebuilt when a brew update changes the
# script that prints it, or on every start if that script ever moves.
brew_env=$HOME/.cache/zsh/brew-shellenv.zsh
brew_src=/opt/homebrew/Library/Homebrew/cmd/shellenv.sh
if [[ ! -s $brew_env || ! -e $brew_src || $brew_src -nt $brew_env ]]; then
  mkdir -p ${brew_env:h}
  # A fixed PATH and shell name, so the cache never depends on the shell that
  # built it: shellenv prints nothing when PATH already starts with brew's dirs,
  # and otherwise guesses the shell from its parent process. Written aside, then
  # moved: shells starting together never read half a file.
  PATH=/usr/bin:/bin:/usr/sbin:/sbin /opt/homebrew/bin/brew shellenv zsh >| $brew_env.$$ &&
    [[ -s $brew_env.$$ ]] && mv -f $brew_env.$$ $brew_env || rm -f $brew_env.$$
fi
source $brew_env
unset brew_env brew_src

# After brew shellenv, which prepends its own dirs: tools installed outside
# Homebrew (native claude in ~/.local/bin, `go install`) must win over any
# Homebrew copy of the same name. The array form is what applies -U: a plain
# PATH="..." assignment keeps duplicates.
path=("$HOME/.local/bin" "$HOME/go/bin" $path)

# to make apps look for home config instead of "Application Support" busines
export XDG_CONFIG_HOME="$HOME/.config"

bindkey -v # vi mode
bindkey -M viins '^P' up-history
bindkey -M viins '^N' down-history

eval "$(fzf --zsh)"

eval "$(starship init zsh)"

eval "$(zoxide init zsh)"

# kubectl, herdr, bd and minikube need no setup here: their Homebrew formulae
# install completion scripts into site-functions, which `brew shellenv` puts on
# fpath, so compinit loads each one on its first Tab.
autoload -Uz compinit
compinit

# Except minikube's script, which is bash completion behind a shim: loaded from
# fpath, its first Tab only registers it (via bashcompinit) and completes
# nothing. Sourcing it up front costs ~25 ms per start, so this stub sources it
# on the first Tab and hands that Tab to the completer it registered.
_minikube() {
  source "$HOMEBREW_PREFIX/share/zsh/site-functions/_minikube"
  [[ $_comps[minikube] != _minikube ]] && eval "$_comps[minikube]"
}

source "$HOMEBREW_PREFIX/opt/zsh-autosuggestions/share/zsh-autosuggestions/zsh-autosuggestions.zsh"

source "$HOMEBREW_PREFIX/opt/zsh-fast-syntax-highlighting/share/zsh-fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"

export KUBE_EDITOR='nvim' # Kubernetes editor

alias lg='lazygit'
alias k='kubectl'
alias ls='ls -lahG' # BSD ls: -G colors only when stdout is a tty (no --color=auto)

# Heroku CLI complains without this
export NODE_EXTRA_CA_CERTS="$HOMEBREW_PREFIX/etc/ca-certificates/cert.pem"

# Enable LSP tool for Claude Code
export ENABLE_LSP_TOOL=1

# vi-mode: j/k move between lines of the command, never through history.
# Keep LAST - must load after fzf/autosuggestions/fast-syntax-highlighting so
# nothing else rebinds these keys.
#
# Enter grows the buffer instead of submitting while a command ends in a
# trailing `\`, since zsh would otherwise drop it into a fresh single-line
# buffer with nothing left for j/k to move through. Ctrl-J still force-submits.
accept-line-or-continue() {
  local trail=${BUFFER##*[^\\]}        # trailing run of backslashes
  local -i atend=0
  if (( CURSOR == ${#BUFFER} )); then
    atend=1                            # insert mode: cursor sits past last char
  elif [[ $KEYMAP == vicmd ]] && (( CURSOR == ${#BUFFER} - 1 )); then
    atend=1                            # normal mode: cursor sits *on* last char
  fi
  if (( atend && ${#trail} % 2 )); then
    BUFFER+=$'\n'
    CURSOR=${#BUFFER}
  else
    zle accept-line
  fi
}
zle -N accept-line-or-continue
# autosuggestions wraps unknown widgets as "modify" widgets, which put the
# suggestion back after accept-line cleared it - it then lingers, unstyled
# (white), in the submitted line. Mark this one as clearing.
ZSH_AUTOSUGGEST_CLEAR_WIDGETS+=(accept-line-or-continue)
bindkey -M viins '^M' accept-line-or-continue
bindkey -M vicmd '^M' accept-line-or-continue

# j/k (and -/+) move within the command only. Guarded so they are a silent
# no-op on the first/last line rather than beeping or pulling in history.
vi-up-line-nobeep()   { [[ $LBUFFER == *$'\n'* ]] && zle up-line;   return 0 }
vi-down-line-nobeep() { [[ $RBUFFER == *$'\n'* ]] && zle down-line; return 0 }
zle -N vi-up-line-nobeep
zle -N vi-down-line-nobeep
bindkey -M vicmd 'k' vi-up-line-nobeep
bindkey -M vicmd 'j' vi-down-line-nobeep
bindkey -M vicmd -- '-' vi-up-line-nobeep    # `--`: bindkey reads a bare - as a flag
bindkey -M vicmd -- '+' vi-down-line-nobeep

# History now lives only on Ctrl-P / Ctrl-N, in both keymaps.
bindkey -M vicmd '^P' up-history
bindkey -M vicmd '^N' down-history

# machine-local overrides, not tracked in the dotfiles repo
[ -f ~/.zshrc.local ] && source ~/.zshrc.local
