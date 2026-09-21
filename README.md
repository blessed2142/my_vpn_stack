# vpnstack — три VPN на одном сервере

Автоматическая установка и обслуживание трёх независимых VPN-протоколов
на одном Linux-сервере (Debian / Ubuntu, RHEL-семейство — best effort):

| # | Протокол | Порт | Чем хорош |
|---|----------|------|-----------|
| 1 | **VLESS + XTLS-Vision + REALITY** (Xray-core) | TCP **443** | Самый продвинутый на сегодня. Без своего TLS-сертификата: сервер «притворяется» чужим сайтом (например `www.microsoft.com`), активное зондирование получает настоящий ответ этого сайта. Максимальная скорость за счёт Vision (без двойного TLS). |
| 2 | **Hysteria 2** | UDP **443** | QUIC поверх UDP, отлично держит потери пакетов и «плохие» каналы (мобильный интернет, перегруженные магистрали). Включена обфускация **Salamander** — трафик не опознаётся как QUIC. |
| 3 | **AmneziaWG** | UDP **51820** | WireGuard с обфускацией от Amnezia (мусорные пакеты + подмена заголовков). Скорость WireGuard, но без характерной сигнатуры, по которой WG блокируют. |

TCP/443 и UDP/443 не конфликтуют — это разные протоколы транспорта.

---

## Быстрый старт

На сервере, под root:

```bash
apt update && apt install -y git
git clone https://github.com/blessed2142/my_vpn_stack /opt/vpnstack
cd /opt/vpnstack
./install.sh --domain vpn.example.com --email you@example.com --client main
```

Домен нужен только для Hysteria 2 (настоящий сертификат Let's Encrypt).
Заранее создайте **A-запись** `vpn.example.com → IPv4 сервера` (и `AAAA` на IPv6,
если он есть). Если домена нет или DNS ещё не разошёлся — скрипт сам возьмёт
самоподписанный сертификат и добавит `insecure=1` в ссылку; переключиться потом:

```bash
vpnctl tls-acme vpn.example.com you@example.com
```

Без домена вообще:

```bash
./install.sh --client main
```

В конце установки скрипт напечатает ссылки и QR-коды для первого клиента.

---

## Управление: `vpnctl`

```
vpnctl add <имя> [--qr]     создать клиента сразу во всех трёх протоколах
vpnctl del <имя>            удалить клиента отовсюду
vpnctl list                 список клиентов
vpnctl show <имя> [--qr]    ссылки и конфиги клиента
vpnctl links [--qr]         то же для всех клиентов
vpnctl status               состояние сервисов, портов, пиров
vpnctl info                 параметры сервера (SNI, ключи, порты, обфускация)
vpnctl regen                перегенерировать конфиги из состояния
vpnctl restart              перезапустить все сервисы
vpnctl tls-acme <домен> <email>   перевести Hysteria2 на Let's Encrypt
```

Конфиги клиентов сохраняются в `/etc/vpnstack/clients/<имя>/`:
`vless-reality.txt`, `hysteria2.txt`, `amneziawg.conf`.

---

## Опции установщика

```
--domain <домен>        домен для Hysteria2 / Let's Encrypt
--email <email>         email для Let's Encrypt
--endpoint <хост|IP>    адрес сервера в клиентских ссылках
--reality-sni <домен>   маскировочный сайт для REALITY (иначе подбирается сам)
--vless-port <порт>     TCP-порт VLESS (443)
--hy2-port <порт>       UDP-порт Hysteria2 (443)
--awg-port <порт>       UDP-порт AmneziaWG (51820)
--client <имя>          имя первого клиента (main)
--only base,xray,hysteria,awg   поставить только часть
--no-hy2-obfs           выключить Salamander
--no-ipv6               не выдавать IPv6 внутри туннеля
--no-firewall           не трогать nftables
--no-torrent-block      разрешить BitTorrent через VLESS
```

Повторный запуск `./install.sh` безопасен: ключи, пароли и клиенты берутся
из `/etc/vpnstack/state.env` и не перегенерируются.

---

## Что ещё делает установщик

* BBR + `fq`, увеличенные UDP-буферы (иначе Hysteria2 упирается в потолок ~100 Мбит),
  `tcp_mtu_probing`, лимит файловых дескрипторов.
* nftables: политика `drop` на входе, открыты только SSH (порт берётся из
  `sshd_config`), 80/tcp для ACME и три VPN-порта; NAT/masquerade и MSS-clamp
  для AmneziaWG; IPv6 внутри туннеля через ULA-префикс.
* Xray блокирует приватные диапазоны (клиент не попадёт в LAN сервера) и
  BitTorrent (чтобы не собрать abuse-жалобы). Отключается `--no-torrent-block`.

## Файлы

```
install.sh                 установщик
bin/vpnctl                 управление клиентами (→ /usr/local/bin/vpnctl)
lib/common.sh              общие функции, состояние
lib/render.sh              генерация конфигов всех трёх сервисов
lib/links.sh               ссылки, конфиги, QR
scripts/00-prepare.sh      пакеты, sysctl/BBR, nftables
scripts/10-xray-reality.sh Xray + VLESS Vision REALITY
scripts/20-hysteria2.sh    Hysteria 2 + Salamander + ACME
scripts/30-amneziawg.sh    AmneziaWG (модуль ядра или userspace)
docs/CLIENTS.md            какие приложения ставить и как подключаться
docs/SECURITY.md           что сделать с сервером сразу после установки
docs/TROUBLESHOOTING.md    если что-то не работает
```

Состояние (ключи, пароли, клиенты): `/etc/vpnstack/state.env`,
`/etc/vpnstack/clients.json` — права `600`, это ваши секреты, их и надо бэкапить.
