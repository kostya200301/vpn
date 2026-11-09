#!/usr/bin/env bash
# Параметры подключения.
#   show-config.sh                 — общие параметры сервера + ссылки всех активных клиентов
#   show-config.sh <имя>           — ссылка и QR-код одного клиента
#   show-config.sh <имя> --png     — дополнительно сохранить QR в data/export/<имя>.png
#   show-config.sh <имя> --no-qr   — без QR-кода
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

NAME=""
PNG=0
QR=1
for arg in "$@"; do
  case "$arg" in
    --png) PNG=1 ;;
    --no-qr) QR=0 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    -*) die "Неизвестный параметр: $arg" ;;
    *) NAME=$arg ;;
  esac
done

require_root
require_cmd jq
load_env
require_reality_env
clients_init

if [[ -z "$NAME" ]]; then
  echo "${C_BOLD}Сервер VLESS + REALITY${C_RESET}"
  printf '  %-14s %s\n' "Адрес:" "$SERVER_ADDRESS" "Порт:" "$XRAY_PORT/tcp" \
    "Протокол:" "VLESS, flow $VLESS_FLOW" "Безопасность:" "REALITY" \
    "SNI:" "$REALITY_SNI" "Fingerprint:" "$CLIENT_FINGERPRINT" \
    "Public key:" "$REALITY_PUBLIC_KEY"
  echo
  echo "${C_BOLD}Активные подключения:${C_RESET}"
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    echo "  [$n]"
    echo "  $(client_link "$n")"
    echo
  done < <(jq -r '.[] | select(.enabled) | .name' "$CLIENTS_DB")
  echo "QR-код конкретного устройства: ./manage.sh show-config <имя>"
  if telegram_enabled && [[ -n "${MTG_SECRET:-}" ]]; then
    echo
    echo "${C_BOLD}Telegram Proxy:${C_RESET}"
    telegram_links | sed 's/^/  /'
  fi
  exit 0
fi

validate_client_name "$NAME"
client_exists "$NAME" || die "Клиент '$NAME' не найден. Список: ./manage.sh list-clients"
[[ $(client_get "$NAME" | jq -r .enabled) == "true" ]] || \
  log_warn "Подключение '$NAME' сейчас ОТКЛЮЧЕНО — ссылка не будет работать, пока его не включить."

link=$(client_link "$NAME")
echo "${C_BOLD}Ссылка для HAPP ($NAME):${C_RESET}"
printf '%s\n' "$link"
if [[ $QR -eq 1 ]]; then
  echo
  print_qr "$link"
fi
if [[ $PNG -eq 1 ]]; then
  require_cmd qrencode
  mkdir -p "$EXPORT_DIR"; chmod 700 "$EXPORT_DIR"
  qrencode -o "$EXPORT_DIR/$NAME.png" -s 8 -m 2 "$link"
  chmod 600 "$EXPORT_DIR/$NAME.png"
  log_ok "QR сохранён: $EXPORT_DIR/$NAME.png (удалите файл после использования)"
fi
