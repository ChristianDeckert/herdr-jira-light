#!/bin/zsh
# Jira pane: the issues of the filters that belong to the directory of this tab's focused pane.
# Fetches run in the background into a file cache, so the pane never waits for Jira. ? lists the keys.
[[ ${LC_ALL:-${LC_CTYPE:-$LANG}} == *(UTF-8|utf8|UTF8)* ]] || export LC_CTYPE=en_US.UTF-8
H="${HERDR_BIN_PATH:-herdr}"
ROOT="${0:A:h}"
JL_ROOT=$ROOT
source "$ROOT/lib/config.zsh"
source "$ROOT/lib/jira.zsh"
source "$ROOT/lib/markup.zsh"
source "$ROOT/lib/update.zsh"
LABEL="jira"
setopt extended_glob

B=$'\e[1m' D=$'\e[2m' R=$'\e[0m' RED=$'\e[31m' GREEN=$'\e[32m' INV=$'\e[7m'
typeset -A CAT_SGR=(new $'\e[34m' indeterminate $'\e[33m' done $'\e[32m')
ORANGE=$'\e[38;5;208m'
typeset -A REOPENED
# SGR mouse reporting on, auto-wrap off (a long line is cut instead of taking a second row) and
# color-scheme reports on (CSI ?997;1n dark, ;2n light, sent whenever the theme changes).
MOUSE_ON=$'\e[?1000h\e[?1006h\e[?7l\e[?2031h' MOUSE_OFF=$'\e[?1000l\e[?1006l\e[?7h\e[?2031l'

APPEARANCE=dark
apply_palette() {
  if [[ $APPEARANCE == light ]]; then K=$'\e[38;5;128m' BAR=$'\e[48;5;254m' DRAFT=$'\e[38;5;67m' DRAFT_BADGE=$'\e[1;97;48;5;67m'
  else K=$'\e[38;5;177m' BAR=$'\e[48;5;236m' DRAFT=$'\e[38;5;117m' DRAFT_BADGE=$'\e[1;30;48;5;117m'
  fi
}

