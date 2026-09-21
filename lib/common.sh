#!/usr/bin/env bash
# Общие функции для vpnstack. Подключается через source.

VPNSTACK_DIR="${VPNSTACK_DIR:-/opt/vpnstack}"
STATE_DIR="${STATE_DIR:-/etc/vpnstack}"
STATE_FILE="$STATE_DIR/state.env"
CLIENTS_FILE="$STATE_DIR/clients.json"

C_RED=$'\033[0;31m'; C_GRN=$'\033[0;32m'; C_YLW=$'\033[0;33m'
C_BLU=$'\033[0;36m'; C_BLD=$'\033[1m'; C_OFF=$'\033[0m'

log()  { printf '%s[*]%s %s\n' "$C_BLU" "$C_OFF" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$C_GRN" "$C_OFF" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YLW" "$C_OFF" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_OFF" "$*" >&2; }
die()  { err "$*"; exit 1; }
hdr()  { printf '\n%s== %s ==%s\n' "$C_BLD" "$*" "$C_OFF"; }

require_root() { [ "$(id -u)" -eq 0 ] || die "Запускать нужно от root."; }

detect_os() {
    [ -r /etc/os-release ] || die "Не найден /etc/os-release — дистрибутив не определён."
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_ID="${ID:-unknown}"
    OS_LIKE="${ID_LIKE:-}"
    OS_VER="${VERSION_ID:-}"
    OS_CODENAME="${VERSION_CODENAME:-}"
    OS_PRETTY="${PRETTY_NAME:-$OS_ID $OS_VER}"
    case "$OS_ID $OS_LIKE" in
        *debian*|*ubuntu*) PKG=apt ;;
        *rhel*|*fedora*|*centos*|*almalinux*|*rocky*) PKG=dnf ;;
        *) PKG="" ;;
    esac
    [ -n "$PKG" ] || die "Неподдерживаемый дистрибутив: $OS_PRETTY (нужен Debian/Ubuntu или RHEL-семейство)."
}

pkg_update() {
    case "$PKG" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get update -qq ;;
        dnf) dnf -q makecache ;;
    esac
}

pkg_install() {
    [ $# -gt 0 ] || return 0
    case "$PKG" in
        apt) DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" >/dev/null ;;
        dnf) dnf install -y -q "$@" >/dev/null ;;
    esac
}

have() { command -v "$1" >/dev/null 2>&1; }

rand_hex() { openssl rand -hex "${1:-8}"; }
rand_pass() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }
rand_int()  { # rand_int MIN MAX
    local min="$1" max="$2" span=$(( $2 - $1 + 1 ))
    echo $(( min + ( $(od -An -N4 -tu4 < /dev/urandom | tr -d ' ') % span ) ))
}

# --- состояние -------------------------------------------------------------
state_load() { [ -r "$STATE_FILE" ] && . "$STATE_FILE"; return 0; }

state_set() { # state_set KEY VALUE
    local k="$1" v="$2"
    mkdir -p "$STATE_DIR"; touch "$STATE_FILE"; chmod 600 "$STATE_FILE"
    if grep -q "^${k}=" "$STATE_FILE" 2>/dev/null; then
        sed -i "s|^${k}=.*|${k}='${v}'|" "$STATE_FILE"
    else
        printf "%s='%s'\n" "$k" "$v" >> "$STATE_FILE"
    fi
    export "$k=$v"
}

clients_init() {
    mkdir -p "$STATE_DIR"
    [ -s "$CLIENTS_FILE" ] || echo '{"clients":{}}' > "$CLIENTS_FILE"
    chmod 600 "$CLIENTS_FILE"
}

clients_names() { jq -r '.clients | keys[]' "$CLIENTS_FILE"; }
client_exists() { jq -e --arg n "$1" '.clients | has($n)' "$CLIENTS_FILE" >/dev/null; }
client_get() { jq -r --arg n "$1" --arg f "$2" '.clients[$n][$f] // empty' "$CLIENTS_FILE"; }

clients_write() { # читает новый json со stdin
    local tmp; tmp=$(mktemp)
    cat > "$tmp"
    jq -e . "$tmp" >/dev/null || { rm -f "$tmp"; die "Повреждён JSON клиентов."; }
    mv "$tmp" "$CLIENTS_FILE"; chmod 600 "$CLIENTS_FILE"
}

# --- сеть ------------------------------------------------------------------
detect_ipv4() {
    local ip
    ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    [ -n "$ip" ] || ip=$(curl -fsS --max-time 8 https://api.ipify.org 2>/dev/null || true)
    echo "$ip"
}

detect_ipv6() {
    local ip
    ip=$(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')
    echo "$ip"
}

default_iface() { ip -4 route show default | awk '{print $5; exit}'; }

ssh_ports() {
    local p
    p=$(awk '/^[[:space:]]*Port[[:space:]]+[0-9]+/{print $2}' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | sort -un | tr '\n' ' ')
    [ -n "${p// /}" ] || p="22"
    echo "$p"
}

svc_active() { systemctl is-active --quiet "$1"; }

# Проверка, что домен указывает на этот сервер
domain_points_here() { # domain ipv4
    local d="$1" ip="$2" resolved
    have dig && resolved=$(dig +short A "$d" 2>/dev/null | tail -n1)
    [ -n "${resolved:-}" ] || resolved=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1; exit}')
    [ -n "${resolved:-}" ] && [ "$resolved" = "$ip" ]
}
