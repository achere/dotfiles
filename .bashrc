
# .bashrc

# Source global definitions
if [ -f /etc/bashrc ]; then
	. /etc/bashrc
fi

# User specific environment
if ! [[ "$PATH" =~ "$HOME/.local/bin:$HOME/bin:" ]]
then
    PATH="$HOME/.local/bin:$HOME/bin:$PATH"
fi
export PATH

export JAVA_HOME=$(readlink -f /usr/bin/java | sed "s:/bin/java::")

# Uncomment the following line if you don't like systemctl's auto-paging feature:
# export SYSTEMD_PAGER=

# User specific aliases and functions
alias sfpush='sfdx force:source:push -u '

function sfdpl {
    sfdx force:source:deploy -u $1 -p $2
}

# sfdx autocomplete setup
SFDX_AC_BASH_SETUP_PATH=/home/achereshnev@VRP.local/.cache/sfdx/autocomplete/bash_setup && test -f $SFDX_AC_BASH_SETUP_PATH && source $SFDX_AC_BASH_SETUP_PATH;

#Bash git prompt
if [ -f "$HOME/.bash-git-prompt/gitprompt.sh" ]; then
#    GIT_PROMPT_ONLY_IN_REPO=1
    GIT_PROMPT_THEME=Single_line_Minimalist
    source $HOME/.bash-git-prompt/gitprompt.sh
fi

