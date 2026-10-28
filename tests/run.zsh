#!/bin/zsh
# Tests for the pure helpers. Run: zsh tests/run.zsh
ROOT="${0:A:h:h}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export JIRA_LIGHT_CONFIG_DIR="$TMP/config" JIRA_LIGHT_STATE_DIR="$TMP/state"
mkdir -p "$JIRA_LIGHT_CONFIG_DIR"
cat > "$JIRA_LIGHT_CONFIG_DIR/config.zsh" <<EOF
JIRA_BASE_URL="https://jira.example.com/jira/"
filter "Mine" 'assignee = currentUser() ORDER BY updated DESC'
context $TMP/work/app-ios "App iOS"
filter "Sprint" 'project = APP AND sprint in openSprints()'
context $TMP/work/app-ios/packages/core
filter "Core" 'component = Core'
context ~/somewhere-else
EOF
JL_ROOT=$ROOT
source "$ROOT/lib/config.zsh"
source "$ROOT/lib/jira.zsh"
source "$ROOT/lib/markup.zsh"

PASS=0 FAILED=0
eq() { # name got want
  if [[ "$2" == "$3" ]]; then (( PASS++ ))
  else (( FAILED++ )); print -r -- "FAIL $1"$'\n'"  got:  ${(q+)2}"$'\n'"  want: ${(q+)3}"
  fi
}

# config
eq "base url trailing slash" "$JIRA_BASE_URL" "https://jira.example.com/jira"
eq "no config error" "$JL_CONFIG_ERROR" ""
eq "context names" "${(j:|:)CTX_NAME}" "App iOS|core|somewhere-else"
eq "tilde expanded" "$CTX_PATH[3]" "$HOME/somewhere-else"
eq "filter scopes" "${(j:,:)FLT_CTX}" "0,1,2"

# context matching
jl_match_context "$TMP/work/app-ios"; eq "exact path" $REPLY 1
jl_match_context "$TMP/work/app-ios/Sources/Feature"; eq "child path" $REPLY 1
jl_match_context "$TMP/work/app-ios/packages/core/src"; eq "deepest wins" $REPLY 2
jl_match_context "$TMP/work/app-ios2"; eq "prefix needs a / boundary" $REPLY 0
jl_match_context "$TMP/work"; eq "parent is global" $REPLY 0

jl_filters_for 1; eq "context then global" "${(j:,:)JL_FILTERS}" "2,1"
JIRA_INHERIT_GLOBAL=0; jl_filters_for 1; eq "no inherit" "${(j:,:)JL_FILTERS}" "2"; JIRA_INHERIT_GLOBAL=1
jl_filters_for 0; eq "global only" "${(j:,:)JL_FILTERS}" "1"
jl_filters_for 3; eq "context without filters" "${(j:,:)JL_FILTERS}" "1"

# sorting
jl_strip_order 'project = A ORDER BY updated DESC'; eq "strip order" "$REPLY" "project = A"
jl_strip_order 'project = A order   by rank'; eq "strip order lowercase" "$REPLY" "project = A"
jl_strip_order 'ORDER BY created'; eq "only order" "$REPLY" ""
jl_strip_order 'summary ~ "border" AND x = 1'; eq "no order" "$REPLY" 'summary ~ "border" AND x = 1'
jl_sorted_jql 'p = A ORDER BY updated DESC' filter 0; eq "sort as filter" "$REPLY" 'p = A ORDER BY updated DESC'
jl_sorted_jql 'p = A ORDER BY updated DESC' priority 0; eq "sort priority" "$REPLY" 'p = A ORDER BY priority DESC'
jl_sorted_jql 'p = A' rank 1; eq "sort rank reversed" "$REPLY" 'p = A ORDER BY rank DESC'
jl_sorted_jql 'ORDER BY key' created 0; eq "sort without condition" "$REPLY" 'ORDER BY created DESC'

