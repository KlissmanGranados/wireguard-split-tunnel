#!/usr/bin/env bash
#
# update-split-tunnel.sh
#
# Toma una configuración WireGuard (.conf) y una lista de dominios/CIDRs,
# resuelve las IPs actuales y genera una configuración NUEVA con AllowedIPs
# limitado a esos destinos. El .conf original nunca se modifica.
#
# Uso:
#   ./update-split-tunnel.sh
#   ./update-split-tunnel.sh -c wg-US-FREE-10.conf -d domains.txt -o split-tunnel.conf
#
set -euo pipefail
umask 077

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
ROOT_DIR=$(cd -- "$SCRIPT_DIR/.." && pwd)
# Private files (WireGuard keys) live in confs/ and generated/ (gitignored).
WG_HOME="${WG_SPLIT_HOME:-$ROOT_DIR}"
CONFS_DIR="$WG_HOME/confs"
GENERATED_DIR="$WG_HOME/generated"

CONFIG=""
DOMAINS="$ROOT_DIR/domains.txt"
OUTPUT="$GENERATED_DIR/split-tunnel.conf"
DISCOVER=1
REFRESH_DISCOVERY=0
FILTER_PRIVATE=1
DRY_RUN=0
VERBOSE=0
MAX_DISCOVER=200
DISCOVERY_JOBS=2
DISCOVERY_TTL_MIN=1440
# Resolver DNS público: evita que el DNS de la red local (DNS filtrado,
# overrides de LAN) devuelva IPs privadas y deje destinos fuera de AllowedIPs.
RESOLVER="1.1.1.1"
JOBS=$(nproc 2>/dev/null || echo 8)
if (( JOBS > 16 )); then JOBS=16; fi
if (( JOBS < 1 )); then JOBS=1; fi

# Subdominios habituales que se prueban al usar comodines. El descubrimiento
# por Certificate Transparency añade los que realmente existen.
COMMON_SUBDOMAINS=(
  www api app chat auth login id accounts oauth sso
  cdn static assets files uploads images media video download
  edge gateway ws realtime search ab codex sora learn operator
  status support help docs blog shop mail vpn dev staging test beta
)

TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/update-split.XXXXXX")
TMP_OUT=""
cleanup() {
  if [[ -n "$TMP_OUT" && -f "$TMP_OUT" ]]; then
    rm -f -- "$TMP_OUT"
  fi
  rm -rf -- "$TMP_DIR"
}
trap cleanup EXIT

log()  { printf '[+] %s\n' "$*" >&2; }
warn() { printf '[!] %s\n' "$*" >&2; }
die()  { printf '[x] %s\n' "$*" >&2; exit 1; }
debug(){ if (( VERBOSE )); then printf '[d] %s\n' "$*" >&2; fi; }

usage() {
  cat <<'EOF'
Uso: update-split-tunnel.sh [opciones]

Genera una configuración WireGuard de túnel dividido (split tunnel) a partir
de un .conf y de una lista de dominios/CIDRs.

Opciones:
  -c, --config ARCHIVO    Configuración WireGuard de origen.
                          Si se omite, se autodetecta el único *.conf del
                          carpeta confs/ del proyecto.
  -d, --domains ARCHIVO   Lista de dominios/CIDRs (por defecto domains.txt).
  -o, --output ARCHIVO    Configuración generada (por defecto split-tunnel.conf).
      --discover          Descubrir subdominios con Certificate Transparency
                          (por defecto: activado).
      --no-discover       No consultar servicios externos de descubrimiento.
      --refresh-discovery Ignorar la caché local de subdominios descubiertos.
      --no-filter-private No descartar IPs privadas/reservadas resueltas.
      --resolver IP       Servidor DNS usado para resolver los dominios
                          (por defecto: 1.1.1.1). Usa "system" para el DNS
                          del sistema, que puede devolver IPs de la LAN.
      --jobs N            Consultas DNS en paralelo (por defecto: hasta 16).
  -n, --dry-run           Mostrar la configuración por stdout sin escribirla.
  -v, --verbose           Mostrar más detalles.
  -h, --help              Mostrar esta ayuda.

Formato de domains.txt:
  - Un dominio/CIDR por línea; se admiten comentarios con #.
  - Dominio exacto:      api.example.com
  - Comodín:             *.example.com  o  *.example.com*
  - CIDR explícito:      160.79.104.0/23
  - IP suelta:           1.2.3.4

Notas:
  - Los comodines se expanden con subdominios habituales y, si está activado
    el descubrimiento, con nombres vistos en Certificate Transparency.
  - El DNS del .conf se elimina a propósito: en split tunnel el DNS de la VPN
    no es alcanzable y rompería la resolución.
  - Vuelve a ejecutar este script cuando cambien las IPs de los dominios.
EOF
}

