#!/usr/bin/env bash
# AmneziaWG — WireGuard с обфускацией (Amnezia). Ядерный модуль, иначе userspace.
set -euo pipefail

hdr "3/3 — AmneziaWG"

AWG_IFACE="${AWG_IFACE:-awg0}"
AWG_CONF="/etc/amnezia/amneziawg/${AWG_IFACE}.conf"

[ -e /dev/net/tun ] || {
    warn "Нет /dev/net/tun. На OpenVZ/LXC попросите провайдера включить TUN/TAP."
    warn "Ядерный модуль может сработать и без него, продолжаю."
}

install_build_deps() {
    case "$PKG" in
        apt) pkg_install build-essential git make gcc pkg-config \
                 "linux-headers-$(uname -r)" || pkg_install build-essential git make gcc ;;
        dnf) pkg_install gcc make git kernel-devel elfutils-libelf-devel || true ;;
    esac
}

install_tools_from_source() {
    log "Собираю amneziawg-tools из исходников..."
    rm -rf /tmp/awg-tools
    git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-tools /tmp/awg-tools >/dev/null 2>&1 \
        || die "Не удалось склонировать amneziawg-tools."
    make -C /tmp/awg-tools/src -j"$(nproc)" >/dev/null 2>&1 || die "Сборка amneziawg-tools не удалась."
    make -C /tmp/awg-tools/src install \
        WITH_WGQUICK=yes WITH_SYSTEMDUNITS=yes WITH_BASHCOMPLETION=yes >/dev/null \
        || die "Установка amneziawg-tools не удалась."
    rm -rf /tmp/awg-tools
    ok "amneziawg-tools установлены ($(command -v awg))."
}

install_go_toolchain() {
    local need=0 ver arch url
    if have go; then
        ver=$(go version | awk '{print $3}' | sed 's/go//')
        [ "$(printf '%s\n1.22\n' "$ver" | sort -V | head -n1)" = "1.22" ] || need=1
    else
        need=1
    fi
    [ "$need" = "1" ] || { ok "Go уже подходящей версии ($(go version | awk '{print $3}'))."; return 0; }

    case "$(uname -m)" in
        x86_64) arch=amd64 ;; aarch64|arm64) arch=arm64 ;;
        *) die "Неизвестная архитектура $(uname -m) для установки Go." ;;
    esac
    ver=$(curl -fsSL https://go.dev/VERSION?m=text | head -n1)
    [ -n "$ver" ] || ver="go1.23.6"
    url="https://go.dev/dl/${ver}.linux-${arch}.tar.gz"
    log "Ставлю Go (${ver}) для сборки amneziawg-go..."
    curl -fsSL "$url" -o /tmp/go.tgz || die "Не удалось скачать Go."
    rm -rf /usr/local/go && tar -C /usr/local -xzf /tmp/go.tgz && rm -f /tmp/go.tgz
    export PATH="/usr/local/go/bin:$PATH"
    ln -sf /usr/local/go/bin/go /usr/local/bin/go
    ok "Go установлен: $(go version)"
}

install_awg_go() {
    have amneziawg-go && { ok "amneziawg-go уже установлен."; return 0; }
    install_go_toolchain
    log "Собираю amneziawg-go (userspace-реализация)..."
    rm -rf /tmp/awg-go
    git clone --depth=1 https://github.com/amnezia-vpn/amneziawg-go /tmp/awg-go >/dev/null 2>&1 \
        || die "Не удалось склонировать amneziawg-go."
    ( cd /tmp/awg-go && PATH="/usr/local/go/bin:$PATH" make >/dev/null 2>&1 ) \
        || die "Сборка amneziawg-go не удалась."
    install -m 0755 /tmp/awg-go/amneziawg-go /usr/bin/amneziawg-go
    rm -rf /tmp/awg-go
    ok "amneziawg-go установлен."
}

# ------------------------------------------------------------- установка
if ! have awg; then
    if [ "$OS_ID" = "ubuntu" ]; then
        log "Подключаю PPA ppa:amnezia/ppa (ядерный модуль + утилиты)..."
        pkg_install software-properties-common
        add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1 || warn "PPA подключить не вышло."
        pkg_update
        pkg_install amneziawg amneziawg-tools >/dev/null 2>&1 \
            || pkg_install amneziawg-dkms amneziawg-tools >/dev/null 2>&1 \
            || warn "Пакеты из PPA не поставились."
    fi
