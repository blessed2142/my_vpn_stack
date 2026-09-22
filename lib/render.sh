#!/usr/bin/env bash
# Генерация конфигов всех трёх сервисов из состояния (/etc/vpnstack).
# Конфиги всегда перегенерируются целиком — никаких правок "на месте".

XRAY_CONF=/usr/local/etc/xray/config.json
HY2_CONF=/etc/hysteria/config.yaml
AWG_IFACE="${AWG_IFACE:-awg0}"
AWG_CONF="/etc/amnezia/amneziawg/${AWG_IFACE}.conf"

# ---------------------------------------------------------------- Xray VLESS
render_xray() {
    [ -n "${REALITY_PRIVATE_KEY:-}" ] || { warn "Xray не настроен — пропускаю рендер."; return 0; }
    local clients
    clients=$(jq -c '[.clients | to_entries[]
        | select(.value.uuid != null)
        | {id: .value.uuid, flow: "xtls-rprx-vision", email: .key}]' "$CLIENTS_FILE")

    mkdir -p "$(dirname "$XRAY_CONF")"
    jq -n \
      --argjson clients "$clients" \
      --argjson port "${VLESS_PORT:-443}" \
      --arg dest "${REALITY_SNI}:443" \
      --arg sni "${REALITY_SNI}" \
      --arg pk "${REALITY_PRIVATE_KEY}" \
      --arg sid "${REALITY_SHORT_ID}" \
      --argjson bt "${BLOCK_TORRENT:-1}" \
      '{
        log: { loglevel: "warning" },
        inbounds: [{
          tag: "vless-reality",
          listen: "::",
          port: $port,
          protocol: "vless",
          settings: { clients: $clients, decryption: "none" },
          streamSettings: {
            network: "tcp",
            security: "reality",
            realitySettings: {
              show: false,
              dest: $dest,
              xver: 0,
              serverNames: [$sni],
              privateKey: $pk,
              shortIds: [$sid]
            }
          },
          sniffing: { enabled: true, destOverride: ["http","tls","quic"], routeOnly: true }
        }],
        outbounds: [
          { tag: "direct", protocol: "freedom", settings: { domainStrategy: "UseIP" } },
          { tag: "block",  protocol: "blackhole" }
        ],
        routing: {
          domainStrategy: "AsIs",
          rules: ([
            { type: "field", ip: [
                "0.0.0.0/8","10.0.0.0/8","100.64.0.0/10","127.0.0.0/8","169.254.0.0/16",
                "172.16.0.0/12","192.0.0.0/24","192.168.0.0/16","198.18.0.0/15",
                "224.0.0.0/4","240.0.0.0/4","::1/128","fc00::/7","fe80::/10"
              ], outboundTag: "block" }
          ] + (if $bt == 1 then [{ type: "field", protocol: ["bittorrent"], outboundTag: "block" }] else [] end))
        }
      }' > "$XRAY_CONF"
    chmod 644 "$XRAY_CONF"
}

