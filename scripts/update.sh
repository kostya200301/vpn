#!/usr/bin/env bash
# Безопасное обновление:
#   1) резервная копия;  2) git pull (если репозиторий чистый);
#   3) загрузка закреплённых образов;  4) генерация и ПРОВЕРКА конфигов новой версией Xray;
#   5) перезапуск;  6) health-check;  7) автоматический откат кода при неудаче.
#   update.sh [-y] [--no-git]
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

YES=0
USE_GIT=1
for arg in "$@"; do
  case "$arg" in
    -y|--yes) YES=1; VPN_NONINTERACTIVE=1 ;;
    --no-git) USE_GIT=0 ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

require_root
require_cmd docker jq git
load_env

step "1. Резервная копия"
BACKUP_FILE=$("$SCRIPTS_DIR/backup.sh" --quiet)
log_ok "Сохранено: $BACKUP_FILE"

PREV_COMMIT=""
CODE_UPDATED=0
if [[ $USE_GIT -eq 1 && -d "$PROJECT_DIR/.git" ]]; then
  step "2. Обновление кода из Git"
  # Репозиторий клонирован другим пользователем, а git запускается от root
  if ! git config --global --get-all safe.directory 2>/dev/null | grep -qxF "$PROJECT_DIR"; then
    git config --global --add safe.directory "$PROJECT_DIR" 2>/dev/null || true
  fi
  PREV_COMMIT=$(git -C "$PROJECT_DIR" rev-parse HEAD)
  if [[ -n "$(git -C "$PROJECT_DIR" status --porcelain --untracked-files=no)" ]]; then
    log_warn "В репозитории есть локальные изменения — git pull пропущен (git status)."
  elif git -C "$PROJECT_DIR" fetch --quiet; then
    upstream=$(git -C "$PROJECT_DIR" rev-parse '@{u}' 2>/dev/null || true)
    if [[ -n "$upstream" && "$upstream" != "$PREV_COMMIT" ]]; then
      git -C "$PROJECT_DIR" --no-pager log --oneline "HEAD..@{u}" | head -n 20
      if [[ $YES -eq 1 ]] || ask_yn "Применить эти изменения?" Y; then
        git -C "$PROJECT_DIR" pull --ff-only --quiet
        CODE_UPDATED=1
        log_ok "Код обновлён до $(git -C "$PROJECT_DIR" rev-parse --short HEAD)"
      fi
    else
      log_ok "Код актуален."
    fi
  else
    log_warn "git fetch не удался — обновляю только образы."
  fi
else
  step "2. Git пропущен"
fi

rollback() {
  log_error "$1"
  if [[ $CODE_UPDATED -eq 1 && -n "$PREV_COMMIT" ]]; then
    log_warn "Откатываю код к $PREV_COMMIT ..."
    git -C "$PROJECT_DIR" reset --hard --quiet "$PREV_COMMIT"
    (load_env; render_all; compose up -d --remove-orphans) || true
    log_warn "Код откачен. Данные не менялись; при необходимости: ./manage.sh restore $BACKUP_FILE"
  else
    log_warn "Восстановить прежнее состояние: ./manage.sh restore $BACKUP_FILE"
  fi
  exit 1
}

step "3. Загрузка образов"
log_info "Xray: $(image_of xray)"
telegram_enabled && log_info "mtg:  $(image_of mtproto)"
compose pull --quiet || rollback "Не удалось загрузить образы."

step "4. Генерация и проверка конфигураций"
( load_env; render_all ) || rollback "Новая версия не принимает конфигурацию."
log_ok "Конфигурации проверены."

step "5. Перезапуск сервисов"
# --force-recreate: контейнеры гарантированно перечитают новые конфигурации (обрыв ~2 сек)
compose up -d --remove-orphans --force-recreate || rollback "Не удалось запустить контейнеры."
wait_container_stable "$XRAY_CONTAINER" || rollback "Xray не запускается после обновления."
if telegram_enabled; then
  wait_container_stable "$MTG_CONTAINER" || rollback "mtg не запускается после обновления."
fi

step "6. Проверка"
"$SCRIPTS_DIR/health-check.sh" --quiet || rollback "Health-check выявил ошибки после обновления."

docker image prune -f >/dev/null 2>&1 || true
log_ok "Обновление завершено успешно."
