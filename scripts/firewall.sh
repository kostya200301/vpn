#!/usr/bin/env bash
# Настройка UFW. SSH-порт(ы) разрешаются ПЕРВЫМИ, до включения firewall,
# поэтому текущее SSH-подключение не обрывается.
#   firewall.sh apply    — разрешить SSH + порты VPN, включить UFW
#   firewall.sh status   — показать правила
#   firewall.sh remove   — удалить правила портов VPN (SSH и сам UFW не трогаются)
#
# Важно: Docker публикует порты через собственные правила iptables, в обход UFW.
# Поэтому наружу открыты только порты, явно опубликованные в docker-compose.yml.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

ACTION=${1:-status}

require_root
load_env

ensure_ufw() {
  if ! have ufw; then
    log_info "Устанавливаю ufw..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ufw >/dev/null
  fi
}

case "$ACTION" in
  apply)
    ensure_ufw
    mapfile -t ports < <(ssh_ports)
    if (( ${#ports[@]} == 0 )); then
      log_warn "Не удалось определить порт SSH — разрешаю стандартный 22/tcp."
      ports=(22)
    fi
    for p in "${ports[@]}"; do
      if [[ $p == "$XRAY_PORT" ]] || { telegram_enabled && [[ $p == "$MTG_PORT" ]]; }; then
        die "Порт SSH ($p) совпадает с портом VPN — измените порт в .env."
      fi
      ufw allow "$p/tcp" comment 'SSH (vpn-server)' >/dev/null
      log_ok "Разрешён SSH: $p/tcp"
    done
    ufw allow "$XRAY_PORT/tcp" comment 'vpn-server Xray' >/dev/null
    log_ok "Разрешён VPN: $XRAY_PORT/tcp"
    if telegram_enabled; then
      ufw allow "$MTG_PORT/tcp" comment 'vpn-server MTProto' >/dev/null
      log_ok "Разрешён Telegram Proxy: $MTG_PORT/tcp"
    fi
    if ufw status | grep -q '^Status: active'; then
      ufw reload >/dev/null
      log_ok "UFW уже был включён — правила добавлены."
    else
      ufw default deny incoming >/dev/null
      ufw default allow outgoing >/dev/null
      ufw --force enable >/dev/null
      log_ok "UFW включён: входящие запрещены, кроме перечисленных портов."
    fi
    ;;
  status)
    if have ufw; then ufw status verbose; else log_info "UFW не установлен."; fi
    ;;
  remove)
    have ufw || exit 0
    ufw delete allow "$XRAY_PORT/tcp" >/dev/null 2>&1 || true
    ufw delete allow "$MTG_PORT/tcp" >/dev/null 2>&1 || true
    log_ok "Правила портов VPN удалены (SSH-правила и UFW оставлены)."
    ;;
  *)
    die "Использование: firewall.sh apply|status|remove"
    ;;
esac