# ----------------------------------------------------------------- Hysteria2
render_hysteria() {
    [ -n "${HY2_PORT:-}" ] || { warn "Hysteria2 не настроена — пропускаю рендер."; return 0; }
    if [ "${HY2_MANAGED:-1}" != "1" ]; then
        log "Hysteria2 под вашим ручным управлением — конфиг не трогаю."
        return 0
    fi
    case "${HY2_TLS_MODE:-selfsigned}" in
        custom) [ -n "${HY2_CERT:-}" ] && [ -n "${HY2_KEY:-}" ] \
                    || die "HY2_TLS_MODE=custom, но HY2_CERT/HY2_KEY не заданы." ;;
        acme)   [ -n "${HY2_DOMAIN:-}" ] \
                    || die "HY2_TLS_MODE=acme, но домен не задан. Укажите его: vpnctl tls-acme <домен> <email>" ;;
    esac
    mkdir -p "$(dirname "$HY2_CONF")"
    {
        echo "# Сгенерировано vpnstack — руками не править, используйте vpnctl."
        echo "listen: :${HY2_PORT}"
        echo
        if [ "${HY2_TLS_MODE:-selfsigned}" = "custom" ]; then
            echo "tls:"
            echo "  cert: ${HY2_CERT}"
            echo "  key: ${HY2_KEY}"
        elif [ "${HY2_TLS_MODE:-selfsigned}" = "acme" ]; then
            echo "acme:"
            echo "  domains:"
            echo "    - ${HY2_DOMAIN}"
            echo "  email: ${ACME_EMAIL:-admin@${HY2_DOMAIN}}"
            echo "  ca: letsencrypt"
            echo "  dir: /var/lib/hysteria/acme"
            echo "  listenHost: 0.0.0.0"
            echo "  type: http"
            echo "  http:"
            echo "    altPort: 80"
        else
            echo "tls:"
            echo "  cert: /etc/hysteria/cert.pem"
            echo "  key: /etc/hysteria/key.pem"
        fi
        echo
        if [ -n "${HY2_OBFS_PASS:-}" ]; then
            echo "obfs:"
            echo "  type: salamander"
            echo "  salamander:"
            echo "    password: ${HY2_OBFS_PASS}"
            echo
        fi
        echo "auth:"
        echo "  type: userpass"
        echo "  userpass:"
        jq -r '.clients | to_entries[] | select(.value.hy2_pass != null)
               | "    \(.key): \(.value.hy2_pass)"' "$CLIENTS_FILE"
        echo
        echo "masquerade:"
        echo "  type: proxy"
        echo "  proxy:"
        echo "    url: ${HY2_MASQ_URL:-https://www.bing.com/}"
        echo "    rewriteHost: true"
        echo
        echo "ignoreClientBandwidth: true"
        echo
        echo "quic:"
        echo "  initStreamReceiveWindow: 8388608"
        echo "  maxStreamReceiveWindow: 8388608"
        echo "  initConnReceiveWindow: 20971520"
        echo "  maxConnReceiveWindow: 20971520"
        echo "  maxIdleTimeout: 30s"
        echo "  keepAlivePeriod: 10s"
    } > "$HY2_CONF"
    chmod 600 "$HY2_CONF"
    chown hysteria:hysteria "$HY2_CONF" 2>/dev/null || true
}

# ---------------------------------------------------------------- AmneziaWG
render_awg() {
    [ -n "${AWG_PRIVATE_KEY:-}" ] || { warn "AmneziaWG не настроена — пропускаю рендер."; return 0; }
    mkdir -p "$(dirname "$AWG_CONF")"
    {
        echo "# Сгенерировано vpnstack — руками не править, используйте vpnctl."
        echo "[Interface]"
        if [ "${ENABLE_IPV6:-1}" = "1" ]; then
            echo "Address = ${AWG_NET4_PREFIX:-10.8.2}.1/24, ${AWG_NET6_PREFIX:-fd42:2142:2142}::1/64"
        else
            echo "Address = ${AWG_NET4_PREFIX:-10.8.2}.1/24"
        fi
        echo "ListenPort = ${AWG_PORT:-51820}"
        echo "PrivateKey = ${AWG_PRIVATE_KEY}"
        echo "MTU = ${AWG_MTU:-1420}"
        # Параметры обфускации AmneziaWG (должны совпадать у сервера и клиента)
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
        jq -r --arg v6 "${ENABLE_IPV6:-1}" --arg p6 "${AWG_NET6_PREFIX:-}" '
            .clients | to_entries[] | select(.value.awg_pub != null) |
            "# \(.key)\n[Peer]\nPublicKey = \(.value.awg_pub)\nPresharedKey = \(.value.awg_psk)\nAllowedIPs = \(.value.awg_ip4)/32" +
            (if $v6 == "1" then ", \(.value.awg_ip6)/128" else "" end) + "\n"
        ' "$CLIENTS_FILE"
    } > "$AWG_CONF"
    chmod 600 "$AWG_CONF"
}

render_all() { render_xray; render_hysteria; render_awg; }

# ------------------------------------------------------------------ reload
reload_xray() { svc_active xray && systemctl restart xray || true; }
reload_hysteria() { svc_active hysteria-server && systemctl restart hysteria-server || true; }
reload_awg() {
    if ip link show "$AWG_IFACE" >/dev/null 2>&1; then
        awg syncconf "$AWG_IFACE" <(awg-quick strip "$AWG_IFACE") 2>/dev/null \
            || systemctl restart "awg-quick@${AWG_IFACE}"
    fi
}
reload_all() { reload_xray; reload_hysteria; reload_awg; }
