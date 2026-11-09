#!/usr/bin/env bash
# Удалить VPN-подключение навсегда (доступ устройства отзывается сразу).
#   remove-client.sh <имя> [-y]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

NAME=""
YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    -h|--help) sed -n '2,3p' "$0"; exit 0 ;;
    -*) die "Неизвестный параметр: $arg" ;;
    *) NAME=$arg ;;
  esac
done

require_root
require_cmd docker jq
load_env
clients_init

if [[ -z "$NAME" ]]; then
  is_interactive || die "Укажите имя: remove-client.sh <имя>"
  echo "Клиенты: $(client_names | paste -sd ' ' -)"
  ask NAME "Какое подключение удалить" ""
fi
validate_client_name "$NAME"
client_exists "$NAME" || die "Клиент '$NAME' не найден."

c=$(client_get "$NAME")
if [[ $(jq -r .enabled <<<"$c") == "true" && $(clients_active_count) -le 1 ]]; then
  die "'$NAME' — последний активный клиент. Сначала добавьте другой (add-client), затем удаляйте этот."
fi

if [[ $YES -eq 0 ]]; then
  ask_yn "Удалить подключение '$NAME' без возможности восстановления?" N || { log_info "Отменено."; exit 0; }
fi

backup_db=$(mktemp)
cp -p "$CLIENTS_DB" "$backup_db"
client_delete "$NAME"
if ! ( render_xray_config ); then
  cp -p "$backup_db" "$CLIENTS_DB"; rm -f "$backup_db"
  die "Клиент не удалён."
fi
rm -f "$backup_db" "$EXPORT_DIR/$NAME.png"
fix_permissions
apply_service xray
log_ok "Клиент '$NAME' удалён, его ссылка больше не работает."
