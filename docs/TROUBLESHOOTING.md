# Если что-то не работает

## Общая диагностика

```bash
vpnctl status          # сервисы, порты, пиры
vpnctl info            # параметры сервера
journalctl -u xray -n 50 --no-pager
journalctl -u hysteria-server -n 50 --no-pager
journalctl -u awg-quick@awg0 -n 50 --no-pager
```

## VLESS REALITY не подключается

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
