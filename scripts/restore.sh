#!/usr/bin/env bash
# Восстановление из резервной копии.
#   restore.sh                   — выбрать из списка backups/
#   restore.sh <файл.tar.gz> [-y]
# Перед восстановлением автоматически делается копия текущего состояния.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

FILE=""
YES=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    -*) die "Неизвестный параметр: $arg" ;;
    *) FILE=$arg ;;
  esac
done

require_root
require_cmd docker jq tar

if [[ -z "$FILE" ]]; then
  mapfile -t list < <(ls -1t "$BACKUP_DIR"/vpn-backup-*.tar.gz 2>/dev/null || true)
  (( ${#list[@]} > 0 )) || die "В $BACKUP_DIR нет резервных копий."
  is_interactive || die "Укажите файл: restore.sh <файл.tar.gz>"
  echo "Доступные резервные копии:"
  for i in "${!list[@]}"; do printf '  %d) %s\n' "$((i + 1))" "$(basename "${list[$i]}")"; done
  ask choice "Номер копии" "1"
  [[ $choice =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#list[@]} )) || die "Неверный выбор."
  FILE=${list[$((choice - 1))]}
fi
[[ -f "$FILE" ]] || die "Файл не найден: $FILE"

# Безопасность: архив может содержать только .env и data/
while IFS= read -r entry; do
  entry=${entry#./}
  [[ -z "$entry" ]] && continue
  if [[ $entry == *..* || $entry == /* ]] || ! [[ $entry == .env || $entry == data || $entry == data/* ]]; then
    die "Архив содержит недопустимый путь '$entry' — восстановление прервано."
  fi
done < <(tar -tzf "$FILE")
tar -tzf "$FILE" | grep -qE '^(\./)?\.env$' || die "В архиве нет .env — это не резервная копия vpn-server."

if [[ $YES -eq 0 ]]; then
  ask_yn "Восстановить из $(basename "$FILE")? Текущие ключи и клиенты будут заменены." N || { log_info "Отменено."; exit 0; }
fi

if [[ -f "$ENV_FILE" ]]; then
  safety=$("$SCRIPTS_DIR/backup.sh" --quiet)
  log_info "Текущее состояние сохранено: $safety"
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
tar -C "$tmpdir" -xzf "$FILE"
jq -e 'type == "array"' "$tmpdir/data/clients.json" >/dev/null 2>&1 || die "В архиве нет корректного data/clients.json."

if [[ -f "$ENV_FILE" ]]; then
  compose --profile telegram down --remove-orphans >/dev/null 2>&1 || true
fi

rm -rf -- "${PROJECT_DIR:?}/data"
mv "$tmpdir/data" "$PROJECT_DIR/data"
mv -f "$tmpdir/.env" "$ENV_FILE"
touch "$PROJECT_DIR/data/.gitkeep"

load_env
render_all
if [[ ${FIREWALL_MANAGE:-yes} == yes ]] && have ufw && ufw status 2>/dev/null | grep -q '^Status: active'; then
  "$SCRIPTS_DIR/firewall.sh" apply
fi
compose up -d --remove-orphans --force-recreate
log_ok "Восстановление завершено."
"$SCRIPTS_DIR/health-check.sh" || log_warn "Проверка выявила проблемы — смотрите вывод выше."
