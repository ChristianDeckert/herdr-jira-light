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
eq "row fields" "${(j:|:)${(@ps:$JL_US:)ROWS[1]}}" "GB-101|In Progress|indeterminate|Bug|High|Ann Example|2026-10-26T10:02:00.000+0100|Crash on login with tab"
eq "row defaults" "${(j:|:)${(@ps:$JL_US:)ROWS[2]}}" "GB-99|To Do|new|Story|—|—|2026-10-20T08:00:00.000+0200|Wishlist"
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

# a broken config reports its first error line and keeps a usable default filter
print 'filter "Broken" $(' > "$JIRA_LIGHT_CONFIG_DIR/config.zsh"
jl_load_config
eq "config error shown" "${JL_CONFIG_ERROR[1,8]}" "config: "
eq "config error is a line" $(( ${#JL_CONFIG_ERROR} > 12 )) 1
eq "default filter" "$FLT_NAME[1]" "My open issues"

print "$PASS passed, $FAILED failed"
(( FAILED == 0 ))