# Sets APPEARANCE from the terminal's color-scheme report, else from its background brightness.
query_theme() {
  if [[ $JIRA_APPEARANCE == (dark|light) ]]; then APPEARANCE=$JIRA_APPEARANCE; apply_palette; return; fi
  local reply="" c
  printf '\e]11;?\e\\\e[?996n' > /dev/tty
  while read -r -s -k1 -t 0.3 c </dev/tty; do
    reply+=$c
    [[ $reply == *$'\e[?997;'[12]n ]] && break
  done
  if [[ $reply =~ $'\e\\[\\?997;([12])n' ]]; then
    [[ $match[1] == 2 ]] && APPEARANCE=light || APPEARANCE=dark
  elif [[ $reply =~ 'rgb:([0-9a-fA-F]{2})[0-9a-fA-F]*/([0-9a-fA-F]{2})[0-9a-fA-F]*/([0-9a-fA-F]{2})' ]]; then
    (( 16#$match[1] * 299 + 16#$match[2] * 587 + 16#$match[3] * 114 >= 128000 )) && APPEARANCE=light || APPEARANCE=dark
  fi
  apply_palette
}

# --- terminal ------------------------------------------------------------------------------------
quiet_tty() { stty -echo -icanon </dev/tty 2>/dev/null }
normal_tty() { [[ -n $TTY_SAVED ]] && stty "$TTY_SAVED" </dev/tty 2>/dev/null }

drain() { # seconds of silence that end the drain
  local c
  while read -r -s -k1 -t "$1" c </dev/tty; do :; done
}

visible_len() { REPLY=${#${(S)1//$'\e'\[[0-9;]#m/}} }

# Sets REPLY to the line cut to the pane width; color codes are copied, only visible characters count.
fit() { # line
  local s=$1 out="" esc n=0 max=$(( COLS - 1 ))
  visible_len "$s"
  if (( REPLY <= max )); then REPLY=$s; return; fi
  while [[ -n $s ]] && (( n < max )); do
    esc=${(M)s#$'\e'\[[0-9;]#m}
    if [[ -n $esc ]]; then out+=$esc s=${s#$esc}
    else out+=${s[1]} s=${s[2,-1]}; (( n++ ))
    fi
  done
  REPLY="$out$R"
}

# A line with text on the left and text aligned to the right edge; the left text is cut to make room.
lr() { # left right
  local l r left=$1 max cols=$COLS
  visible_len "$1"; l=$REPLY
  visible_len "$2"; r=$REPLY
  max=$(( COLS - 3 - r ))
  if (( max < 8 )); then fit "$1"; return; fi
  if (( l > max )); then
    COLS=$(( max + 1 )); fit "$1"; COLS=$cols
    left=$REPLY l=$max
  fi
  REPLY="$left${(l:COLS - 1 - l - r:: :)}$2"
}

# Shows a message in the last row for a few seconds, without blocking.
note() { # message [err]
  NOTE=$1 NOTE_ERR=${2:-0} NOTE_UNTIL=$(( EPOCHSECONDS + 4 ))
  FP=""
}

# Asks for one line in this pane, prefilled with the current value; REPLY is empty when cancelled.
prompt_line() { # title hint value
  printf '%s\e[?25h\e[H\e[2J' "$MOUSE_OFF"
  printf "${B}%s${R}\n${D}%s${R}\n\n" "$1" "$2"
  drain 0.05
  normal_tty
  local v=$3
  vared -p '> ' v </dev/tty 2>/dev/null || read -r v </dev/tty
  quiet_tty
  printf '\e[?25l%s' "$MOUSE_ON"
  REPLY=$v
  FP=""
}

# Runs a command in this pane in place of the list, then waits for a key.
run_inline() { # command
  printf '%s\e[?25h\e[H\e[2J' "$MOUSE_OFF"
  printf "${B}\$ %s${R}  ${D}(Ctrl-C stops)${R}\n\n" "$1"
  normal_tty
  trap ':' INT
  zsh -c "$1"
  local rc=$? k
  trap 'exit 130' INT
  quiet_tty
  printf "\n${D}exit %s — press any key to return${R}" "$rc"
  drain 0.05
  # a late mouse report (ESC sequence) must not count as the key press
  while read -r -s -k1 k </dev/tty; do
    [[ $k == $'\e' ]] && { drain 0.05; continue }
    break
  done
  printf '\e[?25l%s' "$MOUSE_ON"
  FP=""
}

# --- where this pane is ----------------------------------------------------------------------------
# Sets DIR from the pane this tab last focused (herdr marks only the one focused pane of the active tab,
# so it is remembered in LAST_FOCUSED), and TAB_AGENTS/WS_AGENTS from the same pane list. Other plugins'
# panes (the cheat sheet, panes running in herdr's plugin folder) aren't where the user works.
PLUGINS_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/plugins/"
locate() {
  local all
  local -a r
  all=$("$H" pane list 2>/dev/null) || return
  r=("${(@f)$(print -r -- "$all" | jl_jq -r --arg t "$HERDR_TAB_ID" --arg s "$HERDR_PANE_ID" \
      --arg l "$LAST_FOCUSED" --arg w "$HERDR_WORKSPACE_ID" --arg pd "$PLUGINS_DIR" "$JL_PANE_JQ"'
    def plugin: jira or .terminal_title_stripped == "cheatsheet" or ((.cwd // "") | startswith($pd));
    .result.panes as $all
    | [$all[] | select(.tab_id == $t and .pane_id != $s and (plugin | not))] as $tab
    | ([$tab[] | select(.focused)][0]) as $f
    | ([$tab[] | select(.pane_id == ($f.pane_id // $l))] + $tab | first) as $tp
    | ($f.pane_id // ""), ($tp | if . then .foreground_cwd // .cwd // "" else "" end),
      ([$tab[] | select((.agent // "") != "") | .pane_id] | join(" ")),
      ([$all[] | select(.workspace_id == $w and (.agent // "") != "") | .pane_id] | join(" "))')}")
  [[ -n $r[1] ]] && LAST_FOCUSED=$r[1]
  DIR=${r[2]:-${DIR:-$PWD}}
  TAB_AGENTS=(${=r[3]}) WS_AGENTS=(${=r[4]})
  ALLPANES=$all
}

# --- views -----------------------------------------------------------------------------------------
# The filter and sort chosen per context are kept in the state dir, shared by all Jira panes.
VIEWS_FILE="$JL_STATE_DIR/views.zsh"
typeset -A VIEW_FILTER VIEW_SORT VIEW_REV
[[ -f $VIEWS_FILE ]] && source "$VIEWS_FILE" 2>/dev/null

ctx_key() { (( CTX )) && REPLY=$CTX_PATH[CTX] || REPLY=global }

save_view() {
  (( CTX < 0 )) && return
  ctx_key
  VIEW_FILTER[$REPLY]=$FILTER_NAME VIEW_SORT[$REPLY]=$SORT VIEW_REV[$REPLY]=$REV
  typeset -p VIEW_FILTER VIEW_SORT VIEW_REV > "$VIEWS_FILE.tmp" 2>/dev/null && mv "$VIEWS_FILE.tmp" "$VIEWS_FILE"
}

switch_context() { # ctx
  save_view
  CTX=$1 CUSTOM_JQL="" CUSTOM_NAME="" CUSTOM_CTX_NAME=""
  jl_filters_for $CTX
  ctx_key
  local want=${VIEW_FILTER[$REPLY]} i
  FIDX=1
  for (( i = 1; i <= ${#JL_FILTERS}; i++ )); do
    [[ $FLT_NAME[JL_FILTERS[i]] == "$want" ]] && { FIDX=$i; break }
  done
  SORT=${VIEW_SORT[$REPLY]:-filter} REV=${VIEW_REV[$REPLY]:-0}
  (( ${JL_SORTS[(Ie)$SORT]} )) || SORT=filter
  SEL=1 TOP=0 QUERY="" SEARCH=0
  load_entry
}

# FIDX 0 is a view: the JQL typed with J or an entry picked in the browser. It stays until the context
# changes, or until it is pinned with p.
current_filter() {
  if (( FIDX == 0 )); then FILTER_NAME=${CUSTOM_NAME:-JQL} FILTER_JQL=$CUSTOM_JQL
  else FILTER_NAME=$FLT_NAME[JL_FILTERS[FIDX]] FILTER_JQL=$FLT_JQL[JL_FILTERS[FIDX]]
  fi
}

load_entry() { # [force]
  current_filter
  jl_sorted_jql "$FILTER_JQL" $SORT $REV; JQL=$REPLY
  if [[ -n $JL_CONFIG_ERROR ]]; then ENTRY="" ROWS=() ERR=$JL_CONFIG_ERROR; apply_query; setup_check; FP=""; return; fi
  jl_search "$JQL" $1; ENTRY=$REPLY
  ENTRY_STAMP=""
  read_entry
  reopened_fetch $1
  save_view
  FP=""
}

# Re-reads the current cache entry when a fetch has finished; returns non-zero when nothing changed.
read_entry() {
  [[ -n $ENTRY ]] || return 1
  jl_entry_stamp $ENTRY
  [[ $REPLY == "$ENTRY_STAMP" ]] && return 1
  [[ -n $ENTRY_STAMP ]] && JL_INFLIGHT[$ENTRY]=0
  ENTRY_STAMP=$REPLY
  local base="$JL_STATE_DIR/cache/$ENTRY"
  ROWS=() ROWS_TOTAL="" ERR=""
  [[ -f $base.json ]] && jl_parse_rows "$base.json"
  [[ -f $base.err ]] && ERR=$(<$base.err)
  [[ $ERR == "HTTP 401"* ]] && JL_TOKEN_CACHE=""
  setup_check
  apply_query
  FP=""
}

# Fetches again when the entry is older than JIRA_REFRESH_SECS; after a failure, waits 30 s between tries.
refresh_if_stale() {
  [[ -n $ENTRY ]] || return
  local m
  jl_entry_age $ENTRY
  [[ -n $REPLY ]] && (( REPLY < JIRA_REFRESH_SECS )) && return
  m=$(zstat +mtime "$JL_STATE_DIR/cache/$ENTRY.err" 2>/dev/null) && (( EPOCHSECONDS - m < 30 )) && return
  jl_search "$JQL" >/dev/null
  reopened_fetch
}

# REOPENED holds the keys of the list's issues that are back in a "to do" status (see jl_reopened);
# without Jira's status list, or when that search fails, no issue is marked.
reopened_fetch() { # [force]
  local id=""
  [[ -n $STATUS_FILE && -n $JQL ]] && jl_reopened "$JQL" "$STATUS_FILE" $1 && id=$REPLY
  [[ $id == "$REOPEN_ENTRY" ]] || REOPEN_ENTRY=$id REOPEN_STAMP=""
  read_reopened
}

read_reopened() {
  local k f
  if [[ -z $REOPEN_ENTRY ]]; then (( ${#REOPENED} )) && { REOPENED=() FP="" DL_SIG="" }; return; fi
  jl_entry_stamp $REOPEN_ENTRY
  [[ $REPLY == "$REOPEN_STAMP" ]] && return
  [[ -n $REOPEN_STAMP ]] && JL_INFLIGHT[$REOPEN_ENTRY]=0
  REOPEN_STAMP=$REPLY REOPENED=()
  f="$JL_STATE_DIR/cache/$REOPEN_ENTRY.json"
  [[ -f $f ]] && for k in ${(f)"$(jq -r '.issues[]?.key' "$f" 2>/dev/null)"}; do REOPENED[$k]=1; done
  FP="" DL_SIG=""
}

loading() { [[ -n $ENTRY ]] && (( ${JL_INFLIGHT[$ENTRY]:-0} && EPOCHSECONDS - JL_INFLIGHT[$ENTRY] < 30 )) }

# Every word of the query appears in the text, ignoring case.
words_match() { # query text
  local w
  for w in ${=1}; do [[ $2 == (#i)*${~${(b)w}}* ]] || return 1; done
}

# VISIBLE holds the ROWS indices that match QUERY in key, summary, assignee or status. The Jira order is
# kept.
apply_query() {
  local i
  local -a f
  VISIBLE=()
  for (( i = 1; i <= ${#ROWS}; i++ )); do
    if [[ -n $QUERY ]]; then
      f=("${(@ps:$JL_US:)ROWS[i]}")
      words_match "$QUERY" "$f[1] $f[8] $f[6] $f[2]" || continue
    fi
    VISIBLE+=($i)
  done
  (( SEL > ${#VISIBLE} )) && SEL=${#VISIBLE}
  (( SEL < 1 )) && SEL=1
}

# The selected issue as an assoc (key summary url status type priority assignee), for templates.
selected_issue() {
  (( ${#VISIBLE} )) || return 1
  local -a f=("${(@ps:$JL_US:)ROWS[VISIBLE[SEL]]}")
  ISSUE=(key "$f[1]" status "$f[2]" category "$f[3]" type "$f[4]" priority "$f[5]" assignee "$f[6]"
         summary "$f[8]" url "$JIRA_BASE_URL/browse/$f[1]" estimate "$f[9]" spent "$f[10]" remaining "$f[11]"
         points "$f[12]" flagged "$f[13]")
}
typeset -A ISSUE DETAIL
typeset -a DREC DSTACK DACT

# --- actions ---------------------------------------------------------------------------------------
copy() { # text label
  local c
  if (( $+commands[pbcopy] )); then c=pbcopy
  elif (( $+commands[wl-copy] )); then c=wl-copy
  elif (( $+commands[xclip] )); then c="xclip -selection clipboard"
  else note "no clipboard tool (pbcopy, wl-copy, xclip)" 1; return
  fi
  print -rn -- "$1" | ${=c} && note "copied $2: $1" || note "copy failed" 1
}

open_url() {
  local o=open
  (( $+commands[open] )) || o=xdg-open
  "$o" "$1" >/dev/null 2>&1 &!
  note "opened $1"
}

send_to_agent() { # pane
  local out text
  jl_fill "$JIRA_AGENT_PROMPT" ISSUE; text=$REPLY
  if out=$("$H" agent prompt "$1" "$text" 2>&1); then
    note "sent $ISSUE[key] to $1"
  else
    note "agent prompt failed: $(print -r -- "$out" | jq -r '.error.message // empty' 2>/dev/null || print -r -- "$out")" 1
  fi
}

# Agents in this tab, else in this workspace; one is used directly, several are offered to pick from.
pick_agent() {
  [[ $MODE == detail ]] || selected_issue || return
  AGENTS=($TAB_AGENTS)
  (( ${#AGENTS} )) || AGENTS=($WS_AGENTS)
  if (( ! ${#AGENTS} )); then note "no agent in this tab or workspace" 1
  elif (( ${#AGENTS} == 1 )); then send_to_agent $AGENTS[1]
  else MODE_BACK=$MODE MODE=agents; FP=""
  fi
}

# The details of one issue. Issue keys in them (parent, epic, sub-tasks, links) open that issue; Esc
# goes back through DSTACK, then to the list.
open_detail() {
  selected_issue || return
  DSTACK=()
  show_detail "$ISSUE[key]"
}

show_detail() { # key
  [[ $1 == "$ISSUE[key]" ]] || ISSUE=(key "$1" url "$JIRA_BASE_URL/browse/$1")
  DETAIL_KEY=$1 DETAIL_STAMP="" DSCROLL=0 DCUR=0 DL_SIG="" DETAIL=() DREC=()
  jl_issue "$DETAIL_KEY"; DETAIL_ENTRY=$REPLY
  read_detail
  MODE=detail FP=""
}

detail_back() {
  if (( ${#DSTACK} )); then
    local k=$DSTACK[-1]
    DSTACK[-1]=()
    show_detail "$k"
  else
    MODE=list FP=""
  fi
}

detail_act() { # action
  case $1 in
    url:*) open_url "${1#url:}" ;;
    issue:*) [[ ${1#issue:} == "$DETAIL_KEY" ]] || { DSTACK+=("$DETAIL_KEY"); show_detail "${1#issue:}" } ;;
    worklog:) open_worklog ;;
  esac
}

# Tab walks the links of the details (DACT); a link that wraps keeps its action on each of its lines.
# The current one shows highlighted and Enter follows it.
detail_link() { # +1|-1
  local i k
  local -a starts
  for (( i = 1; i <= ${#DACT}; i++ )); do
    [[ -n $DACT[i] ]] && { (( i == 1 )) || [[ $DACT[i] != "$DACT[i-1]" ]] } && starts+=($i)
  done
  (( ${#starts} )) || return
  k=${starts[(Ie)$DCUR]}
  if (( $1 > 0 )); then k=$(( k % ${#starts} + 1 )); else k=$(( k > 1 ? k - 1 : ${#starts} )); fi
  DCUR=$starts[k]
  (( DCUR <= DSCROLL )) && DSCROLL=$(( DCUR - 2 ))
  (( DCUR > DSCROLL + LH )) && DSCROLL=$(( DCUR - LH + 2 ))
  FP=""
}

read_detail() {
  jl_entry_stamp $DETAIL_ENTRY
  [[ $REPLY == "$DETAIL_STAMP" ]] && return 1
  [[ -n $DETAIL_STAMP ]] && JL_INFLIGHT[$DETAIL_ENTRY]=0
  DETAIL_STAMP=$REPLY DL_SIG=""
  local base="$JL_STATE_DIR/cache/$DETAIL_ENTRY"
  DETAIL=() DREC=() DETAIL_ERR=""
  if [[ -f $base.json ]] && jl_parse_detail "$base.json"; then
    ISSUE=(key "$DETAIL[key]" status "$DETAIL[status]" category "$DETAIL[category]" type "$DETAIL[type]"
           priority "$DETAIL[priority]" summary "$DETAIL[summary]" url "$JIRA_BASE_URL/browse/$DETAIL[key]"
           estimate "$DETAIL[estimate]" spent "$DETAIL[spent]" remaining "$DETAIL[remaining]" points "$DETAIL[points]")
    ISSUE[assignee]=${${(M)DREC:#person${JL_US}Assignee${JL_US}*}##*$JL_US}
  fi
  [[ -f $base.err ]] && DETAIL_ERR=$(<$base.err)
  FP=""
}

next_filter() { # +1|-1
  local n=${#JL_FILTERS}
  (( FIDX == 0 )) && FIDX=1 || FIDX=$(( (FIDX - 1 + $1 + n) % n + 1 ))
  SEL=1 TOP=0
  load_entry
}

next_sort() {
  local next=$(( ${JL_SORTS[(Ie)$SORT]} % ${#JL_SORTS} + 1 ))
  SORT=$JL_SORTS[next] REV=0
  load_entry
}

custom_jql() {
  local cur=$JQL
  prompt_line "JQL" "Enter runs it, an empty line cancels. Sorting with s replaces its ORDER BY." "$cur"
  [[ -n ${REPLY// /} ]] || return
  CUSTOM_JQL=$REPLY CUSTOM_NAME="JQL" CUSTOM_CTX_NAME="" FIDX=0 SORT=filter REV=0 SEL=1 TOP=0
  load_entry
}

# --- workflow --------------------------------------------------------------------------------------
# t lists the transitions Jira offers for the issue (ISSUE, from the list or the details) and runs the
# picked one; A assigns the issue to the token's user. Jira hides transitions whose conditions fail
# (e.g. only the assignee may run them) and reports validators only when a transition runs, so the
# view says when the issue isn't yours and keeps a failed transition selected for another try.
typeset -a TR_ID TR_NAME TR_TO TR_CAT TR_ASSIGN TR_NEEDS
TR_HDR=2

unassigned() { [[ -z $ISSUE[assignee] || $ISSUE[assignee] == (—|Unassigned) ]] }

# Refetches the issue and the list after a change.
after_write() { # key
  jl_issue "$1" force
  load_entry force
}

# The picked transition stays selected when the list comes again, so ↵ retries it.
trans_fetch() {
  TR_PICK=$TR_ID[TR_SEL]
  jl_transitions "$TR_KEY"; TR_ENTRY=$REPLY
  TR_ID=() TR_NAME=() TR_TO=() TR_CAT=() TR_ASSIGN=() TR_NEEDS=() TR_LOAD_ERR="" TR_STAMP=""
  read_trans
}

open_trans() {
  [[ $MODE == detail ]] || selected_issue || return
  [[ $MODE == trans ]] || TR_BACK=$MODE
  TR_KEY=$ISSUE[key] TR_SEL=1 TR_ERR="" TR_FN=() TR_ID=()
  jl_me || note "can't tell who you are: $JL_REQUEST_ERROR" 1
  # what fields asked for later need: their allowed values and the issue's current ones
  jl_editmeta "$TR_KEY"
  jl_issue "$TR_KEY"
  trans_fetch
  MODE=trans FP=""
}

read_trans() {
  jl_entry_stamp $TR_ENTRY
  [[ $REPLY == "$TR_STAMP" ]] && return 1
  [[ -n $TR_STAMP ]] && JL_INFLIGHT[$TR_ENTRY]=0
  TR_STAMP=$REPLY
  local base="$JL_STATE_DIR/cache/$TR_ENTRY"
  TR_LOAD_ERR=""
  if [[ -f $base.err ]]; then TR_LOAD_ERR=$(<$base.err)
  elif [[ -f $base.json ]]; then jl_parse_transitions "$base.json"
  fi
  (( ${TR_ID[(Ie)$TR_PICK]} )) && TR_SEL=${TR_ID[(Ie)$TR_PICK]}
  (( TR_SEL > ${#TR_ID} )) && TR_SEL=${#TR_ID}
  (( TR_SEL < 1 )) && TR_SEL=1
  FP=""
}

trans_loading() { (( JL_INFLIGHT[$TR_ENTRY] && EPOCHSECONDS - JL_INFLIGHT[$TR_ENTRY] < 30 )) }

tr_move() { # delta
  (( ${#TR_ID} )) || return
  TR_ERR="" TR_FN=()
  TR_SEL=$(( TR_SEL + $1 ))
  (( TR_SEL > ${#TR_ID} )) && TR_SEL=${#TR_ID}
  (( TR_SEL < 1 )) && TR_SEL=1
  FP=""
}

# A transition whose screen requires an assignee gets the user as assignee while the issue has none.
# Field values asked for (TR_SET, field id -> JSON) go with the transition when they are on its screen;
# the others are saved with an edit of the issue first, since Jira refuses fields a transition doesn't
# show. Required screen fields that are still empty are asked for before the first try.
typeset -A TR_SET
typeset -a TR_FN ASK_Q

run_transition() { # index [asked]
  local i=$1 id k
  local -a screen=() edit=() need=()
  (( i >= 1 && i <= ${#TR_ID} )) || return
  [[ -n $2 ]] || TR_SET=()
  TR_SEL=$i TR_ERR="" TR_FN=()
  if [[ -z $2 && -n $TR_NEEDS[i] ]]; then
    trans_meta || { TR_ERR="can't read the fields to fill in: $REPLY"; FP=""; return }
    jl_issue_file "$TR_KEY"; local file=$REPLY
    for (( k = 1; k <= ${#FM_ID}; k++ )); do
      [[ $FM_SRC[k] == screen && $FM_ID[k] != assignee ]] && (( FM_REQ[k] && ! FM_DEF[k] )) || continue
      if [[ -f $file ]]; then jl_field_current "$file" "$FM_ID[k]"; (( ${#CUR} )) && continue; fi
      need+=("$FM_ID[k]")
    done
    if (( ${#need} )); then ask_fields $need; return; fi
  fi
  if (( TR_ASSIGN[i] )) && unassigned; then
    jl_me || { TR_ERR="can't tell who you are: $JL_REQUEST_ERROR"; FP=""; return }
    screen+=(assignee "$JL_ME_ASSIGN")
  fi
  for id in ${(k)TR_SET}; do
    k=${FM_ID[(Ie)$id]}
    if [[ $FM_SRC[k] == screen ]]; then screen+=("$id" "$TR_SET[$id]"); else edit+=("$id" "$TR_SET[$id]"); fi
  done
  if (( ${#edit} )); then
    note "saving the fields of $TR_KEY…"; paint
    jl_fields_object "${edit[@]}"
    if ! jl_request PUT "/rest/api/2/issue/$TR_KEY" "{\"fields\":$REPLY}"; then
      TR_ERR="saving the fields failed: $JL_REQUEST_ERROR" NOTE="" FP=""
      return
    fi
    jl_issue "$TR_KEY" force
  fi
  note "moving $TR_KEY to $TR_TO[i]…"; paint
  jl_fields_object "${screen[@]}"
  jl_transition_body "$TR_ID[i]" "$REPLY"
  if jl_request POST "/rest/api/2/issue/$TR_KEY/transitions" "$REPLY"; then
    TR_SET=() MODE=$TR_BACK
    note "$TR_KEY → $TR_TO[i]"
    after_write "$TR_KEY"
  else
    TR_ERR=$JL_REQUEST_ERROR NOTE=""
    if trans_meta; then
      jl_fields_named "$TR_ERR"; TR_FN=($FN)
    else
      TR_ERR+=" (the issue's fields can't be read: $REPLY)"
    fi
  fi
  FP=""
}

# --- fields ----------------------------------------------------------------------------------------
# FM_* for the selected transition: its screen fields, then what an edit of the issue may set.
trans_meta() { # -> non-zero with REPLY the error
  local ef
  jl_editmeta "$TR_KEY" id-only; ef="$JL_STATE_DIR/cache/$REPLY.json"
  if [[ ! -f $ef ]]; then
    jl_request GET "/rest/api/2/issue/$TR_KEY/editmeta" || { REPLY=$JL_REQUEST_ERROR; return 1 }
    print -r -- "$REPLY" > "$ef.tmp" && mv "$ef.tmp" "$ef"
  fi
  FM_ID=() FM_NAME=() FM_TYPE=() FM_ITEMS=() FM_CUSTOM=() FM_REQ=() FM_DEF=() FM_SRC=()
  jl_field_meta "$JL_STATE_DIR/cache/$TR_ENTRY.json" "$TR_ID[TR_SEL]" screen
  jl_field_meta "$ef" "" edit
}

field_names() { # field-id... -> REPLY "A, B"
  local id
  local -a n=()
  for id; do n+=("${FM_NAME[${FM_ID[(Ie)$id]}]:-$id}"); done
  REPLY=${(j:, :)n}
}

# Asks for each field in turn, then runs the selected transition again with the answers in TR_SET (they
# add to earlier answers of this attempt; ↵ starts a new attempt).
ask_fields() { # field-id...
  ASK_Q=("$@")
  ask_next
}

ask_next() {
  local id k
  while (( ${#ASK_Q} )); do
    id=$ASK_Q[1]; ASK_Q[1]=()
    k=${FM_ID[(Ie)$id]}
    jl_field_kind "$FM_TYPE[k]" "$FM_ITEMS[k]" "$FM_CUSTOM[k]"
    case $REPLY in
      pick|multi|user) pick_value $k $REPLY; return ;;
      text|number|date|labels) ask_typed $k $REPLY || return ;;
      *) field_names "$id"; ask_cancel "the pane can't set $REPLY: o opens $TR_KEY in Jira"; return ;;
    esac
  done
  MODE=trans
  run_transition $TR_SEL asked
}

ask_cancel() { # [message]
  ASK_Q=() MODE=trans FP=""
  [[ -n $1 ]] && TR_ERR=$1
}

ask_typed() { # field-index kind; non-zero when cancelled
  local k=$1 kind=$2 what cur="" hint
  case $kind in
    text) what="text" ;;
    number) what="a number" ;;
    date) what="a date as YYYY-MM-DD" ;;
    labels) what="words separated by spaces" ;;
  esac
  hint="$what — Enter saves it, an empty line cancels"
  jl_issue_file "$TR_KEY"
  [[ -f $REPLY ]] && { jl_field_current "$REPLY" "$FM_ID[k]"; cur=${(j: :)CUR} }
  while :; do
    prompt_line "$FM_NAME[k] · $TR_KEY" "$hint" "$cur"
    [[ -n ${REPLY//[[:space:]]/} ]] || { ask_cancel; return 1 }
    cur=$REPLY
    jl_field_json $kind "$cur" && break
    hint="“$cur” isn't $what — try again, an empty line cancels"
  done
  TR_SET[$FM_ID[k]]=$REPLY
}

# A field with allowed values (or a user field, which offers you) is picked from a list; the values the
# issue has are ticked, since setting the field replaces them.
pick_value() { # field-index kind
  local k=$1 file tid="" id
  PK_ID=() PK_LABEL=() PK_NOTE=() PK_TICK=()
  if [[ $2 == user ]]; then
    jl_me || { ask_cancel "can't tell who you are: $JL_REQUEST_ERROR"; return }
    PK_ID=("$JL_ME_ASSIGN") PK_LABEL=("you ($JL_ME_NAME)") PK_NOTE=("")
  else
    if [[ $FM_SRC[k] == screen ]]; then file="$JL_STATE_DIR/cache/$TR_ENTRY.json" tid=$TR_ID[TR_SEL]
    else jl_editmeta "$TR_KEY" id-only; file="$JL_STATE_DIR/cache/$REPLY.json"
    fi
    jl_field_options "$file" "$tid" "$FM_ID[k]"
    PK_ID=("${OPT_ID[@]}") PK_LABEL=("${OPT_LABEL[@]}") PK_NOTE=("${OPT_NOTE[@]}")
  fi
  (( ${#PK_ID} )) || { ask_cancel "Jira offers no values for $FM_NAME[k]: o opens $TR_KEY in Jira"; return }
  if [[ $2 == multi ]]; then
    jl_issue_file "$TR_KEY"
    [[ -f $REPLY ]] && { jl_field_current "$REPLY" "$FM_ID[k]"; for id in $CUR; do PK_TICK[$id]=1; done }
  fi
  PK_TITLE="$TR_KEY · $FM_NAME[k]" PK_KIND=$2 PK_FIELD=$k PK_DONE=pick_value_done
  pick_open
}

pick_value_done() {
  if [[ $PK_KIND == user ]]; then REPLY=$PK_PICKED[1]; else jl_field_json $PK_KIND "${PK_PICKED[@]}"; fi
  TR_SET[$FM_ID[PK_FIELD]]=$REPLY
  ask_next
}

# e: any field the pane can write, then its value, then the transition again.
choose_field() {
  local k
  trans_meta || { TR_ERR="can't read the issue's fields: $REPLY"; FP=""; return }
  PK_ID=() PK_LABEL=() PK_NOTE=() PK_TICK=()
  for (( k = 1; k <= ${#FM_ID}; k++ )); do
    jl_field_kind "$FM_TYPE[k]" "$FM_ITEMS[k]" "$FM_CUSTOM[k]"
    [[ -n $REPLY ]] || continue
    PK_ID+=("$FM_ID[k]") PK_LABEL+=("$FM_NAME[k]") PK_NOTE+=("${${FM_REQ[k]:#0}:+required}")
  done
  PK_TITLE="$TR_KEY · set which field?" PK_KIND=field PK_DONE=choose_field_done
  pick_open
}

choose_field_done() { ask_fields "$PK_PICKED[1]" }

# --- picker --------------------------------------------------------------------------------------
# A list to pick from, narrowed by typing. A multi-value field ticks entries with Space; Enter takes the
# ticked ones, or the selected one when none is ticked. PK_DONE gets the ids in PK_PICKED.
typeset -a PK_ID PK_LABEL PK_NOTE PK_VIS PK_PICKED
typeset -A PK_TICK

pick_open() {
  PK_MULTI=0
  [[ $PK_KIND == multi ]] && PK_MULTI=1
  PK_Q="" PK_SEL=1 PK_TOP=0
  pk_filter
  MODE=pick FP=""
}

pk_filter() {
  local i
  PK_VIS=()
  for (( i = 1; i <= ${#PK_ID}; i++ )); do
    [[ -z $PK_Q ]] || words_match "$PK_Q" "$PK_LABEL[i]" || continue
    PK_VIS+=($i)
  done
  (( PK_SEL > ${#PK_VIS} )) && PK_SEL=${#PK_VIS}
  (( PK_SEL < 1 )) && PK_SEL=1
}

pk_move() { # delta
  (( ${#PK_VIS} )) || return
  PK_SEL=$(( PK_SEL + $1 ))
  (( PK_SEL > ${#PK_VIS} )) && PK_SEL=${#PK_VIS}
  (( PK_SEL < 1 )) && PK_SEL=1
  FP=""
}

pk_toggle() {
  (( PK_MULTI && ${#PK_VIS} )) || return
  local id=$PK_ID[PK_VIS[PK_SEL]]
  if (( PK_TICK[$id] )); then unset "PK_TICK[$id]"; else PK_TICK[$id]=1; fi
  FP=""
}

pk_confirm() {
  local i
  PK_PICKED=()
  if (( PK_MULTI )); then
    for (( i = 1; i <= ${#PK_ID}; i++ )); do (( PK_TICK[$PK_ID[i]] )) && PK_PICKED+=("$PK_ID[i]"); done
  fi
  (( ${#PK_PICKED} || ! ${#PK_VIS} )) || PK_PICKED=("$PK_ID[PK_VIS[PK_SEL]]")
  (( ${#PK_PICKED} )) || return
  MODE=trans FP=""
  $PK_DONE
}

assign_me() {
  if [[ $MODE == list ]]; then selected_issue || return; fi
  local key=$ISSUE[key]
  jl_me || { note "can't tell who you are: $JL_REQUEST_ERROR" 1; return }
  if [[ $ISSUE[assignee] == "$JL_ME_NAME" ]]; then note "$key is already assigned to you"; return; fi
  note "assigning $key to you…"; paint
  if jl_request PUT "/rest/api/2/issue/$key/assignee" "$JL_ME_ASSIGN"; then
    ISSUE[assignee]=$JL_ME_NAME
    note "$key assigned to you"
    after_write "$key"
    # conditions may let the assignee run more transitions
    [[ $MODE == trans ]] && { TR_ERR=""; trans_fetch }
  else
    note "assigning failed: $JL_REQUEST_ERROR" 1
  fi
}

# --- work log ------------------------------------------------------------------------------------
# w logs time on the issue, starting now; Jira lowers the remaining estimate by it. The footer offers
# it for issues estimated in time or in story points, the key works on any.
estimated() {
  if [[ $MODE == list ]]; then
    (( ${#VISIBLE} )) || return 1
    local -a f=("${(@ps:$JL_US:)ROWS[VISIBLE[SEL]]}")
    (( f[9] || f[11] )) || [[ -n $f[12] ]]
  else
    (( DETAIL[estimate] || DETAIL[remaining] )) || [[ -n $DETAIL[points] ]]
  fi
}

# Finds the story points (see jl_points_field) and Flagged fields once Jira's field list is cached, and
# the status list that tells reopened issues; a change fetches the list again with them.
fields_check() {
  [[ -n $JIRA_BASE_URL ]] || return
  local pts="" flag="" st="" f
  jl_fields; f="$JL_STATE_DIR/cache/$REPLY.json"
  if [[ -f $f ]]; then
    jl_flag_field "$f"; flag=$REPLY
    [[ $JIRA_POINTS_FIELD == (off|) ]] || { jl_points_field "$f" "$JIRA_POINTS_FIELD"; pts=$REPLY }
  fi
  [[ $JIRA_POINTS_FIELD == customfield_* ]] && pts=$JIRA_POINTS_FIELD
  jl_statuses; [[ -f $JL_STATE_DIR/cache/$REPLY.json ]] && st="$JL_STATE_DIR/cache/$REPLY.json"
  [[ "$pts|$flag|$st" == "$JL_POINTS_FIELD|$JL_FLAG_FIELD|$STATUS_FILE" ]] && return
  JL_POINTS_FIELD=$pts JL_FLAG_FIELD=$flag STATUS_FILE=$st DETAIL_STAMP=""
  (( CTX >= 0 )) && load_entry
}

time_summary() { # -> REPLY "5 points · estimated 1d · logged 2h · 6h left", empty without an estimate
  local -a t=()
  jl_points_text "$ISSUE[points]"; [[ -n $REPLY ]] && t+=("$REPLY")
  (( ISSUE[estimate] )) && { jl_duration $ISSUE[estimate]; t+=("estimated $REPLY") }
  (( ISSUE[spent] )) && { jl_duration $ISSUE[spent]; t+=("logged $REPLY") }
  (( ISSUE[estimate] || ISSUE[remaining] )) && { jl_duration ${ISSUE[remaining]:-0}; t+=("$REPLY left") }
  REPLY=${(j: · :)t}
}

log_work() {
  if [[ $MODE == list ]]; then selected_issue || return; fi
  local key=$ISSUE[key] spent="" summary started
  local hint="like 1h 30m, 2d or 45m — Enter goes on, an empty line cancels"
  time_summary; summary=$REPLY
  while :; do
    prompt_line "Log work · $key${summary:+ · $summary}" "$hint" "$spent"
    [[ -n ${REPLY//[[:space:]]/} ]] || return
    spent=$REPLY
    jl_worklog_body "$spent" "" "" && break
    hint="“$spent” isn't a time like 1h 30m — try again, an empty line cancels"
  done
  prompt_line "Log work · $key · $spent" "what you worked on — Enter logs it; an empty line logs without a comment" ""
  strftime -s started '%Y-%m-%dT%H:%M:%S.000%z' $EPOCHSECONDS
  jl_worklog_body "$spent" "$REPLY" "$started"
  local body=$REPLY
  spent=${${body#*\"timeSpent\":\"}%%\"*}
  note "logging $spent on $key…"; paint
  if jl_request POST "/rest/api/2/issue/$key/worklog" "$body"; then
    note "logged $spent on $key"
    after_write "$key"
    [[ $MODE == worklog ]] && jl_worklogs "$key"
  else
    note "logging work failed: $JL_REQUEST_ERROR" 1
  fi
}

# The issue's logged work, newest first; opened by tapping Logged or Progress in the details.
open_worklog() {
  WL_BACK=$MODE WL_KEY=$DETAIL_KEY WL_SCROLL=0 WL_STAMP="" WL_SIG="" WL_ERR=""
  WL_STARTED=() WL_AUTHOR=() WL_SPENT=() WL_COMMENT=()
  jl_worklogs "$WL_KEY"; WL_ENTRY=$REPLY
  read_worklog
  MODE=worklog FP=""
}

read_worklog() {
  jl_entry_stamp $WL_ENTRY
  [[ $REPLY == "$WL_STAMP" ]] && return 1
  [[ -n $WL_STAMP ]] && JL_INFLIGHT[$WL_ENTRY]=0
  WL_STAMP=$REPLY WL_SIG=""
  local base="$JL_STATE_DIR/cache/$WL_ENTRY"
  WL_ERR=""
  [[ -f $base.json ]] && jl_parse_worklogs "$base.json"
  [[ -f $base.err ]] && WL_ERR=$(<$base.err)
  FP=""
}

# --- setup ---------------------------------------------------------------------------------------
# Until the Jira URL is set and a token can be read, the list shows how to get there, and 1 and 2 do
# the steps. SETUP_TOKEN is ok, missing, tool (the keychain tool isn't installed) or rejected (Jira
# didn't accept the token).
SETUP=0 SETUP_URL=0 SETUP_TOKEN=ok

setup_check() {
  local was="$SETUP $SETUP_URL $SETUP_TOKEN"
  SETUP_URL=0 SETUP_TOKEN=ok
  [[ -n $JIRA_BASE_URL ]] && SETUP_URL=1
  jl_auth_line || SETUP_TOKEN=$JL_TOKEN_STATE
  [[ $SETUP_TOKEN == ok && $ERR == *"didn't accept the token"* ]] && SETUP_TOKEN=rejected
  if (( SETUP_URL )) && [[ $SETUP_TOKEN == ok ]]; then SETUP=0; else SETUP=1; fi
  [[ "$SETUP $SETUP_URL $SETUP_TOKEN" == "$was" ]] || FP=""
}

setup_url() {
  setopt local_options extended_glob
  prompt_line "Jira URL" "The address of your Jira, with its context path such as /jira if it has one. An empty line cancels." "${JIRA_BASE_URL:-https://}"
  local url=${${REPLY##[[:space:]]#}%%[[:space:]]#}
  url=${url%%/##}
  [[ -n $url && $url != http(s|):(/|) ]] || return
  [[ $url == http(s|)://?* ]] || { note "a Jira URL starts with https:// or http://" 1; return }
  jl_set_base_url "$JL_CONFIG" "$url" || { note "could not write $JL_CONFIG" 1; return }
  CONFIG_STAMP=$(zstat +mtime "$JL_CONFIG" 2>/dev/null)
  reload_config
  note "saved the Jira URL in config.zsh"
}

# The keychain's own prompt asks for the token, so it shows neither on screen nor in a history.
setup_token() {
  if ! jl_keychain_cmd store; then
    jl_secret_tool_hint
    note "$JL_KEYCHAIN_MISSING isn't installed: $REPLY" 1
    return
  fi
  run_inline "$REPLY"
  JL_TOKEN_CACHE="" ERR=""
  load_entry force
  setup_check
}

draw_setup() {
  local ok="${GREEN}✓${R}" no="${RED}✗${R}" where=keyring line
  local -a help=()
  [[ $OSTYPE == darwin* ]] && where=Keychain
  VIEW+=("" " ${K}${B}Set up Jira Light${R}" "")
  if (( SETUP_URL )); then fit " $ok ${K}${B}1${R}  Jira URL  $JIRA_BASE_URL"
  else fit " $no ${K}${B}1${R}  Jira URL  ${D}not set; 1 asks for it${R}"
  fi
  VIEW+=("$REPLY")
  case $SETUP_TOKEN in
    ok) line=" $ok ${K}${B}2${R}  Token     found" ;;
    missing)
      if [[ -n $JIRA_TOKEN_CMD ]]; then
        line=" $no ${K}${B}2${R}  Token     JIRA_TOKEN_CMD printed no token"
        help=("Check JIRA_TOKEN_CMD in config.zsh, or remove it: then 2 stores the token in the $where.")
      else
        line=" $no ${K}${B}2${R}  Token     no “$JIRA_KEYCHAIN_SERVICE” entry in the $where"
        help=("Create a personal access token in Jira: your avatar → Profile → Personal Access Tokens."
              "2 stores it in the $where, which asks for it without showing it.")
      fi ;;
    tool)
      jl_secret_tool_hint
      line=" $no ${K}${B}2${R}  Token     $JL_KEYCHAIN_MISSING isn't installed"
      help=("It reads the token from your keyring: $REPLY" "Or set JIRA_TOKEN_CMD in config.zsh to a command that prints the token.") ;;
    rejected)
      line=" $no ${K}${B}2${R}  Token     Jira didn't accept it"
      help=("The token may have expired. Create a new one in Jira; 2 replaces the stored one.") ;;
  esac
  fit "$line"; VIEW+=("$REPLY")
  for line in $help; do
    jl_wrap $(( COLS - 8 )) "$line"
    for line in $WRAPPED; do VIEW+=("       ${D}$line${R}"); done
  done
  fit "   ${K}${B}3${R}  Filters   ${D}then b browses boards and sprints, p pins them here${R}"; VIEW+=("" "$REPLY")
  jl_wrap $(( COLS - 4 )) "Jira Cloud: set JIRA_AUTH=basic and JIRA_EMAIL in config.zsh; the token is an API token from id.atlassian.com."
  VIEW+=("")
  for line in $WRAPPED; do VIEW+=("  ${D}$line${R}"); done
}

# --- browser ---------------------------------------------------------------------------------------
# Projects, then a project's boards, then a board's sprints and backlog. Each level is built from
# cache entries (BR_IDS) once their fetches finish; picking a view shows it in the list. BR_ITEM holds
# the rows, BR_VAL what a row does: project:KEY<US>name, board:id<US>name<US>type or view:name<US>jql.
typeset -a BR_IDS BR_ITEM BR_VAL BR_VIS BR_LABEL BR_NAME BR_JQL
BR_LEVEL="" BR_Q="" BR_SEL=1 BR_TOP=0 BR_STAMP="" BR_ERR="" BR_LOAD=0 BR_FID="" BR_MINE=0

browse() {
  [[ -n $JL_CONFIG_ERROR ]] && { note "$JL_CONFIG_ERROR" 1; return }
  MODE=browse FP=""
  [[ -n $BR_LEVEL ]] || br_level projects
}

br_level() { # projects | boards | entries
  BR_LEVEL=$1 BR_Q="" BR_SEL=1 BR_TOP=0 BR_STAMP="" BR_FID="" BR_IDS=() BR_FIRST_VIEW=0
  [[ $1 == (boards|entries) ]] && BR_FIRST_VIEW=1
  case $1 in
    projects)
      jl_get /rest/api/2/project 3600; BR_IDS+=($REPLY)
      jl_get /rest/api/2/project 3600 recent=20; BR_IDS+=($REPLY) ;;
    boards)
      jl_get /rest/agile/1.0/board 3600 "projectKeyOrId=$BR_PKEY" maxResults=100; BR_IDS+=($REPLY) ;;
    entries)
      jl_get "/rest/agile/1.0/board/$BR_BID/configuration" 3600; BR_IDS+=($REPLY)
      # kanban boards have no sprints: Jira answers their sprint request with an error
      if [[ $BR_BTYPE == scrum ]]; then
        jl_get "/rest/agile/1.0/board/$BR_BID/sprint" 300 state=active,future maxResults=50; BR_IDS+=($REPLY)
      fi ;;
  esac
  br_read
  FP=""
}

# Rebuilds the level when one of its fetches has finished; returns non-zero when nothing changed.
br_read() {
  local id st=""
  for id in $BR_IDS; do jl_entry_stamp $id; st+=$REPLY; done
  [[ $st == "$BR_STAMP" ]] && return 1
  BR_STAMP=$st
  br_build
  FP=""
}

br_build() {
  local c="$JL_STATE_DIR/cache" id
  BR_ITEM=() BR_VAL=() BR_ERR="" BR_LOAD=0
  for id in $BR_IDS; do
    [[ -f $c/$id.err ]] && BR_ERR=${BR_ERR:-$(<$c/$id.err)}
    [[ -f $c/$id.json || -f $c/$id.err ]] || BR_LOAD=1
  done
  br_build_$BR_LEVEL "$c"
  br_filter
}

br_build_projects() { # cache-dir
  local c=$1 k line
  local -a recent rows
  [[ -f $c/$BR_IDS[1].json ]] || return
  [[ -f $c/$BR_IDS[2].json ]] && recent=(${(f)"$(jq -r '.[].key' "$c/$BR_IDS[2].json" 2>/dev/null)"})
  rows=(${(f)"$(jq -r 'sort_by(.key)[] | "\(.key)\u001f\(.name)"' "$c/$BR_IDS[1].json" 2>/dev/null)"})
  for k in $recent; do
    line=${(M)rows:#$k$JL_US*}
    [[ -n $line ]] && { BR_ITEM+=("★ ${line/$JL_US/  }") BR_VAL+=("project:$line") }
  done
  for line in $rows; do
    (( ${recent[(Ie)${line%%$JL_US*}]} )) && continue
    BR_ITEM+=("  ${line/$JL_US/  }") BR_VAL+=("project:$line")
  done
}

br_build_boards() { # cache-dir
  local c=$1 line
  local -a f
  br_mine_row
  BR_ITEM+=("All open issues")
  BR_VAL+=("view:$BR_PKEY · All open issues${JL_US}project = $BR_PKEY AND resolution = Unresolved ORDER BY updated DESC")
  (( BR_FIRST_VIEW )) && { BR_SEL=2 BR_FIRST_VIEW=0 }
  [[ -f $c/$BR_IDS[1].json ]] || return
  for line in ${(f)"$(jq -r '.values[]? | "\(.id)\u001f\(.name)\u001f\(.type)"' "$c/$BR_IDS[1].json" 2>/dev/null)"}; do
    f=("${(@ps:$JL_US:)line}")
    BR_ITEM+=("$f[2]  ${D}${f[3]}${R}") BR_VAL+=("board:$line")
  done
}

# The board's own JQL is in its filter, whose id comes with the board configuration: the filter is
# fetched once the configuration has arrived.
br_build_entries() { # cache-dir
  local c=$1 fid k
  br_mine_row
  [[ -f $c/$BR_IDS[1].json ]] || return
  if [[ -z $BR_FID ]]; then
    fid=$(jq -r '.filter.id // empty' "$c/$BR_IDS[1].json" 2>/dev/null)
    [[ -n $fid ]] || { BR_ERR=${BR_ERR:-"the board has no filter"}; return }
    BR_FID=$fid
    jl_get "/rest/api/2/filter/$fid" 3600; BR_IDS+=($REPLY)
    BR_STAMP="" BR_LOAD=1
    return
  fi
  (( BR_LOAD )) && return
  [[ -f $c/$BR_IDS[-1].json ]] || return
  jl_board_entries "$BR_BTYPE" "$(jq -r '.jql // empty' "$c/$BR_IDS[-1].json")" "$c/$BR_IDS[2].json"
  for (( k = 1; k <= ${#BR_LABEL}; k++ )); do
    BR_ITEM+=("$BR_LABEL[k]") BR_VAL+=("view:$BR_BNAME · $BR_NAME[k]$JL_US$BR_JQL[k]")
  done
  # Enter on a board's views opens the active sprint, not the switch above it
  (( BR_FIRST_VIEW )) && { BR_SEL=2 BR_FIRST_VIEW=0 }
}

# The switch heads the board list and a board's views; it limits the view picked next to the issues
# assigned to the current user.
br_mine_row() {
  if (( BR_MINE )); then BR_ITEM+=("$K☑$R only mine  ${D}assignee = currentUser()${R}")
  else BR_ITEM+=("☐ only mine")
  fi
  BR_VAL+=("toggle:mine")
}

br_filter() {
  local i
  BR_VIS=()
  for (( i = 1; i <= ${#BR_ITEM}; i++ )); do
    # the "only mine" switch stays in reach while typing narrows the views
    [[ -z $BR_Q || $BR_VAL[i] == toggle:* ]] || words_match "$BR_Q" "${(S)BR_ITEM[i]//$'\e'\[[0-9;]#m/}" || continue
    BR_VIS+=($i)
  done
  (( BR_SEL > ${#BR_VIS} )) && BR_SEL=${#BR_VIS}
  (( BR_SEL < 1 )) && BR_SEL=1
}

br_move() { # delta
  (( ${#BR_VIS} )) || return
  BR_FIRST_VIEW=0
  BR_SEL=$(( BR_SEL + $1 ))
  (( BR_SEL > ${#BR_VIS} )) && BR_SEL=${#BR_VIS}
  (( BR_SEL < 1 )) && BR_SEL=1
  FP=""
}

br_open() {
  (( ${#BR_VIS} )) || return
  local v=$BR_VAL[BR_VIS[BR_SEL]]
  local -a f=("${(@ps:$JL_US:)${v#*:}}")
  case $v in
    project:*) BR_PKEY=$f[1] BR_PNAME=$f[2]; br_level boards ;;
    board:*) BR_BID=$f[1] BR_BNAME=$f[2] BR_BTYPE=$f[3]; br_level entries ;;
    toggle:mine) br_toggle_mine ;;
    view:*)
      if (( BR_MINE )); then
        jl_only_mine "$f[2]"; f=("$f[1] · mine" "$REPLY")
      fi
      CUSTOM_NAME=$f[1] CUSTOM_JQL=$f[2] CUSTOM_CTX_NAME=$BR_PNAME
      FIDX=0 SORT=filter REV=0 SEL=1 TOP=0 QUERY="" MODE=list
      load_entry ;;
  esac
}

# Stays on for other boards and projects until it's switched off.
br_toggle_mine() {
  (( BR_MINE = ! BR_MINE ))
  br_build
  FP=""
}

br_up() {
  case $BR_LEVEL in
    entries) br_level boards ;;
    boards) br_level projects ;;
    *) MODE=list FP="" ;;
  esac
}

filter_taken() { # context name
  local j
  for (( j = 1; j <= ${#FLT_NAME}; j++ )); do [[ $FLT_CTX[j] == $1 && $FLT_NAME[j] == "$2" ]] && return 0; done
  return 1
}

# Appends the current view to config.zsh as a filter of a directory's context, then reloads, which
# selects it there.
pin_view() {
  (( FIDX == 0 )) || { note "p pins a view picked with b (browse) or typed with J" 1; return }
  local suggest dir i j ctxname name=$FILTER_NAME n=2
  if (( CTX )); then suggest=$CTX_PATH[CTX]
  else suggest=$(git -C "$DIR" rev-parse --show-toplevel 2>/dev/null) || suggest=$DIR
  fi
  prompt_line "Pin “$FILTER_NAME”" "to this directory; its filters show in every tab working below it. Empty line cancels." "${suggest/#$HOME/~}"
  [[ -n ${REPLY// /} ]] || return
  dir=${REPLY/#\~/$HOME}
  dir=${dir:A}
  i=${CTX_PATH[(Ie)$dir]}
  (( i )) && ctxname=$CTX_NAME[i] || ctxname=${CUSTOM_CTX_NAME:-${dir:t}}
  for (( j = 1; i && j <= ${#FLT_NAME}; j++ )); do
    [[ $FLT_CTX[j] == $i && $FLT_JQL[j] == "$CUSTOM_JQL" ]] && { note "already pinned there as “$FLT_NAME[j]”" 1; return }
  done
  while filter_taken $i "$name"; do name="$FILTER_NAME ($n)"; (( n++ )); done
  jl_pin_text "$dir" "$ctxname" "$name" "$CUSTOM_JQL"
  if ! print -rn -- "$REPLY" >> "$JL_CONFIG"; then note "could not write $JL_CONFIG" 1; return; fi
  VIEW_FILTER[$dir]=$name VIEW_SORT[$dir]=filter VIEW_REV[$dir]=0
  CONFIG_STAMP=$(zstat +mtime "$JL_CONFIG" 2>/dev/null)
  reload_config
  note "pinned “$name” to ${dir/#$HOME/~}"
}

reload_config() {
  jl_load_config
  JL_TOKEN_CACHE=""
  local d=$DIR
  CTX=-1
  jl_match_context "$d"
  switch_context $REPLY
  [[ $MODE == manage ]] && mg_load
  note "config reloaded"
}

# --- pinned filters --------------------------------------------------------------------------------
# m lists what p appended to config.zsh, grouped by directory; d removes an entry after a y.
# Hand-written filters aren't listed. MG_ORDER holds the PIN_ indices in the order shown, MG_SEL a
# position in it, MG_MAP the position of each drawn row (0 for a directory row).
typeset -a MG_MAP MG_ORDER
MG_SEL=1 MG_TOP=0 MG_CONFIRM=0

mg_load() {
  local d i
  jl_pinned "$JL_CONFIG"
  MG_ORDER=()
  for d in "${(@u)PIN_DIR}"; do
    for (( i = 1; i <= ${#PIN_AT}; i++ )); do [[ $PIN_DIR[i] == "$d" ]] && MG_ORDER+=($i); done
  done
}

manage() {
  mg_load
  MODE=manage MG_SEL=1 MG_TOP=0 MG_CONFIRM=0 FP=""
}

mg_move() { # delta
  (( ${#PIN_AT} )) || return
  MG_SEL=$(( MG_SEL + $1 ))
  (( MG_SEL > ${#PIN_AT} )) && MG_SEL=${#PIN_AT}
  (( MG_SEL < 1 )) && MG_SEL=1
  MG_CONFIRM=0 FP=""
}

mg_remove() {
  local i=$MG_ORDER[MG_SEL] rc
  local name=$PIN_NAME[i]
  MG_CONFIRM=0 FP=""
  jl_unpin "$JL_CONFIG" "$PIN_AT[i]" "$PIN_LINE[i]"; rc=$?
  if (( rc == 1 )); then mg_load; note "config.zsh changed meanwhile; nothing removed, the list is fresh now" 1; return; fi
  (( rc )) && { note "could not write $JL_CONFIG" 1; return }
  CONFIG_STAMP=$(zstat +mtime "$JL_CONFIG" 2>/dev/null)
  reload_config
  (( MG_SEL > ${#PIN_AT} )) && MG_SEL=${#PIN_AT}
  (( MG_SEL < 1 )) && MG_SEL=1
  note "removed “$name”; the previous config is in config.zsh.bak"
}

move() { # delta
  (( ${#VISIBLE} )) || return
  SEL=$(( SEL + $1 ))
  (( SEL > ${#VISIBLE} )) && SEL=${#VISIBLE}
  (( SEL < 1 )) && SEL=1
  FP=""
}

# --- drawing ---------------------------------------------------------------------------------------
sort_label() {
  if [[ $SORT == filter ]]; then REPLY="sort: filter"
  else
    local dir=${JL_SORT_DIR[$SORT]}
    (( REV )) && { [[ $dir == DESC ]] && dir=ASC || dir=DESC }
    [[ $dir == DESC ]] && REPLY="sort: ↓$SORT" || REPLY="sort: ↑$SORT"
  fi
}

ago() { # seconds -> REPLY
  if (( $1 < 60 )); then REPLY="just now"
  elif (( $1 < 3600 )); then REPLY="$(( $1 / 60 ))m ago"
  else REPLY="$(( $1 / 3600 ))h ago"
  fi
}

header_lines() {
  local name left right n=${#JL_FILTERS}
  (( CTX )) && name=$CTX_NAME[CTX] || name="all"
  sort_label
  local pos="[$FIDX/$n]"
  (( FIDX )) || pos="[view]"
  lr "${K}${B}${name}${R} ${D}·${R} ${B}${FILTER_NAME}${R} ${D}${pos}${R}" "${D}${REPLY}${R}"
  VIEW+=("$REPLY")
  left="${D}${DIR/#$HOME/~}${R}"
  if (( SETUP )); then right="${K}setup${R}"
  elif [[ -n $ERR ]]; then right="${RED}${ERR}${R}"; (( ${#ROWS} )) && right="${RED}stale: ${ERR}${R}"
  elif loading; then right="${K}loading…${R}"
  elif [[ -n $ENTRY ]] && jl_entry_age $ENTRY; then
    ago $REPLY
    right="${D}${#VISIBLE}${ROWS_TOTAL:+/$ROWS_TOTAL} · $REPLY${R}"
  fi
  if [[ -n $ERR ]] && (( ! SETUP )); then fit "$right"; VIEW+=("$REPLY")
  else lr "$left" "$right"; VIEW+=("$REPLY")
  fi
  if (( SEARCH )) || [[ -n $QUERY ]]; then
    local cur=""; (( SEARCH )) && cur="█"
    lr "${K}/${R} ${QUERY}${cur}" "${D}${#VISIBLE}/${#ROWS}${R}"
    VIEW+=("$REPLY")
  fi
}

# The footer is a bar of key/label pairs, the most useful first, that wraps onto more rows as it needs
# (at most a third of the pane; the last pairs go when there is no room). A note takes over its first
# row for a few seconds. FOOT_HIT holds row:first-column:last-column:key of each pair, so a click or tap
# presses it.
typeset -a FOOT FOOT_HIT
FOOT_N=1

bar_line() { # text -> REPLY, padded to the width on the bar background
  fit "$1"
  local t=${REPLY%$R}
  visible_len "$t"
  REPLY="$BAR$t${(l:COLS - REPLY:: :)}$R"
}

hints() { # key label [key label ...]
  local line=" " c=2 r=1 len max=$(( LINES / 3 ))
  (( max < 2 )) && max=2
  while (( $# >= 2 )); do
    len=$(( ${#1} + 1 + ${#2} ))
    if (( c > 2 && c + 2 + len > COLS )); then
      (( r == max )) && break
      bar_line "$line"; FOOT+=("$REPLY")
      line=" " c=2
      (( r++ ))
    fi
    (( c > 2 )) && { line+="  "; (( c += 2 )) }
    line+="$K$B$1$R$BAR $2"
    FOOT_HIT+=("$r:$c:$(( c + len - 1 )):$1")
    (( c += len ))
    shift 2
  done
  bar_line "$line"; FOOT+=("$REPLY")
}

footer_lines() {
  FOOT=() FOOT_HIT=()
  if (( SEARCH )); then hints "↵" done esc clear
  else
    case $MODE in
      list)
        if (( SETUP )); then hints 1 "Jira URL" 2 "store token" R "check again" "?" help
        else
          local -a h=("?" help "↵" details t status A "assign me")
          (( FIDX )) || h=(p pin "${h[@]}")
          estimated && h+=(w "log work")
          h+=(f filter s sort / search b browse m manage)
          (( FIDX )) && h+=(J jql)
          hints "${h[@]}" o open
        fi ;;
      browse)
        if [[ $BR_LEVEL == projects ]]; then hints "↵" open esc close
        elif (( BR_MINE )); then hints "⇥" "all issues" "↵" open "←" back esc close
        else hints "⇥" "only mine" "↵" open "←" back esc close
        fi ;;
      detail)
        local -a h=(esc back "?" help t status A "assign me")
        estimated && h+=(w "log work")
        hints "${h[@]}" "⇥" link "↵" follow o open y key Y branch a agent ;;
      trans)
        local -a h=(1-9 pick "↵" move)
        (( ${#TR_FN} )) && h+=(f "fill fields")
        hints "${h[@]}" e "set a field" A "assign me" o open esc back ;;
      worklog) hints esc back "↑↓" scroll w "log work" r refresh ;;
      pick)
        if (( PK_MULTI )); then hints "␣" tick "↵" done esc cancel
        else hints "↵" choose esc cancel
        fi ;;
      manage)
        if (( MG_CONFIRM )); then hints y "remove “$PIN_NAME[MG_ORDER[MG_SEL]]”" n keep
        else hints d remove esc back "?" help
        fi ;;
      help) hints "↑↓" scroll esc close ;;
      agents) hints 1-9 pick esc back ;;
    esac
  fi
  # an available update gets a row of its own above the keys of the list
  if [[ $MODE == list ]] && (( ! SEARCH )) && update_available; then
    local h
    local -a hit=()
    for h in $FOOT_HIT; do hit+=("$(( ${h%%:*} + 1 )):${h#*:}"); done
    bar_line " $K${B}u$R$BAR ${B}update to ${UPDATE[version]:-the new version}$R$BAR  herdr shows what changes and asks first"
    FOOT=("$REPLY" "${FOOT[@]}") FOOT_HIT=("1:1:${COLS}:u" "${hit[@]}")
  fi
  if [[ -n $NOTE ]] && (( EPOCHSECONDS < NOTE_UNTIL )); then
    (( NOTE_ERR )) && bar_line " $RED$NOTE" || bar_line " $K$NOTE"
    FOOT[1]=$REPLY FOOT_HIT=(${FOOT_HIT:#1:*})
  else
    NOTE=""
  fi
  (( ${#FOOT} )) || { bar_line ""; FOOT=("$REPLY") }
  FOOT_N=${#FOOT}
}

# A tap on a footer hint does what its key does.
press() { # hint key
  case $1 in
    esc) escape '' ;;
    ←) escape '[D' ;;
    ↵) key_press $'\r' ;;
    ⇥) key_press $'\t' ;;
    ␣) key_press ' ' ;;
    ↑↓|1-9) ;;
    *) key_press "$1" ;;
  esac
  FP=""
}

row_line() { # rows-index selected(0|1) key-width
  local -a f=("${(@ps:$JL_US:)ROWS[$1]}")
  local cat key=${(r:$3:)f[1]} mid="" plain flag=""
  status_sgr "$f[2]" "$f[3]" "$f[1]"; cat=$REPLY
  jl_age "$f[7]"; local age=${(l:3:)REPLY}
  local st=${(r:12:)f[2]} who=${(r:14:)f[6]}
  if (( $2 )); then
    plain="▸ ● $key $age"
    (( COLS >= 80 )) && plain+="  $st"
    (( COLS >= 110 )) && plain+="  $who"
    [[ -n $f[13] ]] && flag="⚑ "
    fit "${INV}${plain}  $flag$f[8]${(l:COLS:: :)}"
    REPLY="${REPLY%$R}$R"
  else
    (( COLS >= 80 )) && mid+="  ${cat}${st}${R}"
    (( COLS >= 110 )) && mid+="  ${D}${who}${R}"
    [[ -n $f[13] ]] && flag="${RED}⚑${R} "
    fit "  ${cat}●${R} ${B}${key}${R} ${D}${age}${R}${mid}  $flag$f[8]"
  fi
}

draw_list() {
  local i kw=6 len avail
  header_lines
  HDR=${#VIEW}
  LH=$(( LINES - HDR - FOOT_N ))
  (( LH < 1 )) && LH=1
  for i in $VISIBLE; do len=${#${ROWS[i]%%$JL_US*}}; (( len > kw )) && kw=$len; done
  (( SEL <= TOP )) && TOP=$(( SEL - 1 ))
  (( SEL > TOP + LH )) && TOP=$(( SEL - LH ))
  (( TOP < 0 )) && TOP=0
  if (( SETUP )); then draw_setup; return; fi
  if (( ! ${#VISIBLE} )); then
    if [[ -n $ERR ]]; then
      jl_wrap $(( COLS - 4 )) "$ERR"
      for i in $WRAPPED; do VIEW+=("  ${RED}$i${R}"); done
    elif loading; then VIEW+=("  ${D}loading…${R}")
    elif [[ -n $QUERY ]]; then VIEW+=("  ${D}no issue matches “$QUERY”${R}")
    else VIEW+=("  ${D}no issues${R}")
    fi
  fi
  for (( i = TOP + 1; i <= ${#VISIBLE} && i <= TOP + LH; i++ )); do
    row_line $VISIBLE[i] $(( i == SEL )) $kw
    VIEW+=("$REPLY")
  done
}

# --- details view --------------------------------------------------------------------------------
# Status as a badge colored by its category, priority and type by their usual meaning.
typeset -A CAT_BADGE=(new $'\e[1;97;44m' indeterminate $'\e[1;30;43m' done $'\e[1;30;42m')

NO_CAT_BADGE=$'\e[1;30;47m' BLOCKED_BADGE=$'\e[1;97;41m' ORANGE_BADGE=$'\e[1;30;48;5;208m'

# Beyond the category's color: a blocked status is red, an issue back in a "to do" status (REOPENED,
# by key) orange, and drafts and the backlog a lighter blue than the other "to do" statuses.
status_kind() { # name category [key] -> REPLY blocked | reopened | draft | the category
  if [[ $1 == (#i)*(block|impediment)* ]]; then REPLY=blocked
  elif [[ $2 == new && -n $3 && -n $REOPENED[$3] ]]; then REPLY=reopened
  elif [[ $2 == new && $1 == (#i)(draft|backlog) ]]; then REPLY=draft
  else REPLY=$2
  fi
}

status_sgr() { # name category [key] -> REPLY
  status_kind "$@"
  case $REPLY in
    blocked) REPLY=$RED ;;
    reopened) REPLY=$ORANGE ;;
    draft) REPLY=$DRAFT ;;
    *) REPLY=${CAT_SGR[$REPLY]:-$D} ;;
  esac
}

status_badge() { # name category [key] -> REPLY
  [[ -n $1 ]] || { REPLY=""; return }
  local name=$1
  status_kind "$@"
  case $REPLY in
    blocked) REPLY=$BLOCKED_BADGE ;;
    reopened) REPLY=$ORANGE_BADGE ;;
    draft) REPLY=$DRAFT_BADGE ;;
    *) REPLY=${CAT_BADGE[$REPLY]:-$NO_CAT_BADGE} ;;
  esac
  REPLY="$REPLY $name $R"
}

priority_text() { # name -> REPLY
  local c=$D g="●"
  case ${(L)1} in
    *(highest|blocker|critical|must)*) c=$'\e[31m' g="▲" ;;
    *(lowest|trivial|won)*) c=$'\e[34m' g="▼" ;;
    *(high|major|should)*) c=$'\e[38;5;208m' g="▲" ;;
    *(low|minor)*) c=$'\e[34m' g="▼" ;;
    *(medium|normal|could)*) c=$'\e[33m' g="■" ;;
  esac
  REPLY="$c$g $1$R"
}

type_text() { # name -> REPLY
  local c=$D
  case ${(L)1} in
    *bug*) c=$'\e[31m' ;;
    *(story|feature|improvement)*) c=$'\e[32m' ;;
    *epic*) c=$'\e[35m' ;;
    *task*) c=$'\e[34m' ;;
  esac
  REPLY="$c■$R $1"
}

dl() { DLINES+=("$1") DACT+=("$2") } # line [action]

dsection() { # title [count]
  local t="$1${2:+ ($2)}" n
  (( n = COLS - 5 - ${#t}, n < 0 ? (n = 0) : n ))
  dl ""
  dl " ${K}${B}${t}${R} ${K}${D}${(l:n::─:)}${R}"
}

# A labelled value, wrapped under its label; style starts every line of it (links are underlined).
dkv() { # label value [action] [style]
  local i
  MARKUP=()
  jl_wrap_into $(( COLS - 19 )) "$2" "" ""
  for (( i = 1; i <= ${#MARKUP}; i++ )); do
    (( i == 1 )) && dl " ${D}${(r:15:)1}${R} $4$MARKUP[i]" "$3" || dl "${(l:17:)} $4$MARKUP[i]" "$3"
  done
}

# A field value; issue keys and URLs become links.
dvalue() { # label value
  local v=$2
  if [[ $1 == Labels ]]; then
    dkv "$1" "${(j: :)${(@)${(s:, :)v}/#/$JL_CODE#}}$R"
  elif [[ $v == [A-Z][A-Z0-9_]##-[0-9]## ]]; then dkv "$1" "$v" "issue:$v" "$K$JL_UL"
  elif [[ $v == http(s|)://[^[:space:]]## ]]; then dkv "$1" "$v" "url:$v" "$JL_UL"
  else dkv "$1" "$v"
  fi
}

# "22 Oct 2026, 08:51 · 4d ago"; dates in the future count down instead.
ddate() { # timestamp -> REPLY
  local e s
  jl_epoch "$1" || { REPLY=$1; return }
  e=$REPLY
  [[ $1 == *T* ]] && strftime -s s '%d %b %Y, %H:%M' $e || strftime -s s '%d %b %Y' $e
  if (( e > EPOCHSECONDS )); then REPLY="$s ${D}· in $(( (e - EPOCHSECONDS + 86399) / 86400 ))d${R}"
  else jl_age "$1"; REPLY="$s ${D}· $REPLY ago${R}"
  fi
}

time_bar() { # estimate spent remaining -> REPLY
  local total=$(( $1 > $2 + $3 ? $1 : $2 + $3 )) n=20 fill c=$'\e[32m'
  (( total )) || { REPLY=""; return }
  fill=$(( $2 * n / total ))
  (( $1 && $2 > $1 )) && c=$'\e[38;5;208m'
  REPLY="$c${(l:fill::█:)}$R$D${(l:n - fill::░:)}$R $(( $2 * 100 / ($1 ? $1 : total) ))%"
}

# DLINES/DACT for the current issue, rebuilt when it, the width or the theme changes.
detail_lines() {
  local sig="$DETAIL_STAMP|$COLS|$APPEARANCE|$DETAIL_KEY"
  [[ $sig == "$DL_SIG" ]] && return
  DL_SIG=$sig DLINES=() DACT=()
  local w=$(( COLS - 3 )) r v n
  local -a f
  MARKUP=()
  jl_wrap_into $w "${DETAIL[summary]:-$ISSUE[summary]}" "" ""
  for v in $MARKUP; do dl " $B$v"; done
  dl " $K$JL_UL$JIRA_BASE_URL/browse/$DETAIL_KEY$R ${D}↗${R}" "url:$JIRA_BASE_URL/browse/$DETAIL_KEY"
  if [[ -n $DETAIL_ERR ]]; then
    dl ""
    MARKUP=(); jl_wrap_into $w "$DETAIL_ERR" "" ""
    for v in $MARKUP; do dl " $RED$v"; done
  fi
  if (( ! ${#DETAIL} )); then dl ""; dl " ${D}loading…${R}"; return; fi

  dsection Details
  status_badge "$DETAIL[status]" "$DETAIL[category]" "$DETAIL_KEY"; dkv Status "$REPLY"
  [[ -n $REOPENED[$DETAIL_KEY] && $DETAIL[category] == new ]] && dkv "" "${D}back in a “to do” status after it was further along${R}"
  (( DETAIL[flagged] )) && dkv Flagged "${RED}⚑${R} yes"
  dkv Resolution "${DETAIL[resolution]:-${D}Unresolved${R}}"
  [[ -n $DETAIL[priority] ]] && { priority_text "$DETAIL[priority]"; dkv Priority "$REPLY" }
  type_text "$DETAIL[type]"; dkv Type "$REPLY"
  [[ -n $DETAIL[parent] ]] && dkv Parent "$DETAIL[parent] $DETAIL[parent_summary]" "issue:$DETAIL[parent]" "$K$JL_UL"
  for r in $DREC; do
    f=("${(@ps:$JL_US:)r}")
    [[ $f[1] == field ]] && dvalue "$f[2]" "$f[3]"
  done

  dsection People
  for r in ${(M)DREC:#person$JL_US*}; do
    f=("${(@ps:$JL_US:)r}")
    [[ $f[3] == Unassigned ]] && dkv "$f[2]" "${D}Unassigned${R}" || dkv "$f[2]" "$B$f[3]$R"
  done
  (( DETAIL[watchers] )) && dkv Watchers "$DETAIL[watchers]"

  dsection Dates
  ddate "$DETAIL[created]"; dkv Created "$REPLY"
  ddate "$DETAIL[updated]"; dkv Updated "$REPLY"
  [[ -n $DETAIL[due] ]] && { ddate "$DETAIL[due]"; dkv Due "$REPLY" }
  [[ -n $DETAIL[resolved] ]] && { ddate "$DETAIL[resolved]"; dkv Resolved "$REPLY" }

  # Logged and Progress open the work log
  if (( DETAIL[estimate] || DETAIL[spent] || DETAIL[remaining] )) || [[ -n $DETAIL[points] ]]; then
    local wl="" wls=""
    (( DETAIL[spent] )) && wl="worklog:" wls="$K$JL_UL"
    if (( DETAIL[estimate] || DETAIL[spent] || DETAIL[remaining] )); then dsection "Time tracking"; else dsection Estimate; fi
    [[ -n $DETAIL[points] ]] && { jl_points_text "$DETAIL[points]"; dkv "Story points" "$REPLY" }
    (( DETAIL[estimate] )) && { jl_duration $DETAIL[estimate]; dkv Estimated "$REPLY" }
    jl_duration $DETAIL[spent]; dkv Logged "$REPLY" "$wl" "$wls"
    (( DETAIL[estimate] || DETAIL[remaining] )) && { jl_duration $DETAIL[remaining]; dkv Remaining "$REPLY" }
    time_bar $DETAIL[estimate] $DETAIL[spent] $DETAIL[remaining]; [[ -n $REPLY ]] && dkv Progress "$REPLY" "$wl"
  fi

  dsection Description
  if [[ -n ${DETAIL[description]//[[:space:]]/} ]]; then
    MARKUP=(); jl_markup $w "$DETAIL[description]"
    for v in $MARKUP; do dl " $v"; done
  else
    dl " ${D}no description${R}"
  fi

  n=${#${(M)DREC:#sub$JL_US*}}
  if (( n )); then
    dsection Sub-tasks $n
    for r in ${(M)DREC:#sub$JL_US*}; do
      f=("${(@ps:$JL_US:)r}")
      status_sgr "$f[3]" "$f[4]" "$f[2]"
      dl "  $REPLY●$R $K$JL_UL$f[2]$R ${D}${f[3]}${R}  $f[5]" "issue:$f[2]"
    done
  fi
  n=${#${(M)DREC:#link$JL_US*}}
  if (( n )); then
    dsection Links $n
    for r in ${(M)DREC:#link$JL_US*}; do
      f=("${(@ps:$JL_US:)r}")
      status_sgr "$f[4]" "$f[5]" "$f[3]"
      dl "  ${D}${f[2]}${R} $REPLY●$R $K$JL_UL$f[3]$R  $f[6]" "issue:$f[3]"
    done
  fi
  n=${#${(M)DREC:#att$JL_US*}}
  if (( n )); then
    dsection Attachments $n
    for r in ${(M)DREC:#att$JL_US*}; do
      f=("${(@ps:$JL_US:)r}")
      jl_size $f[3]; v=$REPLY
      jl_age "$f[5]"
      dl "  $K▪$R $JL_UL$f[2]$R  ${D}$v · $f[4] · $REPLY ago${R}" "url:$f[6]"
    done
  fi
  n=${#${(M)DREC:#comment$JL_US*}}
  if (( n )); then
    dsection Comments "$n, newest first"
    for r in ${(M)DREC:#comment$JL_US*}; do
      f=("${(@ps:$JL_US:)r}")
      ddate "$f[3]"
      dl " $K●$R $B$f[2]$R ${D}·${R} $REPLY"
      MARKUP=(); jl_markup $(( w - 3 )) "$f[4]"
      for v in $MARKUP; do dl "    $v"; done
      dl ""
    done
  fi
}

draw_detail() {
  local left back=""
  type_text "${DETAIL[type]:-$ISSUE[type]}"; left="$K$B$DETAIL_KEY$R  $REPLY"
  status_badge "${DETAIL[status]:-$ISSUE[status]}" "${DETAIL[category]:-$ISSUE[category]}" "$DETAIL_KEY"; left+="  $REPLY"
  (( ${DETAIL[flagged]:-$ISSUE[flagged]} )) && left+="  ${RED}⚑${R}"
  [[ -n ${DETAIL[priority]:-$ISSUE[priority]} ]] && { priority_text "${DETAIL[priority]:-$ISSUE[priority]}"; left+="  $REPLY" }
  (( ${#DSTACK} )) && back="${D}← $DSTACK[-1]${R}"
  lr "$left" "$back"
  VIEW+=("$REPLY")
  detail_lines
  LH=$(( LINES - 1 - FOOT_N ))
  (( DSCROLL > ${#DLINES} - LH )) && DSCROLL=$(( ${#DLINES} - LH ))
  (( DSCROLL < 0 )) && DSCROLL=0
  local i end=$DCUR
  while (( DCUR && end < ${#DACT} )) && [[ $DACT[end+1] == "$DACT[DCUR]" ]]; do (( end++ )); done
  for (( i = DSCROLL + 1; i <= ${#DLINES} && i <= DSCROLL + LH; i++ )); do
    if (( DCUR && i >= DCUR && i <= end )); then
      fit "$INV${(S)DLINES[i]//$'\e'\[[0-9;]#m/}${(l:COLS:: :)}"
      REPLY="${REPLY%$R}$R"
    else
      fit "$DLINES[i]"
    fi
    VIEW+=("$REPLY")
  done
}

# Every key, grouped by where it works. Scrolls with the arrows and wheel; any other key closes it.
show_help() { HELP_BACK=$MODE MODE=help HSCROLL=0 FP="" }

draw_help() {
  local -a rows=(
    "" "List"
    "↑↓ j k" "move (mouse wheel too)"
    "g G" "first / last (also Home End)"
    "PgUp PgDn" "page up / down"
    "↵ l click" "details of the issue"
    "f ⇥  F" "next / previous filter"
    "1–9" "pick a filter"
    "s  S" "next sort / reverse it"
    "/" "search the loaded issues; esc clears it"
    "J" "type a JQL query"
    "b" "browse projects, boards, sprints"
    "p" "pin the view (from b or J) to a directory"
    "m" "manage pinned filters"
    "r  R" "fetch again / reload config, check for updates"
    "u" "update the plugin, when the bar offers it"
    "o" "open the issue in the browser"
    "t" "change the status (workflow)"
    "A" "assign the issue to you"
    "w" "log work (lowers the remaining estimate)"
    "y  Y" "copy key / branch name"
    "a" "send the issue to an agent"
    "q" "close the pane"
    "" "Setup (shows until Jira answers)"
    "1" "set the Jira URL"
    "2" "store the token in the keychain"
    "" "Details"
    "↑↓ j k ␣" "scroll (mouse wheel too)"
    "⇥  ⇧⇥" "next / previous link"
    "↵ click" "follow the link"
    "esc ← h q" "back"
    "o y Y a" "open, copy key / branch, send to agent"
    "t  A  w" "change the status / assign to you / log work"
    "Logged" "tap it (or Progress) for the work log"
    "r" "fetch the issue again"
    "" "Status (t)"
    "1–9 ↵" "move the issue there"
    "assigns you" "Jira needs an assignee; you become it"
    "A" "assign to you; Jira may then offer more"
    "asks for …" "a required field, asked for before the move"
    "error" "a rule Jira checks on the move; ↵ retries"
    "f" "fill the fields the error names, try again"
    "e" "set any field of the issue, then try again"
    "" "Work log (Logged in the details)"
    "↑↓ j k ␣" "scroll"
    "w  r" "log work / fetch again"
    "esc ← q" "back"
    "" "Picking a value"
    "type" "narrow the list"
    "␣" "tick (fields with several values)"
    "↵" "take the ticked or the selected one"
    "esc" "clear the typing, then cancel"
    "" "Browser (b)"
    "type" "narrow the list"
    "↵ → click" "open"
    "⇥" "only mine (board list and a board's views)"
    "← ⌫" "back one level"
    "esc" "clear the typing, then close"
    "" "Pinned filters (m)"
    "↑↓ j k" "move"
    "d ⌫ del" "remove, after y to confirm"
    "esc ← q" "back"
    "" "Colors"
    "●" "status: blue to do, yellow in progress, green done"
    "red" "blocked"
    "orange" "back in to do after it was further along"
    "light blue" "draft or backlog"
    "⚑" "flagged"
    "" "Footer"
    "tap" "a key in the bar presses it")
  local i
  local -a lines=(" ${K}${B}Jira Light${R} ${D}— keys, ↑↓ scroll, any other key closes${R}")
  for (( i = 1; i < ${#rows}; i += 2 )); do
    if [[ -z $rows[i] ]]; then lines+=("" " ${K}${B}$rows[i+1]${R}")
    else lines+=("  ${K}${(r:11:)rows[i]}${R} $rows[i+1]")
    fi
  done
  lines+=("" " ${D}Filters for a directory: context + filter in${R}" " ${D}${JL_CONFIG/#$HOME/~}${R}")
  update_status
  [[ -n $REPLY ]] && lines+=("" " ${D}${REPLY}${R}")
  LH=$(( LINES - FOOT_N ))
  (( HSCROLL > ${#lines} - LH )) && HSCROLL=$(( ${#lines} - LH ))
  (( HSCROLL < 0 )) && HSCROLL=0
  for (( i = HSCROLL + 1; i <= ${#lines} && i <= HSCROLL + LH; i++ )); do fit "$lines[i]"; VIEW+=("$REPLY"); done
}

draw_browse() {
  local crumb i n=${#BR_VIS} line
  case $BR_LEVEL in
    projects) crumb="Projects" ;;
    boards) crumb="$BR_PKEY · $BR_PNAME"; (( BR_MINE )) && crumb+=" · mine" ;;
    entries) crumb="$BR_PKEY › $BR_BNAME"; (( BR_MINE )) && crumb+=" · mine" ;;
  esac
  lr "${K}${B}Browse${R} ${D}·${R} ${B}${crumb}${R}" "${D}${n}/${#BR_ITEM}${R}"
  VIEW+=("$REPLY")
  line=""
  (( BR_LOAD )) && line="${K}loading…${R}"
  lr "${K}>${R} ${BR_Q}█" "$line"
  VIEW+=("$REPLY")
  if [[ -n $BR_ERR ]]; then fit " ${RED}${BR_ERR}${R}"; VIEW+=("$REPLY"); fi
  HDR=${#VIEW}
  LH=$(( LINES - HDR - FOOT_N ))
  (( LH < 1 )) && LH=1
  (( BR_SEL <= BR_TOP )) && BR_TOP=$(( BR_SEL - 1 ))
  (( BR_SEL > BR_TOP + LH )) && BR_TOP=$(( BR_SEL - LH ))
  (( BR_TOP < 0 )) && BR_TOP=0
  (( n || BR_LOAD )) || VIEW+=("  ${D}nothing matches${R}")
  for (( i = BR_TOP + 1; i <= n && i <= BR_TOP + LH; i++ )); do
    line=$BR_ITEM[BR_VIS[i]]
    if (( i == BR_SEL )); then
      fit "${INV}▸ ${(S)line//$'\e'\[[0-9;]#m/}${(l:COLS:: :)}"
      REPLY="${REPLY%$R}$R"
    else
      fit "  $line"
    fi
    VIEW+=("$REPLY")
  done
}

draw_manage() {
  local n=${#PIN_AT} d="" i j k sr=0 name
  local -a rows
  lr "${K}${B}Pinned filters${R}" "${D}${n} in config.zsh${R}"
  VIEW+=("$REPLY")
  HDR=${#VIEW}
  LH=$(( LINES - HDR - FOOT_N ))
  (( LH < 1 )) && LH=1
  MG_MAP=()
  if (( ! n )); then VIEW+=("" "  ${D}nothing pinned yet — pick a view with b and press p${R}"); return; fi
  for (( k = 1; k <= n; k++ )); do
    i=$MG_ORDER[k]
    if [[ $PIN_DIR[i] != "$d" ]]; then
      d=$PIN_DIR[i] j=${CTX_PATH[(Ie)$PIN_DIR[i]]}
      (( j )) && name=$CTX_NAME[j] || name=${PIN_CTX[i]:-${d:t}}
      (( ${#rows} )) && { rows+=("") MG_MAP+=(0) }
      fit " ${K}${d/#$HOME/~}${R} ${D}· ${name}${R}"; rows+=("$REPLY") MG_MAP+=(0)
    fi
    MG_MAP+=($k)
    if (( k == MG_SEL )); then
      sr=${#MG_MAP}
      fit "${INV}▸ $PIN_NAME[i]  $PIN_JQL[i]${(l:COLS:: :)}"; rows+=("${REPLY%$R}$R")
    else
      fit "  $PIN_NAME[i]  ${D}$PIN_JQL[i]${R}"; rows+=("$REPLY")
    fi
  done
  # the directory row above a group's first entry scrolls into view with it
  (( sr - 1 <= MG_TOP )) && MG_TOP=$(( sr - 2 ))
  (( sr > MG_TOP + LH )) && MG_TOP=$(( sr - LH ))
  (( MG_TOP < 0 )) && MG_TOP=0
  for (( i = MG_TOP + 1; i <= ${#rows} && i <= MG_TOP + LH; i++ )); do VIEW+=("$rows[i]"); done
}

draw_agents() {
  local i p name
  VIEW+=(" ${K}${B}Send $ISSUE[key] to which agent?${R}" "")
  for (( i = 1; i <= ${#AGENTS} && i <= 9; i++ )); do
    p=$AGENTS[i]
    name=$(print -r -- "$ALLPANES" | jq -r --arg p "$p" \
      '.result.panes[] | select(.pane_id == $p) | "\(.agent) (\(.agent_status // "?")) \(.foreground_cwd // .cwd // "")"')
    fit "  ${K}$i${R} ${name/$HOME/~}"; VIEW+=("$REPLY")
  done
}

# WLINES for the work log, rebuilt when it, the width or the theme changes.
draw_worklog() {
  local i v total=0 sig="$WL_STAMP|$COLS|$APPEARANCE"
  for i in $WL_SPENT; do (( total += i )); done
  jl_duration $total
  lr "${K}${B}${WL_KEY}${R} ${D}·${R} ${B}Work log${R}" "${D}${#WL_SPENT} entries · $REPLY${R}"
  VIEW+=("$REPLY")
  if [[ $sig != "$WL_SIG" ]]; then
    WL_SIG=$sig WLINES=()
    if [[ -n $WL_ERR ]]; then
      jl_wrap $(( COLS - 3 )) "$WL_ERR"
      for v in $WRAPPED; do WLINES+=(" ${RED}$v${R}"); done
    elif (( ! ${#WL_SPENT} )); then
      [[ -f $JL_STATE_DIR/cache/$WL_ENTRY.json ]] && WLINES+=(" ${D}nothing logged yet — w logs work${R}") || WLINES+=(" ${D}loading…${R}")
    fi
    for (( i = 1; i <= ${#WL_SPENT}; i++ )); do
      jl_duration $WL_SPENT[i]; v=$REPLY
      ddate "$WL_STARTED[i]"
      WLINES+=("" " $K●$R $B$v$R  $WL_AUTHOR[i] ${D}·${R} $REPLY")
      if [[ -n ${WL_COMMENT[i]//[[:space:]]/} ]]; then
        MARKUP=(); jl_markup $(( COLS - 7 )) "$WL_COMMENT[i]"
        for v in $MARKUP; do WLINES+=("    $v"); done
      fi
    done
  fi
  LH=$(( LINES - 1 - FOOT_N ))
  (( WL_SCROLL > ${#WLINES} - LH )) && WL_SCROLL=$(( ${#WLINES} - LH ))
  (( WL_SCROLL < 0 )) && WL_SCROLL=0
  for (( i = WL_SCROLL + 1; i <= ${#WLINES} && i <= WL_SCROLL + LH; i++ )); do fit "$WLINES[i]"; VIEW+=("$REPLY"); done
}

draw_pick() {
  local i j n=${#PK_VIS} line box
  lr "${K}${B}${PK_TITLE}${R}" "${D}${n}/${#PK_ID}${R}"
  VIEW+=("$REPLY")
  fit "${K}>${R} ${PK_Q}█"
  VIEW+=("$REPLY")
  HDR=2
  LH=$(( LINES - HDR - FOOT_N ))
  (( LH < 1 )) && LH=1
  (( PK_SEL <= PK_TOP )) && PK_TOP=$(( PK_SEL - 1 ))
  (( PK_SEL > PK_TOP + LH )) && PK_TOP=$(( PK_SEL - LH ))
  (( PK_TOP < 0 )) && PK_TOP=0
  (( n )) || VIEW+=("  ${D}nothing matches${R}")
  for (( i = PK_TOP + 1; i <= n && i <= PK_TOP + LH; i++ )); do
    j=$PK_VIS[i] box=""
    (( PK_MULTI )) && { (( PK_TICK[$PK_ID[j]] )) && box="[x] " || box="[ ] " }
    line="$box$PK_LABEL[j]${PK_NOTE[j]:+  ${D}$PK_NOTE[j]${R}}"
    if (( i == PK_SEL )); then
      fit "${INV}▸ ${(S)line//$'\e'\[[0-9;]#m/}${(l:COLS:: :)}"
      REPLY="${REPLY%$R}$R"
    else
      fit "  $line"
    fi
    VIEW+=("$REPLY")
  done
}

draw_trans() {
  local i n=${#TR_ID} w=4 tw=4 num tag line who
  unassigned && who="${D}Unassigned${R}" || who="${D}${ISSUE[assignee]}${R}"
  status_badge "$ISSUE[status]" "$ISSUE[category]" "$TR_KEY"
  lr "${K}${B}${TR_KEY}${R}  $REPLY ${D}→ which status?${R}" "$who"
  VIEW+=("$REPLY" "")
  for i in $TR_NAME; do (( ${#i} > w )) && w=${#i}; done
  for i in $TR_TO; do (( ${#i} > tw )) && tw=${#i}; done
  if (( ! n )); then
    if [[ -n $TR_LOAD_ERR ]]; then
      jl_wrap $(( COLS - 4 )) "$TR_LOAD_ERR"
      for i in $WRAPPED; do VIEW+=("  ${RED}$i${R}"); done
    elif trans_loading; then VIEW+=("  ${D}loading…${R}")
    else VIEW+=("  ${D}Jira offers no transition to you here${R}")
    fi
  fi
  for (( i = 1; i <= n; i++ )); do
    num=" "; (( i <= 9 )) && num=$i
    tag=""
    (( TR_ASSIGN[i] )) && unassigned && tag+="  ${K}assigns you${R}"
    [[ -n $TR_NEEDS[i] ]] && tag+="  ${K}asks for $TR_NEEDS[i]${R}"
    status_sgr "$TR_TO[i]" "$TR_CAT[i]"
    line="${(r:w:)TR_NAME[i]}  → $REPLY●${R} ${(r:tw:)TR_TO[i]}$tag"
    if (( i == TR_SEL )); then
      fit "${INV}▸ $num  ${(S)line//$'\e'\[[0-9;]#m/}${(l:COLS:: :)}"
      REPLY="${REPLY%$R}$R"
    else
      fit "  ${K}$num${R}  $line"
    fi
    VIEW+=("$REPLY")
  done
  local -a notes=()
  if [[ -n $TR_ERR ]]; then
    VIEW+=("")
    jl_wrap $(( COLS - 3 )) "$TR_ERR"
    for i in $WRAPPED; do VIEW+=(" ${RED}$i${R}"); done
    if (( ${#TR_FN} )); then field_names $TR_FN; notes+=("f sets $REPLY, then tries again.")
    else notes+=("e sets a field of the issue, then tries again.")
    fi
    unassigned && notes+=("A assigns it to you, then ↵ tries again.")
  elif unassigned; then
    notes+=("Jira lists only the transitions you may run; a status that needs an assignee may appear once you take the issue: A assigns it to you.")
  elif [[ $ISSUE[assignee] != "$JL_ME_NAME" ]]; then
    notes+=("Jira may hold back transitions only the assignee can run: A assigns it to you.")
  fi
  for line in $notes; do
    VIEW+=("")
    jl_wrap $(( COLS - 3 )) "$line"
    for i in $WRAPPED; do VIEW+=(" ${D}$i${R}"); done
  done
}

paint() {
  VIEW=()
  footer_lines
  case $MODE in
    list) draw_list ;;
    detail) draw_detail ;;
    help) draw_help ;;
    agents) draw_agents ;;
    trans) draw_trans ;;
    pick) draw_pick ;;
    worklog) draw_worklog ;;
    browse) draw_browse ;;
    manage) draw_manage ;;
  esac
  while (( ${#VIEW} < LINES - FOOT_N )); do VIEW+=(""); done
  VIEW=("${(@)VIEW[1,LINES-FOOT_N]}")
  VIEW+=("${FOOT[@]}")
  printf '\e]0;%s\a\e[H%s\e[K\e[J' "$LABEL" "${(pj:\e[K\n:)VIEW}"
}

# --- input -----------------------------------------------------------------------------------------
click() { # row column
  local h
  local -a p
  if (( $1 > LINES - FOOT_N )); then
    for h in $FOOT_HIT; do
      p=("${(@s.:.)h}")
      (( p[1] == $1 - LINES + FOOT_N && $2 >= p[2] && $2 <= p[3] )) && { press "$p[4]"; return }
    done
    return
  fi
  case $MODE in
    list)
      local i=$(( TOP + $1 - HDR ))
      (( $1 > HDR && i >= 1 && i <= ${#VISIBLE} )) || return
      if (( i == SEL )); then open_detail; else SEL=$i FP=""; fi ;;
    browse)
      local i=$(( BR_TOP + $1 - HDR ))
      (( $1 > HDR && i >= 1 && i <= ${#BR_VIS} )) || return
      if (( i == BR_SEL )); then br_open; else BR_SEL=$i FP=""; fi ;;
    detail)
      local i=$(( DSCROLL + $1 - 1 ))
      (( $1 > 1 && i <= ${#DACT} )) && [[ -n $DACT[i] ]] && detail_act "$DACT[i]" ;;
    manage)
      local i=$(( MG_TOP + $1 - HDR ))
      (( $1 > HDR && i >= 1 && i <= ${#MG_MAP} && MG_MAP[i] )) || return
      MG_SEL=$MG_MAP[i] MG_CONFIRM=0 FP="" ;;
    trans)
      local i=$(( $1 - TR_HDR ))
      (( i >= 1 && i <= ${#TR_ID} )) || return
      if (( i == TR_SEL )); then run_transition $i; else TR_SEL=$i FP=""; fi ;;
    pick)
      local i=$(( PK_TOP + $1 - HDR ))
      (( $1 > HDR && i >= 1 && i <= ${#PK_VIS} )) || return
      if (( i != PK_SEL )); then PK_SEL=$i FP=""
      elif (( PK_MULTI )); then pk_toggle
      else pk_confirm
      fi ;;
    help) MODE=$HELP_BACK FP="" ;;
  esac
}

scroll() { # delta
  case $MODE in
    list) move $1 ;;
    browse) br_move $1 ;;
    manage) mg_move $1 ;;
    trans) tr_move $1 ;;
    pick) pk_move $1 ;;
    worklog) WL_SCROLL=$(( WL_SCROLL + $1 )); FP="" ;;
    help) HSCROLL=$(( HSCROLL + $1 )); FP="" ;;
    detail) DSCROLL=$(( DSCROLL + $1 )); FP="" ;;
  esac
}

key_list() { # key
  if (( SETUP )); then
    case $1 in
      1) setup_url; return ;;
      2) setup_token; return ;;
    esac
  fi
  case $1 in
    j) move 1 ;;
    k) move -1 ;;
    g) move -100000 ;;
    G) move 100000 ;;
    $'\n'|$'\r'|l) open_detail ;;
    f|$'\t') next_filter 1 ;;
    F) next_filter -1 ;;
    [1-9]) (( $1 <= ${#JL_FILTERS} )) && { FIDX=$1 SEL=1 TOP=0; load_entry } ;;
    s) next_sort ;;
    S) [[ $SORT == filter ]] && note "pick a sort with s first" || { (( REV = ! REV )); load_entry } ;;
    /) SEARCH=1 FP="" ;;
    J) custom_jql ;;
    r) load_entry force; note "fetching…" ;;
    R) reload_config; update_check force ;;
    u) update_available && update_now ;;
    o) selected_issue && open_url "$ISSUE[url]" ;;
    t) open_trans ;;
    A) assign_me ;;
    w) log_work ;;
    y) selected_issue && copy "$ISSUE[key]" key ;;
    Y) selected_issue && { jl_fill "$JIRA_BRANCH_TEMPLATE" ISSUE; copy "$REPLY" branch } ;;
    a) pick_agent ;;
    b) browse ;;
    m) manage ;;
    p) pin_view ;;
    \?) show_help ;;
    q) "$H" pane close "$HERDR_PANE_ID" >/dev/null 2>&1; exit ;;
  esac
}

key_detail() {
  case $1 in
    j) scroll 1 ;;
    k) scroll -1 ;;
    ' ') scroll $(( LH - 1 )) ;;
    $'\t') detail_link 1 ;;
    $'\n'|$'\r') (( DCUR )) && detail_act "$DACT[DCUR]" ;;
    q|h) detail_back ;;
    o) open_url "$ISSUE[url]" ;;
    y) copy "$ISSUE[key]" key ;;
    Y) jl_fill "$JIRA_BRANCH_TEMPLATE" ISSUE; copy "$REPLY" branch ;;
    a) pick_agent ;;
    t) open_trans ;;
    A) assign_me ;;
    w) log_work ;;
    r) jl_issue "$DETAIL_KEY" force; note "fetching…" ;;
    \?) show_help ;;
  esac
}

# Letters narrow the level, so the browser is driven by arrows, Enter, Backspace and Esc.
key_browse() {
  case $1 in
    $'\x7f'|$'\b') if [[ -z $BR_Q ]]; then br_up; return; fi; BR_Q=${BR_Q[1,-2]} ;;
    $'\x15') BR_Q="" ;;
    $'\n'|$'\r') br_open; return ;;
    $'\t') [[ $BR_LEVEL == (boards|entries) ]] && br_toggle_mine; return ;;
    [[:print:]]) BR_Q+=$1 ;;
    *) return ;;
  esac
  BR_SEL=1 BR_TOP=0 BR_FIRST_VIEW=0
  br_filter
  # Enter after typing picks the first match, not the switch that stays on top
  (( ${#BR_VIS} > 1 )) && [[ $BR_VAL[BR_VIS[1]] == toggle:* ]] && BR_SEL=2
  FP=""
}

key_press() { # key
  if (( SEARCH )); then key_search "$1"
  else
    case $MODE in
      list) key_list "$1" ;;
      trans) key_trans "$1" ;;
      pick) key_pick "$1" ;;
      worklog) key_worklog "$1" ;;
      browse) key_browse "$1" ;;
      detail) key_detail "$1" ;;
      manage) key_manage "$1" ;;
      help)
        case $1 in
          j) scroll 1 ;;
          k) scroll -1 ;;
          *) MODE=$HELP_BACK FP="" ;;
        esac ;;
      agents)
        if [[ $1 == [1-9] ]] && (( $1 <= ${#AGENTS} )); then MODE=$MODE_BACK FP=""; send_to_agent $AGENTS[$1]
        else MODE=$MODE_BACK FP=""
        fi ;;
    esac
  fi
}

key_trans() {
  case $1 in
    [1-9]) run_transition $1 ;;
    j) tr_move 1 ;;
    k) tr_move -1 ;;
    $'\n'|$'\r') run_transition $TR_SEL ;;
    A) assign_me ;;
    f) (( ${#TR_FN} )) && ask_fields $TR_FN ;;
    e) choose_field ;;
    o) open_url "$ISSUE[url]" ;;
    q|h) MODE=$TR_BACK FP="" ;;
    \?) show_help ;;
  esac
}

key_worklog() {
  case $1 in
    j) scroll 1 ;;
    k) scroll -1 ;;
    ' ') scroll $(( LH - 1 )) ;;
    w) log_work ;;
    r) jl_worklogs "$WL_KEY"; note "fetching…" ;;
    q|h) MODE=$WL_BACK FP="" ;;
    \?) show_help ;;
  esac
}

# Letters narrow the list, so the picker is driven by arrows, Space, Enter and Esc.
key_pick() {
  case $1 in
    $'\x7f'|$'\b') PK_Q=${PK_Q[1,-2]} ;;
    $'\x15') PK_Q="" ;;
    $'\n'|$'\r') pk_confirm; return ;;
    ' ') if (( PK_MULTI )); then pk_toggle; return; fi; PK_Q+=' ' ;;
    [[:print:]]) PK_Q+=$1 ;;
    *) return ;;
  esac
  PK_SEL=1 PK_TOP=0
  pk_filter
  FP=""
}

key_manage() {
  if (( MG_CONFIRM )); then
    if [[ $1 == y ]]; then mg_remove; else MG_CONFIRM=0 FP=""; fi
    return
  fi
  case $1 in
    j) mg_move 1 ;;
    k) mg_move -1 ;;
    d|$'\x7f'|$'\b') (( ${#PIN_AT} )) && { MG_CONFIRM=1 FP="" } ;;
    q|h) MODE=list FP="" ;;
    \?) show_help ;;
  esac
}

key_search() {
  case $1 in
    $'\x7f'|$'\b') QUERY=${QUERY[1,-2]} ;;
    $'\x15') QUERY="" ;;
    $'\n'|$'\r') SEARCH=0 ;;
    [[:print:]]) QUERY+=$1 ;;
    *) return ;;
  esac
  SEL=1 TOP=0
  apply_query
  FP=""
}

escape() { # sequence after ESC
  case $1 in
    '')
      if (( SEARCH )); then SEARCH=0 QUERY=""; apply_query
      elif [[ $MODE == list && -n $QUERY ]]; then QUERY=""; apply_query
      elif [[ $MODE == agents ]]; then MODE=$MODE_BACK
      elif [[ $MODE == trans ]]; then MODE=$TR_BACK
      elif [[ $MODE == pick && -n $PK_Q ]]; then PK_Q=""; pk_filter
      elif [[ $MODE == pick ]]; then ask_cancel
      elif [[ $MODE == worklog ]]; then MODE=$WL_BACK
      elif [[ $MODE == browse && -n $BR_Q ]]; then BR_Q=""; br_filter
      elif [[ $MODE == detail ]]; then detail_back
      elif [[ $MODE == help ]]; then MODE=$HELP_BACK
      elif [[ $MODE == manage ]] && (( MG_CONFIRM )); then MG_CONFIRM=0
      else MODE=list
      fi
      FP="" ;;
    [[O]A) scroll -1 ;;
    [[O]B) scroll 1 ;;
    [[O]C) case $MODE in list) open_detail ;; browse) br_open ;; esac ;;
    [[O]D) case $MODE in browse) br_up ;; detail) detail_back ;; help) MODE=$HELP_BACK FP="" ;; trans) MODE=$TR_BACK FP="" ;; pick) ask_cancel ;; worklog) MODE=$WL_BACK FP="" ;; *) MODE=list FP="" ;; esac ;;
    '[Z') [[ $MODE == detail ]] && detail_link -1 ;;
    '[3~') [[ $MODE == manage ]] && key_manage d ;;
    '[5~') scroll $(( -LH + 1 )) ;;
    '[6~') scroll $(( LH - 1 )) ;;
    '[H'|'[1~') scroll -100000 ;;
    '[F'|'[4~') scroll 100000 ;;
  esac
}

# Handles everything that is queued: keys, clicks and wheel bursts.
handle_input() {
  local k c seq n=0 delta=0 b
  read -r -s -k1 -t ${INPUT_WAIT:-2} k </dev/tty || return
  while :; do
    if [[ $k == $'\e' ]]; then
      seq=""
      while read -r -s -k1 -t 0.05 c </dev/tty; do
        seq+=$c
        [[ $c == [Mmn~] || $seq == [[O][A-DHFZ] || ${#seq} -gt 20 ]] && break
      done
      # SGR mouse report: [<button;column;row then M (press) or m (release)
      if [[ $seq =~ '^\[<([0-9]+);([0-9]+);([0-9]+)([Mm])$' ]]; then
        b=$(( match[1] & ~28 ))
        if (( b == 64 )); then (( delta -= 3 ))
        elif (( b == 65 )); then (( delta += 3 ))
        elif (( b == 0 )) && [[ $match[4] == M ]]; then
          (( delta )) && scroll $delta
          click "$match[3]" "$match[2]"
          drain 0.08
          return
        fi
      elif [[ $seq =~ '^\[\?997;([12])n$' ]]; then
        [[ $match[1] == 2 ]] && APPEARANCE=light || APPEARANCE=dark
        apply_palette; FP=""
      else
        escape "$seq"
      fi
    else
      key_press "$k"
    fi
    (( ++n < 200 )) || break
    read -r -s -k1 -t 0.01 k </dev/tty || break
  done
  (( delta )) && scroll $delta
}

# The pane runs the code it started with; when the plugin is updated (or edited, when linked), it
# starts itself again, once the new files pass a syntax check.
code_stamp() { # -> REPLY
  local f
  local -a t
  REPLY=""
  for f in "$ROOT/jira.zsh" "$ROOT"/lib/*.zsh(N); do t=(); zstat -A t +mtime "$f" 2>/dev/null; REPLY+="$t[1]:"; done
}

restart_if_updated() {
  code_stamp
  [[ $REPLY == "$CODE_STAMP" ]] && return
  local f
  for f in "$ROOT/jira.zsh" "$ROOT"/lib/*.zsh(N); do zsh -n "$f" 2>/dev/null || return; done
  save_view
  printf '%s\e[?25h' "$MOUSE_OFF"
  normal_tty
  export JL_RESTARTED=1
  exec zsh "$ROOT/jira.zsh"
}

# --- main ------------------------------------------------------------------------------------------
TTY_SAVED=$(stty -g </dev/tty 2>/dev/null)
quiet_tty
printf '\e[?25l%s' "$MOUSE_ON"
trap 'save_view; printf "%s\e[?25h" "$MOUSE_OFF"; normal_tty' EXIT
trap 'exit 130' INT TERM HUP
trap 'FP= NEED_POLL=1' WINCH
query_theme
MODE=list DIR="" LAST_FOCUSED="" FP="" CTX=-1 FIDX=1 SORT=filter REV=0 SEL=1 TOP=0 HDR=2 LH=1
SEARCH=0 QUERY="" NOTE="" NOTE_UNTIL=0 NOTE_ERR=0 ENTRY="" ENTRY_STAMP="" ERR=""
typeset -a ROWS VISIBLE VIEW DLINES WLINES AGENTS TAB_AGENTS WS_AGENTS JL_FILTERS
CONFIG_STAMP=$(zstat +mtime "$JL_CONFIG" 2>/dev/null)
code_stamp; CODE_STAMP=$REPLY
ROOT_STAMP=$(zstat +mtime "$ROOT_FILE" 2>/dev/null) UPDATE_STAMP=""
update_check
read_update
(( ${JL_RESTARTED:-0} )) && note "updated to the new version"
unset JL_RESTARTED
# herdr's pane list is polled every POLL_EVERY seconds; the cache files are checked on every pass,
# which costs no process.
POLL_EVERY=2 LAST_POLL=0 NEED_POLL=1
while :; do
  if (( NEED_POLL || EPOCHREALTIME - LAST_POLL >= POLL_EVERY )); then
    read -r LINES COLS < <(stty size </dev/tty 2>/dev/null || print "40 60")
    locate
    fields_check
    jl_match_context "$DIR"
    if (( REPLY != CTX )); then switch_context $REPLY; MODE=list; fi
    if [[ $(zstat +mtime "$JL_CONFIG" 2>/dev/null) != "$CONFIG_STAMP" ]]; then
      CONFIG_STAMP=$(zstat +mtime "$JL_CONFIG" 2>/dev/null)
      reload_config
    fi
    refresh_if_stale
    follow_update
    restart_if_updated
    update_check $JL_UPDATE_EVERY
    read_update && FP=""
    LAST_POLL=$EPOCHREALTIME NEED_POLL=0
  fi
  read_entry
  read_reopened
  [[ $MODE == detail ]] && read_detail
  [[ $MODE == trans ]] && read_trans
  [[ $MODE == worklog ]] && read_worklog
  [[ $MODE == browse ]] && br_read
  # the minute keeps "updated 3m ago" current; NOTE_UNTIL clears a note when it expires
  fp="$MODE|$LINES|$COLS|$APPEARANCE|$(( EPOCHSECONDS / 60 ))|$(( EPOCHSECONDS < NOTE_UNTIL ))|${JL_INFLIGHT[${ENTRY:-none}]}"
  [[ "$fp" != "$FP" ]] && { FP=$fp; paint }
  INPUT_WAIT=$(( POLL_EVERY - (EPOCHREALTIME - LAST_POLL) ))
  (( INPUT_WAIT < 0.05 )) && INPUT_WAIT=0.05
  handle_input
done
