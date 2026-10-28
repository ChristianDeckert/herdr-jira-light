#!/bin/sh
# herdr-jira-light installer: installs or updates the plugin and adds its key binding.
#
#   curl -fsSL https://raw.githubusercontent.com/ChristianDeckert/herdr-jira-light/main/install.sh | sh
#   ... | sh -s -- --yes          install without herdr's review prompt
#   ... | sh -s -- --uninstall    remove the plugin and the key binding this script added
#   ... | sh -s -- --token        only store (or replace) the Jira token in the keychain
set -eu

REPO=ChristianDeckert/herdr-jira-light
ID=christiandeckert.jira-light
MIN_HERDR=0.9.4
KEY=prefix+alt+j
# the same file herdr reads
CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/herdr/config.toml"
BACKUP="" CREATED=0

say() { printf '%s\n' "$*"; }
info() { printf '  %s\n' "$*"; }
die() { printf 'herdr-jira-light: %s\n' "$*" >&2; exit 1; }

usage() {
  say "usage: install.sh [--yes] [--uninstall] [--token]"
  say "  --yes        install or update without herdr's review prompt"
  say "  --uninstall  remove the plugin and the key binding this script added"
  say "  --token      only store (or replace) the Jira token in the keychain"
}

YES=0 MODE=install
for arg in "$@"; do
  case $arg in
    -y|--yes) YES=1 ;;
    --uninstall) MODE=uninstall ;;
    --token) MODE=token ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; die "unknown option: $arg" ;;
  esac
done

install_hint() { # tool
  if command -v brew >/dev/null 2>&1; then say "brew install $1"
  elif command -v apt-get >/dev/null 2>&1; then say "sudo apt-get install $1"
  elif command -v dnf >/dev/null 2>&1; then say "sudo dnf install $1"
  elif command -v pacman >/dev/null 2>&1; then say "sudo pacman -S $1"
  else say "install $1 with your package manager"
  fi
}

version_ge() { # a b: is a >= b, for dotted numbers
  [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n | head -n 1)" = "$2" ]
}

# herdr asks before installing; it reads the answer from the terminal, since stdin is this script.
herdr_confirmed() { # herdr arguments...
  if [ "$YES" = 1 ]; then
    herdr "$@" --yes
  elif (: </dev/tty) 2>/dev/null; then
    herdr "$@" </dev/tty
  else
    die "no terminal to confirm in; run it again with: sh -s -- --yes"
  fi
}

plugin_source() { # github, local or nothing
  herdr plugin list --json --plugin "$ID" 2>/dev/null |
    jq -r '.result.plugins[0].source.kind // empty' 2>/dev/null || true
}

backup_config() {
  [ -n "$BACKUP" ] && return 0
  BACKUP="$CONFIG.bak-$(date +%Y%m%d-%H%M%S)"
  cp "$CONFIG" "$BACKUP"
}

# herdr rejects a broken config; then the previous version goes back in place.
check_config() {
  if ! out=$(herdr config check 2>&1); then
    if [ -n "$BACKUP" ]; then cp "$BACKUP" "$CONFIG"; elif [ "$CREATED" = 1 ]; then rm -f "$CONFIG"; fi
    die "herdr rejected $CONFIG, restored the previous version:
$out"
  fi
}

# A binding is assigned as key = "…" in a [[keys.command]] block or as action = "…" in [keys].
key_used() { # key
  k=$(printf '%s' "$1" | sed 's/[+.]/\\&/g')
  grep -Eq "=[[:space:]]*[\"']$k[\"']" "$CONFIG" 2>/dev/null && return 0
  herdr --default-config 2>/dev/null | grep -Eq "^#[[:space:]]*[a-z_]+[[:space:]]*=[[:space:]]*\"$k\""
}

action_bound() { # action
  grep -Eq "^[[:space:]]*command[[:space:]]*=[[:space:]]*[\"']$ID\\.$1[\"']" "$CONFIG" 2>/dev/null
}

ADDED=0
add_binding() { # action key description
  if action_bound "$1"; then
    info "$3: already bound in your config"
    return
  fi
  if key_used "$2"; then
    info "$3: $2 is already in use, so no key was added. To bind another key, add:"
    printf '\n[[keys.command]]\nkey = "prefix+..."\ntype = "plugin_action"\ncommand = "%s.%s"\ndescription = "%s"\n\n' "$ID" "$1" "$3"
    return
  fi
  [ "$CREATED" = 1 ] || backup_config
  printf '\n[[keys.command]]\nkey = "%s"\ntype = "plugin_action"\ncommand = "%s.%s"\ndescription = "%s"\n' \
    "$2" "$ID" "$1" "$3" >> "$CONFIG"
  ADDED=1
  info "$3: added $2"
}

reload_config() {
  if herdr server reload-config >/dev/null 2>&1; then
    info "reloaded herdr's config"
  else
    info "herdr isn't running; the key works the next time you start it"
  fi
}

# --- Jira token
# The pane reads the token from this keychain entry: the macOS Keychain, or on Linux the Secret Service
# (GNOME Keyring, KWallet) through secret-tool. Both ask for the token themselves, so it shows neither
# on screen nor in the shell history. The lookup's output goes to /dev/null.
SERVICE=jira-pat
token_cmds() {
  if [ "$(uname -s)" = Darwin ]; then
    TOOL=security WHERE="the Keychain"
    LOOKUP="security find-generic-password -s $SERVICE -w"
    STORE="security add-generic-password -U -s $SERVICE -a \"\$USER\" -w"
  else
    TOOL=secret-tool WHERE="your keyring"
    LOOKUP="secret-tool lookup service $SERVICE"
    STORE="secret-tool store --label='Jira personal access token' service $SERVICE"
  fi
}