# slugs, templates
jl_slug "Login: Über-Änderung für Größe (iOS 26)"; eq "slug umlauts" "$REPLY" "login-ueber-aenderung-fuer-groesse-ios-2"
jl_slug "  --Fix   crash!! "; eq "slug trims" "$REPLY" "fix-crash"
typeset -A ISS=(key GB-12 summary "Fix the Login" url "https://x/browse/GB-12" status Open type Bug priority High assignee "A B")
jl_fill 'feature/{key}-{slug}' ISS; eq "branch" "$REPLY" "feature/GB-12-fix-the-login"
jl_fill 'Work on {key}: {summary}\n{url}' ISS; eq "prompt newline" "$REPLY" $'Work on GB-12: Fix the Login\nhttps://x/browse/GB-12'

# wrapping
jl_wrap 10 $'one two three four\n\nabcdefghijklmnop'
eq "wrap" "${(j:|:)WRAPPED}" "one two|three four||abcdefghij|klmnop"

# age
EPOCHSECONDS_SAVE=$EPOCHSECONDS
TZ=UTC strftime -s now '%Y-%m-%dT%H:%M:%S' $(( EPOCHSECONDS - 7200 ))
jl_age "${now}.000+0000"; eq "age hours" "$REPLY" "2h"
TZ=UTC strftime -s now '%Y-%m-%dT%H:%M:%S' $(( EPOCHSECONDS - 7200 + 3600 ))
jl_age "${now}.000+0100"; eq "age with offset" "$REPLY" "2h"
jl_age ""; eq "age empty" "$REPLY" "—"

