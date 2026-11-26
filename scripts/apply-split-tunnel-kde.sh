#!/usr/bin/env bash
#
# apply-split-tunnel-kde.sh
#
# Aplica la configuración generada por update-split-tunnel.sh en KDE Plasma
# usando NetworkManager (el backend que usa el applet de red de Plasma).
#
# Uso:
#   ./apply-split-tunnel-kde.sh
#   ./apply-split-tunnel-kde.sh --status
#   ./apply-split-tunnel-kde.sh --delete
#
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# Private files (WireGuard keys) live in confs/ and generated/ (gitignored).
WG_HOME="${WG_SPLIT_HOME:-$ROOT_DIR}"
CONFS_DIR="$WG_HOME/confs"
GENERATED_DIR="$WG_HOME/generated"

CONFIG="$GENERATED_DIR/split-tunnel.conf"
NAME="surfshark VPN"
IFACE="surfshark-split"
AUTOCONNECT=0
ACTIVATE=1
ALLOW_FULL=0
ACTION="apply"

log()  { printf '[+] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Uso: apply-split-tunnel-kde.sh [opciones]

Crea o actualiza una conexión WireGuard en NetworkManager (KDE Plasma) a
partir de la configuración generada por update-split-tunnel.sh.

Opciones:
  -c, --config ARCHIVO   Configuración WireGuard generada
                         (por defecto: split-tunnel.conf).
  -n, --name NOMBRE      Nombre de la conexión en NetworkManager
                         (por defecto: wg-split).
  -i, --interface IFACE  Nombre de la interfaz WireGuard (máx. 15 caracteres,
                         por defecto: wg-split).
      --autoconnect      Conectar automáticamente al iniciar sesión.
      --no-activate      Crear/actualizar sin activar la conexión ahora.
      --allow-full-tunnel
                         Permitir una configuración con 0.0.0.0/0 o ::/0.
                         Por seguridad se rechaza por defecto.
      --status           Mostrar estado de la conexión.
      --delete           Eliminar la conexión de NetworkManager.
  -h, --help             Mostrar esta ayuda.

La conexión aparecerá en el applet de red de KDE Plasma. Para el túnel
dividido no se configura DNS de la VPN: las consultas DNS siguen saliendo por
la conexión normal, igual que el resto del tráfico no incluido en AllowedIPs.
EOF
}

need_arg() {
  (( $# >= 2 )) || die "Falta el argumento de $1"
}

while (( $# )); do
  case "$1" in
    -c|--config)  need_arg "$@"; CONFIG=$2; shift 2 ;;
    -n|--name)    need_arg "$@"; NAME=$2; shift 2 ;;
    -i|--interface) need_arg "$@"; IFACE=$2; shift 2 ;;
    --autoconnect) AUTOCONNECT=1; shift ;;
    --no-activate) ACTIVATE=0; shift ;;
    --allow-full-tunnel) ALLOW_FULL=1; shift ;;
    --status) ACTION="status"; shift ;;
    --delete) ACTION="delete"; shift ;;
    -h|--help) usage; exit 0 ;;
    *) die "Opción desconocida: $1 (usa --help)" ;;
  esac
done

