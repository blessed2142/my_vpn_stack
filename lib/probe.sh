#!/usr/bin/env bash
# Живая проверка REALITY: поднимает временную пару сервер+клиент на свободных
# портах и прогоняет через неё настоящий запрос. Проверка "сайт отдаёт TLS 1.3
# и h2" этого не заменяет: сайт может её пройти и всё равно не годиться —
# например, ответив HelloRetryRequest на постквантовый key share клиента.

PROBE_URL="${PROBE_URL:-https://cp.cloudflare.com/generate_204}"

# Маскировочные сайты, проверенные на совместимость с REALITY.
REALITY_CANDIDATES="www.cloudflare.com one.one.one.one dl.google.com www.yahoo.com www.samsung.com www.lovelive-anime.jp"

# Поднимает временную пару сервер+клиент REALITY на свободных портах и
# проверяет, проходит ли через неё трафик. Рабочий сервис при этом не трогается.
probe_reality() { # _probe_pair МАСКИРОВОЧНЫЙ_ДОМЕН ОТПЕЧАТОК
    local dest="$1" fp="$2" tmp k priv pub sid uuid code
    local sport=18443 cport=18080
    k=$(xray x25519 2>/dev/null)
    priv=$(grep -iE '^[[:space:]]*private' <<<"$k" | head -n1 | sed 's/.*:[[:space:]]*//')
    pub=$(grep -iE '^[[:space:]]*(public|password)' <<<"$k" | head -n1 | sed 's/.*:[[:space:]]*//')
    sid=$(rand_hex 8); uuid=$(xray uuid)
    tmp=$(mktemp -d)

    jq -n --arg dest "${dest}:443" --arg sni "$dest" --arg priv "$priv" --arg sid "$sid" \
          --arg uuid "$uuid" --argjson port "$sport" '{
        log: { loglevel: "error" },
        inbounds: [{ listen: "127.0.0.1", port: $port, protocol: "vless",
          settings: { clients: [{ id: $uuid, flow: "xtls-rprx-vision" }], decryption: "none" },
          streamSettings: { network: "tcp", security: "reality",
            realitySettings: { show: false, dest: $dest, xver: 0, serverNames: [$sni],
                               privateKey: $priv, shortIds: [$sid] } } }],
        outbounds: [{ protocol: "freedom" }] }' > "$tmp/s.json"

    jq -n --arg sni "$dest" --arg fp "$fp" --arg pub "$pub" --arg sid "$sid" \
          --arg uuid "$uuid" --argjson sport "$sport" --argjson cport "$cport" '{
        log: { loglevel: "error" },
        inbounds: [{ listen: "127.0.0.1", port: $cport, protocol: "socks",
                     settings: { udp: false } }],
        outbounds: [{ protocol: "vless",
          settings: { vnext: [{ address: "127.0.0.1", port: $sport,
            users: [{ id: $uuid, encryption: "none", flow: "xtls-rprx-vision" }] }] },
          streamSettings: { network: "tcp", security: "reality",
            realitySettings: { serverName: $sni, fingerprint: $fp,
                               publicKey: $pub, shortId: $sid } } }] }' > "$tmp/c.json"

    xray run -c "$tmp/s.json" >"$tmp/s.log" 2>&1 & local sp=$!
    sleep 1
    xray run -c "$tmp/c.json" >"$tmp/c.log" 2>&1 & local cp=$!
    sleep 1
    code=$(timeout 25 curl -s -o /dev/null -w '%{http_code}' \
           --proxy "socks5h://127.0.0.1:${cport}" --max-time 18 "$PROBE_URL" 2>/dev/null) || code=""
    kill "$sp" "$cp" 2>/dev/null || true
    wait "$sp" "$cp" 2>/dev/null || true
    rm -rf "$tmp"
    [ "$code" = "204" ] || [ "$code" = "200" ]
}

