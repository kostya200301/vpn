#!/usr/bin/env bash
# Сквозной тест на чистой Ubuntu/Debian с Docker (GitHub Actions или тестовый VPS).
# ВНИМАНИЕ: выполняет настоящую установку, занимает порты 443 и 8443.
#   sudo bash tests/e2e.sh
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
ROOT=$PWD

pass() { printf '\e[32m[PASS]\e[0m %s\n' "$*"; }
fail() { printf '\e[31m[FAIL]\e[0m %s\n' "$*"; exit 1; }
envval() { grep "^$1=" .env | cut -d= -f2-; }

[[ $EUID -eq 0 ]] || fail "запустите от root"
export VPN_NONINTERACTIVE=1

# 1. Установка
./install.sh -y --skip-firewall || fail "install.sh"
pass "install.sh"
[[ $(stat -c %a .env) == 600 ]] || fail ".env должен иметь права 600"
pass ".env 600"

KEY1=$(envval REALITY_PRIVATE_KEY)
SEC1=$(envval MTG_SECRET)
UUID1=$(jq -r '.[0].uuid' data/clients.json)

# 2. Повторный запуск не меняет ключи и клиентов
./install.sh -y --skip-firewall >/dev/null || fail "повторный install.sh"
[[ $(envval REALITY_PRIVATE_KEY) == "$KEY1" ]] || fail "повторная установка сменила ключ REALITY"
[[ $(envval MTG_SECRET) == "$SEC1" ]] || fail "повторная установка сменила секрет MTProto"
[[ $(jq -r '.[0].uuid' data/clients.json) == "$UUID1" ]] || fail "повторная установка сменила UUID"
[[ $(jq length data/clients.json) == 1 ]] || fail "повторная установка добавила клиента"
pass "идемпотентность install.sh"

# 3. Клиенты
./manage.sh add-client laptop --no-qr >/dev/null || fail "add-client"
[[ $(jq length data/clients.json) == 2 ]] || fail "клиент не добавлен"
U2=$(jq -r '.[] | select(.name=="laptop") | .uuid' data/clients.json)
jq -e --arg u "$U2" '[.inbounds[0].settings.clients[].id] | index($u) != null' data/xray/config.json >/dev/null || fail "UUID нет в config.json"
./manage.sh add-client laptop >/dev/null 2>&1 && fail "дубликат имени разрешён"
./manage.sh add-client 'bad name' >/dev/null 2>&1 && fail "некорректное имя разрешено"
pass "add-client"

./manage.sh disable-client laptop >/dev/null || fail "disable-client"
jq -e --arg u "$U2" '[.inbounds[0].settings.clients[].id] | index($u) == null' data/xray/config.json >/dev/null || fail "отключённый клиент остался в config.json"
./manage.sh enable-client laptop >/dev/null || fail "enable-client"
jq -e --arg u "$U2" '[.inbounds[0].settings.clients[].id] | index($u) != null' data/xray/config.json >/dev/null || fail "клиент не вернулся"
pass "disable/enable-client"

