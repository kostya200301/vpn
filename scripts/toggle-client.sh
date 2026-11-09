#!/usr/bin/env bash
# Временно отключить / снова включить подключение (UUID сохраняется,
# после включения та же ссылка снова работает).
#   toggle-client.sh disable <имя>
#   toggle-client.sh enable  <имя>
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

ACTION=${1:-}
NAME=${2:-}
[[ $ACTION == enable || $ACTION == disable ]] || die "Использование: toggle-client.sh enable|disable <имя>"

require_root
require_cmd docker jq
load_env
clients_init

if [[ -z "$NAME" ]]; then
  is_interactive || die "Укажите имя клиента."
  echo "Клиенты: $(client_names | paste -sd ' ' -)"
  ask NAME "Имя подключения" ""
fi
validate_client_name "$NAME"
client_exists "$NAME" || die "Клиент '$NAME' не найден."

current=$(client_get "$NAME" | jq -r .enabled)
if [[ $ACTION == disable ]]; then
  [[ $current == "true" ]] || { log_info "'$NAME' уже отключён."; exit 0; }
  (( $(clients_active_count) > 1 )) || die "'$NAME' — последний активный клиент, его нельзя отключить."
  new=false
else
  [[ $current == "false" ]] || { log_info "'$NAME' уже включён."; exit 0; }
  new=true
fi

backup_db=$(mktemp)
cp -p "$CLIENTS_DB" "$backup_db"
client_set_enabled "$NAME" "$new"
if ! ( render_xray_config ); then
  cp -p "$backup_db" "$CLIENTS_DB"; rm -f "$backup_db"
  die "Изменение не применено."
fi
rm -f "$backup_db"
fix_permissions
apply_service xray
if [[ $new == true ]]; then
  log_ok "Подключение '$NAME' включено (прежняя ссылка снова работает)."
else
  log_ok "Подключение '$NAME' отключено."
fi
