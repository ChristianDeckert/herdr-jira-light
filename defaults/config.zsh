# Jira Light configuration. Plain zsh, read by every Jira pane; it is re-read when this file changes
# (or with R in the pane).

# --- Jira ---
# Base URL including a context path such as /jira, without a trailing slash. The pane asks for it
# (key 1 in its setup guide) and writes it here.
JIRA_BASE_URL=""
# bearer = Server/Data Center personal access token; basic = Jira Cloud (JIRA_EMAIL + API token)
# JIRA_AUTH=bearer
# JIRA_EMAIL=""
# The token is read from the keychain entry JIRA_KEYCHAIN_SERVICE: the macOS Keychain, or on Linux the
# Secret Service (GNOME Keyring, KWallet) through secret-tool. The installer and the pane's setup guide
# (key 2) store it there. To read it from somewhere else, set a command that prints it, e.g. pass.
# JIRA_KEYCHAIN_SERVICE=jira-pat
# JIRA_TOKEN_CMD="pass show jira/pat"

# JIRA_MAX_RESULTS=50       # issues per filter
# JIRA_REFRESH_SECS=180     # a shown filter is fetched again when its result is older
# JIRA_INHERIT_GLOBAL=1     # also list the global filters below a context's own
# JIRA_WIDTH=72             # pane width in columns when it opens (at most half the split)
# JIRA_RATIO=""             # or a fixed share of the split for the main pane, e.g. 0.6
# JIRA_APPEARANCE=auto      # auto | dark | light
# JIRA_UPDATE_CHECK=on      # on: ask GitHub for a newer version (at start, every 6 h, and on R); off
# JIRA_POINTS_FIELD=auto    # story points: auto finds the field, or its id or name; off

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

# p in the pane appends the views you pin from the browser (b) below; m lists and removes them.
