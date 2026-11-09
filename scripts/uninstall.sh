#!/usr/bin/env bash
# Удаление VPN-сервера.
#   uninstall.sh            — остановить и удалить контейнеры, правила UFW для VPN, sysctl BBR
#   uninstall.sh --purge    — дополнительно удалить образы, .env, data/ и backups/ (необратимо!)
# Docker и сам каталог проекта не удаляются (см. README).
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

PURGE=0
YES=0
for arg in "$@"; do
  case "$arg" in
    --purge) PURGE=1 ;;
    -y|--yes) YES=1 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

require_root
require_cmd docker

echo "Будут остановлены и удалены контейнеры vpn-xray и vpn-mtproto."
[[ $PURGE -eq 1 ]] && echo "${C_RED}Также будут БЕЗВОЗВРАТНО удалены ключи, клиенты, резервные копии и образы.${C_RESET}"
if [[ $YES -eq 0 ]]; then
  ask_yn "Продолжить?" N || { log_info "Отменено."; exit 0; }
fi

if [[ -f "$ENV_FILE" ]]; then
  load_env
  if [[ $PURGE -eq 0 ]]; then
    f=$("$SCRIPTS_DIR/backup.sh" --quiet) && log_info "На всякий случай сохранена копия: $f"
  fi
  "$SCRIPTS_DIR/firewall.sh" remove || true
fi

compose --profile telegram down --remove-orphans || true
log_ok "Контейнеры удалены."

if [[ -f "$SYSCTL_FILE" ]]; then
  rm -f "$SYSCTL_FILE"
  log_ok "Удалён $SYSCTL_FILE (BBR вернётся к значению по умолчанию после перезагрузки)."
fi

if [[ $PURGE -eq 1 ]]; then
  if [[ $YES -eq 0 ]]; then
    is_interactive || die "Для --purge без терминала добавьте -y."
    read -r -p "Для подтверждения введите DELETE: " confirm
    [[ ${confirm:-} == DELETE ]] || { log_info "Удаление данных отменено."; exit 0; }
  fi
  compose --profile telegram down --rmi all >/dev/null 2>&1 || true
  rm -rf -- "${PROJECT_DIR:?}/data" "${PROJECT_DIR:?}/backups" "$ENV_FILE"
  mkdir -p "$PROJECT_DIR/data" "$PROJECT_DIR/backups"
  touch "$PROJECT_DIR/data/.gitkeep" "$PROJECT_DIR/backups/.gitkeep"
  log_ok "Ключи, клиенты, резервные копии и образы удалены."
fi

echo
log_info "Чтобы удалить и каталог проекта: cd .. && rm -rf $(basename "$PROJECT_DIR")"