[[ -n $NAME ]] || die "El nombre de la conexión no puede estar vacío"
[[ $IFACE =~ ^[A-Za-z0-9_.-]+$ ]] || die "Nombre de interfaz inválido: $IFACE"
(( ${#IFACE} <= 15 )) || die "La interfaz debe tener 15 caracteres o menos: $IFACE"
[[ $IFACE != "." && $IFACE != ".." ]] || die "Nombre de interfaz inválido: $IFACE"

command -v nmcli >/dev/null 2>&1 || die "nmcli no está instalado (paquete network-manager)"
if ! nmcli -t -f RUNNING general >/dev/null 2>&1; then
  die "NetworkManager no está disponible"
fi
if [[ "$(nmcli -t -f RUNNING general 2>/dev/null)" != "running" ]]; then
  die "NetworkManager no está en ejecución"
fi

show_status() {
  local iface
  if ! nmcli connection show "$NAME" >/dev/null 2>&1; then
    printf 'La conexión "%s" no existe en NetworkManager.\n' "$NAME"
    return 0
  fi

  printf 'Conexión: %s\n' "$NAME"
  nmcli -g connection.id,connection.interface-name,connection.autoconnect,GENERAL.STATE,IP4.ADDRESS,IP6.ADDRESS \
    connection show "$NAME" 2>/dev/null || true

  iface=$(nmcli -g connection.interface-name connection show "$NAME" 2>/dev/null || true)
  if [[ -z $iface || $iface == "--" ]]; then iface=$IFACE; fi

  if command -v ip >/dev/null 2>&1 && ip link show "$iface" >/dev/null 2>&1; then
    printf '\nInterfaz %s:\n' "$iface"
    ip -brief addr show "$iface"
    printf '\nRutas IPv4:\n'
    ip route show dev "$iface" 2>/dev/null | head -n 20 || true
    printf '\nRutas IPv6:\n'
    ip -6 route show dev "$iface" 2>/dev/null | head -n 20 || true
  fi
}

if [[ $ACTION == "status" ]]; then
  show_status
  exit 0
fi

if [[ $ACTION == "delete" ]]; then
  if nmcli connection show "$NAME" >/dev/null 2>&1; then
    nmcli connection down "$NAME" >/dev/null 2>&1 || true
    nmcli connection delete "$NAME" >/dev/null
    log "Conexión '$NAME' eliminada de NetworkManager."
  else
    warn "La conexión '$NAME' no existe."
  fi
  exit 0
fi

[[ -r "$CONFIG" ]] || die "No se puede leer $CONFIG. Ejecuta primero update-split-tunnel.sh"

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Lectura y validación de la configuración
# ---------------------------------------------------------------------------
PRIVATE_KEY=""
ADDRESS=""
PUBLIC_KEY=""
ALLOWED_IPS=""
ENDPOINT=""
HAS_DNS=0
SECTION=""

while IFS= read -r raw || [[ -n $raw ]]; do
  line=${raw%$'\r'}
  line=$(trim "$line")
  if [[ -z $line || $line == \#* || $line == \;* ]]; then
    continue
  fi

  if [[ $line =~ ^\[([^]]+)\]$ ]]; then
    SECTION=${BASH_REMATCH[1],,}
    continue
  fi

  [[ $line == *=* ]] || continue
  key=$(trim "${line%%=*}")
  val=${line#*=}
  val=${val%%#*}
  val=$(trim "$val")
  key=${key,,}

  case "$SECTION" in
    interface)
      case "$key" in
        privatekey) PRIVATE_KEY=$val ;;
        address)
          if [[ -n $ADDRESS ]]; then ADDRESS+=", $val"; else ADDRESS=$val; fi
          ;;
        dns) HAS_DNS=1 ;;
      esac
      ;;
    peer)
      case "$key" in
        publickey) PUBLIC_KEY=$val ;;
        endpoint) ENDPOINT=$val ;;
        allowedips)
          if [[ -n $ALLOWED_IPS ]]; then ALLOWED_IPS+=", $val"; else ALLOWED_IPS=$val; fi
          ;;
      esac
      ;;
  esac
done < "$CONFIG"

[[ -n $PRIVATE_KEY ]] || die "Falta PrivateKey en $CONFIG"
[[ -n $ADDRESS ]]     || die "Falta Address en $CONFIG"
[[ -n $PUBLIC_KEY ]]  || die "Falta PublicKey en $CONFIG"
[[ -n $ENDPOINT ]]    || die "Falta Endpoint en $CONFIG"
[[ -n $ALLOWED_IPS ]] || die "Falta AllowedIPs en $CONFIG"

ALLOWED_IPS=$(sed -E 's/[[:space:]]*,[[:space:]]*/,/g' <<< "$ALLOWED_IPS")
ALLOWED_IPS=${ALLOWED_IPS%,}
[[ -n $ALLOWED_IPS ]] || die "AllowedIPs está vacío en $CONFIG"
ADDRESS=$(sed -E 's/[[:space:]]*,[[:space:]]*/,/g' <<< "$ADDRESS")
ADDRESS=${ADDRESS%,}