fi
have awg || { install_build_deps; install_tools_from_source; }

USE_KERNEL=0
if modprobe amneziawg 2>/dev/null; then
    USE_KERNEL=1
    echo amneziawg > /etc/modules-load.d/amneziawg.conf
    ok "Ядерный модуль amneziawg загружен (быстрый режим)."
else
    warn "Ядерного модуля нет — перехожу на userspace (amneziawg-go)."
    install_build_deps
    install_awg_go
    mkdir -p /etc/systemd/system/awg-quick@.service.d
    cat > /etc/systemd/system/awg-quick@.service.d/10-userspace.conf <<'UNIT'
[Service]
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
Environment=AWG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
UNIT
    systemctl daemon-reload
fi
state_set AWG_USE_KERNEL "$USE_KERNEL"

# systemd-юнит, если утилиты его не поставили
if ! systemctl cat "awg-quick@.service" >/dev/null 2>&1; then
    log "Создаю systemd-юнит awg-quick@.service..."
    cat > /etc/systemd/system/awg-quick@.service <<'UNIT'
[Unit]
Description=AmneziaWG via awg-quick(8) for %I
After=network-online.target nss-lookup.target
Wants=network-online.target nss-lookup.target
Documentation=man:awg-quick(8)

[Service]
Type=oneshot
RemainAfterExit=yes
Environment=WG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
Environment=AWG_QUICK_USERSPACE_IMPLEMENTATION=amneziawg-go
ExecStart=/usr/bin/awg-quick up %i
ExecStop=/usr/bin/awg-quick down %i
ExecReload=/bin/bash -c 'exec /usr/bin/awg syncconf %i <(exec /usr/bin/awg-quick strip %i)'

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
fi

# ------------------------------------------------- ключи и параметры обфускации
if [ -z "${AWG_PRIVATE_KEY:-}" ]; then
    log "Генерирую ключи сервера и параметры обфускации AmneziaWG..."
    priv=$(awg genkey); pub=$(printf '%s' "$priv" | awg pubkey)
    state_set AWG_PRIVATE_KEY "$priv"
    state_set AWG_PUBLIC_KEY "$pub"

    state_set AWG_JC   "$(rand_int 3 10)"     # число мусорных пакетов
    state_set AWG_JMIN 50                      # мин. размер мусорного пакета
    state_set AWG_JMAX 1000                    # макс. размер
    s1=$(rand_int 15 150)
    s2=$(rand_int 15 150)
    while [ $((s1 + 56)) -eq "$s2" ]; do s2=$(rand_int 15 150); done
    state_set AWG_S1 "$s1"
    state_set AWG_S2 "$s2"
    # H1..H4 — подменённые типы заголовков, должны быть уникальны и > 4
    h=(); while [ "${#h[@]}" -lt 4 ]; do
        n=$(rand_int 5 2147483000); dup=0
        for x in "${h[@]:-}"; do [ "$x" = "$n" ] && dup=1; done
        [ "$dup" = "0" ] && h+=("$n")
    done
    state_set AWG_H1 "${h[0]}"; state_set AWG_H2 "${h[1]}"
    state_set AWG_H3 "${h[2]}"; state_set AWG_H4 "${h[3]}"
    ok "Ключи и параметры обфускации готовы (Jc=${AWG_JC} S1=${AWG_S1} S2=${AWG_S2})."
fi

# --------------------------------------------------------------- конфиг
render_awg

systemctl enable "awg-quick@${AWG_IFACE}" >/dev/null 2>&1 || true
systemctl restart "awg-quick@${AWG_IFACE}"
sleep 2
if awg show "$AWG_IFACE" >/dev/null 2>&1; then
    ok "AmneziaWG поднят на UDP/${AWG_PORT} (интерфейс ${AWG_IFACE}, $( [ "$USE_KERNEL" = 1 ] && echo 'ядро' || echo 'userspace' ))."
else
    journalctl -u "awg-quick@${AWG_IFACE}" -n 30 --no-pager || true
    die "Интерфейс ${AWG_IFACE} не поднялся. Логи: journalctl -u awg-quick@${AWG_IFACE} -n 50"
fi
