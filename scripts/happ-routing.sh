#!/usr/bin/env bash
# Профиль выборочной маршрутизации для HAPP: через VPN идут только заблокированные
# в РФ ресурсы и Telegram, остальное — напрямую (без задержки дробления).
#
#   happ-routing.sh            — ссылка happ://routing/onadd/... и QR-код
#   happ-routing.sh --png      — дополнительно сохранить QR в data/export/happ-routing.png
#   happ-routing.sh --json     — показать итоговый JSON профиля
#   happ-routing.sh --off      — ссылка, выключающая маршрутизацию в HAPP
#
# Списки: config/happ/routing.json (ProxySites — домены, ProxyIp — сети Telegram
# из core.telegram.org/resources/cidr.txt). Геофайлы (geosite/geoip) НЕ используются:
# на iOS туннель ограничен 50 МБ памяти, а большие списки блокировок его превышают.
# Формат профиля — документация HAPP: https://www.happ.su/main/ru/dev-docs/routing.md
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

TEMPLATE="$PROJECT_DIR/config/happ/routing.json"
MODE=link
PNG=0
for arg in "$@"; do
  case "$arg" in
    --png) PNG=1 ;;
    --json) MODE=json ;;
    --off) MODE=off ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

require_cmd jq base64

if [[ $MODE == off ]]; then
  link="happ://routing/off"
  echo "${C_BOLD}Выключить выборочную маршрутизацию (весь трафик снова через VPN):${C_RESET}"
  printf '%s\n\n' "$link"
  print_qr "$link"
  exit 0
fi

[[ -f "$TEMPLATE" ]] || die "Нет файла $TEMPLATE"
# LastUpdated меняется при каждой генерации — HAPP перекачает геофайлы
json=$(jq -c --arg ts "$(date +%s)" '.LastUpdated = $ts' "$TEMPLATE") \
  || die "config/happ/routing.json — некорректный JSON"

if [[ $MODE == json ]]; then
  jq . <<<"$json"
  exit 0
fi

link="happ://routing/onadd/$(printf '%s' "$json" | base64 -w0)"

echo "${C_BOLD}Профиль маршрутизации HAPP «$(jq -r .Name <<<"$json")»:${C_RESET}"
echo "через VPN — Telegram и заблокированные в РФ ресурсы, остальное — напрямую."
echo
printf '%s\n\n' "$link"
print_qr "$link"
echo
echo "Как добавить: отсканируйте QR камерой iPhone (откроется HAPP) или скопируйте"
echo "ссылку на телефон и откройте её. Затем переподключите VPN в HAPP."
echo "Выключить: sudo ./manage.sh happ-routing --off"

if [[ $PNG -eq 1 ]]; then
  require_cmd qrencode
  mkdir -p "$EXPORT_DIR"; chmod 700 "$EXPORT_DIR"
  qrencode -o "$EXPORT_DIR/happ-routing.png" -s 6 -m 2 "$link"
  chmod 600 "$EXPORT_DIR/happ-routing.png"
  log_ok "QR сохранён: $EXPORT_DIR/happ-routing.png"
fi
