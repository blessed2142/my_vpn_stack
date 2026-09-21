#!/usr/bin/env bash
# Базовая подготовка сервера: пакеты, sysctl/BBR, время, firewall.
set -euo pipefail

hdr "Подготовка системы ($OS_PRETTY)"

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
setup_firewall() {
    local sshp awgport
    sshp=$(ssh_ports | tr ' ' ',' | sed 's/,$//')
    awgport="${AWG_PORT:-51820}"

    log "Настраиваю nftables (SSH порты: ${sshp})..."
    [ -f /etc/nftables.conf ] && [ ! -f /etc/nftables.conf.vpnstack-bak ] \
        && cp /etc/nftables.conf /etc/nftables.conf.vpnstack-bak

    cat > /etc/nftables.conf <<NFT
#!/usr/sbin/nft -f
# Сгенерировано vpnstack. Бэкап предыдущего: /etc/nftables.conf.vpnstack-bak
flush ruleset

table inet filter {
    chain input {
        type filter hook input priority filter; policy drop;

        ct state established,related accept
        ct state invalid drop
        iif lo accept
        iifname "${AWG_IFACE:-awg0}" accept

        ip protocol icmp accept
        ip6 nexthdr icmpv6 accept

        tcp dport { ${sshp} } accept comment "SSH"
        tcp dport 80 accept comment "ACME/HTTP-01"
        tcp dport ${VLESS_PORT:-443} accept comment "VLESS REALITY"
        udp dport ${HY2_PORT:-443} accept comment "Hysteria2"
        udp dport ${awgport} accept comment "AmneziaWG"
    }

    chain forward {
        type filter hook forward priority filter; policy drop;
        tcp flags syn / syn,rst tcp option maxseg size set rt mtu comment "MSS clamp"
        ct state established,related accept
        iifname "${AWG_IFACE:-awg0}" accept
        oifname "${AWG_IFACE:-awg0}" accept
    }

    chain output {
        type filter hook output priority filter; policy accept;
    }
}

table inet nat {
    chain postrouting {
        type nat hook postrouting priority srcnat; policy accept;
        ip saddr ${AWG_NET4_PREFIX:-10.8.2}.0/24 oifname != "${AWG_IFACE:-awg0}" masquerade
        ip6 saddr ${AWG_NET6_PREFIX:-fd42:2142:2142}::/64 oifname != "${AWG_IFACE:-awg0}" masquerade
    }
}
NFT

    if nft -c -f /etc/nftables.conf; then
        systemctl enable nftables >/dev/null 2>&1 || true
        systemctl restart nftables
        ok "Firewall включён (открыты: SSH ${sshp}, 80/tcp, ${VLESS_PORT:-443}/tcp, ${HY2_PORT:-443}/udp, ${awgport}/udp)."
    else
        err "Правила nftables не прошли проверку — firewall НЕ применён."
        [ -f /etc/nftables.conf.vpnstack-bak ] && cp /etc/nftables.conf.vpnstack-bak /etc/nftables.conf
        return 1
    fi

    # ufw/firewalld могут конфликтовать
    if systemctl is-enabled --quiet ufw 2>/dev/null; then
        warn "Обнаружен ufw — отключаю, чтобы не конфликтовал с nftables."
        ufw --force disable >/dev/null 2>&1 || true
        systemctl disable --now ufw >/dev/null 2>&1 || true
    fi
    if systemctl is-enabled --quiet firewalld 2>/dev/null; then
        warn "Обнаружен firewalld — отключаю."
        systemctl disable --now firewalld >/dev/null 2>&1 || true
    fi
}

if [ "${SETUP_FIREWALL:-1}" = "1" ]; then
    setup_firewall || warn "Firewall не настроен — сервисы всё равно будут работать."
else
    warn "Firewall пропущен (--no-firewall)."
fi

ok "Система подготовлена."
