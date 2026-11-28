#!/usr/bin/env bash
#
# vpn-cli.sh
#
# Interactive menu to configure and apply the WireGuard split tunnel:
# pick the source .conf, set the connection name, and generate + apply
# everything with one action.
#
# Usage (the authoritative help text lives in usage() below):
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

conn_exists_named() {
  command -v nmcli >/dev/null 2>&1 && nmcli connection show "$1" >/dev/null 2>&1
}

confirm_tty() { [[ -t 0 ]]; }

# ---------------------------------------------------------------------------
# Applied-state snapshot (generated/.applied), parsed, never sourced
# ---------------------------------------------------------------------------
SNAPSHOT="$WG_HOME/generated/.applied"

domains_sha() {
  if [[ -r $ROOT_DIR/domains.txt ]]; then
    sha256sum -- "$ROOT_DIR/domains.txt" | awk '{print $1}'
  else
    printf 'none'
  fi
}

write_snapshot() {
  {
    printf 'CONF=%s\n' "$CONF"
    printf 'NAME=%s\n' "$NAME"
    printf 'IFACE=%s\n' "$IFACE"
    printf 'RESOLVER=%s\n' "$RESOLVER"
    printf 'DISCOVER=%s\n' "$DISCOVER"
    printf 'AUTOCONNECT=%s\n' "$AUTOCONNECT"
    printf 'DOMAINS_SHA=%s\n' "$(domains_sha)"
  } > "$SNAPSHOT"
  chmod 600 "$SNAPSHOT" 2>/dev/null || true
}

# Sets SNAP_<KEY> variables from the snapshot file.
read_snapshot() {
  SNAP_CONF=""; SNAP_NAME=""; SNAP_IFACE=""; SNAP_RESOLVER=""
  SNAP_DISCOVER=""; SNAP_AUTOCONNECT=""; SNAP_DOMAINS_SHA=""
  local key val
  while IFS='=' read -r key val || [[ -n $key ]]; do
    [[ $key =~ ^[A-Z_]+$ ]] || continue
    case "$key" in
      CONF)        SNAP_CONF=$val ;;
      NAME)        SNAP_NAME=$val ;;
      IFACE)       SNAP_IFACE=$val ;;
      RESOLVER)    SNAP_RESOLVER=$val ;;
      DISCOVER)    SNAP_DISCOVER=$val ;;
      AUTOCONNECT) SNAP_AUTOCONNECT=$val ;;
      DOMAINS_SHA) SNAP_DOMAINS_SHA=$val ;;
    esac
  done < "$SNAPSHOT"
}

# Prints "never", "yes" or "no".
has_pending_changes() {
  [[ -r $SNAPSHOT ]] || { printf 'never'; return 0; }
  read_snapshot
  if [[ $SNAP_CONF == "$CONF" && $SNAP_NAME == "$NAME" && $SNAP_IFACE == "$IFACE" \
     && $SNAP_RESOLVER == "$RESOLVER" && $SNAP_DISCOVER == "$DISCOVER" \
     && $SNAP_AUTOCONNECT == "$AUTOCONNECT" && $SNAP_DOMAINS_SHA == "$(domains_sha)" ]]; then
    printf 'no'
  else
    printf 'yes'
  fi
}

# Update one KEY in the snapshot (no-op when there is no snapshot).
snapshot_set() {
  [[ -r $SNAPSHOT ]] || return 0
  local tmp
  tmp=$(mktemp "$SNAPSHOT.XXXXXX")
  { grep -v "^$1=" "$SNAPSHOT" || true; printf '%s=%s\n' "$1" "$2"; } > "$tmp"
  chmod 600 "$tmp"; mv -f -- "$tmp" "$SNAPSHOT"
}

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

# Shared by the menu and the `import` subcommand.
# Usage: import_conf_path SRC [force]
import_conf_path() {
  local src=$1 force=${2:-} base
  if [[ ! -f $src || $src != *.conf ]]; then
    err "Not a readable .conf file: $src"
    return 1
  fi
  base=$(basename -- "$src")
  if [[ -e $CONFS_DIR/$base && $force != force ]]; then
    if confirm_tty; then
      local a
      read -r -p "$base already exists. Overwrite? [y/N]: " a || return 0
      [[ $a =~ ^[yYsS]$ ]] || { warn "Cancelled."; return 3; }
    else
      err "$base already exists. Use --force to overwrite."
      return 1
    fi
  fi
  install -m 600 -- "$src" "$CONFS_DIR/$base"
  ok "Imported into $CONFS_DIR/$base"
  CONF=$base; save_settings; ok "Selected: $CONF"
}

