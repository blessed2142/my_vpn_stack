#!/usr/bin/env bash
# Сборка клиентских ссылок/конфигов.

urlenc() { jq -rn --arg s "$1" '$s|@uri'; }

vless_link() { # vless_link NAME
    local name="$1" uuid
    uuid=$(client_get "$name" uuid); [ -n "$uuid" ] || return 1
    printf 'vless://%s@%s:%s?encryption=none&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp&flow=xtls-rprx-vision#%s\n' \
        "$uuid" "$ENDPOINT" "${VLESS_PORT:-443}" "$REALITY_SNI" \
        "$REALITY_PUBLIC_KEY" "$REALITY_SHORT_ID" "$(urlenc "${TAG_PREFIX:-VPN}-REALITY-$name")"
}

hy2_link() { # hy2_link NAME
    local name="$1" pass q
    pass=$(client_get "$name" hy2_pass); [ -n "$pass" ] || return 1
    q="sni=${HY2_SNI}"
    [ -n "${HY2_OBFS_PASS:-}" ] && q="${q}&obfs=salamander&obfs-password=$(urlenc "$HY2_OBFS_PASS")"
    if [ "${HY2_INSECURE:-0}" = "1" ]; then q="${q}&insecure=1"; fi
    printf 'hy2://%s:%s@%s:%s/?%s#%s\n' \
        "$(urlenc "$name")" "$(urlenc "$pass")" "$ENDPOINT" "${HY2_PORT:-443}" "$q" \
        "$(urlenc "${TAG_PREFIX:-VPN}-HY2-$name")"
}

awg_client_conf() { # awg_client_conf NAME
    local name="$1" priv psk ip4 ip6
    priv=$(client_get "$name" awg_priv); [ -n "$priv" ] || return 1
    psk=$(client_get "$name" awg_psk)
    ip4=$(client_get "$name" awg_ip4)
    ip6=$(client_get "$name" awg_ip6)
    {
        echo "[Interface]"
        echo "PrivateKey = ${priv}"
        if [ "${ENABLE_IPV6:-1}" = "1" ]; then
            echo "Address = ${ip4}/32, ${ip6}/128"
            echo "DNS = ${CLIENT_DNS4:-1.1.1.1}, ${CLIENT_DNS6:-2606:4700:4700::1111}"
        else
            echo "Address = ${ip4}/32"
            echo "DNS = ${CLIENT_DNS4:-1.1.1.1}"
        fi
        echo "MTU = ${AWG_MTU:-1420}"
        echo "Jc = ${AWG_JC}"
        echo "Jmin = ${AWG_JMIN}"
        echo "Jmax = ${AWG_JMAX}"
        echo "S1 = ${AWG_S1}"
        echo "S2 = ${AWG_S2}"
        echo "H1 = ${AWG_H1}"
        echo "H2 = ${AWG_H2}"
        echo "H3 = ${AWG_H3}"
        echo "H4 = ${AWG_H4}"
        echo
        echo "[Peer]"
        echo "PublicKey = ${AWG_PUBLIC_KEY}"
        echo "PresharedKey = ${psk}"
        if [ "${ENABLE_IPV6:-1}" = "1" ]; then
            echo "AllowedIPs = 0.0.0.0/0, ::/0"
        else
            echo "AllowedIPs = 0.0.0.0/0"
        fi
        echo "Endpoint = ${ENDPOINT}:${AWG_PORT}"
        echo "PersistentKeepalive = 25"
    }
}

qr() { have qrencode && qrencode -t ansiutf8 -m 1 "$1" || warn "qrencode не установлен — QR пропущен."; }

show_client() { # show_client NAME [--qr]
    local name="$1" withqr="${2:-}"
    client_exists "$name" || die "Клиент '$name' не найден."
    local outdir="$STATE_DIR/clients/$name"
    mkdir -p "$outdir"; chmod 700 "$STATE_DIR/clients" "$outdir"

    hdr "Клиент: $name"

    if [ -n "${REALITY_PUBLIC_KEY:-}" ] && [ -n "$(client_get "$name" uuid)" ]; then
        local l; l=$(vless_link "$name")
        printf '\n%s1) VLESS + XTLS-Vision + REALITY (TCP %s)%s\n' "$C_BLD" "${VLESS_PORT:-443}" "$C_OFF"
        echo "$l" | tee "$outdir/vless-reality.txt"
        [ "$withqr" = "--qr" ] && qr "$l"
    fi

    if [ -n "${HY2_PORT:-}" ] && [ -n "$(client_get "$name" hy2_pass)" ]; then
        local l; l=$(hy2_link "$name")
        printf '\n%s2) Hysteria2 (UDP %s)%s\n' "$C_BLD" "${HY2_PORT}" "$C_OFF"
        echo "$l" | tee "$outdir/hysteria2.txt"
        [ "$withqr" = "--qr" ] && qr "$l"
    fi

    if [ -n "${AWG_PUBLIC_KEY:-}" ] && [ -n "$(client_get "$name" awg_priv)" ]; then
        printf '\n%s3) AmneziaWG (UDP %s) — файл %s%s\n' "$C_BLD" "${AWG_PORT}" "$outdir/amneziawg.conf" "$C_OFF"
        awg_client_conf "$name" > "$outdir/amneziawg.conf"
        chmod 600 "$outdir/amneziawg.conf"
        cat "$outdir/amneziawg.conf"
        [ "$withqr" = "--qr" ] && qr "$(cat "$outdir/amneziawg.conf")"
    fi
    printf '\nВсе файлы клиента: %s\n' "$outdir"
}
