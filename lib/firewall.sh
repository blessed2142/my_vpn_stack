#!/usr/bin/env bash
# Генерация и применение правил nftables. Общее для установщика и vpnctl:
# порт VLESS можно менять на ходу, и правила должны меняться вместе с ним.

setup_firewall() {
    local sshp awgport
    sshp=$(ssh_ports | tr ' ' ',' | sed 's/,$//')
    awgport="${AWG_PORT:-51820}"

    # Клиент выбирает размер своих пакетов по MSS, которое сервер объявляет в
    # SYN-ACK. Если по пути к серверу теряются крупные пакеты (битый PMTU у
    # провайдера), большое TLS-приветствие не доходит целиком, а мелкие пакеты
    # ходят нормально. Уменьшение MSS заставляет клиента резать приветствие.
    local MSS_RULE=""
    if [ -n "${MSS_CLAMP:-}" ]; then
        MSS_RULE="        tcp flags syn / syn,rst tcp option maxseg size set ${MSS_CLAMP}
"
        log "MSS для входящих соединений ограничен до ${MSS_CLAMP}."
    fi

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
${MSS_RULE}    }
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
        # Правило, отрезавшее сервер от сети, чинить потом по SSH уже нечем.
        if ip_reachability_ok; then
            ok "Firewall включён (открыты: SSH ${sshp}, 80/tcp, ${VLESS_PORT:-443}/tcp, ${HY2_PORT:-443}/udp, ${awgport}/udp)."
        else
            err "После включения firewall пропал доступ к сети по IP — откатываю правила."
            nft flush ruleset 2>/dev/null || true
            if [ -f /etc/nftables.conf.vpnstack-bak ]; then
                cp /etc/nftables.conf.vpnstack-bak /etc/nftables.conf
                nft -f /etc/nftables.conf 2>/dev/null || true
            fi
            return 1
        fi
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


# Слушающий порт и разрешённый в firewall должны совпадать. Разъезжаются они
# легко: например, порт меняли через ./install.sh --only xray, а правила
# остались от прошлого запуска. Снаружи это выглядит как "сервер не отвечает",
# при том что сам сервер подключается к себе нормально — трафик к самому себе
# идёт через lo и правила портов не проверяет.
check_port_allowed() { # check_port_allowed ПОРТ [tcp|udp]
    local port="$1" proto="${2:-tcp}"
    if ! nft list chain inet filter input >/dev/null 2>&1; then
        log "  nftables не настроен — правила не мешают."
        return 0
    fi
    local dports
    dports=$(nft list chain inet filter input 2>/dev/null \
        | grep -oE "${proto} dport [{ ]*[0-9, ]+" \
        | sed "s/${proto} dport//" | tr -d '{ ' | tr ',' '\n' | grep -E '^[0-9]+$' | sort -u)
    if printf '%s\n' "$dports" | grep -qx "$port"; then
        ok "  firewall: ${proto}/${port} разрешён"
        return 0
    fi
    err "  firewall: ${proto}/${port} НЕ разрешён — входящие соединения отбрасываются."
    echo "      Починить:  vpnctl firewall sync"
    return 1
}

# Перегенерирует правила под текущие порты из состояния.
sync_firewall() {
    setup_firewall || return 1
    return 0
}
