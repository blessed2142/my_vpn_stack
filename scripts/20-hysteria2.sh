#!/usr/bin/env bash
# Hysteria 2 (QUIC over UDP) + обфускация Salamander.
set -euo pipefail

hdr "2/3 — Hysteria 2"

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
if [ -z "${HY2_TLS_MODE:-}" ]; then
    if [ -n "${HY2_DOMAIN:-}" ] && domain_points_here "$HY2_DOMAIN" "$SERVER_IP4"; then
        ok "Домен ${HY2_DOMAIN} указывает на ${SERVER_IP4} — беру настоящий сертификат Let's Encrypt (ACME)."
        state_set HY2_TLS_MODE acme
    else
        if [ -n "${HY2_DOMAIN:-}" ]; then
            warn "A-запись ${HY2_DOMAIN} не указывает на ${SERVER_IP4} (или DNS ещё не разошёлся)."
        else
            warn "Домен не задан."
        fi
        warn "Использую самоподписанный сертификат (в ссылке будет insecure=1)."
        warn "Позже можно переключиться: vpnctl tls-acme <домен> <email>"
        state_set HY2_TLS_MODE selfsigned
    fi
fi
state_set HY2_SNI "${HY2_DOMAIN:-${MASQ_SNI:-www.bing.com}}"

if [ "$HY2_TLS_MODE" = "selfsigned" ] && [ ! -s /etc/hysteria/cert.pem ]; then
    log "Генерирую самоподписанный сертификат для SNI ${HY2_SNI}..."
    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem \
        -subj "/CN=${HY2_SNI}" -days 3650 >/dev/null 2>&1 \
        || die "Не удалось создать самоподписанный сертификат."
    chown hysteria:hysteria /etc/hysteria/key.pem /etc/hysteria/cert.pem
    chmod 600 /etc/hysteria/key.pem
fi

if [ "$HY2_TLS_MODE" = "acme" ]; then
    mkdir -p /var/lib/hysteria/acme
    chown -R hysteria:hysteria /var/lib/hysteria
    if ss -lntp 2>/dev/null | awk '{print $4}' | grep -qE ':80$'; then
        warn "Порт 80/tcp уже занят — ACME-проверка Let's Encrypt может не пройти."
    fi
fi

# --------------------------------------------------------------- конфиг
render_hysteria
hysteria server -c "$HY2_CONF" --disable-update-check check >/dev/null 2>&1 \
    || log "(проверка конфига пропущена — старая версия hysteria)"

systemctl enable hysteria-server >/dev/null 2>&1 || true
systemctl restart hysteria-server
sleep 3
if svc_active hysteria-server; then
    ok "Hysteria 2 запущена, слушает UDP/${HY2_PORT}."
else
    journalctl -u hysteria-server -n 30 --no-pager || true
    if [ "$HY2_TLS_MODE" = "acme" ]; then
        warn "Скорее всего не прошла проверка Let's Encrypt. Откатываюсь на самоподписанный сертификат."
        state_set HY2_TLS_MODE selfsigned
        mkdir -p /etc/hysteria
        openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
            -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem \
            -subj "/CN=${HY2_SNI}" -days 3650 >/dev/null 2>&1
        chown hysteria:hysteria /etc/hysteria/key.pem /etc/hysteria/cert.pem
        chmod 600 /etc/hysteria/key.pem
        render_hysteria
        systemctl restart hysteria-server
        sleep 2
        svc_active hysteria-server && ok "Hysteria 2 запущена на самоподписанном сертификате." \
            || die "Hysteria не запускается. Логи: journalctl -u hysteria-server -n 50"
    else
        die "Hysteria не запускается. Логи: journalctl -u hysteria-server -n 50"
    fi
fi