secret_tool_hint() {
  if command -v apt-get >/dev/null 2>&1; then say "sudo apt-get install libsecret-tools"
  elif command -v dnf >/dev/null 2>&1; then say "sudo dnf install libsecret"
  elif command -v pacman >/dev/null 2>&1; then say "sudo pacman -S libsecret"
  else say "install libsecret, which brings secret-tool"
  fi
}

token_step() {
  token_cmds
  if ! command -v "$TOOL" >/dev/null 2>&1; then
    info "$TOOL isn't installed, so the token can't be stored in $WHERE: $(secret_tool_hint)"
    info "(or set JIRA_TOKEN_CMD in config.zsh to a command that prints the token)"
    return 0
  fi
  if [ "$MODE" != token ] && sh -c "$LOOKUP" >/dev/null 2>&1; then
    info "Jira token: found in $WHERE ($SERVICE)"
    return 0
  fi
  if [ "$YES" != 1 ] && (: </dev/tty) 2>/dev/null; then
    printf '  Store your Jira personal access token in %s now? [Y/n] ' "$WHERE"
    answer=n
    read -r answer </dev/tty || answer=n
    case $answer in
      [nN]*) ;;
      *)
        info "Create it in Jira (your avatar > Profile > Personal Access Tokens) and paste it at the prompt:"
        sh -c "$STORE" </dev/tty || true
        if sh -c "$LOOKUP" >/dev/null 2>&1; then
          info "Jira token: stored in $WHERE ($SERVICE)"
          return 0
        fi
        info "the token wasn't stored" ;;
    esac
  fi
  info "Store the token later with: $STORE"
  info "(the pane shows the same as a setup guide, where 2 does it)"
}

if [ "$MODE" = token ]; then
  token_step
  exit 0
fi

# --- checks
command -v herdr >/dev/null 2>&1 ||
  die "herdr isn't installed. Install it first: curl -fsSL https://herdr.dev/install.sh | sh"
command -v jq >/dev/null 2>&1 || die "jq is needed: $(install_hint jq)"

if [ "$MODE" = uninstall ]; then
  say "Removing herdr-jira-light"
  if [ -n "$(plugin_source)" ]; then
    herdr plugin uninstall "$ID" >/dev/null && info "uninstalled the plugin"
  else
    info "the plugin isn't installed"
  fi
  if [ -f "$CONFIG" ] && grep -q "$ID\\." "$CONFIG"; then
    backup_config
    # drops each [[keys.command]] block whose command is one of this plugin's actions
    awk -v pat="^[[:space:]]*command[[:space:]]*=[[:space:]]*[\"']christiandeckert[.]jira-light[.]" '
      function flush() { if (!drop) for (i = 1; i <= n; i++) print buf[i]; n = 0; drop = 0; inb = 0 }
      /^[[:space:]]*\[/ { flush(); if ($0 ~ /^[[:space:]]*\[\[keys\.command\]\]/) inb = 1 }
      inb { buf[++n] = $0; if ($0 ~ pat) drop = 1; next }
      { print }
      END { flush() }' "$BACKUP" > "$CONFIG"
    check_config
    reload_config
    info "removed its key binding (backup: $BACKUP)"
  fi
  say "Done. Your settings stay in $(herdr plugin config-dir "$ID" 2>/dev/null || echo "herdr's plugin config folder")."
  exit 0
fi

version=$(herdr --version 2>/dev/null | awk '{ print $2 }')
version_ge "${version:-0}" "$MIN_HERDR" ||
  die "herdr $MIN_HERDR or newer is needed (you have ${version:-an unknown version}): herdr update"
command -v zsh >/dev/null 2>&1 || die "zsh is needed: $(install_hint zsh)"
command -v curl >/dev/null 2>&1 || die "curl is needed: $(install_hint curl)"

# --- plugin
say "Installing herdr-jira-light"
case $(plugin_source) in
  github)
    info "already installed, updating"
    herdr_confirmed plugin update "$ID" ;;
  local)
    die "$ID is linked from a local folder (herdr plugin link). Unlink it first: herdr plugin unlink $ID" ;;
  *)
    herdr_confirmed plugin install "$REPO" ;;
esac
[ "$(plugin_source)" = github ] || die "the plugin wasn't installed"

# --- key binding
mkdir -p "$(dirname "$CONFIG")"
if [ ! -f "$CONFIG" ]; then : > "$CONFIG"; CREATED=1; fi
add_binding toggle "$KEY" "toggle Jira pane"
check_config
if [ "$ADDED" = 1 ]; then reload_config; fi

# --- token
token_step

say ""
say "Done. Next:"
if [ "$ADDED" = 1 ]; then say "  $KEY opens the Jira pane in the current tab."
else say "  Open the Jira pane with the key bound to $ID.toggle."
fi
say "  The pane asks for your Jira URL and guides you through the rest."
if [ -n "$BACKUP" ]; then say "  your previous herdr config: $BACKUP"; fi
say "  uninstall: curl -fsSL https://raw.githubusercontent.com/$REPO/main/install.sh | sh -s -- --uninstall"
