# Клиенты: что ставить и как подключаться

Сервер выдаёт каждому пользователю три независимых подключения. Ставьте то,
что лучше работает у вас прямо сейчас, и держите остальные как запасные.

## 1. VLESS + XTLS-Vision + REALITY

Формат: ссылка `vless://...` — импортируется из буфера обмена или QR.

| Платформа | Приложение |
|---|---|
| Android | **v2rayNG**, NekoBox, Hiddify |
| iOS / macOS | **Streisand**, Shadowrocket, FoXray, Hiddify |
| Windows | **v2rayN**, Hiddify, NekoRay |
| macOS | V2Box, Streisand, Hiddify |
| Linux | Nekoray, sing-box, Hiddify |
| Роутер | Xray-core в OpenWrt/Keenetic (пакет xray) |

Импорт: «Добавить из буфера обмена» → вставить ссылку → подключиться.

Ключевые поля, если вводите руками: `flow = xtls-rprx-vision`,
`security = reality`, `fingerprint = chrome`, `network = tcp`,
`pbk` — публичный ключ, `sid` — short id, `sni` — маскировочный домен.

## 2. Hysteria 2

Формат: ссылка `hy2://...`.

| Платформа | Приложение |
|---|---|
| Android | **NekoBox**, v2rayNG (свежие версии), Hiddify |
| iOS | **Streisand**, Shadowrocket, Hiddify |
| Windows / macOS / Linux | **Hiddify**, NekoRay, официальный `hysteria` CLI |

Если установка шла без домена, в ссылке есть `insecure=1` — клиент должен
разрешить самоподписанный сертификат (в приложениях это галочка
«Allow insecure» / «Skip cert verify»). С доменом и Let's Encrypt этого не нужно.

Hysteria 2 — лучший выбор, когда канал «рвёт»: мобильный интернет, Wi-Fi в
отеле, вечерние часы пик. На стабильном канале VLESS обычно чуть быстрее.

## 3. AmneziaWG

Формат: файл `amneziawg.conf` (или QR того же файла).

| Платформа | Приложение |
|---|---|
| Android / iOS | **AmneziaWG** (отдельное приложение) или **AmneziaVPN** |
| Windows / macOS / Linux | **AmneziaVPN** (десктоп) |
| Роутер | OpenWrt с пакетом amneziawg |

Импорт: в приложении «Добавить конфигурацию» → из файла или QR.

Обычный клиент WireGuard **не подойдёт** — он не понимает параметры
`Jc/Jmin/Jmax/S1/S2/H1..H4`. Нужен именно AmneziaWG.

## Какой протокол выбирать

* Всё работает → **VLESS REALITY** (быстрее всего, меньше всего заметен).
* Потери пакетов, нестабильный мобильный интернет → **Hysteria 2**.
* Нужен полноценный туннель на уровне устройства/роутера, весь трафик
  включая UDP-игры → **AmneziaWG**.
* Если провайдер начал резать UDP — VLESS на TCP/443 продолжит работать.
