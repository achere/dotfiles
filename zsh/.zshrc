export PATH="$HOME/.local/bin:$HOME/go/bin:$PATH"

# setup brew env
eval "$(/opt/homebrew/bin/brew shellenv)"

# to make apps look for home config instead of "Application Support" busines
export XDG_CONFIG_HOME="$HOME/.config"

bindkey -v # vi mode
bindkey -M viins '^P' up-history
bindkey -M viins '^N' down-history

eval "$(fzf --zsh)"

eval "$(starship init zsh)"

eval "$(zoxide init zsh)"

autoload -Uz compinit
compinit

# Must stay BELOW compinit. nvm's completion file runs its own compinit when it
# finds none, then registers via bashcompinit - and a second compinit afterwards
# resets the completion table and silently drops that registration.
export NVM_DIR="$HOME/.nvm"
[ -s "$HOMEBREW_PREFIX/opt/nvm/nvm.sh" ] && \. "$HOMEBREW_PREFIX/opt/nvm/nvm.sh"  # This loads nvm
[ -s "$HOMEBREW_PREFIX/opt/nvm/etc/bash_completion.d/nvm" ] && \. "$HOMEBREW_PREFIX/opt/nvm/etc/bash_completion.d/nvm"  # This loads nvm bash_completion

source <(kubectl completion zsh)

source "$HOMEBREW_PREFIX/opt/zsh-autosuggestions/share/zsh-autosuggestions/zsh-autosuggestions.zsh"

source "$HOMEBREW_PREFIX/opt/zsh-fast-syntax-highlighting/share/zsh-fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"

export KUBE_EDITOR='nvim' # Kubernetes editor

alias lg='lazygit'

# Heroku CLI complains without this
export NODE_EXTRA_CA_CERTS="$HOMEBREW_PREFIX/etc/ca-certificates/cert.pem"

# Enable LSP tool for Claude Code
export ENABLE_LSP_TOOL=1

# ---------------------------------------------------------------------------
# vi-mode: j/k move between lines of the command, never through history.
#
# Keep this block LAST in .zshrc - it has to load after fzf/autosuggestions/
# fast-syntax-highlighting so nothing rebinds these keys afterwards.
#
# Why the widget below is needed: zsh does NOT keep a `\`-continued command in
# one edit buffer. Pressing Enter after a trailing `\` submits the line and
# reopens a *fresh, single-line* buffer at the PS2 prompt. The earlier lines are
# still on screen but no longer editable, so j/k had no lines to move between
# and fell straight through to history. Keeping the whole command in one buffer
# is what makes line-wise motion possible in the first place.

# Enter: if the command is unfinished (ends in an odd number of backslashes),
# grow the buffer by one line instead of submitting. Ctrl-J still force-submits.
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
