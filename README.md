# herdr-jira-light

A lightweight Jira pane for [herdr](https://herdr.dev). Its filters follow the working directory of the tab it sits in: each project gets its own boards and sprints, and switching tabs, spaces or directories switches the list. It is written in zsh with curl and jq, so there is nothing to compile.

![The list of a directory's active sprint with blocked, draft, reopened and flagged issues, and an issue's details with time tracking and story points](docs/screenshot.png)

```sh
curl -fsSL https://raw.githubusercontent.com/ChristianDeckert/herdr-jira-light/main/install.sh | sh
```

- `prefix+alt+j` shows or hides the pane in the current tab.
- `b` browses projects, their boards and the boards' sprints and backlog, optionally only your issues; `p` pins what you picked to a directory, `m` lists and removes pins.
- `↵` shows an issue with all of its fields, the description rendered, and sub-tasks, links and comments you can follow.
- `t` moves an issue to another status of its workflow, `A` assigns it to you, `w` logs work on it.
- The bar at the bottom shows the keys that matter where you are, wrapping onto more rows in a narrow pane; click or tap one to press it. It also offers new versions of the plugin.
- It works with Jira Server/Data Center (personal access token) and Jira Cloud (email + API token).
- It changes Jira only when you ask for it with `t`, `A` or `w`.
- Needs herdr 0.9.4+, zsh, curl and jq on macOS or Linux (there also `secret-tool` for the keyring).

## Compared with herdr-jira

[herdr-jira](https://github.com/a2u/herdr-jira) is the other Jira pane for herdr. Jira Light is built around the directory you work in:

| | Jira Light | herdr-jira |
|---|---|---|
| **Filters** | per directory: `context` blocks in the config, the deepest matching path wins, and the list follows the tab's working directory as you switch tabs, spaces or `cd` | one list of filters for everything; `{project}` comes from a single `default_project` |
| **Getting the JQL** | `b` browses projects → boards → active sprint, future sprints, backlog; "only mine" adds `assignee = currentUser()`; `p` pins the result to a directory and `m` removes pins | written by hand in `config.toml`, or typed with `J` |
| **Install** | zsh, curl and jq; nothing to compile | a Rust toolchain at install time |
| **Details** | every filled field including custom ones (Sprint, Epic Link, …), people, dates, time tracking, the description rendered from wiki markup, sub-tasks, links, attachments and comments; issue keys and URLs can be followed | the description, as plain text |
| **Caching** | results are cached on disk and shared by all panes: a list shows at once when you switch or reopen, is refreshed in the background, and stays visible (marked stale) when Jira can't be reached | fetched again on each switch; nothing is cached |

herdr-jira can do things Jira Light doesn't: expand epics inline, search text on the server, and start a new agent in a directory you pick.

## Install

The installer:
1. installs the plugin with `herdr plugin install` (herdr shows what it runs and asks first);
2. adds a `prefix+alt+j` binding to `~/.config/herdr/config.toml` if that key is free, after backing up the file;
3. reloads herdr's config;
4. checks for your Jira token in the keychain and, if it's missing, offers to store it. The keychain asks for the token itself, so it shows neither on screen nor in your shell history.

Then open the pane: it asks for your Jira URL and guides you through anything still missing (see [Setup](#setup)).

Options: `sh -s -- --yes` installs without herdr's prompt (and without asking for the token), `sh -s -- --token` only stores or replaces the token, and `sh -s -- --uninstall` removes the plugin and the binding.

Manually:

```sh
herdr plugin install ChristianDeckert/herdr-jira-light
```

```toml
[[keys.command]]
key = "prefix+alt+j"
type = "plugin_action"
command = "christiandeckert.jira-light.toggle"
description = "toggle Jira pane"
```

Then open the pane; its setup guide stores the token and the Jira URL.

## Setup

Until Jira answers, the pane shows what is missing instead of a list:

- **1 Jira URL**: asks for the address (with a context path such as `/jira` if your Jira has one) and writes `JIRA_BASE_URL` into `config.zsh`.
- **2 Token**: create a personal access token in Jira (your avatar → Profile → Personal Access Tokens), then `2` stores it in the keychain entry `jira-pat`. It's also offered when Jira rejects the stored token, e.g. after it expired.

The token is read from:

| | Keychain | Store it by hand |
|---|---|---|
| macOS | the Keychain, via `security` | `security add-generic-password -U -s jira-pat -a "$USER" -w` |
| Linux | the Secret Service (GNOME Keyring, KWallet), via `secret-tool` from `libsecret-tools` (Debian, Ubuntu) or `libsecret` (Fedora, Arch) | `secret-tool store --label='Jira personal access token' service jira-pat` |

Both commands prompt for the token. The Linux path is covered by tests but hasn't been tried with a real keyring yet; reports are welcome. To use another entry name, set `JIRA_KEYCHAIN_SERVICE`. To read the token from somewhere else (pass, 1Password, …), set `JIRA_TOKEN_CMD` to a command that prints it. For Jira Cloud, set `JIRA_AUTH=basic` and `JIRA_EMAIL`; the token is then an API token from id.atlassian.com.

## Configure

Settings live in `config.zsh` in `$(herdr plugin config-dir christiandeckert.jira-light)`. The file is created from [defaults/config.zsh](defaults/config.zsh) the first time the pane opens, and open panes pick up changes on their own.

```zsh
JIRA_BASE_URL="https://jira.example.com/jira"

# global filters: shown wherever no context matches
filter "My open issues" 'assignee = currentUser() AND resolution = Unresolved ORDER BY updated DESC'

# filters for a directory and everything below it; the deepest matching context wins
context ~/Work/shop-ios "Shop iOS"
filter "Active sprint" 'project = SHOP AND platform = iOS AND sprint in openSprints() ORDER BY updated DESC'
filter "Next sprint"   'project = SHOP AND platform = iOS AND sprint in futureSprints() ORDER BY rank'
```

Filters can also be written for you: see [Browse and pin](#browse-and-pin). A context also lists the global filters after its own; set `JIRA_INHERIT_GLOBAL=0` to turn that off. For Jira Cloud, set `JIRA_AUTH=basic` and `JIRA_EMAIL`. [defaults/config.zsh](defaults/config.zsh) lists every setting, including the templates for branch names and agent prompts.

## Browse and pin

`b` opens a browser for whatever your Jira has, without writing JQL:

1. **Projects**, the ones you used recently first (★).
2. A project's **boards**, plus all of its open issues.
3. A board's **active sprint**, its future sprints, its backlog and all of its issues (a Kanban board: the board and all issues).

Typing narrows each level; `↵` opens, `←` or Backspace goes back, `Esc` closes. On top of the board list and of a board's views, **only mine** (`⇥`, or `↵` on it) limits whichever you pick to `assignee = currentUser()`; it stays on for other boards and projects until you switch it off. Picking a sprint or backlog shows its issues right away, as a view. `p` then pins the view: it asks for a directory (the project you're in, or its git root) and appends a filter for it to `config.zsh`:

```zsh
# pinned from the browser, 2026-10-26
context '/Users/me/Work/shop-ios' 'Shop'
filter 'Shop Scrum · Active sprint' '(project = SHOP) AND sprint in openSprints() ORDER BY Rank ASC'
```

The active sprint is pinned as `openSprints()`, so the filter keeps working when the next sprint starts. Edit the line like any other filter, e.g. to add `AND platform = iOS`. A view that is already pinned to that directory isn't pinned twice.

`m` lists everything pinned this way, grouped by directory. `d` (or Delete) and then `y` removes an entry from `config.zsh`; the file as it was before is kept as `config.zsh.bak`. Hand-written filters aren't listed there.

## Colors

Each issue's dot and status follow Jira's status category: blue for "to do", yellow for "in progress", green for "done". Some states stand out more:

- **Red:** a blocked status (its name contains "block" or "impediment"), whatever its category.
- **Orange:** reopened, i.e. back in a "to do" status after it was further along (in review, in progress, done). The pane asks Jira with a second, small search per list: the list's JQL plus `status WAS IN (…)` with every status outside "to do". Jira's status list is fetched once a day; reading each issue's history would take too long.
- **Lighter blue:** Draft and Backlog, to set them apart from Open and To Do.
- **⚑** before the summary: the issue is flagged (Jira Software's Flagged field).

## Details

`↵` shows an issue the way its Jira page does: the status as a colored badge, priority and type, the issue's link, and sections for details (every filled field, custom fields such as Sprint, Platform or Epic Link included), people, dates, time tracking with a progress bar, the description rendered from Jira's wiki markup, sub-tasks, links, attachments and comments (newest first).

Issue keys (parent, epic, sub-tasks, links) and URLs are links: click them, or walk them with `⇥` / `⇧⇥` and follow with `↵`. A followed issue opens in the same view and `Esc` goes back to the previous one.

## Status and assignee

`t` (in the list or the details) lists the transitions Jira offers for the issue, each with the status it leads to. `1`–`9`, or `↵` on the selected one, runs it; the list and the details are fetched again afterwards. `A` assigns the issue to you.

Workflows often want an assignee for some statuses. Jira tells about that in three ways, and the pane passes each on:

- **The transition's screen requires an assignee.** The transition is marked `assigns you` while the issue has none, and running it makes you the assignee.
- **A validator checks it when the transition runs.** Jira answers with an error such as "Assignee is required"; the pane shows it, keeps the transition selected and offers `A`, after which `↵` tries again.
- **A condition hides the transition** (e.g. only the assignee may start progress). While the issue isn't yours, the pane says that more transitions may appear once you take it with `A`.

### Required fields

Some transitions need a field first, such as a fix version before work starts.

- **On the transition's screen:** Jira says so up front. The transition shows `asks for Team`, and the pane asks for each such field that is still empty before it moves the issue.
- **Checked by a validator:** Jira says so only when the transition runs, e.g. "Field Fix Version/s is required.". When the error names a field, `f` asks for it and tries again. Otherwise `e` lets you pick any field of the issue, then its value, and tries again.

Fields with a list of values (versions, components, select lists, checkboxes, priority) open a list that narrows as you type. Fields with several values are ticked with `Space` and start with the issue's current values ticked. Versions come unreleased and newest first; archived ones are left out. Text, numbers, dates (`YYYY-MM-DD`) and labels are typed. A user field offers you.

Values for a field on the transition's screen go with the transition. Any other field is saved by editing the issue first, because Jira refuses fields a transition doesn't show. The pane can't fill fields such as sprint, epic link or a cascading select; `o` opens the issue in Jira for those.

## Log work

`w` (in the list, the details or the work log) logs time on the issue: the time spent in Jira's notation (`1h 30m`, `2d`, `45m`), then an optional comment. The work counts as started now, and Jira lowers the remaining estimate by it. The prompt shows the issue's story points, estimate, logged time and what's left. The bar offers `w` for issues estimated in time or in story points; the key works on any issue.

Work is always logged as time, also on issues estimated in story points; Jira has no way to log points. The points show in the prompt and in the details, next to the time tracking.

In the details, tap **Logged** or **Progress** (or reach them with `⇥` and press `↵`) for the work log: every entry with its time, author, date and comment, newest first.

Story points live in a custom field whose id differs between Jira instances. The pane finds it in Jira's field list (fetched once a day): the first number field named "Story Points", "Story point estimate" or "Original story points", else one with "story point" in its name. `JIRA_POINTS_FIELD` in `config.zsh` names the field by id or name instead, or turns points off with `off`.

## Keys

`?` in the pane shows all of them. The bar at the bottom shows the keys that matter where you are; click or tap one to press it.

**List**

| Key | Action |
|---|---|
| `↑` `↓` `j` `k`, wheel | move |
| `g` `G`, `Home` `End`, `PgUp` `PgDn` | first / last, page |
| `↵` `l`, click | details (see above) |
| `f` `⇥` / `F`, `1`–`9` | next / previous filter, pick one |
| `s` / `S` | next sort (filter, updated, created, priority, rank, key, status) / reverse it |
| `/` | search the loaded issues, every word must match; `Esc` clears it |
| `J` | type a JQL query, prefilled with the current one |
| `b` | browse projects, boards and sprints |
| `p` | pin the current view (from `b` or `J`) to a directory |
| `m` | manage pinned filters |
| `r` / `R` | fetch again / reload the config and check for a new version |
| `u` | update the plugin, when the bar offers it |
| `o` | open the issue in the browser |
| `t` | change the status (see above) |
| `A` | assign the issue to you |
| `w` | log work |
| `y` / `Y` | copy the key / a branch name (`feature/APP-123-fix-login`) |
| `a` | send the issue to an agent in this tab (or workspace) as a prompt |
| `q` | close the pane |

**Details**

| Key | Action |
|---|---|
| `↑` `↓` `j` `k` `Space`, wheel | scroll |
| `⇥` / `⇧⇥` | next / previous link |
| `↵`, click | follow the link |
| `Esc` `←` `h` `q` | back |
| `o` `y` `Y` `a` `r` | open, copy key / branch, send to agent, fetch again |
| `t` `A` `w` | change the status, assign to you, log work |

**Status** (`t`)

| Key | Action |
|---|---|
| `1`–`9`, `↵`, click | move the issue to that status |
| `↑` `↓` `j` `k` | select |
| `A` | assign the issue to you; Jira may then offer more transitions |
| `f` | fill the fields a failed transition names, then try again |
| `e` | set any field of the issue, then try again |
| `o` | open the issue in Jira |
| `Esc` `←` `q` | back |

**Work log** (tap Logged or Progress in the details)

| Key | Action |
|---|---|
| `↑` `↓` `j` `k` `Space`, wheel | scroll |
| `w` / `r` | log work / fetch again |
| `Esc` `←` `q` | back |

**Picking a value**

| Key | Action |
|---|---|
| typing | narrow the list |
| `↑` `↓`, wheel | move |
| `Space`, click | tick (fields with several values) |
| `↵`, click | take the ticked values, or the selected one |
| `Esc` `←` | clear the typing, then cancel |

**Browser**

| Key | Action |
|---|---|
| typing | narrow the list |
| `↵` `→`, click | open |
| `⇥` | only mine (board list and a board's views) |
| `←` `⌫` | back one level |
| `Esc` | clear the typing, then close |

**Pinned filters** (`m`)

| Key | Action |
|---|---|
| `↑` `↓` `j` `k`, wheel, click | move |
| `d` `⌫` `Delete`, then `y` | remove the entry from `config.zsh` |
| `Esc` `←` `q` | back |

## How it works

- The pane watches the focused pane of its own tab (the one you last worked in) and uses its current directory, so it follows `cd`.
- Results are cached in herdr's plugin state folder. A list appears from the cache at once and is fetched again in the background when it's older than `JIRA_REFRESH_SECS` (default 180). When Jira can't be reached, the last result stays visible, marked stale, with the error.
- The token is read from its keychain entry (or with `JIRA_TOKEN_CMD`) and passed to curl on stdin, so it never shows up in the process list.
- Lists and details are only read. `t` and `A` send one request each (`POST …/transitions`, `PUT …/assignee`, after a single `GET /myself` to learn who you are), plus a `PUT /issue/…` when you set fields that aren't on the transition's screen; `w` sends `POST …/worklog`. Each waits for Jira's answer; a failure is shown as Jira words it.
- Besides its search, a list sends a second, small one for its reopened issues (see [Colors](#colors)). Jira's field list (for story points and the Flagged field) and status list are fetched once a day.
- Sorting changes the query's `ORDER BY` and fetches again, since Jira returns at most `JIRA_MAX_RESULTS` issues.
- After a herdr server restart, the startup hook replaces Jira panes that herdr restored as plain shells.
- When a pane starts, every 6 hours, and on `R`, it compares the installed commit (`herdr plugin list --json`) with the repository's latest one using a single `git ls-remote` to github.com; if they differ, it reads the version from the new `herdr-plugin.toml`. Panes share the result in the plugin's state folder. Local or linked installs aren't checked, and `JIRA_UPDATE_CHECK=off` turns the check off.
- A new version shows as `u update to x.y.z` above the keys in the list's bar. `u`, or a click on it, runs `herdr plugin update` in the pane, which shows what changed and asks first. Every open pane then restarts on the new version, keeping its filter and sort; panes of a linked checkout restart the same way when its files change.

## Development

```sh
herdr plugin link .     # use this checkout instead of the GitHub install
zsh tests/run.zsh       # tests for matching, sorting, parsing, pinning, fields, worklogs, requests
```

With the checkout linked, open panes restart within a few seconds of a saved change, once the files pass `zsh -n`.
