# Что сделать с сервером сразу

## 1. Пароль root

Установочный пароль от хостера считайте скомпрометированным — он лежит в
письме, в панели хостера, в переписке. Смените:

```bash
passwd
```

## 2. Вход по ключу вместо пароля

На своей машине:

```bash
ssh-keygen -t ed25519 -C "vpn-server"
ssh-copy-id root@<IP сервера>
```

Проверьте, что вход по ключу работает, и только потом на сервере:

```bash
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin prohibit-password/' /etc/ssh/sshd_config
systemctl restart ssh || systemctl restart sshd
```

Не закрывайте текущую SSH-сессию, пока не убедились, что новая открывается.

## 3. Автообновления безопасности

Debian/Ubuntu:

```bash
apt install -y unattended-upgrades
dpkg-reconfigure -plow unattended-upgrades
```

## 4. Защита от перебора SSH

```bash
apt install -y fail2ban
systemctl enable --now fail2ban
```

## 5. Бэкап секретов

Всё состояние — в двух файлах:

```
/etc/vpnstack/state.env      ключи REALITY, ключ сервера AmneziaWG, параметры обфускации
/etc/vpnstack/clients.json   UUID, пароли, ключи клиентов
```

Скопируйте их в надёжное место. С ними стек восстанавливается на новом
сервере одним `./install.sh` + `vpnctl regen` (поменяется только адрес).

## 6. Если меняли порт SSH

Установщик читает порт из `/etc/ssh/sshd_config` и открывает его в nftables.
Если вы меняете порт SSH **после** установки — сначала добавьте новый порт в
`/etc/nftables.conf`, примените (`nft -f /etc/nftables.conf`), и только потом
перезапускайте sshd.

## О чём стоит знать

* Логи Xray и Hysteria по умолчанию минимальны (`warning`), доступ по
  пользователям не журналируется отдельно — но systemd-журнал всё равно
  пишется, чистится через `journalctl --vacuum-time=7d`.
* BitTorrent через VLESS заблокирован по умолчанию (`--no-torrent-block`
  отключает). Это защита от abuse-жалоб хостеру, а не цензура: через
  AmneziaWG торренты пойдут в любом случае, если вам это нужно — помните,
  что жалобы прилетят на сервер.
