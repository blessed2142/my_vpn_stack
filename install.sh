#!/usr/bin/env bash
# ============================================================================
#  vpnstack — установка трёх VPN на один сервер:
#    1) VLESS + XTLS-Vision + REALITY  (Xray-core, TCP/443)
#    2) Hysteria 2                     (QUIC, UDP/443, обфускация Salamander)
#    3) AmneziaWG                      (обфусцированный WireGuard, UDP/51820)
#  Запускать на сервере от root.
# ============================================================================
set -euo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VPNSTACK_DIR="${VPNSTACK_DIR:-/opt/vpnstack}"
. "$SELF_DIR/lib/common.sh"

usage() {
cat <<USAGE
Использование: ./install.sh [опции]

  --domain <домен>        домен для Hysteria2/Let's Encrypt (напр. vpn.example.com)
  --email <email>         email для Let's Encrypt (по умолчанию admin@<домен>)
  --endpoint <хост|IP>    что писать клиентам как адрес сервера (по умолчанию: домен, иначе IPv4)
  --reality-sni <домен>   маскировочный сайт для REALITY (по умолчанию подбирается)
  --vless-port <порт>     TCP-порт VLESS REALITY (443)
  --hy2-port <порт>       UDP-порт Hysteria2 (443)
  --awg-port <порт>       UDP-порт AmneziaWG (51820)
  --client <имя>          имя первого клиента (по умолчанию: main)
  --only <список>         ставить только часть: base,xray,hysteria,awg (через запятую)
  --keep-hysteria         не трогать уже настроенную вручную Hysteria (порт возьмётся из её конфига)
  --hy2-cert <путь>       использовать свой TLS-сертификат для Hysteria2
  --hy2-key <путь>        ключ к нему
  --hy2-insecure          пометить сертификат как непроверяемый (insecure=1 в ссылке)
  --no-hy2-obfs           выключить обфускацию Salamander у Hysteria2
  --no-ipv6               не выдавать клиентам IPv6 внутри туннеля
  --no-firewall           не трогать nftables
  --no-torrent-block      не блокировать BitTorrent в VLESS
  -h, --help              эта справка

Примеры:
  ./install.sh --domain example.com --email me@example.com --client phone
  ./install.sh --keep-hysteria --client phone      # Hysteria уже стоит, ставим только VLESS и AmneziaWG
USAGE
}

# ------------------------------------------------------------------ аргументы
DOMAIN=""; EMAIL=""; ENDPOINT_ARG=""; SNI_ARG=""
VLESS_PORT_ARG=443; HY2_PORT_ARG=443; AWG_PORT_ARG=51820
FIRST_CLIENT="main"; ONLY="base,xray,hysteria,awg"
HY2_OBFS_ARG=1; IPV6_ARG=1; FW_ARG=1; BT_ARG=1
KEEP_HY2=0; HY2_CERT_ARG=""; HY2_KEY_ARG=""; HY2_INSECURE_ARG=0

while [ $# -gt 0 ]; do
    case "$1" in
        --domain) DOMAIN="$2"; shift 2 ;;
        --email) EMAIL="$2"; shift 2 ;;
        --endpoint) ENDPOINT_ARG="$2"; shift 2 ;;
        --reality-sni) SNI_ARG="$2"; shift 2 ;;
        --vless-port) VLESS_PORT_ARG="$2"; shift 2 ;;
        --hy2-port) HY2_PORT_ARG="$2"; shift 2 ;;
        --awg-port) AWG_PORT_ARG="$2"; shift 2 ;;
        --client) FIRST_CLIENT="$2"; shift 2 ;;
        --only) ONLY="$2"; shift 2 ;;
        --keep-hysteria) KEEP_HY2=1; shift ;;
        --hy2-cert) HY2_CERT_ARG="$2"; shift 2 ;;
        --hy2-key) HY2_KEY_ARG="$2"; shift 2 ;;
        --hy2-insecure) HY2_INSECURE_ARG=1; shift ;;
        --no-hy2-obfs) HY2_OBFS_ARG=0; shift ;;
        --no-ipv6) IPV6_ARG=0; shift ;;
        --no-firewall) FW_ARG=0; shift ;;
        --no-torrent-block) BT_ARG=0; shift ;;
        -h|--help) usage; exit 0 ;;
        *) err "Неизвестный аргумент: $1"; usage; exit 1 ;;
    esac