import_conf() {
  local src
  read -r -e -p "Path to the .conf to import (Enter to cancel): " src || return 0
  [[ -z $src ]] && return 0
  src=${src/#\~/$HOME}
  import_conf_path "$src" || { (( $? == 3 )) && return 0; return 1; }
  local rm_src
  read -r -p "Delete the original at $src? [y/N]: " rm_src || return 0
  if [[ $rm_src =~ ^[yYsS]$ ]]; then rm -f -- "$src"; ok "Original deleted."; fi
}

# Change the connection name without orphaning the NM connection.
# Usage: change_name NEW   (non-TTY stdin defaults to rename)
change_name() {
  local new=$1 old=$NAME choice="r"
  [[ $new == "$old" ]] && return 0
  if conn_exists_named "$old"; then
    if confirm_tty; then
      read -r -p "Connection \"$old\" exists in NetworkManager. [r]ename it / [d]elete it / [k]eep it? [R/d/k]: " choice || return 0
      choice=${choice:-r}
    fi
    case "$choice" in
      [rR])
        if nmcli connection modify "$old" connection.id "$new"; then
          NAME=$new; save_settings; snapshot_set NAME "$new"
          ok "Connection renamed: \"$old\" -> \"$new\""
        else
          err "Could not rename the connection; name unchanged."; return 1
        fi ;;
      [dD])
        "$APPLY" -n "$old" --delete || { err "Could not delete \"$old\"; name unchanged."; return 1; }
        NAME=$new; save_settings
        ok "Name: $NAME (old connection deleted)" ;;
      [kK])
        NAME=$new; save_settings
        warn "Old connection \"$old\" remains in NetworkManager."
        ok "Name: $NAME" ;;
      *) warn "Cancelled."; return 0 ;;
    esac
  else
    NAME=$new; save_settings; ok "Name: $NAME"
  fi
}

# Shared validation + persistence, used by the menu setters and `set`.
apply_name() {
  local v=$1
  [[ -n $v ]] || { err "Name cannot be empty."; return 1; }
  if [[ $v != "$NAME" ]] && conn_exists_named "$v"; then
    err "A different NetworkManager connection is already named \"$v\"."
    return 1
  fi
  change_name "$v"
}

apply_iface() {
  valid_iface "$1" || { err "Invalid interface name."; return 1; }
  IFACE=$1; save_settings; ok "Interface: $IFACE"
  if conn_exists_named "$NAME"; then
    warn "Connection \"$NAME\" already exists: the new interface takes effect after apply."
  fi
}

apply_resolver() {
  valid_resolver "$1" || { err "Invalid resolver."; return 1; }
  RESOLVER=$1; save_settings; ok "Resolver: $RESOLVER"
}

# Prints 1/0 for on|off|1|0|yes|no|true|false; fails otherwise.
parse_bool() {
  case "${1,,}" in
    on|1|yes|true)  printf '1' ;;
    off|0|no|false) printf '0' ;;
    *) return 1 ;;
  esac
}

# Usage: apply_bool discover|autoconnect VALUE
apply_bool() {
  local b
  b=$(parse_bool "$2") || { err "Invalid value \"$2\" (use on/off, 1/0, yes/no)."; return 1; }
  case "$1" in
    discover)    DISCOVER=$b;    save_settings; ok "Subdomain discovery: $(yesno "$DISCOVER")" ;;
    autoconnect) AUTOCONNECT=$b; save_settings; ok "Autoconnect: $(yesno "$AUTOCONNECT")" ;;
  esac
}

set_name() {
  local v
  read -r -p "Connection name [$NAME]: " v || return 0
  [[ -z $v ]] && return 0
  apply_name "$v" || true
}

set_iface() {
  local v
  read -r -p "Interface name, max 15 chars [$IFACE]: " v || return 0
  [[ -z $v ]] && return 0
  apply_iface "$v" || true
}

set_resolver() {
  local v
  read -r -p "DNS resolver IP or 'system' [$RESOLVER]: " v || return 0
  [[ -z $v ]] && return 0
  apply_resolver "$v" || true
}

toggle_discover() {
  apply_bool discover "$(( 1 - DISCOVER ))"
}

