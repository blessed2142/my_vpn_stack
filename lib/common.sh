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

# Жив ли IP-уровень — без участия DNS. Отделять обязательно: сломанный
# резолвинг не повод откатывать совершенно исправные правила firewall.
ip_reachability_ok() {
    local i
    for i in 1 2 3; do
        ping -c1 -W3 1.1.1.1 >/dev/null 2>&1 && return 0
        timeout 8 curl -fsS -o /dev/null --max-time 6 https://1.1.1.1/ 2>/dev/null && return 0
        sleep 2
    done
    return 1
}

dns_ok() { getent hosts "${1:-github.com}" >/dev/null 2>&1; }

# Жив ли выход наружу целиком: резолвинг имени и реальный HTTPS-запрос.
net_sanity_check() {
    local host="${1:-github.com}" i
    for i in 1 2 3; do
        dns_ok "$host" && timeout 12 curl -fsS -o /dev/null "https://${host}" 2>/dev/null && return 0
        sleep 2
    done
    return 1
}

# Чиним резолвинг. При systemd-resolved — через drop-in: /etc/resolv.conf там
# лишь ссылка на сгенерированный файл, и запись в него либо бесполезна, либо
# ломает конфигурацию resolved.
ensure_dns() {
    dns_ok && return 0
    warn "DNS не резолвит имена — пытаюсь починить."

    if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
        log "Прописываю публичные резолверы для systemd-resolved..."
        mkdir -p /etc/systemd/resolved.conf.d
        cat > /etc/systemd/resolved.conf.d/99-vpnstack.conf <<'RSLV'
# vpnstack: резервные резолверы, чтобы сервер не остался без DNS
[Resolve]
DNS=1.1.1.1 8.8.8.8 2606:4700:4700::1111
FallbackDNS=9.9.9.9 1.0.0.1
RSLV
        systemctl restart systemd-resolved 2>/dev/null || true
        sleep 2
        if dns_ok; then ok "DNS заработал (systemd-resolved)."; return 0; fi
        warn "systemd-resolved всё ещё не резолвит."
    fi

    if [ ! -L /etc/resolv.conf ]; then
        cp -a /etc/resolv.conf /etc/resolv.conf.vpnstack-bak 2>/dev/null || true
        printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
        if dns_ok; then ok "Добавил публичные резолверы в /etc/resolv.conf."; return 0; fi
    fi

    err "DNS не удалось починить автоматически. Смотрите: vpnctl diag (раздел «Сеть»)."
    return 1
}

# Ждёт, пока сервис не только «активен», но и реально занял свой порт.
# Сервисы вроде hysteria стартуют мгновенно, а падают через пару секунд
# (например, не получив сертификат), поэтому проверка сразу после restart врёт.
wait_service_ready() { # wait_service_ready ЮНИТ tcp|udp ПОРТ [СЕКУНД]
    local unit="$1" proto="$2" port="$3" t="${4:-25}" i=0 flag
    [ "$proto" = "tcp" ] && flag="-lnt" || flag="-lnu"
    while [ "$i" -lt "$t" ]; do
        svc_active "$unit" || return 1
        if ss -H $flag 2>/dev/null | awk '{print $4}' | grep -qE "[:.]${port}\$"; then
            sleep 2
            svc_active "$unit" && return 0 || return 1
        fi
        sleep 1; i=$((i + 1))
    done
    return 1
}

# Все A-записи домена. dig спрашиваем у публичного резолвера, чтобы не нарваться
# на устаревший локальный кэш; getent — запасной путь, он есть всегда.
resolve_a() { # resolve_a <домен>
    local d="$1" ips=""
    if have dig; then
        ips=$(dig +short +time=3 +tries=2 A "$d" @1.1.1.1 2>/dev/null | grep -E '^[0-9.]+$')
        [ -n "$ips" ] || ips=$(dig +short +time=3 +tries=2 A "$d" 2>/dev/null | grep -E '^[0-9.]+$')
    fi
    [ -n "$ips" ] || ips=$(getent ahostsv4 "$d" 2>/dev/null | awk '{print $1}' | sort -u)
    printf '%s\n' "$ips" | grep -E '^[0-9.]+$' || true
}

# Проверка, что домен указывает на этот сервер (годится любая из его A-записей)
domain_points_here() { # domain ipv4
    local d="$1" ip="$2" ips
    ips=$(resolve_a "$d")
    [ -n "$ips" ] || return 1
    printf '%s\n' "$ips" | grep -qx "$ip"
}
