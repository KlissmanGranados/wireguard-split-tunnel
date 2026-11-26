#!/usr/bin/env bash
#
# vpn-cli.sh
#
# Interactive menu to configure and apply the WireGuard split tunnel:
# pick the source .conf, set the connection name, and generate + apply
# everything with one action.
#
# Usage:
#   ./vpn-cli.sh                 Open the menu
#   ./vpn-cli.sh apply           Generate and apply with saved settings
#   ./vpn-cli.sh up | down       Connect / disconnect
#   ./vpn-cli.sh status          Show settings and connection state
#   ./vpn-cli.sh use FILE.conf   Select a .conf from the secure folder
#   ./vpn-cli.sh import PATH     Copy a .conf into the secure folder
#
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$SCRIPT_DIR
UPDATE="$SCRIPT_DIR/scripts/update-split-tunnel.sh"
APPLY="$SCRIPT_DIR/scripts/apply-split-tunnel-kde.sh"

# Private files (WireGuard keys) live in confs/ and generated/ (gitignored).
WG_HOME="${WG_SPLIT_HOME:-$ROOT_DIR}"
CONFS_DIR="$WG_HOME/confs"
SETTINGS="$WG_HOME/settings.env"
mkdir -p "$CONFS_DIR" "$WG_HOME/generated"
chmod 700 "$CONFS_DIR" "$WG_HOME/generated" 2>/dev/null || true

# Defaults (overridden by the settings file).
CONF=""
NAME="split VPN"
IFACE="wg-split"
RESOLVER="1.1.1.1"
DISCOVER=0
AUTOCONNECT=0

if [[ -t 1 ]]; then
  B=$'\e[1m'; G=$'\e[32m'; Y=$'\e[33m'; R=$'\e[31m'; D=$'\e[2m'; N=$'\e[0m'
else
  B=""; G=""; Y=""; R=""; D=""; N=""
fi

ok()   { printf '%s[ok]%s %s\n' "$G" "$N" "$*"; }
warn() { printf '%s[!]%s %s\n' "$Y" "$N" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$R" "$N" "$*" >&2; }

# ---------------------------------------------------------------------------
# Settings (plain KEY=VALUE, parsed, never sourced)
# ---------------------------------------------------------------------------
load_settings() {
  [[ -r $SETTINGS ]] || return 0
  local key val
  while IFS='=' read -r key val || [[ -n $key ]]; do
    [[ $key =~ ^[A-Z_]+$ ]] || continue
    case "$key" in
      CONF)        CONF=$val ;;
      NAME)        NAME=$val ;;
      IFACE)       IFACE=$val ;;
      RESOLVER)    RESOLVER=$val ;;
      DISCOVER)    [[ $val == 1 ]] && DISCOVER=1 || DISCOVER=0 ;;
      AUTOCONNECT) [[ $val == 1 ]] && AUTOCONNECT=1 || AUTOCONNECT=0 ;;
    esac
  done < "$SETTINGS"
}