toggle_autoconnect() {
  apply_bool autoconnect "$(( 1 - AUTOCONNECT ))"
}

# `set` subcommand. No args: print values. Usage: cmd_set [KEY VALUE]
cmd_set() {
  if (( $# == 0 )); then
    printf 'name=%s\niface=%s\nresolver=%s\ndiscover=%s\nautoconnect=%s\n' \
      "$NAME" "$IFACE" "$RESOLVER" "$(yesno "$DISCOVER")" "$(yesno "$AUTOCONNECT")"
    return 0
  fi
  if (( $# != 2 )); then
    err "Usage: $0 set [name|iface|resolver|discover|autoconnect VALUE]"; return 1
  fi
  case "$1" in
    name)             apply_name "$2" ;;
    iface)            apply_iface "$2" ;;
    resolver)         apply_resolver "$2" ;;
    discover|autoconnect) apply_bool "$1" "$2" ;;
    *) err "Unknown key: $1 (use name, iface, resolver, discover, autoconnect)"; return 1 ;;
  esac
}

# Usage: do_apply [--dry-run|-n] [--verbose|-v] [--refresh-discovery]
do_apply() {
  local dry=0 verbose=0 refresh=0 a
  for a in "$@"; do
    case "$a" in
      --dry-run|-n)  dry=1 ;;
      --verbose|-v)  verbose=1 ;;
      --refresh-discovery) refresh=1 ;;
      *) err "Unknown apply option: $a (use --dry-run, --verbose, --refresh-discovery)"; return 1 ;;
    esac
  done
  require_conf || return 1
  local -a uargs=(-c "$CONFS_DIR/$CONF" --resolver "$RESOLVER")
  (( DISCOVER )) || uargs+=(--no-discover)
  (( dry )) && uargs+=(--dry-run)
  (( verbose )) && uargs+=(--verbose)
  (( refresh )) && uargs+=(--refresh-discovery)
  local -a aargs=(-n "$NAME" -i "$IFACE")
  (( AUTOCONNECT )) && aargs+=(--autoconnect)

  printf '\n%sGenerating split tunnel from %s...%s\n' "$B" "$CONF" "$N"
  "$UPDATE" "${uargs[@]}" || { err "Generation failed."; return 1; }
  if (( dry )); then
    ok "Dry run: NetworkManager not touched, snapshot not written."
    return 0
  fi
  printf '\n%sApplying to NetworkManager as "%s"...%s\n' "$B" "$NAME" "$N"
  "$APPLY" "${aargs[@]}" || { err "Apply failed."; return 1; }
  write_snapshot
  ok "Done."
}

# Open domains.txt in the editor; offer to apply if it changed.
do_edit() {
  local file=$ROOT_DIR/domains.txt before after ed=${VISUAL:-${EDITOR:-nano}} a
  [[ -e $file ]] || : > "$file"
  before=$(domains_sha)
  # shellcheck disable=SC2086
  $ed "$file" || { err "Editor exited with an error."; return 1; }
  after=$(domains_sha)
  if [[ $before == "$after" ]]; then
    ok "domains.txt unchanged."
    return 0
  fi
  ok "domains.txt changed."
  if confirm_tty; then
    read -r -p "Apply now? [y/N]: " a || return 0
    if [[ $a =~ ^[yYsS]$ ]]; then do_apply; fi
  else
    warn "Not interactive: run apply to use the new domains."
  fi
}

do_toggle() {
  if is_active; then do_down; else do_up; fi
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
  local pend
  pend=$(has_pending_changes)
  case "$pend" in
    yes)   pend="${Y}yes — run apply${N}" ;;
    never) pend="never applied" ;;
  esac
  printf '  Pending      : %s\n' "$pend"
  local gen="$WG_HOME/generated/split-tunnel.conf" n_ips="(not generated)" gen_at="never" tip=""
  if [[ -r $gen ]]; then
    n_ips=$(awk -F= 'tolower($1) ~ /^[[:space:]]*allowedips[[:space:]]*$/ {
        v=$0; sub(/^[^=]*=/, "", v); k=split(v, a, ",")
        for (i=1;i<=k;i++) { gsub(/[[:space:]]/, "", a[i]); if (a[i] != "") c++ } }
      END {print c+0}' "$gen" 2>/dev/null || true)
    n_ips="${n_ips:-0} entries"
    gen_at=$(date -r "$gen" '+%Y-%m-%d %H:%M' 2>/dev/null || true)
    gen_at=${gen_at:-unknown}
  fi
  printf '  AllowedIPs   : %s\n' "$n_ips"
  printf '  Generated    : %s\n' "$gen_at"
  if command -v nmcli >/dev/null 2>&1 && is_active; then
    tip=$(nmcli -g IP4.ADDRESS connection show "$NAME" 2>/dev/null | head -n1 || true)
    [[ -n $tip ]] && printf '  Tunnel IP    : %s\n' "$tip"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# verify / doctor