# parsing
jl_parse_rows "$ROOT/tests/fixtures/search.json"
eq "row count" "${#ROWS}" 2
eq "total" "$ROWS_TOTAL" 2
eq "row fields" "${(j:|:)${(@ps:$JL_US:)ROWS[1]}}" "GB-101|In Progress|indeterminate|Bug|High|Ann Example|2026-10-26T10:02:00.000+0100|Crash on login with tab|28800|7200|21600||"
eq "row defaults" "${(j:|:)${(@ps:$JL_US:)ROWS[2]}}" "GB-99|To Do|new|Story|—|—|2026-10-20T08:00:00.000+0200|Wishlist|0|0|0||"
typeset -A DETAIL
typeset -a DREC
jl_parse_detail "$ROOT/tests/fixtures/issue.json"
eq "detail head" "$DETAIL[key] $DETAIL[type] $DETAIL[category] $DETAIL[priority] $DETAIL[due]" "GB-101 Bug indeterminate High 2026-11-01"
eq "detail time" "$DETAIL[estimate] $DETAIL[spent] $DETAIL[remaining]" "3600 8100 0"
eq "detail description" "$DETAIL[description]" $'Steps:\n1. open app'
recs=("${DREC[@]//$JL_US/:}")
recs_matching() { local -a m=(${(M)recs:#$~1}); REPLY=${(j: / :)m} }
recs_matching "field:Labels:*"; eq "detail labels" "$REPLY" "field:Labels:ios, login"
recs_matching "field:Sprint:*"; eq "detail sprint" "$REPLY" "field:Sprint:Sprint 42"
recs_matching "field:Platform:*"; eq "detail custom option" "$REPLY" "field:Platform:iOS"
recs_matching "person:Reviewer:*"; eq "detail user field" "$REPLY" "person:Reviewer:Rae Viewer"
recs_matching "*:Rank:*"; eq "detail skips rank" "$REPLY" ""
recs_matching "field:Fix versions:*"; eq "detail skips empty" "$REPLY" ""
recs_matching "sub:*"; eq "detail subtask" "$REPLY" "sub:GB-102:Done:done:Write test"
recs_matching "link:*"; eq "detail link" "$REPLY" "link:is blocked by:GB-90:Open:new:API change"
att=${(M)recs:#att:*}
eq "detail attachment" "${att[1,32]}" "att:shot.png:28779:Rob Reporter:"
authors=()
for r in ${(M)recs:#comment:*}; do r=${r#comment:}; authors+=("${r%%:*}"); done
eq "comments newest first" "${(j:,:)authors}" "Rae Viewer,Ann Example"

# markup
B='<b>' D='<d>' R='</>' K='<k>' JL_UL='<u>' JL_CODE='<c>'
MARKUP=()
jl_markup 60 $'h3. AC\n* one *bold* {{mono}}\n** two\n# a\n# b\nsee [Docs|https://x] [~ann] !p.png|thumbnail!\n{code:swift}\nlet a = 1\n{code}\n||H||I||\n|x|y|\n5 * 3 * 2'
eq "markup" "${(pj:\n:)MARKUP}" "<b><k>AC</>
<k>•</> one <b>bold</> <c>mono</></>
  <k>◦</> two</>
<k>1.</> a</>
<k>2.</> b</>
see <u>Docs</> <k>@ann</> <d>[p.png]</></>
<d>│</> <c>let a = 1</>
<b>H</> <d>│</> <b>I</></>
x</> <d>│</> y</></>
5 * 3 * 2</>"
MARKUP=()
jl_wrap_into 10 "abcdefghijklmnopqrstuvwxyz end" "> " "  "
eq "wrap cuts long words" "${(j:|:)MARKUP}" "> abcdefgh|  ijklmnop|  qrstuvwx|  yz end</>"
jl_duration 8100; eq "duration" "$REPLY" "2h 15m"
jl_size 28779; eq "size" "$REPLY" "28 KB"
jl_epoch 2026-01-01; eq "epoch of a date" "$REPLY" "1767225600"

# board views
jl_board_entries scrum 'project = SHOP ORDER BY Rank ASC' "$ROOT/tests/fixtures/sprints.json"
eq "scrum labels" "${(j:|:)BR_LABEL}" "Active sprint: Shop Sprint 12|Sprint: Next|Sprint: Ideas|Backlog|All issues"
eq "scrum names" "${(j:|:)BR_NAME}" "Active sprint|Next|Ideas|Backlog|All issues"
eq "active sprint jql" "$BR_JQL[1]" "(project = SHOP) AND sprint in openSprints() ORDER BY Rank ASC"
eq "future sprint jql" "$BR_JQL[2]" "(project = SHOP) AND sprint = 102 ORDER BY Rank ASC"
eq "backlog jql" "$BR_JQL[4]" "(project = SHOP) AND (sprint is EMPTY OR sprint not in (openSprints(), futureSprints())) AND statusCategory != Done ORDER BY Rank ASC"
eq "all issues jql" "$BR_JQL[5]" "project = SHOP ORDER BY Rank ASC"
print '{"values":[{"id":1,"state":"active","name":"A"},{"id":2,"state":"active","name":"B"}]}' > "$TMP/two.json"
jl_board_entries scrum 'project = X' "$TMP/two.json"
eq "several active sprints" "$BR_LABEL[1]" "Active sprints (2)"
eq "default order" "$BR_JQL[1]" "(project = X) AND sprint in openSprints() ORDER BY Rank ASC"
jl_board_entries scrum 'project = X' "$TMP/missing.json"
eq "no sprints file" "${(j:|:)BR_LABEL}" "Active sprint (none running)|Backlog|All issues"
jl_board_entries kanban 'project = K AND component = App ORDER BY updated DESC'
eq "kanban labels" "${(j:|:)BR_LABEL}" "Board (not done)|All issues"
eq "kanban jql" "$BR_JQL[1]" "(project = K AND component = App) AND statusCategory != Done ORDER BY updated DESC"

jl_only_mine '(project = SHOP) AND sprint in openSprints() ORDER BY Rank ASC'
eq "only mine" "$REPLY" "((project = SHOP) AND sprint in openSprints()) AND assignee = currentUser() ORDER BY Rank ASC"
jl_only_mine 'project = SHOP'; eq "only mine without order" "$REPLY" "(project = SHOP) AND assignee = currentUser()"
jl_only_mine 'ORDER BY created DESC'; eq "only mine, order only" "$REPLY" "assignee = currentUser() ORDER BY created DESC"

# pinning: the appended block parses and lands in the context that already has the path
jl_pin_text "$TMP/work/app-ios" "Ignored name" "Board · it's active" "summary ~ 'x' AND sprint in openSprints()"
print -rn -- "$REPLY" >> "$JIRA_LIGHT_CONFIG_DIR/config.zsh"
zsh -n "$JIRA_LIGHT_CONFIG_DIR/config.zsh"; eq "pinned config parses" $? 0
jl_load_config
eq "no duplicate context" "${#CTX_PATH}" 3
eq "context keeps its name" "$CTX_NAME[1]" "App iOS"
eq "pinned filter scope" "$FLT_CTX[-1]" 1
eq "pinned filter name" "$FLT_NAME[-1]" "Board · it's active"
eq "pinned filter jql" "$FLT_JQL[-1]" "summary ~ 'x' AND sprint in openSprints()"
jl_filters_for 1; eq "pinned filter listed" "${(j:,:)JL_FILTERS}" "2,4,1"

# managing pins: only the blocks p wrote are listed, and removing one leaves every other line as it was
jl_pin_text "$TMP/work/other" "Other" 'Say "hi"' 'project = O'
print -rn -- "$REPLY" >> "$JIRA_LIGHT_CONFIG_DIR/config.zsh"
cfg="$JIRA_LIGHT_CONFIG_DIR/config.zsh"
jl_pinned "$cfg"
eq "pinned count" ${#PIN_AT} 2
eq "pinned names" "${(j:|:)PIN_NAME}" "Board · it's active|Say \"hi\""
eq "pinned jql" "$PIN_JQL[1]" "summary ~ 'x' AND sprint in openSprints()"
eq "pinned dir" "$PIN_DIR[2]" "${TMP:A}/work/other"
eq "pinned context name" "$PIN_CTX[2]" "Other"
before=$(<$cfg)
jl_unpin "$cfg" "$PIN_AT[1]" "filter 'other' 'line'"; eq "stale unpin refused" $? 1
eq "stale unpin leaves the file" "$(<$cfg)" "$before"
jl_unpin "$cfg" "$PIN_AT[1]" "$PIN_LINE[1]"; eq "unpin" $? 0
eq "unpin keeps a backup" "$(<$cfg.bak)" "$before"
zsh -n "$cfg"; eq "unpinned config parses" $? 0
jl_pinned "$cfg"; eq "one pin left" "${(j:|:)PIN_NAME}" "Say \"hi\""
eq "hand-written lines kept" "$(grep -v pinned "$cfg" | grep -c .)" 9
jl_load_config; eq "unpinned filter gone" "${(j:|:)FLT_NAME}" "Mine|Sprint|Core|Say \"hi\""

# the token's keychain entry: per platform, with stand-ins for security and secret-tool
mkdir -p "$TMP/bin"
for t in security secret-tool; do
  print -r -- '#!/bin/sh
[ -n "$STUB_TOKEN" ] && printf "%s\n" "$STUB_TOKEN" || exit 44' > "$TMP/bin/$t"
  chmod +x "$TMP/bin/$t"
done
path=("$TMP/bin" $path); rehash
jl_keychain_cmd lookup darwin; eq "mac lookup" "$REPLY" "security find-generic-password -s 'jira-pat' -w"
jl_keychain_cmd store darwin; eq "mac store asks itself" "$REPLY" "security add-generic-password -U -s 'jira-pat' -a \"\$USER\" -w"
JIRA_KEYCHAIN_SERVICE="my pat"
jl_keychain_cmd lookup linux-gnu; eq "linux lookup" "$REPLY" "secret-tool lookup service 'my pat'"
jl_keychain_cmd store linux-gnu; eq "linux store" "$REPLY" "secret-tool store --label='Jira personal access token' service 'my pat'"
JIRA_KEYCHAIN_SERVICE=jira-pat
path=(${path:#$TMP/bin}); rm "$TMP/bin/secret-tool"; path=("$TMP/bin" $path); rehash
if (( ! $+commands[secret-tool] )); then
  jl_keychain_cmd lookup linux-gnu; eq "missing tool fails" $? 1
  eq "missing tool named" "$JL_KEYCHAIN_MISSING" secret-tool
fi
JIRA_TOKEN="" JIRA_TOKEN_CMD="" JL_TOKEN_CACHE=""
if [[ $OSTYPE == darwin* ]]; then
  STUB_TOKEN="" jl_auth_line; eq "no entry fails" $? 1
  eq "no entry state" "$JL_TOKEN_STATE" missing
  export STUB_TOKEN=pat-123
  jl_auth_line; eq "token from the keychain" "$REPLY" 'header = "Authorization: Bearer pat-123"'
  unset STUB_TOKEN
fi
JL_TOKEN_CACHE="" JIRA_TOKEN_CMD="exit 1"
jl_auth_line; eq "own command printed nothing" "$JL_TOKEN_ERROR" "JIRA_TOKEN_CMD printed no token"
JL_TOKEN_CACHE="" JIRA_TOKEN_CMD=""

# the Jira URL the setup guide writes
url_cfg="$TMP/url.zsh"
print -l '# settings' 'JIRA_BASE_URL=""' 'filter "A" "x"' > "$url_cfg"
jl_set_base_url "$url_cfg" "https://jira.example.com/it's"
eq "url replaced" "$(sed -n 2p "$url_cfg")" "JIRA_BASE_URL='https://jira.example.com/it'\\''s'"
zsh -n "$url_cfg"; eq "url config parses" $? 0
eq "url value" "$(zsh -c "source ${(q)url_cfg} 2>/dev/null; filter() {}; print -r -- \$JIRA_BASE_URL" 2>/dev/null)" "https://jira.example.com/it's"
print -l '# no url yet' > "$url_cfg"
jl_set_base_url "$url_cfg" "https://jira.example.com"
eq "url added on top" "$(<$url_cfg)" "JIRA_BASE_URL='https://jira.example.com'"$'\n'"# no url yet"

# transitions
jl_parse_transitions "$ROOT/tests/fixtures/transitions.json"
eq "transition ids" "${(j:,:)TR_ID}" "21,31,11,41"
eq "transition targets" "${(j:,:)TR_TO}" "In Review,Done,To Do,In Progress"
eq "transition categories" "${(j:,:)TR_CAT}" "indeterminate,done,new,indeterminate"
eq "assignee required" "${(j:,:)TR_ASSIGN}" "1,0,0,0"
eq "other required fields without default" "${(j:|:)TR_NEEDS}" "|Resolution||Team"
jl_transition_body 31; eq "transition body" "$REPLY" '{"transition":{"id":"31"}}'
jl_fields_object assignee '{"name":"j\"d"}' customfield_100 '{"id":"501"}'
eq "fields object" "$REPLY" '{"assignee":{"name":"j\"d"},"customfield_100":{"id":"501"}}'
jl_transition_body 21 "$REPLY"
eq "transition body with fields" "$REPLY" '{"transition":{"id":"21"},"fields":{"assignee":{"name":"j\"d"},"customfield_100":{"id":"501"}}}'
jl_fields_object; eq "no fields" "$REPLY" '{}'

# story points
jl_points_field "$ROOT/tests/fixtures/fields.json" auto; eq "points field found" "$REPLY" customfield_902
jl_points_field "$ROOT/tests/fixtures/fields.json" "original Story points"; eq "points field by name" "$REPLY" customfield_901
jl_points_field "$ROOT/tests/fixtures/fields.json" customfield_901; eq "points field by id" "$REPLY" customfield_901
jl_points_field "$ROOT/tests/fixtures/fields.json" customfield_903; eq "text field isn't points" "$REPLY" ""
jl_points_field "$ROOT/tests/fixtures/fields.json" off; eq "points off" "$REPLY" ""
jq 'map(select(.id != "customfield_902"))' "$ROOT/tests/fixtures/fields.json" > "$TMP/fields.json"
jl_points_field "$TMP/fields.json" auto; eq "planning points as fallback" "$REPLY" customfield_901
jq '[.[] | select(.id == "customfield_903" or .id == "timespent")]' "$ROOT/tests/fixtures/fields.json" > "$TMP/fields.json"
jl_points_field "$TMP/fields.json" auto; eq "no points field" "$REPLY" ""
JL_POINTS_FIELD=customfield_902
jl_parse_rows "$ROOT/tests/fixtures/search.json"
eq "row points" "${${(@ps:$JL_US:)ROWS[1]}[12]}" 3
eq "row without points" "${${(@ps:$JL_US:)ROWS[2]}[12]}" ""
jl_parse_detail "$ROOT/tests/fixtures/issue.json"
eq "detail points" "$DETAIL[points]" 5
recs=("${DREC[@]//$JL_US/:}"); recs_matching "field:Story Points:*"
eq "points not repeated as a field" "$REPLY" ""
JL_POINTS_FIELD=""
jl_parse_detail "$ROOT/tests/fixtures/issue.json"
recs=("${DREC[@]//$JL_US/:}"); recs_matching "field:Story Points:*"
eq "points as a plain field without the setting" "$REPLY" "field:Story Points:5"
jl_flag_field "$ROOT/tests/fixtures/fields.json"; eq "flag field found" "$REPLY" customfield_904
jl_flag_field "$TMP/fields.json"; eq "no flag field" "$REPLY" ""
JL_FLAG_FIELD=customfield_904
jl_parse_rows "$ROOT/tests/fixtures/search.json"
eq "flagged row" "${${(@ps:$JL_US:)ROWS[1]}[13]}" 1
eq "unflagged row" "${${(@ps:$JL_US:)ROWS[2]}[13]}" ""
jl_parse_detail "$ROOT/tests/fixtures/issue.json"; eq "flagged detail" "$DETAIL[flagged]" 1
JL_FLAG_FIELD=""
jl_parse_detail "$ROOT/tests/fixtures/issue.json"; eq "flag unknown" "$DETAIL[flagged]" ""

# reopened issues
jl_reopened_jql 'project = APP ORDER BY rank' "$ROOT/tests/fixtures/statuses.json"
eq "reopened jql" "$REPLY" '(project = APP) AND statusCategory = new AND status WAS IN ("Done", "In Progress", "Review \"2\"")'
jl_reopened_jql 'ORDER BY updated' "$ROOT/tests/fixtures/statuses.json"
eq "reopened jql without condition" "$REPLY" 'statusCategory = new AND status WAS IN ("Done", "In Progress", "Review \"2\"")'
print '[]' > "$TMP/st.json"; jl_reopened_jql 'x = 1' "$TMP/st.json"; eq "no statuses" $? 1

jl_points_text 1; eq "one point" "$REPLY" "1 point"
jl_points_text 2.5; eq "points" "$REPLY" "2.5 points"

# worklogs
jl_parse_worklogs "$ROOT/tests/fixtures/worklog.json"
eq "worklog order" "${(j:,:)WL_AUTHOR}" "Kim Dev,Ann Example"
eq "worklog seconds" "${(j:,:)WL_SPENT}" "900,7200"
eq "worklog comments" "${(j:|:)WL_COMMENT}" "|First pass"
print '{"worklogs":[]}' > "$TMP/wl.json"; jl_parse_worklogs "$TMP/wl.json"; eq "no worklogs" "${#WL_AUTHOR}" 0
jl_worklog_body " 1h   30m " "fixed it" "2026-10-28T09:15:00.000+0100"
eq "worklog body" "$REPLY" '{"timeSpent":"1h 30m","started":"2026-10-28T09:15:00.000+0100","comment":"fixed it"}'
jl_worklog_body "2d" "" "2026-10-28T09:15:00.000+0100"
eq "worklog without comment" "$REPLY" '{"timeSpent":"2d","started":"2026-10-28T09:15:00.000+0100"}'
jl_worklog_body "1.5h" ""  x; eq "decimal hours" $? 0
jl_worklog_body "1h30m" "" x; eq "units without space" $? 0
jl_worklog_body "90" "" x; eq "a number needs a unit" $? 1
jl_worklog_body "1 hour" "" x; eq "words aren't units" $? 1

# the fields a transition or an edit may set
FM_ID=() FM_NAME=() FM_TYPE=() FM_ITEMS=() FM_CUSTOM=() FM_REQ=() FM_DEF=() FM_SRC=()
jl_field_meta "$ROOT/tests/fixtures/transitions.json" 41 screen
jl_field_meta "$ROOT/tests/fixtures/editmeta.json" "" edit
eq "fields, screen first, issue type not settable" "${(j:,:)FM_ID}" \
  "customfield_100,summary,fixVersions,customfield_200,labels,duedate,customfield_300,customfield_400"
eq "field sources" "${(j:,:)FM_SRC}" "screen,edit,edit,edit,edit,edit,edit,edit"
eq "field required" "${(j:,:)FM_REQ}" "1,1,0,1,0,0,0,0"
eq "custom type without prefix" "$FM_CUSTOM[1]" select
kinds=()
for (( i = 1; i <= ${#FM_ID}; i++ )); do jl_field_kind "$FM_TYPE[i]" "$FM_ITEMS[i]" "$FM_CUSTOM[i]"; kinds+=("${REPLY:--}"); done
eq "field kinds" "${(j:,:)kinds}" "pick,text,multi,pick,labels,date,-,user"
jl_field_kind array user multiuserpicker; eq "several users unsupported" "$REPLY" ""
jl_field_options "$ROOT/tests/fixtures/editmeta.json" "" fixVersions
eq "versions: unreleased newest first, archived dropped" "${(j:,:)OPT_LABEL}" "2.0,1.2,1.0"
eq "version ids" "${(j:,:)OPT_ID}" "13,12,10"
eq "released noted" "${(j:,:)OPT_NOTE}" ",,released"
jl_field_options "$ROOT/tests/fixtures/transitions.json" 41 customfield_100
eq "screen field options" "${(j:,:)OPT_ID}:${(j:,:)OPT_LABEL}" "501,502:Mobile,Web"
jl_field_options "$ROOT/tests/fixtures/editmeta.json" "" customfield_200
eq "option label with a quote" "$OPT_LABEL[2]" 'Client "A"'
jl_field_current "$ROOT/tests/fixtures/issue.json" labels; eq "current labels" "${(j:,:)CUR}" "ios,login"
jl_field_current "$ROOT/tests/fixtures/issue.json" fixVersions; eq "no current versions" "${#CUR}" 0
jl_field_current "$ROOT/tests/fixtures/issue.json" duedate; eq "current date" "$CUR" "2026-11-01"
jl_field_json multi 12 13; eq "versions json" "$REPLY" '[{"id":"12"},{"id":"13"}]'
jl_field_json pick 701; eq "option json" "$REPLY" '{"id":"701"}'
jl_field_json labels 'ios  login'; eq "labels json" "$REPLY" '["ios","login"]'
jl_field_json text 'say "hi"'; eq "text json" "$REPLY" '"say \"hi\""'
jl_field_json number 2.5; eq "number json" "$REPLY" '2.5'
jl_field_json number 2,5; eq "not a number" $? 1
jl_field_json date 2026-11-30; eq "date json" "$REPLY" '"2026-11-30"'
jl_field_json date 30.11.2026; eq "not a date" $? 1
jl_fields_named "HTTP 400: fixVersions: Fix Version/s is required."; eq "named by id" "${(j:,:)FN}" fixVersions
jl_fields_named "HTTP 400: Field fix version/s is required."; eq "named by name" "${(j:,:)FN}" fixVersions
jl_fields_named "HTTP 400: Team and Cost Center are required"; eq "two named" "${(j:,:)FN}" "customfield_100,customfield_200"
jl_fields_named "HTTP 400: Bitte erst die Version setzen"; eq "none named" "${#FN}" 0

# requests, through a stand-in curl that answers with STUB_BODY / STUB_CODE and logs its arguments
print -r -- '#!/bin/zsh
cat >/dev/null
print -r -- "$*" >> "$STUB_LOG"
while (( $# )); do case $1 in -o) out=$2; shift ;; esac; shift; done
[[ -n $STUB_BODY ]] && cp "$STUB_BODY" "$out"
print -n "${STUB_CODE:-200}"' > "$TMP/bin/curl"
chmod +x "$TMP/bin/curl"; rehash
export STUB_LOG="$TMP/curl.log"
JIRA_TOKEN=pat-test JL_TOKEN_CACHE=""
STUB_BODY="$ROOT/tests/fixtures/myself-server.json" jl_me
eq "me on server" "$JL_ME_ASSIGN" '{"name":"jdoe"}'
eq "my display name" "$JL_ME_NAME" "Jane Doe"
JL_ME_ASSIGN=""
STUB_BODY="$ROOT/tests/fixtures/myself-cloud.json" jl_me
eq "me on cloud" "$JL_ME_ASSIGN" '{"accountId":"5b10ac8d82e05b22cc7d4ef5"}'
: > "$STUB_LOG"
STUB_BODY="$ROOT/tests/fixtures/myself-server.json" jl_me
eq "me asked once" "$(<$STUB_LOG)" ""
STUB_CODE=204 STUB_BODY="" jl_request PUT /rest/api/2/issue/APP-1/assignee '{"name":"jdoe"}'
eq "write succeeds" $? 0
eq "write method and body" "$(tail -1 "$STUB_LOG")" \
  "-sS -K - -X PUT --max-time 15 -H Accept: application/json -H X-Atlassian-Token: no-check -H Content-Type: application/json --data-binary {\"name\":\"jdoe\"} -D $JIRA_LIGHT_STATE_DIR/request.$$.hdr -o $JIRA_LIGHT_STATE_DIR/request.$$.body -w %{http_code} https://jira.example.com/jira/rest/api/2/issue/APP-1/assignee"
STUB_CODE=400 STUB_BODY="$ROOT/tests/fixtures/error-400.json" jl_request POST /rest/api/2/issue/APP-1/transitions '{}'
eq "write fails" $? 1
eq "validator message" "$JL_REQUEST_ERROR" "HTTP 400: assignee: Assignee is required."
eq "no files left" "$(print -l $JIRA_LIGHT_STATE_DIR/request.*(N))" ""
jl_http_error 0 401 "$ROOT/tests/fixtures/error-400.json" /nonexistent /nonexistent
eq "rejected token" "$REPLY" "HTTP 401: assignee: Assignee is required. — Jira didn't accept the token (JIRA_TOKEN_CMD)"
print 'curl: (6) Could not resolve host: jira.example.com' > "$TMP/curl.err"
jl_http_error 6 000 /nonexistent /nonexistent "$TMP/curl.err"
eq "offline" "$REPLY" "(6) Could not resolve host: jira.example.com — VPN?"
JIRA_TOKEN="" JL_TOKEN_CACHE=""
path=(${path:#$TMP/bin}); rehash

# a broken config reports its first error line and keeps a usable default filter
print 'filter "Broken" $(' > "$JIRA_LIGHT_CONFIG_DIR/config.zsh"
jl_load_config
eq "config error shown" "${JL_CONFIG_ERROR[1,8]}" "config: "
eq "config error is a line" $(( ${#JL_CONFIG_ERROR} > 12 )) 1
eq "default filter" "$FLT_NAME[1]" "My open issues"

print "$PASS passed, $FAILED failed"
(( FAILED == 0 ))