need_arg() {
  (( $# >= 2 )) || die "Falta el argumento de $1"
}

while (( $# )); do
  case "$1" in
    -c|--config)   need_arg "$@"; CONFIG=$2; shift 2 ;;
    -d|--domains)  need_arg "$@"; DOMAINS=$2; shift 2 ;;
    -o|--output)   need_arg "$@"; OUTPUT=$2; shift 2 ;;
    --discover)    DISCOVER=1; shift ;;
    --no-discover) DISCOVER=0; shift ;;
    --refresh-discovery) REFRESH_DISCOVERY=1; shift ;;
    --no-filter-private) FILTER_PRIVATE=0; shift ;;
    --resolver)    need_arg "$@"; RESOLVER=$2; shift 2 ;;
    --jobs)        need_arg "$@"; JOBS=$2; shift 2 ;;
    -n|--dry-run)  DRY_RUN=1; shift ;;
    -v|--verbose)  VERBOSE=1; shift ;;
    -h|--help)     usage; exit 0 ;;
    *)             die "Opción desconocida: $1 (usa --help)" ;;
  esac
done

[[ $JOBS =~ ^[0-9]+$ ]] || die "--jobs debe ser un número"
(( JOBS >= 1 )) || die "--jobs debe ser mayor que 0"
[[ $RESOLVER == system || $RESOLVER =~ ^[A-Za-z0-9.:-]+$ ]] || die "--resolver inválido: $RESOLVER"

# Autodetecta el .conf de origen si no se indicó uno.
if [[ -z "$CONFIG" ]]; then
  shopt -s nullglob
  candidates=("$CONFS_DIR"/*.conf)
  shopt -u nullglob

  filtered=()
  for f in "${candidates[@]}"; do
    base=$(basename -- "$f")
    if [[ "$base" == "$(basename -- "$OUTPUT")" || "$base" == "split-tunnel.conf" ]]; then
      continue
    fi
    filtered+=("$f")
  done

  case ${#filtered[@]} in
    1) CONFIG=${filtered[0]} ;;
    0) die "No hay ningún .conf en $CONFS_DIR. Usa -c ARCHIVO." ;;
    *) die "Hay varios .conf en $CONFS_DIR. Usa -c ARCHIVO: ${filtered[*]##*/}" ;;
  esac
fi

[[ -r "$CONFIG" ]]  || die "No se puede leer la configuración: $CONFIG"
[[ -r "$DOMAINS" ]] || die "No se puede leer la lista de dominios: $DOMAINS"
[[ -s "$DOMAINS" ]] || die "La lista de dominios está vacía: $DOMAINS"

if [[ -e "$OUTPUT" ]] && [[ "$(realpath -m -- "$OUTPUT")" == "$(realpath -m -- "$CONFIG")" ]]; then
  die "La salida no puede ser el mismo archivo que la configuración de origen"
fi