save_settings() {
  {
    printf 'CONF=%s\n' "$CONF"
    printf 'NAME=%s\n' "$NAME"
    printf 'IFACE=%s\n' "$IFACE"
    printf 'RESOLVER=%s\n' "$RESOLVER"
    printf 'DISCOVER=%s\n' "$DISCOVER"
    printf 'AUTOCONNECT=%s\n' "$AUTOCONNECT"
  } > "$SETTINGS"
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
list_confs() {
  local f
  shopt -s nullglob
  for f in "$CONFS_DIR"/*.conf; do
    printf '%s\n' "$(basename -- "$f")"
  done
  shopt -u nullglob
}

conf_endpoint() {
  awk -F= 'tolower($1) ~ /^[[:space:]]*endpoint[[:space:]]*$/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' \
    "$CONFS_DIR/$1" 2>/dev/null || true
}

is_active() {
  nmcli -t -f NAME connection show --active 2>/dev/null | grep -Fxq -- "$NAME"
}

conn_exists() {
  nmcli connection show "$NAME" >/dev/null 2>&1
}

valid_iface() {
  [[ $1 =~ ^[A-Za-z0-9_.-]+$ && ${#1} -le 15 && $1 != . && $1 != .. ]]
}

valid_resolver() {
  [[ $1 == system || $1 =~ ^[A-Za-z0-9.:-]+$ ]]
}

require_conf() {
  [[ -n $CONF ]] || { err "No source .conf selected. Choose one first."; return 1; }
  [[ -r $CONFS_DIR/$CONF ]] || { err "Cannot read $CONF."; return 1; }
}

yesno() { [[ $1 == 1 ]] && printf 'yes' || printf 'no'; }

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
select_conf() {
  local -a files
  mapfile -t files < <(list_confs)
  if (( ${#files[@]} == 0 )); then
    err "No .conf files in $CONFS_DIR. Use the import option (i)."
    return 1
  fi
  printf '\n%sAvailable configurations:%s\n' "$B" "$N"
  local i mark ep
  for i in "${!files[@]}"; do
    mark=" "; [[ ${files[i]} == "$CONF" ]] && mark="*"
    ep=$(conf_endpoint "${files[i]}")
    printf '  %s %d) %s %s(%s)%s\n' "$mark" "$((i + 1))" "${files[i]}" "$D" "${ep:-no endpoint}" "$N"
  done
  local pick
  read -r -p "Number (Enter to cancel): " pick || return 0
  [[ -z $pick ]] && return 0
  if [[ $pick =~ ^[0-9]+$ ]] && (( pick >= 1 && pick <= ${#files[@]} )); then
    CONF=${files[pick - 1]}
    save_settings
    ok "Selected: $CONF"
  else
    err "Invalid option."
  fi
}

import_conf() {
  local src base
  read -r -e -p "Path to the .conf to import (Enter to cancel): " src || return 0
  [[ -z $src ]] && return 0
  src=${src/#\~/$HOME}
  if [[ ! -f $src || $src != *.conf ]]; then
    err "Not a readable .conf file: $src"
    return 1
  fi
  base=$(basename -- "$src")
  if [[ -e $CONFS_DIR/$base ]]; then
    local a
    read -r -p "$base already exists. Overwrite? [y/N]: " a || return 0
    [[ $a =~ ^[yYsS]$ ]] || { warn "Cancelled."; return 0; }
  fi
  install -m 600 -- "$src" "$CONFS_DIR/$base"
  ok "Imported into $CONFS_DIR/$base"
  local rm_src
  read -r -p "Delete the original at $src? [y/N]: " rm_src || return 0
  if [[ $rm_src =~ ^[yYsS]$ ]]; then rm -f -- "$src"; ok "Original deleted."; fi
  CONF=$base; save_settings; ok "Selected: $CONF"
}

set_name() {
  local v
  read -r -p "Connection name [$NAME]: " v || return 0
  [[ -z $v ]] && return 0
  NAME=$v
  save_settings
  ok "Name: $NAME"
}

set_iface() {
  local v
  read -r -p "Interface name, max 15 chars [$IFACE]: " v || return 0
  [[ -z $v ]] && return 0
  if valid_iface "$v"; then
    IFACE=$v; save_settings; ok "Interface: $IFACE"
  else
    err "Invalid interface name."
  fi
}

set_resolver() {
  local v
  read -r -p "DNS resolver IP or 'system' [$RESOLVER]: " v || return 0
  [[ -z $v ]] && return 0
  if valid_resolver "$v"; then
    RESOLVER=$v; save_settings; ok "Resolver: $RESOLVER"
  else
    err "Invalid resolver."
  fi
}

toggle_discover() {
  DISCOVER=$(( 1 - DISCOVER )); save_settings
  ok "Subdomain discovery: $(yesno "$DISCOVER")"
}

toggle_autoconnect() {
  AUTOCONNECT=$(( 1 - AUTOCONNECT )); save_settings
  ok "Autoconnect: $(yesno "$AUTOCONNECT")"
}

do_apply() {
  require_conf || return 1
  local -a uargs=(-c "$CONFS_DIR/$CONF" --resolver "$RESOLVER")
  (( DISCOVER )) || uargs+=(--no-discover)
  local -a aargs=(-n "$NAME" -i "$IFACE")
  (( AUTOCONNECT )) && aargs+=(--autoconnect)

  printf '\n%sGenerating split tunnel from %s...%s\n' "$B" "$CONF" "$N"
  "$UPDATE" "${uargs[@]}" || { err "Generation failed."; return 1; }
  printf '\n%sApplying to NetworkManager as "%s"...%s\n' "$B" "$NAME" "$N"
  "$APPLY" "${aargs[@]}" || { err "Apply failed."; return 1; }
  ok "Done."
}

do_up() {
  conn_exists || { err "Connection \"$NAME\" does not exist. Run apply first."; return 1; }
  nmcli connection up "$NAME" >/dev/null && ok "Connected: $NAME" || err "Could not connect."
}

do_down() {
  if is_active; then
    nmcli connection down "$NAME" >/dev/null && ok "Disconnected: $NAME"
  else
    warn "\"$NAME\" is not active."
  fi
}

do_delete() {
  conn_exists || { warn "\"$NAME\" does not exist."; return 0; }
  local a
  read -r -p "Delete connection \"$NAME\" from NetworkManager? [y/N]: " a || return 0
  if [[ $a =~ ^[yYsS]$ ]]; then
    "$APPLY" -n "$NAME" --delete
  else
    warn "Cancelled."
  fi
}

show_settings() {
  local state="not created"
  if command -v nmcli >/dev/null 2>&1; then
    if is_active; then state="${G}active${N}"
    elif conn_exists; then state="inactive"
    fi
  else
    state="nmcli not installed"
  fi
  printf '  Confs folder : %s\n' "$CONFS_DIR"
  printf '  Source .conf : %s\n' "${CONF:-${Y}(none)${N}}"
  printf '  Name         : %s\n' "$NAME"
  printf '  Interface    : %s\n' "$IFACE"
  printf '  DNS resolver : %s\n' "$RESOLVER"
  printf '  Discovery    : %s\n' "$(yesno "$DISCOVER")"
  printf '  Autoconnect  : %s\n' "$(yesno "$AUTOCONNECT")"
  printf '  State        : %s\n' "$state"
}

# ---------------------------------------------------------------------------
# Menu
# ---------------------------------------------------------------------------
pause() { read -r -p $'\nPress Enter to continue...' _ || true; }

menu() {
  local c
  while true; do
    printf '\n%s=== WireGuard split tunnel ===%s\n' "$B" "$N"
    show_settings
    cat <<EOF

  ${B}1)${N} Select source .conf
  ${B}2)${N} Set connection name
  ${B}3)${N} Set interface name
  ${B}4)${N} Set DNS resolver
  ${B}5)${N} Toggle subdomain discovery
  ${B}6)${N} Toggle autoconnect
  ${B}7)${N} Generate + apply
  ${B}8)${N} Connect
  ${B}9)${N} Disconnect
  ${B}i)${N} Import a .conf into the secure folder
  ${B}d)${N} Delete connection
  ${B}q)${N} Quit

EOF
    read -r -p "Option: " c || { printf '\n'; return 0; }
    case "$c" in
      1) select_conf || true ;;
      2) set_name ;;
      3) set_iface ;;
      4) set_resolver ;;
      5) toggle_discover ;;
      6) toggle_autoconnect ;;
      7) do_apply || true; pause ;;
      8) do_up || true ;;
      9) do_down || true ;;
      i|I) import_conf || true ;;
      d|D) do_delete || true ;;
      q|Q) return 0 ;;
      "") ;;
      *) err "Invalid option." ;;
    esac
  done
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
[[ -x $UPDATE && -x $APPLY ]] || { err "update-split-tunnel.sh / apply-split-tunnel-kde.sh not found or not executable."; exit 1; }

load_settings

case "${1:-menu}" in
  menu)    menu ;;
  apply)   do_apply ;;
  up)      do_up ;;
  down)    do_down ;;
  status)  show_settings ;;
  import)
    [[ -n ${2:-} ]] || { err "Usage: $0 import PATH.conf"; exit 1; }
    [[ -f $2 && $2 == *.conf ]] || { err "Not a readable .conf file: $2"; exit 1; }
    install -m 600 -- "$2" "$CONFS_DIR/$(basename -- "$2")"
    ok "Imported into $CONFS_DIR/$(basename -- "$2")" ;;
  use)
    [[ -n ${2:-} ]] || { err "Usage: $0 use FILE.conf"; exit 1; }
    f=$(basename -- "$2")
    [[ -r $CONFS_DIR/$f ]] || { err "Not a valid source .conf: $2"; exit 1; }
    CONF=$f; save_settings; ok "Selected: $CONF" ;;
  -h|--help|help) sed -n '3,16p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//' ;;
  *) err "Unknown command: $1 (use --help)"; exit 1 ;;
esac
