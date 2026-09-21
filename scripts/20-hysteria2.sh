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

# ------------------------------------- бэкап чужого (не нашего) конфига
if [ -s "$HY2_CONF" ] && ! grep -q 'Сгенерировано vpnstack' "$HY2_CONF"; then
    BAK="${HY2_CONF}.manual-$(date +%Y%m%d%H%M%S)"
    cp -a "$HY2_CONF" "$BAK"
    warn "Найден конфиг Hysteria, созданный не этим скриптом. Сохранил копию: ${BAK}"
    users=$(awk '/^[[:space:]]*userpass:/{f=1;next} f&&/^[^[:space:]]/{f=0} f&&/^[[:space:]]+[A-Za-z0-9_.-]+:/{s=$0; sub(/:.*/,"",s); gsub(/[[:space:]]/,"",s); print s}' "$BAK" 2>/dev/null | tr '\n' ' ')
    [ -n "${users// /}" ] && warn "Пользователи из старого конфига: ${users}— их логины/пароли изменятся, ссылки надо раздать заново."
fi

# ------------------------------------------------------- обфускация/пароли
if [ -z "${HY2_OBFS_PASS:-}" ] && [ "${HY2_OBFS:-1}" = "1" ]; then state_set HY2_OBFS_PASS "$(rand_pass)"; fi

# -------------------------------------- переиспользование сертификата certbot
adopt_certbot_cert() { # adopt_certbot_cert <домен>
    local d="$1" live="/etc/letsencrypt/live/$1"
    [ -s "$live/fullchain.pem" ] && [ -s "$live/privkey.pem" ] || return 1
    install -o hysteria -g hysteria -m 644 "$live/fullchain.pem" /etc/hysteria/cert.pem
    install -o hysteria -g hysteria -m 600 "$live/privkey.pem"   /etc/hysteria/key.pem
    mkdir -p /etc/letsencrypt/renewal-hooks/deploy
    cat > /etc/letsencrypt/renewal-hooks/deploy/vpnstack-hysteria.sh <<HOOK
#!/bin/sh
# vpnstack: обновляет копию сертификата для Hysteria после продления certbot
install -o hysteria -g hysteria -m 644 /etc/letsencrypt/live/${d}/fullchain.pem /etc/hysteria/cert.pem
install -o hysteria -g hysteria -m 600 /etc/letsencrypt/live/${d}/privkey.pem   /etc/hysteria/key.pem
systemctl restart hysteria-server
HOOK
    chmod +x /etc/letsencrypt/renewal-hooks/deploy/vpnstack-hysteria.sh
    return 0
}

make_selfsigned() {
    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem \
        -subj "/CN=${HY2_SNI}" -days 3650 >/dev/null 2>&1 \
        || die "Не удалось создать самоподписанный сертификат."
    chown hysteria:hysteria /etc/hysteria/key.pem /etc/hysteria/cert.pem
    chmod 600 /etc/hysteria/key.pem
}

# ---------------------------------------------------------------- TLS
state_set HY2_SNI "${HY2_DOMAIN:-${MASQ_SNI:-www.bing.com}}"

if [ -z "${HY2_TLS_MODE:-}" ]; then
    if [ -n "${HY2_CERT:-}" ] && [ -n "${HY2_KEY:-}" ]; then
        [ -s "$HY2_CERT" ] && [ -s "$HY2_KEY" ] || die "Указанные --hy2-cert/--hy2-key не найдены."
        ok "Использую ваш сертификат: ${HY2_CERT}"
        state_set HY2_TLS_MODE custom
    elif [ -n "${HY2_DOMAIN:-}" ] && adopt_certbot_cert "$HY2_DOMAIN"; then
        ok "Нашёл сертификат certbot для ${HY2_DOMAIN} — переиспользую его (ACME повторно не гоняю)."
        log "Добавил deploy-hook, чтобы после продления копия обновлялась автоматически."
        state_set HY2_CERT /etc/hysteria/cert.pem
        state_set HY2_KEY  /etc/hysteria/key.pem
        state_set HY2_TLS_MODE custom
    elif [ -n "${HY2_DOMAIN:-}" ] && domain_points_here "$HY2_DOMAIN" "$SERVER_IP4"; then
        ok "Домен ${HY2_DOMAIN} указывает на ${SERVER_IP4} — беру сертификат Let's Encrypt (ACME)."
        state_set HY2_TLS_MODE acme
    else
        if [ -n "${HY2_DOMAIN:-}" ]; then
            resolved=$(getent ahostsv4 "$HY2_DOMAIN" 2>/dev/null | awk '{print $1; exit}')
            warn "A-запись ${HY2_DOMAIN} = ${resolved:-нет} , а сервер — ${SERVER_IP4}."
        else
            warn "Домен не задан."
        fi
        warn "Использую самоподписанный сертификат (в ссылке будет insecure=1)."
        warn "Когда домен будет указывать сюда: vpnctl tls-acme ${HY2_DOMAIN:-<домен>} <email>"
        state_set HY2_TLS_MODE selfsigned
    fi
fi

case "$HY2_TLS_MODE" in
    selfsigned) [ -s /etc/hysteria/cert.pem ] || { log "Генерирую самоподписанный сертификат для SNI ${HY2_SNI}..."; make_selfsigned; }
                state_set HY2_INSECURE 1 ;;
    custom)     state_set HY2_INSECURE "${HY2_INSECURE_FORCE:-0}" ;;
    acme)       state_set HY2_INSECURE 0
                mkdir -p /var/lib/hysteria/acme; chown -R hysteria:hysteria /var/lib/hysteria
                if ss -H -lnt 2>/dev/null | awk '{print $4}' | grep -qE '[:.]80$'; then
                    warn "Порт 80/tcp уже занят — проверка Let's Encrypt может не пройти."
                fi ;;
esac

# --------------------------------------------------------------- конфиг
render_hysteria
systemctl enable hysteria-server >/dev/null 2>&1 || true
systemctl restart hysteria-server
sleep 3
if svc_active hysteria-server; then
    ok "Hysteria 2 запущена, слушает UDP/${HY2_PORT} (TLS: ${HY2_TLS_MODE})."
else
    journalctl -u hysteria-server -n 30 --no-pager || true
    if [ "$HY2_TLS_MODE" = "acme" ]; then
        warn "Скорее всего не прошла проверка Let's Encrypt. Откатываюсь на самоподписанный сертификат."
        state_set HY2_TLS_MODE selfsigned; state_set HY2_INSECURE 1
        make_selfsigned; render_hysteria
        systemctl restart hysteria-server; sleep 2
        svc_active hysteria-server && ok "Hysteria 2 запущена на самоподписанном сертификате." \
            || die "Hysteria не запускается. Логи: journalctl -u hysteria-server -n 50"
    else
        die "Hysteria не запускается. Логи: journalctl -u hysteria-server -n 50"
    fi
fi
