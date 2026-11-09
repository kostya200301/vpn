#!/usr/bin/env bash
# Список VPN-подключений. UUID по умолчанию маскируется.
#   list-clients.sh [--full]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

FULL=0
[[ ${1:-} == --full ]] && FULL=1

require_root
require_cmd jq
clients_init

total=$(jq length "$CLIENTS_DB")
if [[ $total -eq 0 ]]; then
  log_info "Клиентов нет. Добавьте: ./manage.sh add-client <имя>"
  exit 0
fi

{
  printf 'ИМЯ\tСТАТУС\tСОЗДАН (UTC)\tUUID\n'
  jq -r --argjson full "$FULL" '.[] | [
      .name,
      (if .enabled then "активен" else "отключён" end),
      .created_at,
      (if $full == 1 then .uuid else (.uuid[0:8] + "-****") end)
    ] | @tsv' "$CLIENTS_DB"
} | if have column; then column -t -s $'\t'; else cat; fi

echo
echo "Всего: $total, активных: $(clients_active_count)"
