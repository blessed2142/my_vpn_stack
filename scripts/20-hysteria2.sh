#!/usr/bin/env bash
# Hysteria 2 (QUIC over UDP) + обфускация Salamander.
set -euo pipefail

hdr "2/3 — Hysteria 2"

# ------------------------------------------- уже установленная вручную Hysteria
if [ "${HY2_MANAGED:-1}" != "1" ]; then
    log "Режим --keep-hysteria: вашу настройку не трогаю."
    if [ -s "$HY2_CONF" ]; then
        p=$(awk -F: '/^[[:space:]]*listen:/{gsub(/[^0-9]/,"",$NF); print $NF; exit}' "$HY2_CONF")
        [ -n "$p" ] && { state_set HY2_PORT "$p"; ok "Нашёл ваш порт в ${HY2_CONF}: UDP/${p} — открою его в firewall."; }
    else
        warn "Конфиг ${HY2_CONF} не найден — порт для firewall беру из --hy2-port (${HY2_PORT})."
    fi
    svc_active hysteria-server && ok "Сервис hysteria-server работает." \
        || warn "Сервис hysteria-server не активен — проверьте сами."
    return 0 2>/dev/null || exit 0
fi

# ВАЖНО: проверяем ДО установки. Официальный установщик сам кладёт свой
# демонстрационный config.yaml, и если смотреть после него, любой чистый
# сервер выглядит как «тут уже что-то настроено».
PREEXISTING_CONF=0
if [ -s "$HY2_CONF" ] && ! grep -q 'Сгенерировано vpnstack' "$HY2_CONF"; then
    PREEXISTING_CONF=1
    BAK="${HY2_CONF}.manual-$(date +%Y%m%d%H%M%S)"
    cp -a "$HY2_CONF" "$BAK"
    warn "Найден конфиг Hysteria, созданный не этим скриптом. Сохранил копию: ${BAK}"
    users=$(awk '/^[[:space:]]*userpass:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/^[[:space:]]+[A-Za-z0-9_.-]+:/{s=$0; sub(/:.*/,"",s); gsub(/[[:space:]]/,"",s); print s}' "$BAK" 2>/dev/null | tr '\n' ' ')
    if [ -n "${users// /}" ]; then
        warn "Пользователи в нём: ${users}— чтобы их ссылки продолжили работать: vpnctl import-hysteria"
    fi
fi

# ------------------------------------------------------------- установка
if ! have hysteria; then
    log "Ставлю Hysteria 2 (официальный установщик get.hy2.sh)..."
    curl -fsSL https://get.hy2.sh/ -o /tmp/hy2-install.sh || die "Не удалось скачать установщик Hysteria."
    bash /tmp/hy2-install.sh >/dev/null || die "Установка Hysteria завершилась с ошибкой."
    rm -f /tmp/hy2-install.sh
    ok "Hysteria установлена: $(hysteria version 2>/dev/null | head -n1)"
else
    ok "Hysteria уже установлена: $(hysteria version 2>/dev/null | head -n1)"
fi
id hysteria >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin hysteria

# ------------------------------------------------------- обфускация/пароли
if [ -z "${HY2_OBFS_PASS:-}" ] && [ "${HY2_OBFS:-1}" = "1" ]; then state_set HY2_OBFS_PASS "$(rand_pass)"; fi

# ---------------------------------------------------------------- TLS
state_set HY2_SNI "${HY2_DOMAIN:-${MASQ_SNI:-www.bing.com}}"

# Раньше сертификат получал сам hysteria (режим acme). От него отказались:
# проверка шла уже после старта сервиса, а TLS-ALPN в части версий лезла на
# TCP/443, занятый Xray. Старое состояние сбрасываем, чтобы решение приняли заново.
if [ "${HY2_TLS_MODE:-}" = "acme" ]; then
    log "Прежний режим встроенного ACME больше не используется — перехожу на certbot."
    state_set HY2_TLS_MODE ""
    HY2_TLS_MODE=""
fi

