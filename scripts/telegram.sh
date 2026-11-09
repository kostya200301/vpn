#!/usr/bin/env bash
# Управление MTProto-прокси для Telegram (mtg).
#   telegram.sh link              — ссылка tg:// и https://t.me + QR-код
#   telegram.sh rotate [домен]    — новый секрет (старая ссылка перестанет работать)
#   telegram.sh enable            — включить прокси
#   telegram.sh disable           — выключить прокси
#   telegram.sh status            — состояние контейнера
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

ACTION=${1:-link}
ARG=${2:-}

require_root
require_cmd docker jq
load_env

show_link() {
  telegram_enabled || die "Telegram-прокси выключен. Включить: ./manage.sh telegram-enable"
  [[ -n "${MTG_SECRET:-}" ]] || die "Секрет не сгенерирован. Выполните: ./manage.sh telegram-rotate"
  echo "${C_BOLD}Telegram Proxy (MTProto, FakeTLS):${C_RESET}"
  printf '  %-8s %s\n' "Сервер:" "$SERVER_ADDRESS" "Порт:" "$MTG_PORT" "Секрет:" "$MTG_SECRET"
  echo
  telegram_links
  echo
  print_qr "$(telegram_links | tail -n1)"
}

firewall_port() {
  local op=$1
  [[ ${FIREWALL_MANAGE:-yes} == yes ]] || return 0
  have ufw || return 0
  ufw status 2>/dev/null | grep -q '^Status: active' || return 0
  if [[ $op == allow ]]; then
    ufw allow "$MTG_PORT/tcp" comment 'vpn-server MTProto' >/dev/null
  else
    ufw delete allow "$MTG_PORT/tcp" >/dev/null 2>&1 || true
  fi
}

case "$ACTION" in
  link)
    show_link
    ;;
  rotate)
    if [[ -n "$ARG" ]]; then
      valid_host "$ARG" || die "Некорректный домен: $ARG"
      set_env MTG_DOMAIN "$ARG"
    fi
    if telegram_enabled; then
      ask_yn "Сгенерировать новый секрет? Старая ссылка у всех перестанет работать." Y || exit 0
    fi
    "$SCRIPTS_DIR/generate-keys.sh" --rotate-mtg
    load_env
    if telegram_enabled; then
      render_mtg_config
      fix_permissions
      apply_service mtproto
      log_ok "Секрет изменён, прокси перезапущен."
      echo
      show_link
    fi
    ;;
  enable)
    if telegram_enabled; then log_info "Telegram-прокси уже включён."; show_link; exit 0; fi
    if port_busy "$MTG_PORT"; then
      die "Порт $MTG_PORT занят ($(port_owner "$MTG_PORT")). Укажите другой: отредактируйте MTG_PORT в .env."
    fi
    set_env COMPOSE_PROFILES telegram
    "$SCRIPTS_DIR/generate-keys.sh"
    load_env
    render_mtg_config
    fix_permissions
    firewall_port allow
    compose up -d mtproto >/dev/null
    wait_container_stable "$MTG_CONTAINER" || die "Контейнер $MTG_CONTAINER не запустился. Логи: ./manage.sh logs mtproto"
    log_ok "Telegram-прокси включён."
    echo
    show_link
    ;;
  disable)
    compose --profile telegram rm -sf mtproto >/dev/null 2>&1 || true
    set_env COMPOSE_PROFILES ""
    firewall_port delete
    log_ok "Telegram-прокси выключен (секрет сохранён в .env)."
    ;;
  status)
    if ! telegram_enabled; then log_info "Telegram-прокси выключен."; exit 0; fi
    compose ps mtproto
    ;;
  -h|--help)
    sed -n '2,7p' "$0"
    ;;
  *)
    die "Неизвестное действие: $ACTION (link|rotate|enable|disable|status)"
    ;;
esac
