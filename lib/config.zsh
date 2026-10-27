# Shared settings loader for panel.zsh and jira.zsh.
# User config lives in herdr's per-plugin config dir so plugin updates never overwrite it.
JL_ROOT="${JL_ROOT:-${0:A:h:h}}"
JL_CONFIG_DIR="${JIRA_LIGHT_CONFIG_DIR:-${HERDR_PLUGIN_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-jira-light}}"
JL_PLUGIN_ID="${JIRA_LIGHT_PLUGIN_ID:-${HERDR_PLUGIN_ID:-christiandeckert.jira-light}}"
JL_STATE_DIR="${JIRA_LIGHT_STATE_DIR:-${HERDR_PLUGIN_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-jira-light}}"
JL_CONFIG="$JL_CONFIG_DIR/config.zsh"

# config.zsh declares filters with these two words; see defaults/config.zsh. A path declared again (as
# pinning does) continues its first context, keeping that context's name.
context() { # path [name]
  local p=${1/#\~/$HOME} i
  p=${p:A}
  i=${CTX_PATH[(Ie)$p]}
  if (( i )); then JL_SCOPE=$i; return; fi
  CTX_PATH+=("$p") CTX_NAME+=("${2:-${p:t}}")
  JL_SCOPE=${#CTX_PATH}
}

filter() { # name jql
  FLT_CTX+=($JL_SCOPE) FLT_NAME+=("$1") FLT_JQL+=("$2")
}

# Re-reading the config starts from the defaults again, so a setting removed from the file goes back to
# its default instead of keeping the old value.
jl_load_config() {
  typeset -ga CTX_PATH=() CTX_NAME=() FLT_CTX=() FLT_NAME=() FLT_JQL=()
  typeset -g JL_SCOPE=0
  typeset -g JIRA_BASE_URL="" JIRA_AUTH=bearer JIRA_EMAIL="" JIRA_TOKEN="" JIRA_TOKEN_CMD=""
  typeset -g JIRA_MAX_RESULTS=50 JIRA_REFRESH_SECS=180 JIRA_INHERIT_GLOBAL=1
  typeset -g JIRA_WIDTH=72 JIRA_RATIO="" JIRA_APPEARANCE=auto JIRA_UPDATE_CHECK=on
  typeset -g JIRA_BRANCH_TEMPLATE='feature/{key}-{slug}'
  typeset -g JIRA_AGENT_PROMPT='Work on Jira issue {key}: {summary}\n{url}'
  JL_CONFIG_ERROR=""
  if [[ -f "$JL_CONFIG" ]]; then
    local errfile="$JL_STATE_DIR/config.err"
    source "$JL_CONFIG" 2>"$errfile"
    if [[ -s $errfile ]]; then
      local -a lines=("${(@f)$(<$errfile)}")
      JL_CONFIG_ERROR="config: $lines[1]"
    fi
  fi
  JIRA_BASE_URL=${JIRA_BASE_URL%/}
  [[ -z $JIRA_BASE_URL && -z $JL_CONFIG_ERROR ]] && JL_CONFIG_ERROR="set JIRA_BASE_URL in $JL_CONFIG"
  (( ${#FLT_NAME} )) || filter "My open issues" 'assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC'
}

mkdir -p "$JL_STATE_DIR/cache" 2>/dev/null
if mkdir -p "$JL_CONFIG_DIR" 2>/dev/null; then
  [[ -f "$JL_CONFIG" ]] || cp "$JL_ROOT/defaults/config.zsh" "$JL_CONFIG" 2>/dev/null
fi
jl_load_config

# Jira panes are recognized by their title "jira" while the TUI runs, or by their working directory:
# herdr runs plugin panes in the plugin root and restores them there, as plain shells, after a server
# restart. Linked installs skip the directory test, since a developer's own shells may sit in the root.
if [[ $JL_ROOT == */checkout && ${JL_ROOT:h:h:t} == "${JL_PLUGIN_ID}-"* ]]; then
  JL_PANE_HOME="${JL_ROOT:h:h}/"
else
  JL_PANE_HOME=""
fi
JL_PANE_JQ='def jira: .terminal_title_stripped == "jira" or .label == "jira"
  or ($home != "" and ((.cwd // "") | startswith($home)));'
jl_jq() { jq --arg home "$JL_PANE_HOME" "$@" }
