#!/usr/bin/env bash
# Параметры подключения.
#   show-config.sh                 — общие параметры сервера + ссылки всех активных клиентов
#   show-config.sh <имя>           — ссылка и QR-код одного клиента
#   show-config.sh <имя> --png     — дополнительно сохранить QR в data/export/<имя>.png
#   show-config.sh <имя> --no-qr   — без QR-кода
#   show-config.sh <имя> --home | --mobile — только один профиль (Дом / Мобильный)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

NAME=""
PNG=0
QR=1
WHICH=all
for arg in "$@"; do
  case "$arg" in
    --png) PNG=1 ;;
    --home) WHICH=home ;;
    --mobile) WHICH=mobile ;;
    --no-qr) QR=0 ;;
    -h|--help) sed -n '2,7p' "$0"; exit 0 ;;
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
    "Public key:" "$REALITY_PUBLIC_KEY" \
    "Мобильный:" "${MOBILE_FRAGMENT:-выключен} (fragment=длина,интервал,пакеты)"
  echo
  echo "${C_BOLD}Активные подключения:${C_RESET}"
  while IFS= read -r n; do
    [[ -n "$n" ]] || continue
    print_client_links "$n" 0 | sed 's/^/  /'
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

if [[ $WHICH == mobile ]] && ! mobile_profile_enabled; then
  die "Профиль «Мобильный» выключен (MOBILE_FRAGMENT пустой в .env)."
fi
print_client_links "$NAME" "$QR" "$WHICH"
if [[ $PNG -eq 1 ]]; then
  require_cmd qrencode
  mkdir -p "$EXPORT_DIR"; chmod 700 "$EXPORT_DIR"
  if [[ $WHICH != mobile ]]; then
    qrencode -o "$EXPORT_DIR/$NAME.png" -s 8 -m 2 "$(client_link "$NAME" home)"
    chmod 600 "$EXPORT_DIR/$NAME.png"
    log_ok "QR «Дом» сохранён: $EXPORT_DIR/$NAME.png"
  fi
  if mobile_profile_enabled && [[ $WHICH != home ]]; then
    qrencode -o "$EXPORT_DIR/$NAME-mobile.png" -s 8 -m 2 "$(client_link "$NAME" mobile)"
    chmod 600 "$EXPORT_DIR/$NAME-mobile.png"
    log_ok "QR «Мобильный» сохранён: $EXPORT_DIR/$NAME-mobile.png"
  fi
  log_info "Удалите PNG-файлы после использования."
fi
