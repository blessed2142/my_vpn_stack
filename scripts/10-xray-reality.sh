#!/usr/bin/env bash
# Xray-core: VLESS + XTLS-Vision + REALITY на TCP/443.
set -euo pipefail

hdr "1/3 — VLESS + XTLS-Vision + REALITY (Xray-core)"

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

# ---------------------------------------------- выбор маскировочного сайта
# Проверяем сайт живым рукопожатием REALITY, а не только наличием TLS 1.3 и h2:
# сайт может отдавать и то и другое, но отвечать HelloRetryRequest на
# постквантовый key share клиента — REALITY этого не переживает.
pick_reality_sni() {
    local d
    for d in "$@"; do
        [ -n "$d" ] || continue
        log "Проверяю маскировочный сайт ${d} живым рукопожатием..." >&2
        if probe_reality "$d" "${REALITY_FP:-chrome}"; then
            ok "Подходит: ${d}" >&2
            echo "$d"; return 0
        fi
        warn "${d} не подходит." >&2
    done
    return 1
}

# Маскировочный домен мог приехать испорченным (например, скопированным из
# чата вместе с разметкой) — тогда REALITY молча не работает. Проверяем форму.
if [ -n "${REALITY_SNI:-}" ] && ! [[ "$REALITY_SNI" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]]; then
    warn "REALITY_SNI задан некорректно: '${REALITY_SNI}' — это не доменное имя. Подберу заново."
    state_set REALITY_SNI ""
    REALITY_SNI=""
fi

SNI_PREV="${REALITY_SNI:-}"
if [ -z "${REALITY_SNI:-}" ]; then
    SNI=$(pick_reality_sni ${REALITY_SNI_PREFERRED:-} $REALITY_CANDIDATES) \
        || die "Ни один маскировочный сайт не прошёл проверку. Задайте свой: --reality-sni <домен>"
    state_set REALITY_SNI "$SNI"
fi
log "REALITY dest/SNI: ${REALITY_SNI}"

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

if [ -n "$SNI_PREV" ] && [ "$SNI_PREV" != "${REALITY_SNI}" ]; then
    warn "Маскировочный домен сменился: ${SNI_PREV} -> ${REALITY_SNI}"
    warn "СТАРЫЕ ССЫЛКИ VLESS БОЛЬШЕ НЕ РАБОТАЮТ. Раздайте новые: vpnctl links --qr"
fi

systemctl enable xray >/dev/null 2>&1 || true
systemctl restart xray
sleep 2
if svc_active xray; then
    ok "Xray запущен, слушает TCP/${VLESS_PORT:-443}."
else
    journalctl -u xray -n 30 --no-pager || true
    die "Xray не запустился."
fi