trim() {
  local s=$1
  s=${s#"${s%%[![:space:]]*}"}
  s=${s%"${s##*[![:space:]]}"}
  printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Validación de IPs / CIDRs
# ---------------------------------------------------------------------------
is_ipv4() {
  local ip=$1 a b c d
  [[ $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || return 1
  IFS=. read -r a b c d <<< "$ip"
  (( 10#$a <= 255 && 10#$b <= 255 && 10#$c <= 255 && 10#$d <= 255 ))
}

is_ipv6_groups() {
  local part=$1 n
  if [[ -z $part ]]; then return 0; fi
  [[ $part =~ ^[0-9a-f]{1,4}(:[0-9a-f]{1,4})*$ ]] || return 1
  n=$(awk -F: '{print NF}' <<< "$part")
  (( n <= 7 ))
}

is_ipv6() {
  local ip=${1,,} left right ln=0 rn=0
  [[ $ip == *:* ]] || return 1
  [[ $ip =~ ^[0-9a-f:]+$ ]] || return 1

  if [[ $ip == *::* ]]; then
    [[ $ip != *:::* ]] || return 1
    left=${ip%%::*}
    right=${ip#*::}
    if [[ $right == *::* ]]; then return 1; fi
    is_ipv6_groups "$left" || return 1
    is_ipv6_groups "$right" || return 1
    if [[ -n $left ]]; then ln=$(awk -F: '{print NF}' <<< "$left"); fi
    if [[ -n $right ]]; then rn=$(awk -F: '{print NF}' <<< "$right"); fi
    (( ln + rn <= 7 )) || return 1
    return 0
  fi

  [[ $ip =~ ^([0-9a-f]{1,4}:){7}[0-9a-f]{1,4}$ ]]
}

is_ipv4_cidr() {
  local cidr=$1 ip prefix
  [[ $cidr == */* ]] || return 1
  ip=${cidr%/*}
  prefix=${cidr#*/}
  is_ipv4 "$ip" || return 1
  [[ $prefix =~ ^[0-9]+$ ]] || return 1
  (( 10#$prefix >= 0 && 10#$prefix <= 32 ))
}

is_ipv6_cidr() {
  local cidr=$1 ip prefix
  [[ $cidr == */* ]] || return 1
  ip=${cidr%/*}
  prefix=${cidr#*/}
  is_ipv6 "$ip" || return 1
  [[ $prefix =~ ^[0-9]+$ ]] || return 1
  (( 10#$prefix >= 0 && 10#$prefix <= 128 ))
}

is_public_ipv4() {
  local ip=$1 a b c d
  IFS=. read -r a b c d <<< "$ip"
  if (( 10#$a == 0 || 10#$a == 10 || 10#$a == 127 || 10#$a >= 224 )); then return 1; fi
  if (( 10#$a == 100 && 10#$b >= 64 && 10#$b <= 127 )); then return 1; fi
  if (( 10#$a == 169 && 10#$b == 254 )); then return 1; fi
  if (( 10#$a == 172 && 10#$b >= 16 && 10#$b <= 31 )); then return 1; fi
  if (( 10#$a == 192 && 10#$b == 168 )); then return 1; fi
  if (( 10#$a == 192 && 10#$b == 0 && 10#$c == 0 )); then return 1; fi
  if (( 10#$a == 192 && 10#$b == 0 && 10#$c == 2 )); then return 1; fi
  if (( 10#$a == 198 && (10#$b == 18 || 10#$b == 19) )); then return 1; fi
  if (( 10#$a == 198 && 10#$b == 51 && 10#$c == 100 )); then return 1; fi
  if (( 10#$a == 203 && 10#$b == 0 && 10#$c == 113 )); then return 1; fi
  return 0
}

is_public_ipv6() {
  local ip=${1,,}
  if [[ $ip == "::" || $ip == "::1" ]]; then return 1; fi
  if [[ $ip == fc* || $ip == fd* ]]; then return 1; fi
  if [[ $ip == fe8* || $ip == fe9* || $ip == fea* || $ip == feb* ]]; then return 1; fi
  if [[ $ip == ff* ]]; then return 1; fi
  if [[ $ip == 2001:db8* ]]; then return 1; fi
  return 0
}

is_hostname() {
  local h=$1 label
  [[ -n $h && ${#h} -le 253 ]] || return 1
  [[ $h =~ ^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$ ]] || return 1
  if [[ $h == *..* ]]; then return 1; fi
  local IFS=.
  read -r -a labels <<< "$h"
  for label in "${labels[@]}"; do
    [[ ${#label} -le 63 ]] || return 1
    [[ $label =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || return 1
  done
  return 0
}

# ---------------------------------------------------------------------------
# Lectura del .conf de origen
# ---------------------------------------------------------------------------
PRIVATE_KEY=""
ADDRESS=""
LISTEN_PORT=""
MTU=""
PEER_PUB=""
PRESHARED_KEY=""
ENDPOINT=""
KEEPALIVE="25"
HAS_DNS=0
PEER_COUNT=0
SECTION=""

while IFS= read -r raw || [[ -n $raw ]]; do
  line=${raw%$'\r'}
  line=$(trim "$line")
  if [[ -z $line || $line == \#* || $line == \;* ]]; then
    continue
  fi

  if [[ $line =~ ^\[([^]]+)\]$ ]]; then
    SECTION=${BASH_REMATCH[1],,}
    if [[ $SECTION == "peer" ]]; then
      PEER_COUNT=$((PEER_COUNT + 1))
      (( PEER_COUNT == 1 )) || die "Solo se admite un [Peer] en $CONFIG"
    fi
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
        listenport) LISTEN_PORT=$val ;;
        mtu)        MTU=$val ;;
        dns)        HAS_DNS=1 ;;
        *)          debug "Ignorando Interface.$key" ;;
      esac
      ;;
    peer)
      case "$key" in
        publickey)          PEER_PUB=$val ;;
        presharedkey)       PRESHARED_KEY=$val ;;
        endpoint)           ENDPOINT=$val ;;
        persistentkeepalive) KEEPALIVE=$val ;;
        allowedips)         debug "AllowedIPs original será reemplazado" ;;
        *)                  debug "Ignorando Peer.$key" ;;
      esac
      ;;
    *) debug "Sección desconocida [$SECTION]" ;;
  esac
done < "$CONFIG"

[[ -n $PRIVATE_KEY ]] || die "Falta PrivateKey en [Interface] de $CONFIG"
[[ -n $ADDRESS ]]     || die "Falta Address en [Interface] de $CONFIG"
[[ -n $PEER_PUB ]]    || die "Falta PublicKey en [Peer] de $CONFIG"
[[ -n $ENDPOINT ]]    || die "Falta Endpoint en [Peer] de $CONFIG"
[[ $KEEPALIVE =~ ^[0-9]+$ ]] || KEEPALIVE=25
[[ -z $LISTEN_PORT || $LISTEN_PORT =~ ^[0-9]+$ ]] || die "ListenPort inválido"
[[ -z $MTU || $MTU =~ ^[0-9]+$ ]] || die "MTU inválido"
(( HAS_DNS == 0 )) || warn "El DNS de $CONFIG se omitirá en la configuración generada"

ADDRESS=$(sed -E 's/[[:space:]]*,[[:space:]]*/,/g' <<< "$ADDRESS")
ADDRESS=${ADDRESS%,}

HAS_IPV4_ADDR=0
HAS_IPV6_ADDR=0
IFS=',' read -r -a addr_parts <<< "$ADDRESS"
for addr in "${addr_parts[@]}"; do
  addr=${addr%/*}
  if is_ipv4 "$addr"; then
    HAS_IPV4_ADDR=1
  elif is_ipv6 "$addr"; then
    HAS_IPV6_ADDR=1
  fi
done
(( HAS_IPV4_ADDR || HAS_IPV6_ADDR )) || die "Address no contiene ninguna IP válida: $ADDRESS"

# ---------------------------------------------------------------------------
# Lista de dominios / CIDRs
# ---------------------------------------------------------------------------
declare -A HOST_SEEN=()
declare -A CIDR_SEEN=()
HOSTS=()
CIDRS=()

add_cidr() {
  local cidr=$1
  [[ -n $cidr ]] || return 0
  if [[ $cidr == *:* ]]; then
    (( HAS_IPV6_ADDR )) || return 0
  else
    (( HAS_IPV4_ADDR )) || return 0
  fi
  if [[ -n ${CIDR_SEEN[$cidr]+x} ]]; then return 0; fi
  CIDR_SEEN[$cidr]=1
  CIDRS+=("$cidr")
}

add_host() {
  local h=$1
  h=${h%.}
  h=${h,,}
  [[ -n $h ]] || return 0
  if ! is_hostname "$h"; then
    warn "Host inválido, se ignora: $h"
    return 0
  fi
  if [[ -n ${HOST_SEEN[$h]+x} ]]; then return 0; fi
  HOST_SEEN[$h]=1
  HOSTS+=("$h")
}

wildcard_base() {
  local p=$1
  p=${p#\*.}
  p=${p#\*}
  p=${p%\*}
  p=${p#.}
  p=${p%.}
  if [[ $p == *'*'* ]]; then
    p=${p##*\*.}
    p=${p##*\*}
  fi
  printf '%s' "$p"
}

DISCOVERY_CACHE="$TMP_DIR/discovery"
DISCOVERY_CACHE_DIR="$ROOT_DIR/.cache/discovery"
mkdir -p "$DISCOVERY_CACHE" "$DISCOVERY_CACHE_DIR"

fetch_certspotter() {
  local base=$1
  curl -fsS --connect-timeout 3 --max-time 8 \
    "https://api.certspotter.com/v1/issuances?domain=${base}&include_subdomains=true&expand=dns_names" \
    2>/dev/null |
    jq -r '.[].dns_names[]?' 2>/dev/null || true
}

fetch_hackertarget() {
  local base=$1
  curl -fsS --connect-timeout 3 --max-time 8 \
    "https://api.hackertarget.com/hostsearch/?q=${base}" \
    2>/dev/null |
    cut -d, -f1 || true
}

fetch_subdomain_center() {
  local base=$1
  curl -fsS --connect-timeout 3 --max-time 8 \
    "https://api.subdomain.center/?domain=${base}" \
    2>/dev/null |
    jq -r '.[]?' 2>/dev/null || true
}

fetch_crtsh() {
  local base=$1
  curl -fsS --connect-timeout 3 --max-time 8 \
    "https://crt.sh/?q=%25.${base}&output=json" \
    2>/dev/null |
    jq -r '.[].name_value?' 2>/dev/null || true
}

discover_hosts() {
  local base=$1 raw=""
  if ! command -v curl >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
    warn "curl/jq no disponibles; no se descubren subdominios de $base"
    return 0
  fi

  debug "Descubriendo subdominios de $base..."
  raw=$(fetch_certspotter "$base")
  if [[ -z $raw ]]; then raw=$(fetch_hackertarget "$base"); fi
  if [[ -z $raw ]]; then raw=$(fetch_subdomain_center "$base"); fi
  if [[ -z $raw ]]; then raw=$(fetch_crtsh "$base"); fi

  if [[ -z $raw ]]; then
    warn "No se pudieron descubrir subdominios de $base"
    return 0
  fi

  printf '%s\n' "$raw" | tr '[:upper:]' '[:lower:]' \
    | tr ',' '\n' \
    | sed -e 's/\\n/\n/g' -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' -e 's/^\*\.//' \
    | grep -E '^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$' \
    | grep -E "\\.${base//./\\.}$" \
    | LC_ALL=C sort -u \
    | head -n "$MAX_DISCOVER"
}

discover_cached() {
  local base=$1 f="$DISCOVERY_CACHE/${base}.txt"
  if [[ ! -f $f ]]; then
    discover_hosts "$base" > "$f" 2>/dev/null || true
  fi
  cat "$f"
}

expand_wildcard() {
  local pattern=$1 base host sub
  [[ $pattern =~ ^[a-z0-9*._-]+$ ]] || die "Patrón de comodín inválido: $pattern"

  base=$(wildcard_base "$pattern")
  if [[ -z $base ]] || [[ $base != *.* ]] || ! is_hostname "$base"; then
    warn "No se puede derivar un dominio base de '$pattern'; se ignora"
    return 0
  fi

  # Un patrón que empieza por * también incluye el dominio base.
  if [[ $pattern == \** ]]; then
    add_host "$base"
  fi

  for sub in "${COMMON_SUBDOMAINS[@]}"; do
    host="$sub.$base"
    if [[ $host == $pattern ]]; then
      add_host "$host"
    fi
  done

  if (( DISCOVER )); then
    while IFS= read -r host; do
      host=${host%.}
      [[ -n $host ]] || continue
      if [[ $host == $pattern ]]; then
        add_host "$host"
      fi
    done < <(discover_cached "$base")
  fi
}

process_entry() {
  local token=$1 maybe
  token=$(trim "$token")
  [[ -n $token ]] || return 0
  token=${token,,}

  if [[ $token == http://* || $token == https://* ]]; then
    token=${token#*://}
    token=${token%%/*}
    token=${token%%\?*}
    token=${token%%#*}
  fi

  # Quita :puerto de un host/IPv4 (no de una IPv6, que tiene varios ':').
  if [[ $token == *:* && $token != *:*:* ]]; then
    token=${token%%:*}
  fi
  token=${token%.}

  if [[ $token == *'*'* ]]; then
    expand_wildcard "$token"
  elif [[ $token == */* ]]; then
    if is_ipv4_cidr "$token"; then
      if (( HAS_IPV4_ADDR )); then add_cidr "$token"; else warn "Se ignora $token: no hay Address IPv4"; fi
    elif is_ipv6_cidr "$token"; then
      if (( HAS_IPV6_ADDR )); then add_cidr "$token"; else warn "Se ignora $token: no hay Address IPv6"; fi
    else
      maybe=${token%%/*}
      if is_hostname "$maybe"; then
        add_host "$maybe"
      else
        warn "CIDR/ruta inválida, se ignora: $token"
      fi
    fi
  elif is_ipv4 "$token"; then
    if (( HAS_IPV4_ADDR )); then add_cidr "$token/32"; else warn "Se ignora $token: no hay Address IPv4"; fi
  elif is_ipv6 "$token"; then
    if (( HAS_IPV6_ADDR )); then add_cidr "$token/128"; else warn "Se ignora $token: no hay Address IPv6"; fi
  else
    add_host "$token"
  fi
}

mapfile -t DOMAIN_LINES < "$DOMAINS"

# Primera pasada: recoger los dominios base de los comodines y descubrir sus
# subdominios en paralelo (si el descubrimiento está activado).
declare -A BASE_SEEN=()
WILDCARD_BASES=()
for raw in "${DOMAIN_LINES[@]}"; do
  line=${raw%$'\r'}
  line=${line%%#*}
  line=$(trim "$line")
  [[ -n $line ]] || continue
  read -r -a tokens <<< "${line//,/ }"
  for token in "${tokens[@]}"; do
    token=$(trim "$token")
    token=${token,,}
    [[ $token == *'*'* ]] || continue
    base=$(wildcard_base "$token")
    if [[ -n $base && $base == *.* ]] && is_hostname "$base"; then
      if [[ -z ${BASE_SEEN[$base]+x} ]]; then
        BASE_SEEN[$base]=1
        WILDCARD_BASES+=("$base")
      fi
    fi
  done
done

if (( DISCOVER )) && (( ${#WILDCARD_BASES[@]} > 0 )); then
  log "Descubriendo subdominios para ${#WILDCARD_BASES[@]} dominios base..."
  discovery_running=0
  for base in "${WILDCARD_BASES[@]}"; do
    persistent="$DISCOVERY_CACHE_DIR/${base}.txt"
    target="$DISCOVERY_CACHE/${base}.txt"

    # La caché persistente guarda nombres de subdominios (no IPs). Las IPs se
    # resuelven de nuevo en cada ejecución.
    if (( ! REFRESH_DISCOVERY )) && [[ -s $persistent ]] &&
       [[ -n "$(find "$persistent" -mmin -"$DISCOVERY_TTL_MIN" -print -quit 2>/dev/null)" ]]; then
      cp -f -- "$persistent" "$target"
      continue
    fi

    (
      tmp=$(mktemp "${target}.tmp.XXXXXX")
      discover_hosts "$base" > "$tmp" 2>/dev/null || true
      if [[ -s $tmp ]]; then
        mv -f -- "$tmp" "$target"
        ptmp=$(mktemp "${persistent}.tmp.XXXXXX")
        cp -f -- "$target" "$ptmp"
        mv -f -- "$ptmp" "$persistent"
      else
        rm -f -- "$tmp"
        if [[ -s $persistent ]]; then
          cp -f -- "$persistent" "$target"
        else
          : > "$target"
        fi
      fi
    ) &

    discovery_running=$((discovery_running + 1))
    if (( discovery_running >= DISCOVERY_JOBS )); then
      wait -n || true
      discovery_running=$((discovery_running - 1))
    fi
  done
  wait || true
fi

log "Procesando $DOMAINS..."
for raw in "${DOMAIN_LINES[@]}"; do
  line=${raw%$'\r'}
  line=${line%%#*}
  line=$(trim "$line")
  [[ -n $line ]] || continue
  read -r -a tokens <<< "${line//,/ }"
  for token in "${tokens[@]}"; do
    process_entry "$token"
  done
done

log "Entradas: ${#HOSTS[@]} hosts, ${#CIDRS[@]} CIDRs/IPs explícitas"

# ---------------------------------------------------------------------------
# Resolución DNS
# ---------------------------------------------------------------------------
resolve_hosts() {
  local line host

  if command -v dig >/dev/null 2>&1; then
    printf '%s\n' "${HOSTS[@]}" |
      xargs -r -P "$JOBS" -n 1 bash -c '
        h=$2
        srv=()
        if [[ -n $1 && $1 != system ]]; then srv=("@$1"); fi
        dig +short +time=2 +tries=1 "${srv[@]}" A "$h" 2>/dev/null || true
        dig +short +time=2 +tries=1 "${srv[@]}" AAAA "$h" 2>/dev/null || true
      ' _ "$RESOLVER" |
      while IFS= read -r line; do
        line=$(trim "$line")
        [[ -n $line ]] || continue
        if is_ipv4 "$line"; then
          (( HAS_IPV4_ADDR )) || continue
          if (( FILTER_PRIVATE )) && ! is_public_ipv4 "$line"; then continue; fi
          printf '%s/32\n' "$line"
        elif is_ipv6 "$line"; then
          (( HAS_IPV6_ADDR )) || continue
          if (( FILTER_PRIVATE )) && ! is_public_ipv6 "$line"; then continue; fi
          printf '%s/128\n' "$line"
        fi
      done
  else
    warn "dig no está instalado; usando getent (más lento, ignora --resolver)"
    for host in "${HOSTS[@]}"; do
      timeout 5 getent ahosts "$host" 2>/dev/null | cut -d' ' -f1 || true
    done | while IFS= read -r line; do
      line=$(trim "$line")
      [[ -n $line ]] || continue
      if is_ipv4 "$line"; then
        (( HAS_IPV4_ADDR )) || continue
        if (( FILTER_PRIVATE )) && ! is_public_ipv4 "$line"; then continue; fi
        printf '%s/32\n' "$line"
      elif is_ipv6 "$line"; then
        (( HAS_IPV6_ADDR )) || continue
        if (( FILTER_PRIVATE )) && ! is_public_ipv6 "$line"; then continue; fi
        printf '%s/128\n' "$line"
      fi
    done
  fi
}

if (( ${#HOSTS[@]} > 0 )); then
  log "Resolviendo ${#HOSTS[@]} hosts (paralelismo: $JOBS)..."
  RESOLVED_FILE="$TMP_DIR/resolved.txt"
  resolve_hosts > "$RESOLVED_FILE"
  while IFS= read -r cidr; do
    add_cidr "$cidr"
  done < "$RESOLVED_FILE"
else
  warn "No hay hosts que resolver; solo se usarán CIDRs explícitas"
fi

# ---------------------------------------------------------------------------
# Construcción de AllowedIPs
# ---------------------------------------------------------------------------
mapfile -t ALLOWED < <(
  {
    if (( ${#CIDRS[@]} > 0 )); then
      printf '%s\n' "${CIDRS[@]}"
    fi
  } | LC_ALL=C sort -u
)

(( ${#ALLOWED[@]} > 0 )) || die "No se resolvió ninguna IP. Revisa domains.txt y la conexión DNS."

ALLOWED_JOINED=""
V4=0
V6=0
for cidr in "${ALLOWED[@]}"; do
  if [[ $cidr == *:* ]]; then
    V6=$((V6 + 1))
  else
    V4=$((V4 + 1))
  fi
  if [[ -n $ALLOWED_JOINED ]]; then ALLOWED_JOINED+=", "; fi
  ALLOWED_JOINED+=$cidr
done

log "Destinos: ${#ALLOWED[@]} (IPv4: $V4, IPv6: $V6)"
if (( ${#ALLOWED[@]} > 500 )); then
  warn "Hay más de 500 destinos; la lista puede ser difícil de mantener."
fi
if (( VERBOSE )); then
  for cidr in "${ALLOWED[@]}"; do
    printf '[d]   %s\n' "$cidr" >&2
  done
fi

# ---------------------------------------------------------------------------
# Escritura de la configuración
# ---------------------------------------------------------------------------
generate_config() {
  printf '# Generado por %s el %s\n' "$(basename -- "$0")" "$(date -Is)"
  printf '# Fuente: %s\n' "$(basename -- "$CONFIG")"
  printf '# Dominios: %s\n' "$(basename -- "$DOMAINS")"
  printf '# Destinos permitidos: %d (IPv4: %d, IPv6: %d)\n' "${#ALLOWED[@]}" "$V4" "$V6"
  printf '# DNS omitido intencionalmente para split tunneling.\n'
  printf '\n[Interface]\n'
  printf 'PrivateKey = %s\n' "$PRIVATE_KEY"
  printf 'Address = %s\n' "$ADDRESS"
  if [[ -n $LISTEN_PORT ]]; then printf 'ListenPort = %s\n' "$LISTEN_PORT"; fi
  if [[ -n $MTU ]]; then printf 'MTU = %s\n' "$MTU"; fi
  printf '\n[Peer]\n'
  printf 'PublicKey = %s\n' "$PEER_PUB"
  if [[ -n $PRESHARED_KEY ]]; then printf 'PresharedKey = %s\n' "$PRESHARED_KEY"; fi
  printf 'AllowedIPs = %s\n' "$ALLOWED_JOINED"
  printf 'Endpoint = %s\n' "$ENDPOINT"
  printf 'PersistentKeepalive = %s\n' "$KEEPALIVE"
}

if (( DRY_RUN )); then
  generate_config
  exit 0
fi

OUT_DIR=$(dirname -- "$OUTPUT")
mkdir -p -- "$OUT_DIR"
TMP_OUT=$(mktemp "${OUT_DIR}/.split-tunnel.XXXXXX")
generate_config > "$TMP_OUT"
chmod 600 "$TMP_OUT"
mv -f -- "$TMP_OUT" "$OUTPUT"
TMP_OUT=""

log "Configuración actualizada: $OUTPUT"
log "Aplícala en KDE con: $(dirname -- "$0")/apply-split-tunnel-kde.sh"
