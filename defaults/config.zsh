# Jira Light configuration. Plain zsh, read by every Jira pane; it is re-read when this file changes
# (or with R in the pane).

# --- Jira ---
# Base URL including a context path such as /jira, without a trailing slash.
JIRA_BASE_URL=""
# bearer = Server/Data Center personal access token; basic = Jira Cloud (JIRA_EMAIL + API token)
# JIRA_AUTH=bearer
# JIRA_EMAIL=""
# A command that prints the token, e.g. from the macOS Keychain:
#   security add-generic-password -s jira-pat -a "$USER" -w
JIRA_TOKEN_CMD="security find-generic-password -s jira-pat -w"

# JIRA_MAX_RESULTS=50       # issues per filter
# JIRA_REFRESH_SECS=180     # a shown filter is fetched again when its result is older
# JIRA_INHERIT_GLOBAL=1     # also list the global filters below a context's own
# JIRA_WIDTH=72             # pane width in columns when it opens (at most half the split)
# JIRA_RATIO=""             # or a fixed share of the split for the main pane, e.g. 0.6
# JIRA_APPEARANCE=auto      # auto | dark | light

# Templates for Y (copy branch name) and a (send to agent). Placeholders: {key} {summary} {slug} {url}
# {status} {type} {priority} {assignee}; \n is a line break.
# JIRA_BRANCH_TEMPLATE='feature/{key}-{slug}'
# JIRA_AGENT_PROMPT='Work on Jira issue {key}: {summary}\n{url}'

# --- Filters ---
# Filters before the first context are global: shown everywhere no context matches.
filter "My open issues" 'assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC'
filter "Recently updated (7d)" 'updated >= -7d ORDER BY updated DESC'

# `context <dir> [name]` starts the filters for a directory and everything below it. When directories
# are nested, the deepest one wins.
# context ~/Work/my-app "My App"
# filter "Active sprint" 'project = APP AND sprint in openSprints() ORDER BY rank'
# filter "Next sprint"   'project = APP AND sprint in futureSprints() ORDER BY rank'

# p in the pane appends the views you pin from the browser (b) below.
