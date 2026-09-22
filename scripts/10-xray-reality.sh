#!/usr/bin/env bash
# Xray-core: VLESS + XTLS-Vision + REALITY на TCP/443.
set -euo pipefail

hdr "1/3 — VLESS + XTLS-Vision + REALITY (Xray-core)"

# ---------------------------------------------- выбор маскировочного сайта
check_reality_dest() { # домен -> 0 если годится
    local d="$1" out
    out=$(timeout 10 openssl s_client -connect "${d}:443" -servername "$d" \
            -alpn h2 -tls1_3 </dev/null 2>/dev/null) || return 1
    grep -q 'ALPN protocol: h2' <<<"$out" || return 1
    grep -q 'TLSv1.3' <<<"$out" || return 1
    return 0
}

pick_reality_sni() {
    local candidates=("$@")
    local d
    for d in "${candidates[@]}"; do
        [ -n "$d" ] || continue
        log "Проверяю маскировочный сайт ${d} (нужен TLS 1.3 + HTTP/2)..." >&2
        if check_reality_dest "$d"; then
            ok "Подходит: ${d}" >&2
            echo "$d"; return 0
        fi
        warn "${d} не подходит (нет TLS1.3/h2 или недоступен)."
    done
    return 1
}

if [ -z "${REALITY_SNI:-}" ]; then
    SNI=$(pick_reality_sni "${REALITY_SNI_PREFERRED:-}" www.microsoft.com www.nvidia.com www.samsung.com dl.google.com www.cloudflare.com) \
        || die "Ни один маскировочный сайт не прошёл проверку. Задайте свой: --reality-sni <домен>"
    state_set REALITY_SNI "$SNI"
fi
log "REALITY dest/SNI: ${REALITY_SNI}"

# ------------------------------------------------------------- установка
if ! have xray; then
    log "Ставлю Xray-core (официальный установщик XTLS/Xray-install)..."
    curl -fsSL https://github.com/XTLS/Xray-install/raw/main/install-release.sh -o /tmp/xray-install.sh \
        || die "Не удалось скачать установщик Xray."
    bash /tmp/xray-install.sh install >/dev/null || die "Установка Xray завершилась с ошибкой."
    rm -f /tmp/xray-install.sh
    ok "Xray установлен: $(xray version | head -n1)"
else
    ok "Xray уже установлен: $(xray version | head -n1)"
fi

# ---------------------------------------------------------------- ключи
if [ -z "${REALITY_PRIVATE_KEY:-}" ]; then
    log "Генерирую ключевую пару X25519 для REALITY..."
    KEYS=$(xray x25519)
    # разные версии Xray печатают по-разному: Private key/Public key либо PrivateKey/Password
    PRIV=$(grep -iE '^[[:space:]]*private' <<<"$KEYS" | head -n1 | sed 's/.*:[[:space:]]*//')
    PUB=$(grep -iE '^[[:space:]]*(public|password)' <<<"$KEYS" | head -n1 | sed 's/.*:[[:space:]]*//')
    [ -n "$PRIV" ] && [ -n "$PUB" ] || die "Не смог разобрать вывод 'xray x25519': $KEYS"
    state_set REALITY_PRIVATE_KEY "$PRIV"
    state_set REALITY_PUBLIC_KEY "$PUB"
    state_set REALITY_SHORT_ID "$(rand_hex 8)"
    ok "Ключи REALITY сгенерированы."
fi

# Конфиг генерируется из списка клиентов — он должен быть непустым.
provision_client "${FIRST_CLIENT:-main}"

# --------------------------------------------------------------- конфиг
render_xray
xray run -test -config "$XRAY_CONF" >/dev/null 2>&1 || {
    xray run -test -config "$XRAY_CONF" || true
    die "Конфиг Xray не прошёл проверку."
}

systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
if svc_active xray; then
    ok "Xray запущен, слушает TCP/${VLESS_PORT:-443}."
else
    journalctl -u xray -n 30 --no-pager || true
    die "Xray не запустился."
fi