LINK=$(./manage.sh show-config laptop --no-qr | grep '^vless://')
[[ $LINK =~ ^vless://[0-9a-f-]{36}@[^:]+:443\?encryption=none\&flow=xtls-rprx-vision\&security=reality\&sni=[^\&]+\&fp=chrome\&pbk=[A-Za-z0-9_-]{43}\&sid=[0-9a-f]{16}\&spx=%2F\&type=tcp\&headerType=none#.+ ]] \
  || fail "формат ссылки: $LINK"
pass "формат vless:// ссылки"

# 4. Реальное соединение через VPN: клиент Xray -> наш сервер -> интернет
IMG=$(docker inspect -f '{{.Config.Image}}' vpn-xray)
C=$(jq -c '.[] | select(.name=="laptop")' data/clients.json)
CLI_DIR=$(mktemp -d)
jq -n --arg id "$(jq -r .uuid <<<"$C")" --arg sid "$(jq -r .short_id <<<"$C")" \
      --arg sni "$(envval REALITY_SNI)" --arg pbk "$(envval REALITY_PUBLIC_KEY)" '{
  log: {loglevel: "warning"},
  inbounds: [{listen: "127.0.0.1", port: 10808, protocol: "socks", settings: {udp: false}}],
  outbounds: [{protocol: "vless",
    settings: {vnext: [{address: "127.0.0.1", port: 443,
      users: [{id: $id, encryption: "none", flow: "xtls-rprx-vision"}]}]},
    streamSettings: {network: "raw", security: "reality",
      realitySettings: {serverName: $sni, fingerprint: "chrome", password: $pbk, shortId: $sid, spiderX: "/"}}}]
}' > "$CLI_DIR/client.json"
chmod 755 "$CLI_DIR"; chmod 644 "$CLI_DIR/client.json"
docker run -d --rm --name vpn-e2e-client --network host -v "$CLI_DIR:/etc/xray:ro" "$IMG" run -c /etc/xray/client.json >/dev/null
sleep 3
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 20 -x socks5h://127.0.0.1:10808 https://www.gstatic.com/generate_204 || true)
docker rm -f vpn-e2e-client >/dev/null 2>&1 || true
[[ $code == 204 ]] || fail "трафик через VPN не прошёл (HTTP $code)"
pass "реальное VLESS+REALITY соединение (HTTP 204 через туннель)"

# Отключённый клиент не должен подключаться
./manage.sh disable-client laptop >/dev/null
docker run -d --rm --name vpn-e2e-client --network host -v "$CLI_DIR:/etc/xray:ro" "$IMG" run -c /etc/xray/client.json >/dev/null
sleep 3
code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 -x socks5h://127.0.0.1:10808 https://www.gstatic.com/generate_204 || true)
docker rm -f vpn-e2e-client >/dev/null 2>&1 || true
[[ $code != 204 ]] || fail "отключённый клиент всё ещё имеет доступ"
pass "отключённый клиент не получает доступ"
rm -rf "$CLI_DIR"

./manage.sh remove-client laptop -y >/dev/null || fail "remove-client"
[[ $(jq length data/clients.json) == 1 ]] || fail "клиент не удалён"
./manage.sh remove-client phone -y >/dev/null 2>&1 && fail "удалён последний активный клиент"
pass "remove-client"

# 5. Telegram
TG=$(./manage.sh telegram-link | grep '^tg://')
[[ $TG =~ ^tg://proxy\?server=[^\&]+\&port=8443\&secret=ee[0-9a-f]+$ ]] || fail "формат tg:// ссылки: $TG"
timeout 5 bash -c 'exec 3<>/dev/tcp/127.0.0.1/8443' || fail "mtg не принимает соединения"
VPN_NONINTERACTIVE=1 ./manage.sh telegram-rotate >/dev/null || fail "telegram-rotate"
[[ $(envval MTG_SECRET) != "$SEC1" ]] || fail "секрет не сменился"
pass "Telegram Proxy: ссылка, порт, смена секрета"

# 6. Backup / restore
B=$(./scripts/backup.sh --quiet)
[[ -f $B && $(stat -c %a "$B") == 600 ]] || fail "backup"
./manage.sh add-client tmpdev --no-qr >/dev/null
./manage.sh restore "$B" -y >/dev/null || fail "restore"
[[ $(jq length data/clients.json) == 1 ]] || fail "restore не вернул состояние"
pass "backup/restore"

# 7. Автозапуск: перезапуск Docker (имитация перезагрузки)
systemctl restart docker
sleep 8
for c in vpn-xray vpn-mtproto; do
  [[ $(docker inspect -f '{{.State.Running}}' "$c") == true ]] || fail "$c не поднялся после перезапуска Docker"
done
pass "контейнеры поднимаются после перезапуска Docker"

# 8. Безопасность контейнеров
for c in vpn-xray vpn-mtproto; do
  [[ $(docker inspect -f '{{.Config.User}}' "$c") =~ ^655 ]] || fail "$c работает от root"
  [[ $(docker inspect -f '{{.HostConfig.ReadonlyRootfs}}' "$c") == true ]] || fail "$c: rootfs не read-only"
  docker inspect -f '{{.HostConfig.CapDrop}}' "$c" | grep -q ALL || fail "$c: capabilities не сброшены"
done
pass "контейнеры: non-root, read-only, cap_drop ALL"

# 9. Секреты не попадают в Git
for p in .env data/clients.json data/xray/config.json data/mtproto/config.toml "$B"; do
  git -C "$ROOT" check-ignore -q --no-index "${p#"$ROOT"/}" || fail "Git не игнорирует $p"
done
docker logs vpn-xray 2>&1 | grep -q "$KEY1" && fail "ключ попал в логи"
pass "секреты исключены из Git и логов"

# 10. Итоговая диагностика
./manage.sh health || fail "health-check"
pass "ВСЕ ТЕСТЫ ПРОЙДЕНЫ"
