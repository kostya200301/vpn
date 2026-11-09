#!/usr/bin/env bash
# Добавить VPN-подключение (отдельный UUID и shortId для устройства).
#   add-client.sh <имя> [--no-qr]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

NAME=""
SHOW_QR=1
for arg in "$@"; do
  case "$arg" in
    --no-qr) SHOW_QR=0 ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    -*) die "Неизвестный параметр: $arg" ;;
    *) NAME=$arg ;;
  esac
done

require_root
require_cmd docker jq openssl
load_env
clients_init

if [[ -z "$NAME" ]]; then
  is_interactive || die "Укажите имя: add-client.sh <имя>"
  ask NAME "Имя нового устройства (например iphone, win-laptop)" ""
fi
validate_client_name "$NAME"
client_exists "$NAME" && die "Клиент '$NAME' уже существует. Показать его: ./manage.sh show-config $NAME"

backup_db=$(mktemp)
cp -p "$CLIENTS_DB" "$backup_db"
client_add "$NAME"
if ! ( render_xray_config ); then
  cp -p "$backup_db" "$CLIENTS_DB"; rm -f "$backup_db"
  die "Клиент не добавлен."
fi
rm -f "$backup_db"
fix_permissions
apply_service xray
log_ok "Клиент '$NAME' добавлен, Xray перезапущен."

echo
echo "${C_BOLD}Ссылка для HAPP ($NAME):${C_RESET}"
link=$(client_link "$NAME")
printf '%s\n' "$link"
if [[ $SHOW_QR -eq 1 ]]; then
  echo
  print_qr "$link"
fi
