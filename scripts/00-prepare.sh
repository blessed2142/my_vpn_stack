#!/usr/bin/env bash
# Базовая подготовка сервера: пакеты, sysctl/BBR, время, firewall.
set -euo pipefail

hdr "Подготовка системы ($OS_PRETTY)"

. "${VPNSTACK_DIR:-/opt/vpnstack}/lib/firewall.sh"

ensure_dns || warn "Продолжаю, но скачивание пакетов может не сработать."

log "Обновляю индекс пакетов и ставлю зависимости..."
pkg_update
case "$PKG" in
    apt) pkg_install ca-certificates curl wget jq openssl qrencode iproute2 nftables \
                     dnsutils gnupg lsb-release chrony unzip tar git ;;
    dnf) pkg_install ca-certificates curl wget jq openssl qrencode iproute nftables \
                     bind-utils gnupg2 chrony unzip tar git ;;
esac
systemctl enable --now chrony chronyd 2>/dev/null || true
ok "Зависимости установлены."

# ----------------------------------------------------------------- sysctl
log "Применяю сетевые параметры (BBR, форвардинг, буферы UDP для QUIC)..."
cat > /etc/sysctl.d/99-vpnstack.conf <<'SYS'
# --- форвардинг для VPN ---
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
net.ipv6.conf.default.forwarding = 1

# Включение forwarding заставляет ядро игнорировать Router Advertisement,
# и на серверах, получающих IPv6 через SLAAC, пропадает маршрут по умолчанию
# (а вместе с ним DNS, если резолверы указаны по IPv6). accept_ra=2 возвращает
# приём RA при включённом форвардинге.
net.ipv6.conf.all.accept_ra = 2
net.ipv6.conf.default.accept_ra = 2

# --- перегрузка/очередь: BBR + fq ---
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr

# --- буферы: критично для Hysteria2/QUIC на высоких скоростях ---
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.core.rmem_default = 1048576
net.core.wmem_default = 1048576
net.ipv4.tcp_rmem = 4096 1048576 16777216
net.ipv4.tcp_wmem = 4096 1048576 16777216

# --- прочее ---
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.core.netdev_max_backlog = 16384
net.ipv4.tcp_max_syn_backlog = 8192
fs.file-max = 1000000
SYS
sysctl --system >/dev/null 2>&1 || true

if [ "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)" = "bbr" ]; then
    ok "BBR активен."
else
    warn "BBR не включился (ядро без tcp_bbr?) — не критично, всё будет работать."
fi

# лимит открытых файлов для сервисов
mkdir -p /etc/systemd/system.conf.d
cat > /etc/systemd/system.conf.d/99-vpnstack-limits.conf <<'LIM'
[Manager]
DefaultLimitNOFILE=1000000
LIM
systemctl daemon-reexec 2>/dev/null || true

# ----------------------------------------------------------------- firewall
if [ "${SETUP_FIREWALL:-1}" = "1" ]; then
    setup_firewall || warn "Firewall не настроен — сервисы всё равно будут работать."
else
    warn "Firewall пропущен (--no-firewall)."
fi

ok "Система подготовлена."
