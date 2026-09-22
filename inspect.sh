#!/usr/bin/env bash
# ============================================================================
#  inspect.sh — снимок конфигурации VPN-сервера для разбора.
#
#  Самодостаточный: ничего не требует, кроме обычных системных утилит, и не
#  зависит от vpnstack. Запускать на любом сервере, в том числе на том, где
#  VPN ставился совсем другим способом.
#
#      curl -fsSL https://raw.githubusercontent.com/blessed2142/my_vpn_stack/claude/vpn-server-setup-7jpufu/inspect.sh | bash
#
#  Секреты (ключи, пароли, UUID) маскируются: остаётся длина и первые символы,
#  чтобы можно было сравнивать, но не воспользоваться.
# ============================================================================
set -uo pipefail

OUT="${1:-/tmp/vpn-inspect-$(hostname -s 2>/dev/null || echo host)-$(date +%Y%m%d-%H%M%S).txt}"

h()   { printf '\n========== %s ==========\n' "$*"; }
sub() { printf '\n--- %s ---\n' "$*"; }
have(){ command -v "$1" >/dev/null 2>&1; }
run() { # run ОПИСАНИЕ КОМАНДА...
    local d="$1"; shift
    sub "$d"
    if have "${1##*/}" || [ -x "$1" ]; then "$@" 2>&1 | head -n 200; else echo "(нет ${1})"; fi
}
show() { # show ФАЙЛ [строк]
    local f="$1" n="${2:-200}"
    if [ -r "$f" ]; then sub "$f"; mask < "$f" | head -n "$n"; fi
}

# Маскировка секретов: структура остаётся, значения — нет.
mask() {
    sed -E \
      -e 's/\b([0-9a-fA-F]{8})-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b/<uuid \1…>/g' \
      -e 's/("(privateKey|PrivateKey|password|Password|PresharedKey|preSharedKey|psk|secret|token)"[[:space:]]*:[[:space:]]*")[^"]*"/\1****"/g' \
      -e 's/^([[:space:]]*(PrivateKey|PresharedKey)[[:space:]]*=[[:space:]]*).*/\1****/' \
      -e 's/^([[:space:]]*(password|Password|auth|obfs-password)[[:space:]]*:[[:space:]]*).*/\1****/' \
      -e 's/("(publicKey|shortId)"[[:space:]]*:[[:space:]]*")([^"]{6})[^"]*"/\1\3…"/g' \
      -e 's/^([[:space:]]*(PublicKey)[[:space:]]*=[[:space:]]*)(.{6}).*/\1\3…/'
}

{
echo "снимок собран: $(date -Is)"
echo "хост: $(hostname 2>/dev/null)"

h "СИСТЕМА"
[ -r /etc/os-release ] && (. /etc/os-release; echo "  ОС     : ${PRETTY_NAME:-?}")
echo "  ядро   : $(uname -r) $(uname -m)"
echo "  аптайм : $(uptime -p 2>/dev/null || uptime)"
echo "  время  : $(date -Is)"
have timedatectl && timedatectl 2>/dev/null | grep -Ei 'synchron|time zone' | sed 's/^/  /'
have systemd-detect-virt && echo "  виртуализация: $(systemd-detect-virt 2>/dev/null)"

h "СЕТЬ"
run "интерфейсы и MTU" ip -br addr
sub "MTU по интерфейсам"
ip link show 2>/dev/null | awk '/^[0-9]+:/{name=$2; for(i=1;i<=NF;i++) if($i=="mtu") print "  " name " mtu " $(i+1)}'
run "маршруты IPv4" ip -4 route
run "маршруты IPv6" ip -6 route
sub "внешние адреса"
echo "  v4 (по маршруту): $(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"
echo "  v6 (по маршруту): $(ip -6 route get 2606:4700:4700::1111 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") {print $(i+1); exit}}')"

h "ПОРТЫ"
run "слушающие сокеты" ss -lntup

h "FIREWALL"
sub "nftables"
if have nft; then nft list ruleset 2>/dev/null | head -n 250; echo "(конец правил)"; else echo "(нет nft)"; fi
sub "iptables"
have iptables-save && iptables-save 2>/dev/null | head -n 120 || echo "(нет iptables-save)"
sub "ip6tables"
have ip6tables-save && ip6tables-save 2>/dev/null | head -n 60 || echo "(нет)"
sub "ufw"
have ufw && ufw status verbose 2>/dev/null | head -n 40 || echo "(нет ufw)"
sub "firewalld"
have firewall-cmd && firewall-cmd --list-all 2>/dev/null | head -n 40 || echo "(нет firewalld)"
sub "ограничение MSS (важно для крупных пакетов)"
{ have nft && nft list ruleset 2>/dev/null | grep -i maxseg; } || true
{ have iptables-save && iptables-save 2>/dev/null | grep -i tcpmss; } || true
echo "(пусто — ограничения нет)"

h "SYSCTL"
for k in net.ipv4.ip_forward net.ipv6.conf.all.forwarding net.ipv4.tcp_congestion_control \
         net.core.default_qdisc net.core.rmem_max net.core.wmem_max \
         net.ipv4.tcp_mtu_probing net.ipv4.ip_no_pmtu_disc net.ipv4.tcp_fastopen \
         net.ipv6.conf.all.accept_ra net.ipv6.bindv6only; do
    printf '  %-38s = %s\n' "$k" "$(sysctl -n "$k" 2>/dev/null || echo '-')"