done

require_root
detect_os

printf '%s\n' "$C_BLD"
cat <<'BANNER'
 ┌────────────────────────────────────────────────────────┐
 │  vpnstack: VLESS REALITY + Hysteria2 + AmneziaWG       │
 └────────────────────────────────────────────────────────┘
BANNER
printf '%s' "$C_OFF"
log "Система: $OS_PRETTY ($(uname -r), $(uname -m))"

# ------------------------------------------------------------- копируем себя
if [ "$SELF_DIR" != "$VPNSTACK_DIR" ]; then
    mkdir -p "$VPNSTACK_DIR"
    cp -a "$SELF_DIR"/{lib,scripts,bin,install.sh} "$VPNSTACK_DIR"/ 2>/dev/null || true
fi
. "$VPNSTACK_DIR/lib/common.sh"
. "$VPNSTACK_DIR/lib/render.sh"
. "$VPNSTACK_DIR/lib/links.sh"
. "$VPNSTACK_DIR/lib/cert.sh"

mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
clients_init
state_load

# ------------------------------------------------------------- базовые факты
SERVER_IP4="$(detect_ipv4)"; SERVER_IP6="$(detect_ipv6)"
[ -n "$SERVER_IP4" ] || die "Не удалось определить внешний IPv4."
state_set SERVER_IP4 "$SERVER_IP4"
state_set SERVER_IP6 "$SERVER_IP6"
state_set WAN_IFACE "$(default_iface)"

[ -n "$DOMAIN" ] && state_set HY2_DOMAIN "$DOMAIN"
[ -n "$EMAIL" ] && state_set ACME_EMAIL "$EMAIL"
[ -z "${ACME_EMAIL:-}" ] && [ -n "${HY2_DOMAIN:-}" ] && state_set ACME_EMAIL "admin@${HY2_DOMAIN}"
[ -n "$SNI_ARG" ] && state_set REALITY_SNI "$SNI_ARG"

state_set VLESS_PORT "$VLESS_PORT_ARG"
state_set HY2_PORT   "$HY2_PORT_ARG"
state_set AWG_PORT   "$AWG_PORT_ARG"
state_set AWG_IFACE  "${AWG_IFACE:-awg0}"
state_set AWG_NET4_PREFIX "${AWG_NET4_PREFIX:-10.8.2}"
state_set AWG_NET6_PREFIX "${AWG_NET6_PREFIX:-fd42:2142:2142}"
state_set AWG_MTU "${AWG_MTU:-1420}"
state_set ENABLE_IPV6 "$IPV6_ARG"
state_set SETUP_FIREWALL "$FW_ARG"
state_set BLOCK_TORRENT "$BT_ARG"
state_set HY2_OBFS "$HY2_OBFS_ARG"
state_set HY2_MANAGED "$([ "$KEEP_HY2" = "1" ] && echo 0 || echo 1)"
if [ "$KEEP_HY2" = "1" ] && [ -s /etc/hysteria/config.yaml ]; then
    # порт нужен firewall'у, а он настраивается раньше этапа Hysteria — читаем сейчас
    p_detected=$(awk -F: '/^[[:space:]]*listen:/{gsub(/[^0-9]/,"",$NF); print $NF; exit}' /etc/hysteria/config.yaml)
    [ -n "$p_detected" ] && { state_set HY2_PORT "$p_detected"; log "Ваша Hysteria слушает UDP/${p_detected} — открою этот порт."; }