# ---------------------------------------------------------------------------
# Prints the interface used to reach IP (stubbable).
route_dev() {
  ip route get "$1" 2>/dev/null | awk '{for(i=1;i<NF;i++) if($i=="dev"){print $(i+1); exit}}'
}

# Prints the first exact domain in domains.txt.
first_domain() {
  local line
  [[ -r $ROOT_DIR/domains.txt ]] || return 1
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%%#*}
    line=${line//[[:space:]]/}
    line=${line#*://}; line=${line%%/*}
    [[ -n $line && $line != *'*'* ]] || continue
    [[ $line =~ ^[0-9.]+(:[0-9]+)?$ || $line == *:* ]] && continue
    [[ $line =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && $line == *.* ]] || continue
    printf '%s\n' "$line"; return 0
  done < "$ROOT_DIR/domains.txt"
  return 1
}

resolve_v4() {
  local ip=""
  if command -v dig >/dev/null 2>&1; then
    ip=$(dig +short A "$1" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' | head -n1 || true)
  fi
  if [[ -z $ip ]] && command -v getent >/dev/null 2>&1; then
    ip=$(getent ahostsv4 "$1" 2>/dev/null | awk '{print $1; exit}' || true)
  fi
  printf '%s' "$ip"
}

do_verify() {
  local fail=0 domain ip dev ctrl=9.9.9.9
  if ! command -v nmcli >/dev/null 2>&1 || ! is_active; then
    err "Connection \"$NAME\" is not active. Connect first (up)."
    return 1
  fi
  domain=$(first_domain) || domain=""
  if [[ -z $domain ]]; then
    printf '%s✗%s no exact domain found in domains.txt\n' "$R" "$N"; fail=1
  else
    ip=$(resolve_v4 "$domain")
    if [[ -z $ip ]]; then
      printf '%s✗%s %s: could not resolve\n' "$R" "$N" "$domain"; fail=1
    else
      dev=$(route_dev "$ip")
      if [[ $dev == "$IFACE" ]]; then
        printf '%s✓%s %s (%s) -> %s\n' "$G" "$N" "$domain" "$ip" "$dev"
      else
        printf '%s✗%s %s (%s) -> %s (expected %s)\n' "$R" "$N" "$domain" "$ip" "${dev:-unknown}" "$IFACE"; fail=1
      fi
    fi
  fi
  if grep -qF -- "$ctrl" "$WG_HOME/generated/split-tunnel.conf" 2>/dev/null; then
    printf '%s-%s control %s is listed in AllowedIPs, skipped\n' "$Y" "$N" "$ctrl"
  else
    dev=$(route_dev "$ctrl")
    if [[ -n $dev && $dev != "$IFACE" ]]; then
      printf '%s✓%s control %s -> %s (outside the tunnel)\n' "$G" "$N" "$ctrl" "$dev"
    else
      printf '%s✗%s control %s -> %s (should not use %s)\n' "$R" "$N" "$ctrl" "${dev:-unknown}" "$IFACE"; fail=1
    fi
  fi
  return "$fail"
}

do_doctor() {
  local fail=0
  have() { command -v "$1" >/dev/null 2>&1; }
  chk() { # chk NAME REQUIRED(1/0) CONSEQUENCE TEST...
    local name=$1 req=$2 msg=$3; shift 3
    if "$@"; then
      printf '%s✓%s %s\n' "$G" "$N" "$name"
    else
      printf '%s✗%s %s — %s\n' "$R" "$N" "$name" "$msg"
      (( req )) && fail=1
    fi
    return 0
  }
  chk nmcli 1 "required: cannot create or manage the connection" have nmcli
  chk "$(basename -- "$UPDATE")" 1 "required: cannot generate the split tunnel" test -x "$UPDATE"
  chk "$(basename -- "$APPLY")" 1 "required: cannot apply to NetworkManager" test -x "$APPLY"
  chk dig 0 "falls back to slower getent" have dig
  chk curl 0 "no Certificate Transparency subdomain discovery" have curl
  chk jq 0 "no Certificate Transparency subdomain discovery" have jq
  chk ip 0 "verify unavailable" have ip
  return "$fail"
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

  ${B}Settings${N}
    ${B}c)${N} Select source .conf        ${B}n)${N} Connection name
    ${B}f)${N} Interface name             ${B}r)${N} DNS resolver
    ${B}s)${N} Toggle subdomain discovery ${B}o)${N} Toggle autoconnect (on login)
  ${B}Actions${N}
    ${B}a)${N} Generate + apply            ${B}u)${N} Connect
    ${B}d)${N} Disconnect                  ${B}t)${N} Toggle connection
    ${B}v)${N} Verify routing
  ${B}Files & tools${N}
    ${B}e)${N} Edit domains                ${B}i)${N} Import a .conf
    ${B}x)${N} Delete connection           ${B}h)${N} Doctor (check tools)
    ${B}q)${N} Quit