done

h "DNS"
echo "  resolv.conf -> $(readlink -f /etc/resolv.conf 2>/dev/null)"
grep -vE '^[[:space:]]*(#|$)' /etc/resolv.conf 2>/dev/null | sed 's/^/  /'
have resolvectl && resolvectl status 2>/dev/null | grep -E 'Current DNS|DNS Servers|Link [0-9]' | sed 's/^/  /'

h "СЕРВИСЫ VPN"
sub "запущенные процессы"
ps -eo pid,comm,args --no-headers 2>/dev/null \
  | grep -Ei 'xray|sing-box|hysteria|v2ray|wireguard|amneziawg|awg|openvpn|shadowsocks|trojan|naive|tuic|x-ui|marzban' \
  | grep -v grep | cut -c1-200 | sed 's/^/  /' || echo "  (нет)"
sub "юниты systemd"
have systemctl && systemctl list-units --type=service --state=running --no-pager --no-legend 2>/dev/null \
  | grep -Ei 'xray|sing|hyster|wg|amnezia|v2ray|ui|vpn|nginx|caddy|haproxy' | sed 's/^/  /' || echo "  (нет)"
sub "docker"
have docker && (docker ps --format '  {{.Names}}  {{.Image}}  {{.Ports}}' 2>/dev/null || echo "  (докер не отвечает)") || echo "  (нет docker)"

h "ВЕРСИИ"
for b in xray sing-box hysteria v2ray awg wg amneziawg-go caddy nginx; do
    if have "$b"; then printf '  %-14s %s\n' "$b" "$("$b" version 2>/dev/null | head -n1 || "$b" --version 2>&1 | head -n1)"; fi
done

h "КОНФИГИ XRAY / SING-BOX"
for f in /usr/local/etc/xray/config.json /etc/xray/config.json /opt/xray/config.json \
         /usr/local/etc/sing-box/config.json /etc/sing-box/config.json; do
    show "$f" 400
done
sub "дополнительные конфиги в каталогах"
for d in /usr/local/etc/xray /etc/xray /etc/sing-box; do
    [ -d "$d" ] && find "$d" -maxdepth 1 -name '*.json' 2>/dev/null | sed 's/^/  /'
done
sub "юнит xray"
have systemctl && systemctl cat xray 2>/dev/null | head -n 40 | sed 's/^/  /'

h "КОНФИГИ HYSTERIA"
for f in /etc/hysteria/config.yaml /etc/hysteria/config.json /opt/hysteria/config.yaml; do
    show "$f" 120
done

h "КОНФИГИ WIREGUARD / AMNEZIAWG"
for d in /etc/amnezia/amneziawg /etc/wireguard; do
    if [ -d "$d" ]; then
        for f in "$d"/*.conf; do [ -r "$f" ] && show "$f" 80; done
    fi
done
have awg && { sub "awg show"; awg show 2>/dev/null | mask | sed 's/^/  /'; }
have wg  && { sub "wg show";  wg show  2>/dev/null | mask | sed 's/^/  /'; }

h "ПАНЕЛИ (3x-ui / x-ui / marzban)"
for db in /etc/x-ui/x-ui.db /usr/local/x-ui/x-ui.db /etc/3x-ui/x-ui.db; do
    if [ -r "$db" ] && have sqlite3; then
        sub "инбаунды из $db"
        sqlite3 "$db" "select id,port,protocol,remark,stream_settings from inbounds;" 2>/dev/null \
          | mask | head -n 60 | sed 's/^/  /'
    elif [ -r "$db" ]; then
        echo "  найден $db (нет sqlite3, поставьте: apt install -y sqlite3)"
    fi
done
for f in /opt/marzban/.env /etc/opt/marzban/.env; do
    [ -r "$f" ] && { sub "$f"; grep -vE '^[[:space:]]*#' "$f" | mask | sed 's/^/  /'; }
done

h "СЕРТИФИКАТЫ"
have certbot && certbot certificates 2>/dev/null | grep -E 'Certificate Name|Domains|Expiry' | sed 's/^/  /'
for d in /etc/letsencrypt/live /root/.acme.sh; do
    [ -d "$d" ] && { sub "$d"; ls -1 "$d" 2>/dev/null | head -n 10 | sed 's/^/  /'; }
done

h "ЖУРНАЛЫ (последнее)"
for u in xray sing-box hysteria-server wg-quick@wg0 awg-quick@awg0; do
    if have systemctl && systemctl list-unit-files 2>/dev/null | grep -q "^${u}"; then
        sub "journalctl -u $u"
        journalctl -u "$u" -n 40 --no-pager 2>/dev/null | mask | sed 's/^/  /'
    fi
done

h "КОНЕЦ СНИМКА"
} 2>&1 | tee "$OUT" >/dev/null

echo
echo "Снимок сохранён: $OUT"
echo "Размер: $(wc -l < "$OUT") строк, $(du -h "$OUT" | cut -f1)"
echo
echo "Секреты замаскированы. Пришлите этот файл целиком."
echo "Посмотреть:  less $OUT"
