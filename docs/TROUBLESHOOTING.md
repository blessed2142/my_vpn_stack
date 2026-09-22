# Если что-то не работает

## На сервере пропал DNS / нет интернета

Признак: `Could not resolve host: github.com`, `apt update` висит.

```bash
vpnctl diag          # раздел «Сеть» покажет resolv.conf, маршруты, ping, резолвинг
```

Быстрая развилка:

```bash
ping -c2 1.1.1.1              # пингуется, а имена не резолвятся -> проблема в DNS
getent hosts github.com
ip -6 route show default      # пусто, а раньше был -> см. accept_ra ниже
```

**Не резолвятся имена, IP пингуется.** Смотрите, кто управляет резолвингом:

```bash
readlink -f /etc/resolv.conf
systemctl is-active systemd-resolved
resolvectl status | head -20
```

Если работает **systemd-resolved** (обычный случай для Debian 12), писать в
`/etc/resolv.conf` бесполезно — это ссылка на генерируемый файл. Резолверы
задаются через drop-in:

```bash
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/99-vpnstack.conf <<'EOF'
[Resolve]
DNS=1.1.1.1 8.8.8.8 2606:4700:4700::1111
FallbackDNS=9.9.9.9 1.0.0.1
EOF
systemctl restart systemd-resolved
getent hosts github.com
```

Если resolved не используется и `/etc/resolv.conf` — обычный файл:

```bash
printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > /etc/resolv.conf
```

Установщик делает это сам (`ensure_dns`) перед установкой пакетов.

**Пропал только IPv6.** Включение `net.ipv6.conf.all.forwarding=1` (нужно для
VPN) заставляет ядро игнорировать Router Advertisement, и на серверах со SLAAC
исчезает маршрут по умолчанию. Лечится `accept_ra=2`, он уже прописан в
`/etc/sysctl.d/99-vpnstack.conf`; применить:

```bash
sysctl --system && systemctl restart systemd-networkd 2>/dev/null
```

**Ничего не пингуется.** Скорее всего правила firewall. Выключите и проверьте:

```bash
vpnctl firewall off
ping -c2 1.1.1.1
vpnctl firewall on
```

Начиная с текущей версии установщик сам проверяет связь после включения
firewall и откатывает правила, если она пропала.

## Куда указывает домен (если нет `dig`)

```bash
vpnctl dns aslanblessed.space    # на сервере: покажет A-записи и совпадение
```

Без vpnctl, на любой системе:

| Где | Команда |
|---|---|
| Linux (без доустановки) | `getent ahostsv4 aslanblessed.space` |
| Windows | `nslookup aslanblessed.space 8.8.8.8` |
| macOS | `nslookup aslanblessed.space 8.8.8.8` или `host aslanblessed.space` |
| Поставить `dig` на сервер | `apt install -y dnsutils` (Debian/Ubuntu), `dnf install -y bind-utils` (RHEL) |

Явно указанный резолвер (`8.8.8.8`) важен: локальный кэш может ещё держать
старый адрес, и проверка соврёт.

## Общая диагностика

```bash
vpnctl status          # сервисы, порты, пиры
vpnctl info            # параметры сервера
journalctl -u xray -n 50 --no-pager
journalctl -u hysteria-server -n 50 --no-pager
journalctl -u awg-quick@awg0 -n 50 --no-pager
```

## VLESS REALITY не подключается

Сначала выясните, доходят ли пакеты вообще:

```bash
vpnctl debug on      # включить подробные логи
#   -> попробовать подключиться с устройства
vpnctl debug log     # покажет логи и разберёт типовые ошибки
vpnctl debug off
```

* `REALITY: failed to read client hello` — пакеты доходят, но приложение не
  включило REALITY. Почти всегда неполный импорт ссылки: импортируйте по
  QR-коду (`vpnctl show <имя> --qr`) и проверьте в профиле `publicKey`,
  `shortId`, `sni`, `flow`.
* Записей нет вовсе — трафик до сервера не доходит, смотрите внешний firewall
  хостера (`vpnctl check-ports`).

### Прочие причины


* Проверьте, что клиент использует `flow = xtls-rprx-vision` и `fp = chrome`.
* `sni` в клиенте должен в точности совпадать с `REALITY_SNI` из `vpnctl info`.
* Маскировочный сайт мог перестать отдавать TLS 1.3 + h2. Сменить:
  `./install.sh --only xray --reality-sni www.nvidia.com` (ссылки после этого
  надо раздать заново: `vpnctl links`).
* Время на сервере обязано быть точным: `timedatectl` → NTP synchronized: yes.

## Hysteria 2 не подключается

* `HY2_TLS_MODE=selfsigned` → в клиенте должна стоять галочка «allow insecure».
* С ACME: проверьте, что A-запись домена указывает на сервер и порт 80/tcp
  открыт снаружи (Let's Encrypt ходит туда за проверкой).
* Провайдер режет UDP или QUIC → попробуйте другой порт:
  `./install.sh --only hysteria --hy2-port 8443`.
* Скорость упирается в ~100 Мбит → проверьте буферы:
  `sysctl net.core.rmem_max` должно быть 16777216.

## AmneziaWG: handshake не проходит

* Параметры `Jc/Jmin/Jmax/S1/S2/H1..H4` в клиенте обязаны совпадать с
  серверными (`vpnctl info`). Самый частый источник ошибки — конфиг,
  отредактированный руками.
* Обычный WireGuard-клиент не подойдёт, нужен AmneziaWG.
* Проверьте, что UDP-порт открыт: `nft list ruleset | grep 51820`.
* Userspace-режим требует `/dev/net/tun`. На OpenVZ/LXC его включает хостер.

## Интернет внутри туннеля не работает (handshake есть, сайтов нет)

```bash
sysctl net.ipv4.ip_forward            # должно быть 1
nft list table inet nat               # должно быть правило masquerade
```

Если сайты открываются по IP, но не по имени — проблема в DNS клиента,
поменяйте `DNS =` в его конфиге.

## Сайты «сломаны», большие страницы не грузятся

Проблема MTU. Уменьшите `AWG_MTU`:

```bash
sed -i "s/^AWG_MTU=.*/AWG_MTU='1360'/" /etc/vpnstack/state.env
vpnctl regen
```

и поправьте `MTU` в клиентских конфигах (`vpnctl links` выдаст обновлённые).

## Заблокировали доступ к серверу файрволом

Через панель хостера (VNC/console):

```bash
systemctl stop nftables && nft flush ruleset
```

затем поправьте `/etc/nftables.conf` и `nft -f /etc/nftables.conf`.
Бэкап старых правил: `/etc/nftables.conf.vpnstack-bak`.
