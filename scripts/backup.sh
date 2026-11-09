#!/usr/bin/env bash
# Резервная копия: .env (ключи, секреты) + data/ (клиенты, конфигурации).
# Архив содержит секреты — права 600, каталог backups/ в .gitignore.
#   backup.sh [--quiet]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

QUIET=0
[[ ${1:-} == --quiet ]] && QUIET=1

require_root
[[ -f "$ENV_FILE" ]] || die "Нечего сохранять: .env не найден (проект не установлен)."
load_env

mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"
file="$BACKUP_DIR/vpn-backup-$(date +%Y%m%d-%H%M%S).tar.gz"

tar -C "$PROJECT_DIR" --exclude='data/export' --exclude='*.candidate.json' \
  -czf "$file" .env data
chmod 600 "$file"
tar -tzf "$file" >/dev/null || die "Архив повреждён: $file"

# Ротация: оставляем BACKUP_KEEP последних
keep=${BACKUP_KEEP:-10}
[[ $keep =~ ^[0-9]+$ && $keep -ge 1 ]] || keep=10
mapfile -t old < <(ls -1t "$BACKUP_DIR"/vpn-backup-*.tar.gz 2>/dev/null | tail -n +"$((keep + 1))")
for f in "${old[@]}"; do rm -f -- "$f"; done

if [[ $QUIET -eq 1 ]]; then
  printf '%s\n' "$file"
else
  log_ok "Резервная копия создана: $file ($(du -h "$file" | cut -f1))"
  log_info "Скопировать на свой компьютер: scp root@${SERVER_ADDRESS:-SERVER}:$file ."
fi
