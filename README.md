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

Домен нужен **только для Hysteria 2** (настоящий сертификат Let's Encrypt).
VLESS REALITY маскируется под чужой сайт, AmneziaWG работает по IP — им домен не нужен.
Поддомен заводить необязательно, апекс подходит: `--domain example.com`.

Нужна **A-запись** `example.com → IPv4 сервера` (и `AAAA` на IPv6, если он есть).
Если DNS смотрит в другое место — скрипт возьмёт самоподписанный сертификат и
добавит `insecure=1` в ссылку; переключиться потом:

```bash
vpnctl tls-acme vpn.example.com you@example.com
```

Без домена вообще:

```bash
./install.sh --client main
```

### Если Hysteria 2 уже настроена руками

Установщик её не тронет, если передать `--keep-hysteria`: он прочитает порт из
вашего `/etc/hysteria/config.yaml`, откроет его в firewall и поставит только
VLESS и AmneziaWG. Управление пользователями Hysteria останется за вами.

```bash
./install.sh --keep-hysteria --client main
```

Если же хотите отдать Hysteria под `vpnctl`, запускайте без этого флага: старый
конфиг сохранится рядом как `config.yaml.manual-<дата>`, а логины и пароли
сгенерируются новые (ссылки придётся раздать заново — скрипт об этом предупредит).

Чтобы прежние ссылки продолжили работать, заберите старые учётки из бэкапа:

```bash
vpnctl import-hysteria            # возьмёт самый свежий config.yaml.manual-*
vpnctl import-hysteria /etc/hysteria/config.yaml.manual-20260101120000
```

Импортируются пользователи с их паролями и пароль обфускации Salamander.
Если старый порт отличался, команда об этом скажет — ссылки совпадут полностью
только когда совпадут и порт, и сертификат.

Уже есть сертификат от certbot? Установщик сам найдёт
`/etc/letsencrypt/live/<домен>/` и переиспользует его, добавив deploy-hook на
обновление после продления — повторно гонять ACME не будет. Свой сертификат из
другого места указывается явно: `--hy2-cert /path/cert.pem --hy2-key /path/key.pem`.

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

### Диагностика

```
vpnctl status                состояние сервисов, портов, пиров
vpnctl diag                  подробная диагностика (секреты замаскированы)
vpnctl selftest              подключиться к своему же VLESS настоящим клиентом
vpnctl probe                 перебрать маскировочные сайты и отпечатки TLS
vpnctl capture [порт] [сек]  доходят ли TLS-приветствия от клиента
vpnctl debug on|off|log      подробные логи Xray с разбором типовых ошибок
vpnctl firewall status|sync  сверить и перегенерировать правила под текущие порты
vpnctl inspect [файл]        снимок ВСЕЙ конфигурации сервера в один файл
```

`inspect` работает и отдельно от vpnstack — на любом сервере, где VPN ставился
каким угодно способом. Собирает систему, сеть, MTU, порты, firewall, sysctl,
DNS, конфиги Xray/sing-box/Hysteria/WireGuard, панели (3x-ui, marzban),
сертификаты и журналы. Секреты маскируются.

```bash
curl -fsSL https://raw.githubusercontent.com/blessed2142/my_vpn_stack/claude/vpn-server-setup-7jpufu/inspect.sh | bash
```

Нужен, чтобы сравнить рабочую установку с нерабочей.

### Настройка на ходу

```
vpnctl set-sni <домен>       сменить маскировочный домен (с проверкой)
vpnctl set-fp <отпечаток>    сменить отпечаток TLS в ссылках
vpnctl set-port <порт>       перенести VLESS на другой порт
vpnctl set-mss <байт|off>    ограничить MSS, если теряются крупные пакеты
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
--keep-hysteria         не трогать уже настроенную вручную Hysteria
--hy2-cert / --hy2-key  свой TLS-сертификат для Hysteria2
--hy2-insecure          пометить его как непроверяемый (insecure=1 в ссылке)
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
* Перед установкой проверяет, не занят ли нужный порт посторонним процессом,
  и останавливается с понятным сообщением, а не падает молча.
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
