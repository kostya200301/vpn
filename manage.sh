#!/usr/bin/env bash
# =====================================================================
#  Управление VPN-сервером. Без аргументов — интерактивное меню.
#  sudo ./manage.sh <команда> [параметры]      (список: ./manage.sh help)
# =====================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

usage() {
  cat <<EOF
${C_BOLD}Использование:${C_RESET} sudo ./manage.sh <команда> [параметры]

${C_BOLD}Сервисы${C_RESET}
  install [--reconfigure]     установка / повторная настройка
  start | stop | restart      запуск / остановка / перезапуск всех сервисов
  status                      состояние контейнеров и потребление ресурсов
  logs [xray|mtproto] [N]     логи (последние N строк, по умолчанию 100, затем «живой» вывод)
  update [-y] [--no-git]      безопасное обновление (бэкап → проверка → откат при ошибке)
  health                      полная диагностика

${C_BOLD}Устройства (VPN, HAPP)${C_RESET}
  add-client <имя>            новое подключение + ссылка + QR-код
  remove-client <имя> [-y]    удалить подключение навсегда
  disable-client <имя>        временно отключить (ссылка сохраняется)
  enable-client <имя>         снова включить
  list-clients [--full]       список подключений
  show-config [<имя>] [--png] параметры сервера / ссылка и QR устройства

${C_BOLD}Telegram${C_RESET}
  telegram-link               ссылка и QR-код Telegram Proxy
  telegram-rotate [домен]     сменить секрет (старая ссылка перестанет работать)
  telegram-enable | telegram-disable

${C_BOLD}Обслуживание${C_RESET}
  backup                      резервная копия ключей, клиентов и настроек
  restore [<файл>]            восстановление из резервной копии
  firewall [apply|status]     правила UFW
  find-sni [--dry-run|--auto] подобрать сайт маскировки REALITY среди соседей VPS
                              (помогает, когда VPN не работает в мобильной сети)
  rotate-reality-keys         новые ключи REALITY (ВСЕ устройства нужно переподключить)
  uninstall [--purge]         удаление
EOF
}

run() { "$SCRIPTS_DIR/$1" "${@:2}"; }

need_installed() {
  require_root
  load_env
}

cmd_logs() {
  need_installed
  local svc="" lines=100 a
  for a in "$@"; do
    case "$a" in
      xray|mtproto) svc=$a ;;
      ''|*[!0-9]*) die "Неизвестный параметр: $a (xray|mtproto|число строк)" ;;
      *) lines=$a ;;
    esac
  done
  log_info "Ctrl+C — выход из просмотра логов."
  if [[ -n $svc ]]; then
    compose logs --tail "$lines" -f "$svc"
  else
    compose logs --tail "$lines" -f
  fi
}

cmd_status() {
  need_installed
  compose ps
  echo
  local ids
  ids=$(compose ps -q)
  if [[ -n "$ids" ]]; then
    # shellcheck disable=SC2086
    docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}\t{{.NetIO}}' $ids
  fi
  echo
  echo "Клиентов активных: $(clients_init; clients_active_count) | Telegram: $(telegram_enabled && echo включён || echo выключен)"
}

cmd_rotate_reality() {
  need_installed
  log_warn "Будут созданы новые ключи REALITY. Все текущие ссылки перестанут работать —"
  log_warn "каждое устройство придётся добавить в HAPP заново (show-config <имя>)."
  ask_yn "Продолжить?" N || { log_info "Отменено."; return 0; }
  "$SCRIPTS_DIR/backup.sh" --quiet >/dev/null
  run generate-keys.sh --rotate-reality
  load_env
  render_xray_config
  fix_permissions
  apply_service xray
  log_ok "Ключи заменены, Xray перезапущен. Новые ссылки: ./manage.sh show-config"
}