if [ -z "${HY2_TLS_MODE:-}" ]; then
    if [ -n "${HY2_CERT:-}" ] && [ -n "${HY2_KEY:-}" ]; then
        [ -s "$HY2_CERT" ] && [ -s "$HY2_KEY" ] || die "Указанные --hy2-cert/--hy2-key не найдены."
        ok "Использую ваш сертификат: ${HY2_CERT}"
        state_set HY2_TLS_MODE custom
    elif [ -n "${HY2_DOMAIN:-}" ] && adopt_certbot_cert "$HY2_DOMAIN"; then
        ok "Нашёл готовый сертификат certbot для ${HY2_DOMAIN} — переиспользую."
        state_set HY2_CERT /etc/hysteria/cert.pem; state_set HY2_KEY /etc/hysteria/key.pem
        state_set HY2_TLS_MODE custom
    elif [ -n "${HY2_DOMAIN:-}" ] && domain_points_here "$HY2_DOMAIN" "$SERVER_IP4"; then
        if issue_certbot_cert "$HY2_DOMAIN" "${ACME_EMAIL:-admin@${HY2_DOMAIN}}" \
           && adopt_certbot_cert "$HY2_DOMAIN"; then
            state_set HY2_CERT /etc/hysteria/cert.pem; state_set HY2_KEY /etc/hysteria/key.pem
            state_set HY2_TLS_MODE custom
        else
            warn "Не вышло получить сертификат Let's Encrypt — беру самоподписанный."
            warn "Повторить потом: vpnctl tls-acme ${HY2_DOMAIN} <email>"
            state_set HY2_TLS_MODE selfsigned
        fi
    else
        if [ -n "${HY2_DOMAIN:-}" ]; then
            warn "A-записи ${HY2_DOMAIN}: $(resolve_a "$HY2_DOMAIN" | tr '\n' ' ') , а сервер — ${SERVER_IP4}."
        else
            warn "Домен не задан."
        fi
        warn "Использую самоподписанный сертификат (в ссылке будет insecure=1)."
        state_set HY2_TLS_MODE selfsigned
    fi
fi

case "$HY2_TLS_MODE" in
    selfsigned) [ -s /etc/hysteria/cert.pem ] || { log "Генерирую самоподписанный сертификат для ${HY2_SNI}..."; selfsigned_cert "$HY2_SNI"; }
                state_set HY2_INSECURE 1 ;;
    custom)     state_set HY2_INSECURE "${HY2_INSECURE_FORCE:-0}" ;;
esac

# Hysteria с пустым auth.userpass не стартует вообще — клиент нужен до рендера.
provision_client "${FIRST_CLIENT:-main}"

# --------------------------------------------------------------- запуск
render_hysteria
systemctl enable hysteria-server >/dev/null 2>&1 || true
systemctl restart hysteria-server

# Мало проверить «сервис активен» сразу: hysteria поднимается мгновенно, а
# падает через несколько секунд. Ждём, пока реально займёт свой UDP-порт.
if wait_service_ready hysteria-server udp "$HY2_PORT" 25; then
    ok "Hysteria 2 работает, слушает UDP/${HY2_PORT} (TLS: ${HY2_TLS_MODE})."
else
    err "Hysteria 2 не поднялась. Последние строки журнала:"
    journalctl -u hysteria-server -n 25 --no-pager >&2 || true
    if [ "$HY2_TLS_MODE" != "selfsigned" ]; then
        warn "Пробую самоподписанный сертификат как запасной вариант..."
        state_set HY2_TLS_MODE selfsigned; state_set HY2_INSECURE 1
        selfsigned_cert "$HY2_SNI"; render_hysteria
        systemctl restart hysteria-server
        wait_service_ready hysteria-server udp "$HY2_PORT" 20 \
            && ok "Hysteria 2 работает на самоподписанном сертификате." \
            || die "Hysteria не запускается. Диагностика: vpnctl diag"
    else
        die "Hysteria не запускается. Диагностика: vpnctl diag"
    fi
fi
