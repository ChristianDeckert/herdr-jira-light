# Update notice for GitHub installs, sourced by jira.zsh.
# All panes share one result file and redraw when it changes.
UPDATE_FILE="$JL_STATE_DIR/update"
# The pane that runs an update writes the new plugin root here; every pane then restarts from it.
ROOT_FILE="$JL_STATE_DIR/root"
# A pane that stays open checks again after this many seconds.
JL_UPDATE_EVERY=21600
typeset -A UPDATE

plugin_info() { # prints kind, owner, repo, commit, version, root (tab separated)
  "$H" plugin list --json --plugin "$JL_PLUGIN_ID" 2>/dev/null | jq -r '.result.plugins[0] |
    [.source.kind, .source.owner, .source.repo, .source.resolved_commit, .version, .plugin_root] | @tsv'
}

write_update_file() { # lines
  print -rl -- "$@" > "$UPDATE_FILE.tmp" && mv "$UPDATE_FILE.tmp" "$UPDATE_FILE"
}

fetch_update() {
  setopt local_options extended_glob
  local kind owner repo installed version root remote ver
  IFS=$'\t' read -r kind owner repo installed version root <<< "$(plugin_info)"
  if [[ $kind != github ]]; then
    write_update_file "skipped=installed from ${kind:-unknown source}" "current=$version"
    return
  fi
  remote=$(GIT_TERMINAL_PROMPT=0 git -c http.lowSpeedLimit=100 -c http.lowSpeedTime=15 \
    ls-remote "https://github.com/$owner/$repo.git" HEAD 2>&1)
  if [[ $? -ne 0 || ${remote%%$'\t'*} != [0-9a-f](#c40) ]]; then
    write_update_file "installed=$installed" "current=$version" "error=git ls-remote: ${${(f)remote}[1]}"
    return
  fi
  remote=${remote%%$'\t'*}
  if [[ $remote != $installed ]]; then
    ver=$(curl -fsS --max-time 15 "https://raw.githubusercontent.com/$owner/$repo/$remote/herdr-plugin.toml" |
      sed -n 's/^version *= *"\(.*\)".*/\1/p')
  fi
  write_update_file "installed=$installed" "current=$version" "remote=$remote" "version=${ver//[^0-9A-Za-z.+-]/}"
}

# Starts a background check unless the last result is younger than max-age. Panes starting together
# (herdr restores all of them at once) share one check.
update_check() { # [force | max-age, default 60]
  [[ $JIRA_UPDATE_CHECK == off ]] && return
  local lock="$UPDATE_FILE.lock" age=${1:-60}
  local -a m
  if [[ $1 != force && -f $UPDATE_FILE ]]; then
    zstat -A m +mtime "$UPDATE_FILE" 2>/dev/null
    (( EPOCHSECONDS - m[1] < age )) && return
  fi
  # a lock left behind by a killed check expires after ten minutes
  m=()
  zstat -A m +mtime "$lock" 2>/dev/null && (( EPOCHSECONDS - m[1] > 600 )) && rmdir "$lock" 2>/dev/null
  mkdir "$lock" 2>/dev/null || return
  ( { fetch_update } always { rmdir "$lock" 2>/dev/null } ) </dev/null >/dev/null 2>&1 &!
}

# Re-reads the result when it changed; returns non-zero when nothing changed.
read_update() {
  local l
  local -a m
  zstat -A m +mtime "$UPDATE_FILE" 2>/dev/null
  [[ $m[1] == "$UPDATE_STAMP" ]] && return 1
  UPDATE_STAMP=$m[1] UPDATE=()
  [[ -f $UPDATE_FILE ]] || return 0
  for l in "${(@f)$(<$UPDATE_FILE)}"; do UPDATE[${l%%=*}]=${l#*=}; done
}

update_available() { [[ -n $UPDATE[remote] && $UPDATE[remote] != $UPDATE[installed] ]] }

update_status() { # -> REPLY, one line for the help screen
  if update_available; then REPLY="${UPDATE[version]:-a new version} is available, u updates"
  elif [[ -n $UPDATE[error] ]]; then REPLY="update check failed: $UPDATE[error]"
  elif [[ -n $UPDATE[skipped] ]]; then REPLY="no update check: $UPDATE[skipped]"
  elif [[ -n $UPDATE[remote] ]]; then REPLY="up to date${UPDATE[current]:+ · $UPDATE[current]}"
  else REPLY=""
  fi
}

# Runs herdr's own update in this pane; herdr shows what changed and asks before installing.
update_now() {
  local kind owner repo before after version root
  IFS=$'\t' read -r kind owner repo before version root <<< "$(plugin_info)"
  run_inline "${(q)H} plugin update ${(q)JL_PLUGIN_ID}"
  IFS=$'\t' read -r kind owner repo after version root <<< "$(plugin_info)"
  [[ -n $after && $after != $before ]] || return
  read_update
  write_update_file "installed=$after" "current=$version" "remote=${UPDATE[remote]}" "version=${UPDATE[version]}"
  print -r -- "$root" > "$ROOT_FILE.tmp" && mv "$ROOT_FILE.tmp" "$ROOT_FILE"
}

# Restarts this pane from the new plugin root once an update was installed from any pane.
follow_update() {
  local root
  local -a m
  zstat -A m +mtime "$ROOT_FILE" 2>/dev/null
  [[ $m[1] == "$ROOT_STAMP" ]] && return
  ROOT_STAMP=$m[1]
  root=$(<"$ROOT_FILE")
  [[ $root != $ROOT && -f $root/jira.zsh ]] || return
  save_view
  printf '%s\e[?25h' "$MOUSE_OFF"
  normal_tty
  export JL_RESTARTED=1
  exec zsh "$root/jira.zsh"
}