dispatch() {
  local cmd=${1:-help}
  shift || true
  case "$cmd" in
    install)            exec "$PROJECT_DIR/install.sh" "$@" ;;
    start)              need_installed; compose up -d; log_ok "Сервисы запущены." ;;
    stop)               need_installed; compose stop; log_ok "Сервисы остановлены (после перезагрузки VPS запустятся снова; полностью: uninstall)." ;;
    restart)            need_installed; compose up -d; compose restart; log_ok "Сервисы перезапущены." ;;
    status)             cmd_status ;;
    logs)               cmd_logs "$@" ;;
    update)             run update.sh "$@" ;;
    backup)             run backup.sh "$@" ;;
    restore)            run restore.sh "$@" ;;
    add-client)         run add-client.sh "$@" ;;
    remove-client)      run remove-client.sh "$@" ;;
    disable-client)     run toggle-client.sh disable "$@" ;;
    enable-client)      run toggle-client.sh enable "$@" ;;
    list-clients)       run list-clients.sh "$@" ;;
    show-config)        run show-config.sh "$@" ;;
    telegram-link)      run telegram.sh link ;;
    telegram-rotate)    run telegram.sh rotate "$@" ;;
    telegram-enable)    run telegram.sh enable ;;
    telegram-disable)   run telegram.sh disable ;;
    telegram-status)    run telegram.sh status ;;
    health)             run health-check.sh "$@" ;;
    firewall)           run firewall.sh "${1:-status}" ;;
    find-sni)           run find-sni.sh "$@" ;;
    rotate-reality-keys) cmd_rotate_reality ;;
    uninstall)          run uninstall.sh "$@" ;;
    help|-h|--help)     usage ;;
    *)                  log_error "Неизвестная команда: $cmd"; usage; exit 1 ;;
  esac
}

menu() {
  local items=(
    "status:Состояние сервисов"
    "health:Диагностика"
    "list-clients:Список устройств"
    "add-client:Добавить устройство"
    "show-config:Ссылка / QR устройства"
    "disable-client:Отключить устройство"
    "enable-client:Включить устройство"
    "remove-client:Удалить устройство"
    "telegram-link:Ссылка Telegram Proxy"
    "telegram-rotate:Сменить секрет Telegram"
    "find-sni:Подобрать сайт маскировки (если не работает мобильный интернет)"
    "logs:Логи (Ctrl+C — выход)"
    "restart:Перезапустить сервисы"
    "backup:Резервная копия"
    "restore:Восстановить из копии"
    "update:Обновить"
  )
  local i choice cmd name
  # Ctrl+C прерывает только текущую команду (например, просмотр логов), а не меню
  trap ':' INT
  while true; do
    echo
    echo "${C_BOLD}===== VPN Server: управление =====${C_RESET}"
    for i in "${!items[@]}"; do
      printf '  %2d) %s\n' "$((i + 1))" "${items[$i]#*:}"
    done
    printf '   0) Выход\n'
    read -r -p "Выберите пункт: " choice || exit 0
    [[ $choice == 0 || -z $choice ]] && exit 0
    if ! [[ $choice =~ ^[0-9]+$ ]] || (( choice < 1 || choice > ${#items[@]} )); then
      log_warn "Нет такого пункта."
      continue
    fi
    cmd=${items[$((choice - 1))]%%:*}
    case "$cmd" in
      add-client|remove-client|disable-client|enable-client)
        [[ $cmd != add-client ]] && { clients_init; echo "Устройства: $(client_names | paste -sd ' ' -)"; }
        read -r -p "Имя устройства: " name || continue
        [[ -n $name ]] || continue
        ( dispatch "$cmd" "$name" ) || true ;;
      show-config)
        read -r -p "Имя устройства (Enter — все): " name || continue
        if [[ -n $name ]]; then ( dispatch show-config "$name" ) || true; else ( dispatch show-config ) || true; fi ;;
      logs)
        ( dispatch logs ) || true ;;
      *)
        ( dispatch "$cmd" ) || true ;;
    esac
  done
}

if [[ $# -eq 0 ]]; then
  require_root
  [[ -f "$ENV_FILE" ]] || { log_warn "Проект ещё не установлен."; ask_yn "Запустить установку сейчас?" Y && exec "$PROJECT_DIR/install.sh"; exit 0; }
  menu
else
  dispatch "$@"
fi
