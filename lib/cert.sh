#!/usr/bin/env bash
# Получение и подключение TLS-сертификата для Hysteria2.
# Встроенный в hysteria ACME не используем: он стартует уже после запуска
# сервиса, поэтому провал выясняется поздно, а TLS-ALPN-проверка в части
# версий лезет на TCP/443, где уже сидит Xray. certbot делает всё до старта.

selfsigned_cert() { # selfsigned_cert <CN>
    mkdir -p /etc/hysteria
    openssl req -x509 -nodes -newkey ec:<(openssl ecparam -name prime256v1) \
        -keyout /etc/hysteria/key.pem -out /etc/hysteria/cert.pem \
        -subj "/CN=${1}" -days 3650 >/dev/null 2>&1 \
        || die "Не удалось создать самоподписанный сертификат."
    chown hysteria:hysteria /etc/hysteria/key.pem /etc/hysteria/cert.pem 2>/dev/null || true
    chmod 600 /etc/hysteria/key.pem
}

# Копирует сертификат certbot туда, где его прочтёт пользователь hysteria,
# и вешает хук, чтобы копия обновлялась после каждого продления.
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

# Выпускает сертификат через certbot standalone (HTTP-01, порт 80).
issue_certbot_cert() { # issue_certbot_cert <домен> <email>
    local d="$1" e="$2" owner
    have certbot || { log "Ставлю certbot..."; pkg_install certbot || return 1; }

    owner=$(ss -H -lnt -p 2>/dev/null | awk '$4 ~ /[:.]80$/ {print $NF; exit}')
    if [ -n "$owner" ]; then
        err "Порт 80/tcp занят ($owner) — certbot не сможет пройти проверку."
        err "Остановите этот сервис и повторите, либо используйте --hy2-cert/--hy2-key."
        return 1
    fi

    log "Запрашиваю сертификат Let's Encrypt для ${d} (HTTP-01, порт 80)..."
    certbot certonly --standalone --non-interactive --agree-tos \
        --preferred-challenges http --cert-name "$d" -d "$d" -m "$e" \
        --keep-until-expiring >/tmp/certbot-vpnstack.log 2>&1 || {
            err "certbot не смог выпустить сертификат. Последние строки:"
            tail -n 15 /tmp/certbot-vpnstack.log >&2
            return 1
        }
    ok "Сертификат получен."
    return 0
}