fi
[ -n "$HY2_CERT_ARG" ] && state_set HY2_CERT "$HY2_CERT_ARG"
[ -n "$HY2_KEY_ARG" ] && state_set HY2_KEY "$HY2_KEY_ARG"
state_set HY2_INSECURE_FORCE "$HY2_INSECURE_ARG"
state_set CLIENT_DNS4 "${CLIENT_DNS4:-1.1.1.1}"
state_set CLIENT_DNS6 "${CLIENT_DNS6:-2606:4700:4700::1111}"
state_set TAG_PREFIX "${TAG_PREFIX:-$(hostname -s 2>/dev/null || echo vpn)}"

if [ -n "$ENDPOINT_ARG" ]; then
    state_set ENDPOINT "$ENDPOINT_ARG"
elif [ -n "${HY2_DOMAIN:-}" ] && domain_points_here "${HY2_DOMAIN}" "$SERVER_IP4"; then
    state_set ENDPOINT "${HY2_DOMAIN}"
else
    state_set ENDPOINT "$SERVER_IP4"
fi
log "Клиенты будут подключаться на: ${ENDPOINT}"

[ "$VLESS_PORT" = "$HY2_PORT" ] && log "VLESS на TCP/${VLESS_PORT}, Hysteria2 на UDP/${HY2_PORT} — конфликта нет (разные протоколы)."

run_part() { case ",${ONLY}," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# Порт занят кем-то посторонним? Лучше сказать сразу, чем ловить молчаливый сбой.
port_owner() { # port_owner tcp|udp ПОРТ  -> имя процесса или пусто
    local f; [ "$1" = "tcp" ] && f=-lnt || f=-lnu
    ss -H "$f" -p 2>/dev/null | awk -v p="$2" '$4 ~ ("[:.]" p "$") {print $NF; exit}' \
        | sed -n 's/.*users:((\"\([^\"]*\)\".*/\1/p'
}
check_port() { # check_port tcp|udp ПОРТ ОЖИДАЕМЫЙ_ПРОЦЕСС ОПИСАНИЕ
    local owner; owner=$(port_owner "$1" "$2")
    [ -z "$owner" ] && return 0
    [ "$owner" = "$3" ] && { log "$4: порт $1/$2 уже занят своим же процессом ($owner) — это нормально."; return 0; }
    err "$4: порт $1/$2 занят процессом '$owner'."
    err "Освободите его, либо задайте другой порт (--vless-port / --hy2-port / --awg-port)."
    die "Установка остановлена, чтобы ничего не сломать."
}

run_part xray     && check_port tcp "$VLESS_PORT" xray     "VLESS REALITY"
[ "$KEEP_HY2" = "1" ] || { run_part hysteria && check_port udp "$HY2_PORT" hysteria "Hysteria2"; }

run_part base     && . "$VPNSTACK_DIR/scripts/00-prepare.sh"
run_part xray     && . "$VPNSTACK_DIR/scripts/10-xray-reality.sh"
run_part hysteria && . "$VPNSTACK_DIR/scripts/20-hysteria2.sh"
run_part awg      && . "$VPNSTACK_DIR/scripts/30-amneziawg.sh"

# ------------------------------------------------------------------ vpnctl
install -m 0755 "$VPNSTACK_DIR/bin/vpnctl" /usr/local/bin/vpnctl
ok "Установлена утилита: vpnctl"

# ------------------------------------------------------------ первый клиент
state_load
if ! client_exists "$FIRST_CLIENT"; then
    log "Создаю первого клиента '$FIRST_CLIENT'..."
    vpnctl add "$FIRST_CLIENT" --qr
else
    state_load; show_client "$FIRST_CLIENT" --qr
fi

hdr "Готово"
state_load
cat <<FIN
  Проверить состояние : vpnctl status
  Параметры сервера   : vpnctl info
  Добавить клиента    : vpnctl add <имя> --qr
  Все ссылки          : vpnctl links

  Конфиги клиентов лежат в ${STATE_DIR}/clients/<имя>/

  ВАЖНО, сделайте сейчас:
   1) смените пароль root:            passwd
   2) настройте вход по SSH-ключу и отключите вход по паролю
      (PasswordAuthentication no в /etc/ssh/sshd_config, затем systemctl restart ssh)
FIN
