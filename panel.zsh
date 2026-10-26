#!/bin/zsh
# Manages the Jira pane:
#   toggle   open/close it in the current tab
#   refresh  make the current tab's Jira pane fetch again
#   restore  on startup, swap Jira panes that herdr restored as plain shells for running ones
H="${HERDR_BIN_PATH:-herdr}"
ROOT="${0:A:h}"
JL_ROOT=$ROOT
source "$ROOT/lib/config.zsh"
LABEL="jira"

panes() { "$H" pane list | jq -c '.result.panes' }

# Jira panes matching a jq filter on tab/workspace
jl_panes() { # panes-json filter
  print -r -- "$1" | jl_jq -r "$JL_PANE_JQ .[] | select($2) | select(jira) | .pane_id"
}

current_tab() {
  REPLY="${HERDR_TAB_ID:-$("$H" pane list | jq -r '.result.panes[] | select(.focused) | .tab_id')}"
}

# herdr starts the pane without the user's shell, closes it when jira.zsh exits, and always splits
# plugin panes 50/50, so the width is applied afterwards.
open_right_of() { # pane
  local new
  new=$("$H" plugin pane open --plugin "$JL_PLUGIN_ID" --entrypoint jira --placement split \
          --target-pane "$1" --direction right --focus | jq -r '.result.plugin_pane.pane.pane_id // empty')
  if [[ -z "$new" ]]; then
    print -u2 "jira-light: could not open a plugin pane next to $1"
    return 1
  fi
  size_panel "$1" "$new"
}

# Gives the pane JIRA_WIDTH content columns, at most half of its split, or the fixed share JIRA_RATIO.
# A pane's frame takes 3 columns. herdr's resize amount is a change of the split's ratio.
size_panel() { # main-pane jira-pane
  local mw pw w panel want now delta dir=right
  read -r mw pw < <("$H" pane layout --pane "$2" | jq -r --arg a "$1" --arg b "$2" \
    '.result.layout.panes as $p | [($p[] | select(.pane_id == $a) | .rect.width), ($p[] | select(.pane_id == $b) | .rect.width)] | @tsv')
  if [[ -z "$pw" ]] || (( mw + pw <= 0 )); then
    print -u2 "jira-light: no layout for $1 and $2, keeping the split as it is"
    return 1
  fi
  w=$(( mw + pw ))
  if [[ -n "$JIRA_RATIO" ]]; then
    want=$(printf '%.0f' $(( JIRA_RATIO * 1000 )))
  else
    panel=$(( JIRA_WIDTH + 3 ))
    (( panel > w / 2 )) && panel=$(( w / 2 ))
    want=$(( (w - panel) * 1000 / w ))
  fi
  now=$(( mw * 1000 / w ))
  delta=$(( want - now ))
  (( delta < 0 )) && { dir=left; delta=$(( -delta )) }
  (( delta < 3 )) && return
  "$H" pane resize --pane "$1" --direction $dir --amount $(printf '0.%03d' $delta) >/dev/null
}

# Closes a Jira pane that runs a plain shell and opens a running one in its tab.
replace() { # pane
  local all tab target
  all=$(panes)
  tab=$(print -r -- "$all" | jq -r --arg p "$1" '.[] | select(.pane_id == $p) | .tab_id')
  target=$(print -r -- "$all" | jl_jq -r --arg t "$tab" \
    "$JL_PANE_JQ"' [.[] | select(.tab_id == $t and (jira | not))][0].pane_id // empty')
  [[ -n "$target" ]] || return
  "$H" pane close "$1" >/dev/null && open_right_of "$target"
}

case "$1" in
  toggle)
    current_tab; tab=$REPLY
    all=$(panes)
    existing=($(jl_panes "$all" ".tab_id == \"$tab\""))
    if (( ${#existing} )); then
      for p in $existing; do "$H" pane close "$p" >/dev/null; done
    else
      target="${HERDR_PANE_ID:-$(print -r -- "$all" | jq -r --arg t "$tab" '[.[] | select(.tab_id == $t)][0].pane_id // empty')}"
      [[ -n "$target" ]] && open_right_of "$target"
    fi ;;
  refresh)
    current_tab; tab=$REPLY
    for p in $(jl_panes "$(panes)" ".tab_id == \"$tab\""); do "$H" pane send-text "$p" r >/dev/null; done ;;
  restore)
    # a pane that is running jira.zsh carries its title; one restored as a shell doesn't
    all=$(panes)
    for p in $(jl_panes "$all" "true"); do
      print -r -- "$all" | jq -e --arg p "$p" --arg l "$LABEL" \
        '.[] | select(.pane_id == $p and .terminal_title_stripped == $l)' >/dev/null || replace "$p"
    done ;;
  *) print -u2 "usage: panel.zsh toggle|refresh|restore"; exit 2 ;;
esac
