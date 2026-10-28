# Jira helpers: context matching, JQL sorting, text helpers, and background fetches into a file cache.
zmodload zsh/datetime
zmodload -F zsh/stat b:zstat
JL_US=$'\x1f'

# Index of the context whose path is DIR or the deepest parent of it; 0 = the global filters.
jl_match_context() { # dir -> REPLY
  local d=${1:A} p i best=0 blen=-1
  for (( i = 1; i <= ${#CTX_PATH}; i++ )); do
    p=$CTX_PATH[i]
    if [[ $d == "$p" || $d == "$p"/* ]] && (( ${#p} > blen )); then best=$i blen=${#p}; fi
  done
  REPLY=$best
}

# Indices into FLT_* shown for a context: its own filters, then (JIRA_INHERIT_GLOBAL) the global ones.
jl_filters_for() { # ctx -> JL_FILTERS
  local i
  JL_FILTERS=()
  for (( i = 1; i <= ${#FLT_NAME}; i++ )); do (( FLT_CTX[i] == $1 )) && JL_FILTERS+=($i); done
  (( $1 && JIRA_INHERIT_GLOBAL )) || return 0
  for (( i = 1; i <= ${#FLT_NAME}; i++ )); do (( FLT_CTX[i] == 0 )) && JL_FILTERS+=($i); done
}

JL_SORTS=(filter updated created priority rank key status)
typeset -gA JL_SORT_DIR=(updated DESC created DESC priority DESC rank ASC key DESC status ASC)

jl_strip_order() { # jql -> REPLY
  setopt local_options extended_glob
  local j=$1
  if [[ $j =~ '(^|[[:space:]])[Oo][Rr][Dd][Ee][Rr][[:space:]]+[Bb][Yy]([[:space:]].*)?$' ]]; then
    j=${j[1,MBEGIN-1]}
  fi
  REPLY=${j%%[[:space:]]#}
}

# The filter's JQL with its ORDER BY replaced by the sort mode; "filter" keeps the filter's own order.
jl_sorted_jql() { # jql mode reverse(0|1) -> REPLY
  if [[ $2 == filter ]]; then REPLY=$1; return; fi
  local dir=${JL_SORT_DIR[$2]:-DESC}
  (( $3 )) && { [[ $dir == DESC ]] && dir=ASC || dir=DESC }
  jl_strip_order "$1"
  REPLY="${REPLY:+$REPLY }ORDER BY $2 $dir"
}

jl_slug() { # text -> REPLY
  setopt local_options extended_glob
  local s=${(L)1}
  s=${s//ä/ae} s=${s//ö/oe} s=${s//ü/ue} s=${s//ß/ss}
  s=${s//[^a-z0-9]##/-}
  s=${s##-##} s=${s%%-##}
  s=${s[1,40]}
  REPLY=${s%%-##}
}

# Fills {key} {summary} {url} {status} {type} {priority} {assignee} {slug}; \n becomes a newline.
jl_fill() { # template issue-assoc-name -> REPLY
  local t=$1 f v
  local -A iss=("${(@Pkv)2}")
  jl_slug "$iss[summary]"; iss[slug]=$REPLY
  for f in key summary url status type priority assignee slug; do
    v=$iss[$f]
    t=${t//\{$f\}/$v}
  done
  REPLY=${t//\\n/$'\n'}
}

# "3m", "5h", "2d", "6w" since a Jira timestamp (2026-10-26T14:46:03.000+0100).
jl_age() { # timestamp -> REPLY
  local s
  jl_epoch "$1" || { REPLY="—"; return }
  s=$(( EPOCHSECONDS - REPLY ))
  (( s < 0 )) && s=0
  if (( s < 3600 )); then REPLY="$(( s / 60 ))m"
  elif (( s < 86400 )); then REPLY="$(( s / 3600 ))h"
  elif (( s < 86400 * 14 )); then REPLY="$(( s / 86400 ))d"
  elif (( s < 86400 * 365 )); then REPLY="$(( s / 604800 ))w"
  else REPLY="$(( s / (86400 * 365) ))y"
  fi
}

# Word-wraps text to a width; long words are cut. Blank lines are kept.
jl_wrap() { # width text -> WRAPPED
  local w=$1 para word cur
  WRAPPED=()
  (( w < 10 )) && w=10
  for para in "${(@f)2}"; do
    para=${para//$'\r'/}
    if [[ -z ${para// /} ]]; then WRAPPED+=(""); continue; fi
    cur=""
    for word in ${=para}; do
      while (( ${#word} > w )); do
        [[ -n $cur ]] && { WRAPPED+=("$cur"); cur="" }
        WRAPPED+=("${word[1,w]}"); word=${word[w+1,-1]}
      done
      if [[ -z $cur ]]; then cur=$word
      elif (( ${#cur} + 1 + ${#word} <= w )); then cur+=" $word"
      else WRAPPED+=("$cur"); cur=$word
      fi
    done
    [[ -n $cur ]] && WRAPPED+=("$cur")
  done
}

# One line per issue, fields separated by \x1f: key status category type priority assignee updated summary,
# then the time tracking in seconds (estimate spent remaining), the story points ($p, the field's id) and
# 1 when the issue is flagged ($fl, the Flagged field's id).
JL_ROWS_JQ='.issues[]? | [.key, (.fields.status.name // "?"), (.fields.status.statusCategory.key // ""),
  (.fields.issuetype.name // ""), (.fields.priority.name // "—"),
  (.fields.assignee.displayName // .fields.assignee.name // "—"), (.fields.updated // ""),
  ((.fields.summary // "") | gsub("[\\t\\r\\n]"; " ")),
  (.fields.timeoriginalestimate // 0), (.fields.timespent // 0), (.fields.timeestimate // 0),
  (if $p != "" then (.fields[$p] // "") else "" end),
  (if $fl != "" and ((.fields[$fl] // []) | length > 0) then 1 else "" end)] | map(tostring) | join("\u001f")'
JL_SEARCH_FIELDS="summary,status,issuetype,priority,assignee,updated,timeoriginalestimate,timespent,timeestimate"

jl_parse_rows() { # json-file -> ROWS (one \x1f-joined line per issue), ROWS_TOTAL
  ROWS=(${(f)"$(jq -r --arg p "$JL_POINTS_FIELD" --arg fl "$JL_FLAG_FIELD" "$JL_ROWS_JQ" "$1" 2>/dev/null)"})
  ROWS_TOTAL=$(jq -r '.total // empty' "$1" 2>/dev/null)
}

# The issue as records for the details view, separated by \x1e, fields by \x1f. The first field names
# the record: head, desc, time, field (label value), person (label name), sub, link, att, comment.
# Custom fields are found by their display name (expand=names), so other instances' fields show too;
# Server/DC sends a sprint as "...Sprint@1a2b[id=7,name=Sprint 5,...]".
JL_RS=$'\x1e'
JL_DETAIL_JQ='
  def nm: if type == "object" then (.displayName // .name // .value // .key // "")
    elif type == "string" then ((capture("Sprint@[^\\[]*\\[.*name=(?<n>[^,\\]]*)") | .n) // .)
    elif type == "number" or type == "boolean" then tostring else "" end;
  def val: if type == "array" then (map(nm) | map(select(. != "")) | join(", ")) else nm end;
  def user: type == "object" and (has("emailAddress") or has("avatarUrls"));
  def status: [(.fields.status.name // ""), (.fields.status.statusCategory.key // "")];
  . as $i | ($i.fields // {}) as $f | ($i.names // {}) as $n
  | [ ["head", $i.key, ($f.issuetype.name // ""), ($f.status.name // ""), ($f.status.statusCategory.key // ""),
       ($f.priority.name // ""), ($f.resolution.name // ""), ($f.summary // ""), ($f.project.name // ""),
       ($f.created // ""), ($f.updated // ""), ($f.duedate // ""), ($f.resolutiondate // ""),
       ($f.watches.watchCount // 0), ($f.parent.key // ""), ($f.parent.fields.summary // ""),
       (if $fl != "" and (($f[$fl] // []) | length > 0) then 1 else "" end)],
      ["desc", (if ($f.description | type) == "string" then $f.description else "" end)],
      ["time", ($f.timeoriginalestimate // 0), ($f.timespent // 0), ($f.timeestimate // 0),
       (if $p != "" then ($f[$p] // "") else "" end)],
      ["field", "Fix versions", ($f.fixVersions // [] | val)],
      ["field", "Affects versions", ($f.versions // [] | val)],
      ["field", "Components", ($f.components // [] | val)],
      ["field", "Labels", ($f.labels // [] | val)],
      ["person", "Assignee", (if $f.assignee then ($f.assignee | nm) else "Unassigned" end)],
      ["person", "Reporter", ($f.reporter // {} | nm)] ]
    + [ $f | to_entries[] | select((.key | startswith("customfield_")) and .key != $p and .value != null)
        | ($n[.key] // .key) as $name
        | select($name | test("^(Rank|Development|Σ)") | not)
        | if (.value | user) then ["person", $name, (.value | nm)] else ["field", $name, (.value | val)] end ]
    + [ $f.subtasks // [] | .[] | ["sub", .key] + status + [(.fields.summary // "")] ]
    + [ $f.issuelinks // [] | .[]
        | (if .outwardIssue then [(.type.outward // ""), .outwardIssue] else [(.type.inward // ""), .inwardIssue] end) as [$rel, $o]
        | ["link", $rel, $o.key] + ($o | status) + [($o.fields.summary // "")] ]
    + [ $f.attachment // [] | .[] | ["att", .filename, (.size // 0), (.author.displayName // ""), (.created // ""), (.content // "")] ]
    + [ $f.comment.comments // [] | reverse | .[] | ["comment", (.author.displayName // .author.name // ""), (.created // ""), (.body // "")] ]
  | map(select(.[0] != "field" and .[0] != "person" or .[2] != ""))
  | map(map(tostring | gsub("[\u001e\u001f]"; " ")) | join("\u001f")) | join("\u001e")'

# DETAIL gets the head, description and time tracking by name; DREC keeps the other records in order.
jl_parse_detail() { # json-file -> assoc DETAIL, DREC
  local raw rec
  local -a f
  DETAIL=() DREC=()
  raw=$(jq -r --arg p "$JL_POINTS_FIELD" --arg fl "$JL_FLAG_FIELD" "$JL_DETAIL_JQ" "$1" 2>/dev/null) || return 1
  for rec in "${(@ps:$JL_RS:)raw}"; do
    f=("${(@ps:$JL_US:)rec}")
    case $f[1] in
      head) DETAIL+=(key "$f[2]" type "$f[3]" status "$f[4]" category "$f[5]" priority "$f[6]"
              resolution "$f[7]" summary "$f[8]" project "$f[9]" created "$f[10]" updated "$f[11]"
              due "$f[12]" resolved "$f[13]" watchers "$f[14]" parent "$f[15]" parent_summary "$f[16]"
              flagged "$f[17]") ;;
      desc) DETAIL[description]=$f[2] ;;
      time) DETAIL+=(estimate "$f[2]" spent "$f[3]" remaining "$f[4]" points "$f[5]") ;;
      *) DREC+=("$rec") ;;
    esac
  done
}

jl_epoch() { # Jira timestamp or date -> REPLY epoch seconds
  setopt local_options extended_glob
  local ts=$1 then off
  REPLY=""
  [[ $ts == [0-9](#c4)-[0-9][0-9]-[0-9][0-9] ]] && ts+="T00:00:00"
  [[ $ts =~ '^([0-9-]+T[0-9:]+)[.0-9]*([+-][0-9]{4}|Z)?$' ]] || return 1
  local base=$match[1] tz=$match[2]
  TZ=UTC strftime -r -s then '%Y-%m-%dT%H:%M:%S' "$base" 2>/dev/null || return 1
  if [[ $tz == [+-]* ]]; then
    off=$(( 10#${tz[2,3]} * 3600 + 10#${tz[4,5]} * 60 ))
    [[ $tz == +* ]] && (( then -= off )) || (( then += off ))
  fi
  REPLY=$then
}

jl_duration() { # seconds -> REPLY like "2h 15m"
  local s=$1 h m
  (( h = s / 3600, m = s % 3600 / 60 ))
  if (( h && m )); then REPLY="${h}h ${m}m"
  elif (( h )); then REPLY="${h}h"
  else REPLY="${m}m"
  fi
}

jl_size() { # bytes -> REPLY like "1.2 MB"
  if (( $1 >= 1048576 )); then REPLY="$(printf '%.1f' $(( $1 / 1048576.0 ))) MB"
  elif (( $1 >= 1024 )); then REPLY="$(( $1 / 1024 )) KB"
  else REPLY="$1 B"
  fi
}

# --- fetching -------------------------------------------------------------------------------------
# Each request has a cache entry named by a checksum of its URL: <id>.json holds the last good body,
# <id>.err the last failure (removed by a success). Fetches run in the background and replace the files
# atomically; the TUI notices through their stamps. The token reaches curl on stdin (curl -K -), so it
# never shows in the process list.

jl_cache_id() { # string -> REPLY
  REPLY=${${=$(print -rn -- "$1" | cksum)}[1]}
}

# The commands for the token's keychain entry: the macOS Keychain, or on Linux the Secret Service
# (GNOME Keyring, KWallet) through libsecret's secret-tool. Both ask for the secret themselves, so it
# never appears in an argument list or the shell history.
jl_keychain_cmd() { # lookup|store [os] -> REPLY; non-zero with JL_KEYCHAIN_MISSING when the tool is missing
  local os=${2:-$OSTYPE} svc=${(qq)${JIRA_KEYCHAIN_SERVICE:-jira-pat}} tool
  JL_KEYCHAIN_MISSING=""
  if [[ $os == darwin* ]]; then
    tool=security
    if [[ $1 == lookup ]]; then REPLY="security find-generic-password -s $svc -w"
    else REPLY="security add-generic-password -U -s $svc -a \"\$USER\" -w"
    fi
  else
    tool=secret-tool
    if [[ $1 == lookup ]]; then REPLY="secret-tool lookup service $svc"
    else REPLY="secret-tool store --label='Jira personal access token' service $svc"
    fi
  fi
  (( $+commands[$tool] )) || { JL_KEYCHAIN_MISSING=$tool; return 1 }
}

# The package that brings secret-tool, for this system's package manager.
jl_secret_tool_hint() { # -> REPLY
  if (( $+commands[apt-get] )); then REPLY="sudo apt-get install libsecret-tools"
  elif (( $+commands[dnf] )); then REPLY="sudo dnf install libsecret"
  elif (( $+commands[pacman] )); then REPLY="sudo pacman -S libsecret"
  else REPLY="install libsecret, which brings secret-tool"
  fi
}

# The token comes from JIRA_TOKEN, else from JIRA_TOKEN_CMD, else from the keychain entry. A failure
# sets JL_TOKEN_STATE: missing (nothing printed) or tool (the keychain tool isn't installed).
jl_auth_line() { # -> REPLY (curl config line), non-zero with JL_TOKEN_ERROR when the token is missing
  if [[ -z $JL_TOKEN_CACHE ]]; then
    JL_TOKEN_STATE=ok
    if [[ -n $JIRA_TOKEN ]]; then JL_TOKEN_CACHE=$JIRA_TOKEN
    else
      local cmd=$JIRA_TOKEN_CMD
      if [[ -z $cmd ]]; then
        if ! jl_keychain_cmd lookup; then
          JL_TOKEN_STATE=tool JL_TOKEN_ERROR="$JL_KEYCHAIN_MISSING isn't installed, so the token can't be read"
          return 1
        fi
        cmd=$REPLY
      fi
      JL_TOKEN_CACHE=$(sh -c "$cmd" 2>/dev/null)
      JL_TOKEN_CACHE=${JL_TOKEN_CACHE//[$'\r\n']/}
      if [[ -z $JL_TOKEN_CACHE ]]; then
        JL_TOKEN_STATE=missing
        if [[ -n $JIRA_TOKEN_CMD ]]; then JL_TOKEN_ERROR="JIRA_TOKEN_CMD printed no token"
        else JL_TOKEN_ERROR="no keychain entry “${JIRA_KEYCHAIN_SERVICE:-jira-pat}” with the Jira token"
        fi
        return 1
      fi
    fi
  fi
  if [[ $JIRA_AUTH == basic ]]; then REPLY="user = \"$JIRA_EMAIL:$JL_TOKEN_CACHE\""
  else REPLY="header = \"Authorization: Bearer $JL_TOKEN_CACHE\""
  fi
}

# Starts a background GET unless one for the same entry is running. Query args are name=value pairs.
typeset -gA JL_INFLIGHT
jl_fetch() { # cache-id endpoint query-args...
  local id=$1 endpoint=$2 auth; shift 2
  local base="$JL_STATE_DIR/cache/$id"
  (( JL_INFLIGHT[$id] && EPOCHSECONDS - JL_INFLIGHT[$id] < 30 )) && return 0
  if ! jl_auth_line; then
    print -r -- "$JL_TOKEN_ERROR" > "$base.err.tmp" && mv "$base.err.tmp" "$base.err"
    return 1
  fi
  auth=$REPLY
  local -a args=()
  local q
  for q; do args+=(--data-urlencode "$q"); done
  JL_INFLIGHT[$id]=$EPOCHSECONDS
  (
    local code rc
    code=$(print -r -- "$auth" | curl -sS -K - -G --max-time 20 -H 'Accept: application/json' \
      -D "$base.$$.hdr" -o "$base.$$.body" -w '%{http_code}' "${args[@]}" "$JIRA_BASE_URL$endpoint" 2>"$base.$$.curl")
    rc=$?
    if (( rc == 0 )) && [[ $code == 2* ]] && jq -e . "$base.$$.body" >/dev/null 2>&1; then
      mv "$base.$$.body" "$base.json"
      rm -f "$base.err" "$base.$$.curl" "$base.$$.hdr"
      exit
    fi
    jl_http_error $rc "$code" "$base.$$.body" "$base.$$.hdr" "$base.$$.curl"
    print -r -- "$REPLY" > "$base.err.tmp" && mv "$base.err.tmp" "$base.err"
    rm -f "$base.$$.body" "$base.$$.curl" "$base.$$.hdr"
  ) &!
}

# A failed request in one line: curl's own error, else the HTTP code with Jira's messages.
jl_http_error() { # curl-rc http-code body-file header-file curl-stderr-file -> REPLY
  local msg
  local -a lines
  if (( $1 )); then
    lines=("${(@f)$(<$5)}")
    msg=${lines[-1]#curl: }
    [[ $msg == *"resolve host"* || $msg == *"timed out"* || $msg == *"connect"* ]] && msg+=" — VPN?"
  else
    msg="HTTP $2: $(jq -r '[.errorMessages[]?, (.errors // {} | to_entries[] | "\(.key): \(.value)")] | join("; ")' "$3" 2>/dev/null)"
    [[ $msg == *": " ]] && msg+=$(sed -n 's:.*<title>\(.*\)</title>.*:\1:p' "$3" 2>/dev/null | head -1)
    # Server/DC treats a token it doesn't accept as an anonymous request, which then fails on
    # permissions (often a 400 for an "unknown" project) rather than with a 401
    if [[ $2 == 401 || $2 == 403 ]] || grep -qi '^x-ausername: *anonymous' "$4" 2>/dev/null; then
      msg+=" — Jira didn't accept the token (JIRA_TOKEN_CMD)"
    fi
  fi
  REPLY=${msg:-request failed}
}

# A request the user started (a write, or what one needs), waited for. The body is JSON on the command
# line; only the token goes through stdin.
jl_request() { # method endpoint [json-body] -> REPLY body; non-zero with JL_REQUEST_ERROR
  local method=$1 endpoint=$2 auth code rc tmp
  local -a data=()
  JL_REQUEST_ERROR="" REPLY=""
  if ! jl_auth_line; then JL_REQUEST_ERROR=$JL_TOKEN_ERROR; return 1; fi
  auth=$REPLY
  [[ -n $3 ]] && data=(-H 'Content-Type: application/json' --data-binary "$3")
  tmp="$JL_STATE_DIR/request.$$"
  code=$(print -r -- "$auth" | curl -sS -K - -X "$method" --max-time 15 -H 'Accept: application/json' \
    -H 'X-Atlassian-Token: no-check' "${data[@]}" -D "$tmp.hdr" -o "$tmp.body" -w '%{http_code}' \
    "$JIRA_BASE_URL$endpoint" 2>"$tmp.curl")
  rc=$?
  if (( rc == 0 )) && [[ $code == 2* ]]; then
    [[ -f $tmp.body ]] && REPLY=$(<$tmp.body)
    rm -f "$tmp.body" "$tmp.hdr" "$tmp.curl"
    return 0
  fi
  jl_http_error $rc "$code" "$tmp.body" "$tmp.hdr" "$tmp.curl"
  JL_REQUEST_ERROR=$REPLY REPLY=""
  rm -f "$tmp.body" "$tmp.hdr" "$tmp.curl"
  return 1
}

# The user the token belongs to: JL_ME_ASSIGN is the assignee JSON (Cloud knows users by accountId,
# Server/DC by name), JL_ME_NAME the display name the issues show.
jl_me() { # -> non-zero with JL_REQUEST_ERROR
  [[ -n $JL_ME_ASSIGN ]] && return 0
  jl_request GET /rest/api/2/myself || return 1
  local -a me=("${(@f)$(print -r -- "$REPLY" | jq -r \
    '(if .accountId then {accountId} else {name} end | tojson), (.displayName // .name // "")' 2>/dev/null)}")
  if [[ $me[1] != '{"'*'":"'?*'"}' ]]; then JL_REQUEST_ERROR="Jira didn't say who you are (/myself)"; return 1; fi
  JL_ME_ASSIGN=$me[1] JL_ME_NAME=$me[2]
}

# The transitions of an issue as parallel arrays. TR_ASSIGN is 1 when the transition's screen requires
# an assignee; TR_NEEDS names the other required fields Jira has no default for.
JL_TRANSITIONS_JQ='.transitions[]? | [.id, .name, (.to.name // ""), (.to.statusCategory.key // ""),
  (if .fields.assignee.required then "1" else "0" end),
  ([.fields // {} | to_entries[] | select(.key != "assignee" and .value.required and (.value.hasDefaultValue | not))
    | .value.name // .key] | join(", "))] | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")'

jl_parse_transitions() { # json-file -> TR_ID TR_NAME TR_TO TR_CAT TR_ASSIGN TR_NEEDS
  local l
  local -a f
  TR_ID=() TR_NAME=() TR_TO=() TR_CAT=() TR_ASSIGN=() TR_NEEDS=()
  for l in ${(f)"$(jq -r "$JL_TRANSITIONS_JQ" "$1" 2>/dev/null)"}; do
    f=("${(@ps:$JL_US:)l}")
    TR_ID+=("$f[1]") TR_NAME+=("$f[2]") TR_TO+=("$f[3]") TR_CAT+=("$f[4]") TR_ASSIGN+=("$f[5]") TR_NEEDS+=("$f[6]")
  done
}

jl_transition_body() { # transition-id [fields-json-object] -> REPLY
  local fields=$2
  [[ -n $fields ]] || fields='{}'
  REPLY=$(jq -nc --arg id "$1" --arg f "$fields" \
    '{transition: {id: $id}} + (($f | fromjson) as $o | if $o == {} then {} else {fields: $o} end)')
}

# {"id": value, ...} from id / JSON value pairs.
jl_fields_object() { # id json [id json ...] -> REPLY
  (( $# )) || { REPLY='{}'; return }
  REPLY=$(jq -nc '[$ARGS.positional | _nwise(2) | {(.[0]): (.[1] | fromjson)}] | add // {}' --args "$@")
}

# --- story points ----------------------------------------------------------------------------------
# Points live in a custom field whose id differs per Jira. JIRA_POINTS_FIELD is auto (the first number
# field named Story Points, Story point estimate or Original story points, else any number field with
# "story point" in its name), a field's id or name, or off. JL_POINTS_FIELD holds the id found.
JL_POINTS_FIELD=""

jl_fields() { # -> REPLY cache id of Jira's field list
  jl_get /rest/api/2/field 86400
}

jl_points_field() { # field-list-json setting -> REPLY field id, empty when there is none
  REPLY=$(jq -r --arg s "$2" '[.[]? | select(.schema.type == "number")] as $n
    | if $s == "auto" then
        ((["story points", "story point estimate", "original story points"]
          | map(. as $w | $n[] | select((.name | ascii_downcase) == $w)) | first | .id)
        // ([$n[] | select(.name | ascii_downcase | contains("story point"))] | first | .id) // empty)
      else ([$n[] | select(.id == $s or (.name | ascii_downcase) == ($s | ascii_downcase))] | first | .id) // empty
      end' "$1" 2>/dev/null)
}

# Jira Software's Flagged field (an impediment), found by its name in the field list.
JL_FLAG_FIELD=""
jl_flag_field() { # field-list-json -> REPLY field id, empty when there is none
  REPLY=$(jq -r '[.[]? | select((.name // "") | ascii_downcase == "flagged")] | first | .id // empty' "$1" 2>/dev/null)
}

# --- reopened issues -------------------------------------------------------------------------------
# An issue counts as reopened when it is back in a "to do" status after it was in one further along.
# The history of a whole list is too slow to read (expand=changelog), so a second search asks Jira
# which of the list's issues fit: the list's JQL, in the "to do" category, with a status WAS IN every
# status of the other categories (from Jira's status list, fetched once a day).
jl_statuses() { # -> REPLY cache id of Jira's status list
  jl_get /rest/api/2/status 86400
}

jl_reopened_jql() { # jql statuses-json-file -> REPLY; non-zero when the status list has none to use
  local list
  jl_strip_order "$1"; local cond=$REPLY
  list=$(jq -r '[.[]? | select(.statusCategory.key != "new") | .name] | unique
    | map("\"" + gsub("\""; "\\\"") + "\"") | join(", ")' "$2" 2>/dev/null)
  [[ -n $list ]] || { REPLY=""; return 1 }
  REPLY="${cond:+($cond) AND }statusCategory = new AND status WAS IN ($list)"
}

jl_reopened() { # jql statuses-json-file [force] -> REPLY cache id; non-zero without statuses
  local ttl=$JIRA_REFRESH_SECS
  [[ $3 == force ]] && ttl=0
  jl_reopened_jql "$1" "$2" || return 1
  jl_get /rest/api/2/search $ttl "jql=$REPLY" "maxResults=$JIRA_MAX_RESULTS" "fields=status"
}

jl_points_text() { # points -> REPLY "5 points", empty without points
  case $1 in
    "") REPLY="" ;;
    1) REPLY="1 point" ;;
    *) REPLY="$1 points" ;;
  esac
}

# --- work log ------------------------------------------------------------------------------------
jl_worklogs() { # key -> REPLY cache id, fetched fresh
  jl_get "/rest/api/2/issue/$1/worklog" 0
}

# The entries newest first: WL_STARTED WL_AUTHOR WL_SPENT (seconds) WL_COMMENT.
jl_parse_worklogs() { # json-file
  local l
  local -a f
  WL_STARTED=() WL_AUTHOR=() WL_SPENT=() WL_COMMENT=()
  for l in "${(@ps:$JL_RS:)$(jq -r '[.worklogs // [] | sort_by(.started) | reverse | .[]
      | [(.started // ""), (.author.displayName // .author.name // ""), (.timeSpentSeconds // 0), (.comment // "")]
      | map(tostring | gsub("[\u001e\u001f]"; " ")) | join("\u001f")] | join("\u001e")' "$1" 2>/dev/null)}"; do
    [[ -n $l ]] || continue
    f=("${(@ps:$JL_US:)l}")
    WL_STARTED+=("$f[1]") WL_AUTHOR+=("$f[2]") WL_SPENT+=("$f[3]") WL_COMMENT+=("$f[4]")
  done
}

# A worklog: time in Jira's notation (1h 30m, 2d, 45m; weeks and days as Jira counts them), an optional
# comment, and when the work started.
jl_worklog_body() { # time-spent comment started -> REPLY; non-zero when the time isn't in Jira's notation
  setopt local_options extended_glob
  local t=${${1//[[:space:]]##/ }## }
  t=${t%% }
  [[ $t == ([0-9]##(.[0-9]##|)[wdhm]( |))## ]] || return 1
  REPLY=$(jq -nc --arg t "$t" --arg c "$2" --arg s "$3" '{timeSpent: $t, started: $s} + (if $c != "" then {comment: $c} else {} end)')
}

# --- fields ----------------------------------------------------------------------------------------
# What a transition or an edit may set. FM_* are parallel arrays appended to, so a transition's screen
# fields (src screen: sent with the transition) come before the issue's editable ones (src edit: set
# with an edit first); a field already listed isn't added twice.
jl_field_meta() { # file transition-id|"" src -> appends FM_ID FM_NAME FM_TYPE FM_ITEMS FM_CUSTOM FM_REQ FM_DEF FM_SRC
  local l sel='.fields'
  local -a f
  [[ -n $2 ]] && sel='(.transitions[]? | select(.id == $t) | .fields)'
  for l in ${(f)"$(jq -r --arg t "$2" "$sel"' // {} | to_entries[]
      | select(.value.operations == null or (.value.operations | index("set")))
      | [.key, (.value.name // .key), (.value.schema.type // ""), (.value.schema.items // ""),
         (.value.schema.custom // "" | sub(".*:"; "")), (if .value.required then 1 else 0 end),
         (if .value.hasDefaultValue then 1 else 0 end)]
      | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' "$1" 2>/dev/null)"}; do
    f=("${(@ps:$JL_US:)l}")
    (( ${FM_ID[(Ie)$f[1]]} )) && continue
    FM_ID+=("$f[1]") FM_NAME+=("$f[2]") FM_TYPE+=("$f[3]") FM_ITEMS+=("$f[4]") FM_CUSTOM+=("$f[5]")
    FM_REQ+=("$f[6]") FM_DEF+=("$f[7]") FM_SRC+=("$3")
  done
}

# How the pane asks for a field: pick (one of a list), multi (several of a list), text, number, date,
# labels (words), user (you), or nothing when it can't write that kind of field.
jl_field_kind() { # type items custom -> REPLY
  case "$1/$2/$3" in
    */*/(gh-sprint|gh-epic-link|gh-lexo-rank|cascadingselect)) REPLY="" ;;
    array/(option|version|component)/*) REPLY=multi ;;
    array/string/*) REPLY=labels ;;
    (option|priority|version|component|resolution|securitylevel)/*) REPLY=pick ;;
    string/*) REPLY=text ;;
    number/*) REPLY=number ;;
    date/*) REPLY=date ;;
    user/*) REPLY=user ;;
    *) REPLY="" ;;
  esac
}

# The values a field allows. Versions come unreleased first, newest first, then the released ones;
# archived versions are left out.
jl_field_options() { # file transition-id|"" field-id -> OPT_ID OPT_LABEL OPT_NOTE
  local l sel='.fields'
  local -a f
  OPT_ID=() OPT_LABEL=() OPT_NOTE=()
  [[ -n $2 ]] && sel='(.transitions[]? | select(.id == $t) | .fields)'
  for l in ${(f)"$(jq -r --arg t "$2" --arg f "$3" "$sel"'[$f].allowedValues // []
      | if any(.[]; has("released")) then [.[] | select(.archived | not)]
          | (map(select(.released | not)) | reverse) + (map(select(.released)) | reverse) else . end
      | .[] | [(.id // ""), (.name // .value // .key // .id // ""), (if .released then "released" else "" end)]
      | map(tostring | gsub("[\u001f\n]"; " ")) | join("\u001f")' "$1" 2>/dev/null)"}; do
    f=("${(@ps:$JL_US:)l}")
    OPT_ID+=("$f[1]") OPT_LABEL+=("$f[2]") OPT_NOTE+=("$f[3]")
  done
}

# A field's value on the issue: the ids of objects (versions, options, ...), else the plain values.
jl_field_current() { # issue-json-file field-id -> CUR
  CUR=(${(f)"$(jq -r --arg f "$2" '.fields[$f] // empty | (if type == "array" then .[] else . end)
    | if type == "object" then (.id // .name // empty) else . end | tostring' "$1" 2>/dev/null)"})
}

# The JSON for a field's new value; non-zero when the input doesn't fit the kind.
jl_field_json() { # kind value... -> REPLY
  setopt local_options extended_glob
  local kind=$1; shift
  case $kind in
    pick) REPLY=$(jq -nc --arg v "$1" '{id: $v}') ;;
    multi) REPLY=$(jq -nc '[$ARGS.positional[] | {id: .}]' --args "$@") ;;
    text) REPLY=$(jq -nc --arg v "$1" '$v') ;;
    number) [[ $1 == (-|)[0-9]##(.[0-9]##|) ]] || return 1; REPLY=$(jq -nc --arg v "$1" '$v | tonumber') ;;
    date) [[ $1 == [0-9](#c4)-[0-9](#c2)-[0-9](#c2) ]] || return 1; REPLY=$(jq -nc --arg v "$1" '$v') ;;
    labels) REPLY=$(jq -nc '$ARGS.positional' --args ${=1}) ;;
    user) REPLY=$1 ;;
    *) return 1 ;;
  esac
}

# The fields an error names: by id as Jira's errors map gives them ("fixVersions: ..."), or by name in
# a validator's message ("Field Fix Version/s is required.").
jl_fields_named() { # message -> FN (field ids)
  setopt local_options extended_glob
  local i
  FN=()
  for (( i = 1; i <= ${#FM_ID}; i++ )); do
    if [[ $1 == *"$FM_ID[i]:"* ]] || { (( ${#FM_NAME[i]} > 2 )) && [[ $1 == (#i)*${(b)FM_NAME[i]}* ]] }; then
      FN+=("$FM_ID[i]")
    fi
  done
}

# The previous answer is dropped first: transitions change with the status, so it may be outdated.
jl_transitions() { # key -> REPLY cache id
  local endpoint="/rest/api/2/issue/$1/transitions"
  jl_get_id "$endpoint" "expand=transitions.fields"
  rm -f "$JL_STATE_DIR/cache/$REPLY".(json|err)(N)
  jl_get "$endpoint" 0 "expand=transitions.fields"
}

# A finished fetch (success or failure) changes this stamp.
jl_entry_stamp() { # cache-id -> REPLY
  local f base="$JL_STATE_DIR/cache/$1"
  local -A h
  REPLY=""
  for f in "$base.json" "$base.err"; do h=(); zstat -H h "$f" 2>/dev/null; REPLY+="$h[mtime]:$h[inode]."; done
}

jl_entry_age() { # cache-id -> REPLY seconds since the last good body (empty when there is none)
  local m
  m=$(zstat +mtime "$JL_STATE_DIR/cache/$1.json" 2>/dev/null) || { REPLY=""; return 1 }
  REPLY=$(( EPOCHSECONDS - m ))
}

# A GET through the cache: the fetch starts when the entry is missing or older than ttl (0 forces it).
jl_get_id() { # endpoint query-args... -> REPLY cache id
  local endpoint=$1; shift
  jl_cache_id "get|$JIRA_BASE_URL|$endpoint|$*"
}

jl_get() { # endpoint ttl query-args... -> REPLY cache id
  local endpoint=$1 ttl=$2 id; shift 2
  jl_get_id "$endpoint" "$@"; id=$REPLY
  jl_entry_age "$id"
  # a forced fetch goes out even while an earlier one may still run: it asks after a change
  (( ttl == 0 )) && JL_INFLIGHT[$id]=0
  if (( ttl == 0 )) || [[ -z $REPLY ]] || (( REPLY >= ttl )); then
    jl_fetch "$id" "$endpoint" "$@"
  fi
  REPLY=$id
}

jl_search() { # jql [force] -> REPLY cache id
  local ttl=$JIRA_REFRESH_SECS
  [[ $2 == force ]] && ttl=0
  jl_get /rest/api/2/search $ttl "jql=$1" "maxResults=$JIRA_MAX_RESULTS" "fields=$JL_SEARCH_FIELDS${JL_POINTS_FIELD:+,$JL_POINTS_FIELD}${JL_FLAG_FIELD:+,$JL_FLAG_FIELD}"
}

JL_ISSUE_QUERY=("expand=names" "fields=*all")
jl_issue() { # key [force] -> REPLY cache id
  local ttl=60
  [[ $2 == force ]] && ttl=0
  jl_get "/rest/api/2/issue/$1" $ttl "${JL_ISSUE_QUERY[@]}"
}

jl_issue_file() { # key -> REPLY the cached issue's path
  jl_get_id "/rest/api/2/issue/$1" "${JL_ISSUE_QUERY[@]}"
  REPLY="$JL_STATE_DIR/cache/$REPLY.json"
}

# What an edit of the issue may set, with the allowed values.
jl_editmeta() { # key [id-only] -> REPLY cache id
  if [[ -n $2 ]]; then jl_get_id "/rest/api/2/issue/$1/editmeta"
  else jl_get "/rest/api/2/issue/$1/editmeta" 300
  fi
}

# --- browsing ------------------------------------------------------------------------------------

# The views of a board: BR_LABEL (shown in the browser), BR_NAME (filter name) and BR_JQL. The active
# sprint uses openSprints(), so a pinned filter keeps working when the next sprint starts.
jl_board_entries() { # type board-jql [sprints-json-file]
  setopt local_options extended_glob
  local type=$1 bjql=$2 base order line
  local -a act fut f
  BR_LABEL=() BR_NAME=() BR_JQL=()
  jl_strip_order "$bjql"; base=$REPLY
  order=${bjql[${#base}+1,-1]}
  order=${order##[[:space:]]#}
  [[ -n $order ]] || order="ORDER BY Rank ASC"
  [[ -n $base ]] && base="($base) AND "
  if [[ $type == scrum ]]; then
    if [[ -f $3 ]]; then
      act=(${(f)"$(jq -r '.values[]? | select(.state == "active") | .name' "$3" 2>/dev/null)"})
      fut=(${(f)"$(jq -r '.values[]? | select(.state == "future") | "\(.id)\u001f\(.name)"' "$3" 2>/dev/null)"})
    fi
    if (( ${#act} == 1 )); then BR_LABEL+=("Active sprint: $act[1]")
    elif (( ${#act} > 1 )); then BR_LABEL+=("Active sprints (${#act})")
    else BR_LABEL+=("Active sprint (none running)")
    fi
    BR_NAME+=("Active sprint") BR_JQL+=("${base}sprint in openSprints() $order")
    for line in $fut; do
      f=("${(@ps:$JL_US:)line}")
      BR_LABEL+=("Sprint: $f[2]") BR_NAME+=("$f[2]") BR_JQL+=("${base}sprint = $f[1] $order")
    done
    BR_LABEL+=("Backlog") BR_NAME+=("Backlog")
    BR_JQL+=("${base}(sprint is EMPTY OR sprint not in (openSprints(), futureSprints())) AND statusCategory != Done $order")
  else
    BR_LABEL+=("Board (not done)") BR_NAME+=("Board") BR_JQL+=("${base}statusCategory != Done $order")
  fi
  BR_LABEL+=("All issues") BR_NAME+=("All issues") BR_JQL+=("$bjql")
}

# The JQL limited to issues assigned to the current user; its ORDER BY stays at the end.
jl_only_mine() { # jql -> REPLY
  setopt local_options extended_glob
  local jql=$1 base order
  jl_strip_order "$jql"; base=$REPLY
  order=${jql[${#base}+1,-1]}
  order=${order##[[:space:]]#}
  REPLY="${base:+($base) AND }assignee = currentUser()${order:+ $order}"
}

# The lines `p` appends to config.zsh. Quoted for zsh, so any quote in a name or the JQL is safe.
jl_pin_text() { # dir context-name filter-name jql -> REPLY
  local day
  strftime -s day '%Y-%m-%d' $EPOCHSECONDS
  REPLY=$'\n'"# pinned from the browser, $day"$'\n'"context ${(qq)1} ${(qq)2}"$'\n'"filter ${(qq)3} ${(qq)4}"$'\n'
}

# Sets JIRA_BASE_URL in config.zsh: replaces its line, or adds one at the top. Written through .tmp,
# which keeps the file's permissions.
jl_set_base_url() { # config-file url
  local -a lines
  [[ -s $1 ]] && lines=("${(@f)$(<$1)}")
  local i=${lines[(i)JIRA_BASE_URL=*]} new="JIRA_BASE_URL=${(qq)2}"
  if (( i <= ${#lines} )); then lines[i]=$new; else lines=("$new" "${(@)lines}"); fi
  if [[ -f $1 ]]; then
    cp -p "$1" "$1.tmp" && print -rl -- "${(@)lines}" >| "$1.tmp" && mv "$1.tmp" "$1"
  else
    print -rl -- "${(@)lines}" > "$1"
  fi
}

# The blocks jl_pin_text appended: its comment directly followed by a context and a filter line.
# Hand-written filters are not listed. PIN_LINE keeps the filter line as written, for jl_unpin.
jl_pinned() { # config-file -> PIN_AT PIN_DATE PIN_DIR PIN_CTX PIN_NAME PIN_JQL PIN_LINE
  typeset -ga PIN_AT=() PIN_DATE=() PIN_DIR=() PIN_CTX=() PIN_NAME=() PIN_JQL=() PIN_LINE=()
  [[ -f $1 ]] || return 0
  local -a lines=("${(@f)$(<$1)}") c f
  local i
  for (( i = 1; i + 2 <= ${#lines}; i++ )); do
    [[ $lines[i] == '# pinned from the browser, '* && $lines[i+1] == 'context '* && $lines[i+2] == 'filter '* ]] || continue
    c=("${(@Q)${(z)lines[i+1]}}") f=("${(@Q)${(z)lines[i+2]}}")
    (( ${#c} >= 2 && ${#f} == 3 )) || continue
    PIN_AT+=($i) PIN_DATE+=("${lines[i]#\# pinned from the browser, }") PIN_DIR+=("${${c[2]/#\~/$HOME}:A}")
    PIN_CTX+=("$c[3]") PIN_NAME+=("$f[2]") PIN_JQL+=("$f[3]") PIN_LINE+=("$lines[i+2]")
  done
}

# Removes the pinned block whose comment is on line `at`, and the blank line before it. Returns 1 when
# that block no longer holds the filter line (the file was edited meanwhile), 2 when writing failed.
# The previous file is kept as .bak; the copy through .tmp keeps the file's permissions.
jl_unpin() { # config-file at filter-line
  local -a lines=("${(@f)$(<$1)}")
  local at=$2 from=$2
  [[ $lines[at] == '# pinned from the browser, '* && $lines[at+1] == 'context '* && $lines[at+2] == "$3" ]] || return 1
  (( at > 1 )) && [[ -z $lines[at-1] ]] && from=$(( at - 1 ))
  lines[from,at+2]=()
  cp -p "$1" "$1.bak" && cp -p "$1" "$1.tmp" && print -rl -- "${(@)lines}" >| "$1.tmp" && mv "$1.tmp" "$1" || return 2
}