HAS_IPV4=0
HAS_IPV6=0
IFS=',' read -r -a addr_parts <<< "$ADDRESS"
for addr in "${addr_parts[@]}"; do
  addr=${addr%/*}
  if [[ $addr =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    HAS_IPV4=1
  elif [[ $addr == *:* ]]; then
    HAS_IPV6=1
  fi
done
(( HAS_IPV4 || HAS_IPV6 )) || die "Address no contiene ninguna IP válida: $ADDRESS"

FULL_TUNNEL=0
IFS=',' read -r -a allowed_parts <<< "$ALLOWED_IPS"
for cidr in "${allowed_parts[@]}"; do
  cidr=$(trim "$cidr")
  if [[ $cidr == "0.0.0.0/0" || $cidr == "::/0" ]]; then
    FULL_TUNNEL=1
  fi
done

if (( FULL_TUNNEL && ! ALLOW_FULL )); then
  die "La configuración contiene 0.0.0.0/0 o ::/0 (túnel completo). Ejecuta update-split-tunnel.sh o usa --allow-full-tunnel si es intencional."
fi
if (( FULL_TUNNEL )); then
  warn "Túnel completo permitido por --allow-full-tunnel: no es una configuración split."
fi
if (( HAS_DNS )); then
  warn "El DNS de $CONFIG se elimina al importar: el DNS de la VPN no funciona en split tunnel."
fi

if (( FULL_TUNNEL )); then
  NEVER_DEFAULT="no"
  AUTO_DEFAULT="1"
else
  NEVER_DEFAULT="yes"
  AUTO_DEFAULT="0"
fi
if (( AUTOCONNECT )); then
  AUTOCONNECT_STR="yes"
else
  AUTOCONNECT_STR="no"
fi

# ---------------------------------------------------------------------------
# Importación en NetworkManager (backend de KDE Plasma)
# ---------------------------------------------------------------------------
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/apply-split.XXXXXX")
TMP_CONN="wgsplit$RANDOM"
while nmcli connection show "$TMP_CONN" >/dev/null 2>&1; do
  TMP_CONN="wgsplit$RANDOM"
done
TMP_CONF="$TMP_DIR/$TMP_CONN.conf"

# Se elimina DNS (y claves propias de wg-quick que NetworkManager no usa).
sed -E \
  -e '/^[[:space:]]*DNS[[:space:]]*=/Id' \
  -e '/^[[:space:]]*(Table|SaveConfig|PreUp|PostUp|PreDown|PostDown|FwMark)[[:space:]]*=/Id' \
  "$CONFIG" > "$TMP_CONF"
chmod 600 "$TMP_CONF"

FINALIZED=0
cleanup() {
  rm -rf -- "$TMP_DIR"
  if (( FINALIZED == 0 )); then
    nmcli connection delete "$TMP_CONN" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

log "Importando $CONFIG en NetworkManager..."
if ! nmcli connection import type wireguard file "$TMP_CONF" >/dev/null 2>&1; then
  die "No se pudo importar la configuración WireGuard en NetworkManager"
fi

# La importación puede autoconectar; se detiene para aplicar los ajustes.
nmcli connection down "$TMP_CONN" >/dev/null 2>&1 || true

log "Aplicando ajustes de split tunnel..."
IPV4_METHOD=$(nmcli -g ipv4.method connection show "$TMP_CONN" 2>/dev/null || true)
IPV6_METHOD=$(nmcli -g ipv6.method connection show "$TMP_CONN" 2>/dev/null || true)

MODIFY_ARGS=(
  connection.autoconnect "$AUTOCONNECT_STR"
  wireguard.peer-routes yes
)
if [[ $IPV4_METHOD != "disabled" && $IPV4_METHOD != "--" && $IPV4_METHOD != "" ]]; then
  MODIFY_ARGS+=(
    ipv4.never-default "$NEVER_DEFAULT"
    ipv4.ignore-auto-dns yes
    wireguard.ip4-auto-default-route "$AUTO_DEFAULT"
  )
fi
if [[ $IPV6_METHOD != "disabled" && $IPV6_METHOD != "--" && $IPV6_METHOD != "" ]]; then
  MODIFY_ARGS+=(
    ipv6.never-default "$NEVER_DEFAULT"
    ipv6.ignore-auto-dns yes
    wireguard.ip6-auto-default-route "$AUTO_DEFAULT"
  )
fi

if ! nmcli connection modify "$TMP_CONN" "${MODIFY_ARGS[@]}" >/dev/null; then
  die "No se pudieron aplicar los ajustes a la conexión"
fi

nmcli connection down "$TMP_CONN" >/dev/null 2>&1 || true

if nmcli connection show "$NAME" >/dev/null 2>&1; then
  log "Reemplazando la conexión existente '$NAME'..."
  nmcli connection down "$NAME" >/dev/null 2>&1 || true
  nmcli connection delete "$NAME" >/dev/null
fi

nmcli connection modify "$TMP_CONN" connection.id "$NAME" >/dev/null
nmcli connection modify "$NAME" connection.interface-name "$IFACE" >/dev/null
FINALIZED=1

if (( ACTIVATE )); then
  log "Activando '$NAME'..."
  if ! nmcli connection up "$NAME" >/dev/null; then
    die "La conexión se creó, pero no se pudo activar. Revisa el endpoint y el estado en el applet de red."
  fi
  log "Conexión activa: $NAME (interfaz $IFACE)"
else
  log "Conexión creada/actualizada sin activar: $NAME (interfaz $IFACE)"
fi

log "Disponible en el applet de red de KDE Plasma (NetworkManager)."
log "Estado: $(nmcli -g GENERAL.STATE connection show "$NAME" 2>/dev/null || echo desconocido)"
