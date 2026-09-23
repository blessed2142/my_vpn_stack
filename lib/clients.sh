#!/usr/bin/env bash
# Работа с записями клиентов. Общее для install.sh и vpnctl.

valid_name() { [[ "$1" =~ ^[A-Za-z0-9_.-]{1,32}$ ]]; }

next_awg_index() {
    local used max=1 i
    used=$(jq -r '.clients[]? | .awg_ip4 // empty' "$CLIENTS_FILE" | awk -F. '{print $4}')
    for i in $used; do [ "$i" -gt "$max" ] && max="$i"; done
    echo $((max + 1))
}

_client_patch() { # _client_patch ИМЯ <jq-выражение> [--arg ...]
    local name="$1" expr="$2"; shift 2
    jq --arg n "$name" "$@" "$expr" "$CLIENTS_FILE" | clients_write
}

# Дозаполняет клиента теми протоколами, которые уже настроены. Вызывается на
# каждом этапе установки: когда работает этап Hysteria, ключей AmneziaWG ещё
# нет, и наоборот. Пустой auth.userpass для Hysteria — фатальная ошибка при
# старте, поэтому клиент обязан появиться до генерации конфига, а не после.
# Какие протоколы выдавать клиенту. Пусто — все, что настроены на сервере.
# Ограничение нужно, например, когда Hysteria используется одним общим
# аккаунтом, а отдельные записи заводятся только ради AmneziaWG.
_want() { # _want vless|hy2|awg
    [ -z "${PROVISION_ONLY:-}" ] && return 0
    case ",${PROVISION_ONLY}," in *",$1,"*) return 0 ;; *) return 1 ;; esac
}

provision_client() { # provision_client ИМЯ [ПАРОЛЬ_HY2]
    local name="$1" forced="${2:-}"
    valid_name "$name" || die "Недопустимое имя клиента: '$name'"
    clients_init
    client_exists "$name" || _client_patch "$name" '.clients[$n] = {created: $ts}' --arg ts "$(date -Is)"

    if _want vless && [ -n "${REALITY_PRIVATE_KEY:-}" ] && [ -z "$(client_get "$name" uuid)" ]; then
        local uuid
        uuid=$(have xray && xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid)
        _client_patch "$name" '.clients[$n].uuid = $v' --arg v "$uuid"
    fi

    if _want hy2 && [ "${HY2_MANAGED:-1}" = "1" ] && [ -n "${HY2_PORT:-}" ]; then
        if [ -n "$forced" ]; then
            _client_patch "$name" '.clients[$n].hy2_pass = $v' --arg v "$forced"
        elif [ -z "$(client_get "$name" hy2_pass)" ]; then
            _client_patch "$name" '.clients[$n].hy2_pass = $v' --arg v "$(rand_pass)"
        fi
    fi

    if _want awg && [ -n "${AWG_PUBLIC_KEY:-}" ] && [ -z "$(client_get "$name" awg_pub)" ]; then
        local priv pub psk idx
        priv=$(awg genkey); pub=$(printf '%s' "$priv" | awg pubkey); psk=$(awg genpsk)
        idx=$(next_awg_index)
        [ "$idx" -le 254 ] || die "Свободные адреса в подсети AmneziaWG закончились."
        _client_patch "$name" '.clients[$n] += {awg_priv:$priv, awg_pub:$pub, awg_psk:$psk,
                                               awg_ip4:$ip4, awg_ip6:$ip6}' \
            --arg priv "$priv" --arg pub "$pub" --arg psk "$psk" \
            --arg ip4 "${AWG_NET4_PREFIX:-10.8.2}.${idx}" \
            --arg ip6 "${AWG_NET6_PREFIX:-fd42:2142:2142}::${idx}"
    fi
}

# --- разбор «ручного» конфига Hysteria (для import-hysteria) ---
hy2_parse_obfs() {
    awk '/^obfs:/{o=1;next} o&&/^[^[:space:]]/{o=0}
         o&&/^[[:space:]]*password:/{s=$0
            sub(/^[[:space:]]*password:[[:space:]]*/,"",s)
            gsub(/^"|"$/,"",s); gsub(/^\047|\047$/,"",s)
            print s; exit}' "$1"
}
hy2_parse_port() {
    awk -F: '/^[[:space:]]*listen:/{gsub(/[^0-9]/,"",$NF); print $NF; exit}' "$1"
}
hy2_parse_users() { # -> "имя<TAB>пароль"
    awk '/^[[:space:]]*userpass:/{f=1;next} f&&/^[^[:space:]]/{f=0}
         f&&/^[[:space:]]+[A-Za-z0-9_.-]+:/{
            k=$0; sub(/:.*/,"",k); gsub(/[[:space:]]/,"",k)
            v=$0; sub(/^[[:space:]]*[A-Za-z0-9_.-]+:[[:space:]]*/,"",v)
            gsub(/^"|"$/,"",v); gsub(/^\047|\047$/,"",v)
            if (k != "" && v != "") print k "\t" v}' "$1"
}