EOF
    read -r -p "Option: " c || { printf '\n'; return 0; }
    case "${c,,}" in
      c) select_conf || true ;;
      n) set_name ;;
      f) set_iface ;;
      r) set_resolver ;;
      s) toggle_discover ;;
      o) toggle_autoconnect ;;
      a) do_apply || true; pause ;;
      u) do_up || true ;;
      d) do_down || true ;;
      t) do_toggle || true ;;
      v) do_verify || true; pause ;;
      e) do_edit || true ;;
      i) import_conf || true ;;
      x) do_delete || true ;;
      h) do_doctor || true; pause ;;
      q) return 0 ;;
      "") ;;
      *) err "Invalid option." ;;
    esac
  done
}

usage() {
  cat <<EOF
Usage: ${0##*/} [COMMAND]

Commands:
  menu                   Open the interactive menu (default)
  apply [--dry-run] [--verbose] [--refresh-discovery]
                         Generate and apply with saved settings
                         (--dry-run generates only: no NetworkManager change)
  set [KEY VALUE]        Show settings, or set name|iface|resolver|discover|autoconnect
                         (discover/autoconnect accept on/off, 1/0, yes/no)
  edit | domains         Edit domains.txt; offers to apply if it changed
  toggle                 Connect if inactive, disconnect if active
  up                     Connect
  down                   Disconnect
  status                 Show settings, connection state and pending changes
  use FILE.conf          Select a .conf from the secure folder
  import PATH [--force]  Copy a .conf into the secure folder and select it
  verify                 Check routes: first domain via the tunnel, a control host outside
  doctor                 Check required and optional tools
  help                   Show this help
EOF
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------
case "${1:-menu}" in
  doctor|help|-h|--help) ;;
  *) [[ -x $UPDATE && -x $APPLY ]] || { err "update-split-tunnel.sh / apply-split-tunnel-kde.sh not found or not executable."; exit 1; } ;;
esac

load_settings

case "${1:-menu}" in
  menu)    menu ;;
  apply)   shift; do_apply "$@" ;;
  set)     shift; cmd_set "$@" ;;
  edit|domains) do_edit ;;
  toggle)  do_toggle ;;
  up)      do_up ;;
  down)    do_down ;;
  status)  show_settings ;;
  verify)  do_verify ;;
  doctor)  do_doctor ;;
  import)
    force=""; ipath=""
    shift
    for arg in "$@"; do
      case "$arg" in
        --force) force=force ;;
        *) ipath=$arg ;;
      esac
    done
    [[ -n $ipath ]] || { err "Usage: $0 import PATH.conf [--force]"; exit 1; }
    import_conf_path "$ipath" "$force" || { rc=$?; (( rc == 3 )) && exit 0; exit "$rc"; } ;;
  use)
    [[ -n ${2:-} ]] || { err "Usage: $0 use FILE.conf"; exit 1; }
    f=$(basename -- "$2")
    [[ -r $CONFS_DIR/$f ]] || { err "Not a valid source .conf: $2"; exit 1; }
    CONF=$f; save_settings; ok "Selected: $CONF" ;;
  -h|--help|help) usage ;;
  *) err "Unknown command: $1 (use --help)"; exit 1 ;;
esac
