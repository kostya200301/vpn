#!/usr/bin/env bash
# Диагностика всей инфраструктуры. Код выхода 0 — всё в порядке, 1 — есть ошибки.
#   health-check.sh [--quiet]   (--quiet: печатать только проблемы)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

QUIET=0
[[ ${1:-} == --quiet ]] && QUIET=1

FAILS=0
WARNS=0
pass() { [[ $QUIET -eq 1 ]] || log_ok "$*"; }
fail() { log_error "$*"; FAILS=$((FAILS + 1)); }
warn() { log_warn "$*"; WARNS=$((WARNS + 1)); }

require_root
require_cmd docker jq
load_env

[[ $QUIET -eq 1 ]] || step "Проверка работоспособности"

# 1. Docker
if docker info >/dev/null 2>&1; then
  pass "Docker работает ($(docker version --format '{{.Server.Version}}' 2>/dev/null))"
else
  fail "Docker daemon не отвечает: systemctl status docker"
fi
if have systemctl; then
  if [[ $(systemctl is-enabled docker 2>/dev/null || true) == enabled ]]; then
    pass "Docker включён в автозапуск"
  else
    fail "Docker не в автозапуске — после перезагрузки VPN не поднимется. Исправить: systemctl enable docker"
  fi
fi

# 2. Контейнеры
services=(xray)
telegram_enabled && services+=(mtproto)
for svc in "${services[@]}"; do
  name=$XRAY_CONTAINER
  [[ $svc == mtproto ]] && name=$MTG_CONTAINER
  if ! container_running "$name"; then
    fail "Контейнер $name не запущен. Логи: ./manage.sh logs $svc"
    continue
  fi
  restarts=$(docker inspect -f '{{.RestartCount}}' "$name")
  policy=$(docker inspect -f '{{.HostConfig.RestartPolicy.Name}}' "$name")
  started=$(docker inspect -f '{{.State.StartedAt}}' "$name" | cut -d. -f1)
  pass "Контейнер $name работает (с $started UTC, перезапусков: $restarts)"
  [[ $policy == unless-stopped || $policy == always ]] || fail "У $name нет политики автоперезапуска ($policy)"
  (( restarts < 5 )) || warn "$name перезапускался $restarts раз — проверьте логи"
done

# 3. Порты
if port_busy "$XRAY_PORT"; then pass "Порт VPN $XRAY_PORT/tcp слушается"; else fail "Порт $XRAY_PORT/tcp не слушается"; fi
if telegram_enabled; then
  if port_busy "$MTG_PORT"; then pass "Порт Telegram $MTG_PORT/tcp слушается"; else fail "Порт $MTG_PORT/tcp не слушается"; fi
fi

# 4. Конфигурация Xray
if [[ -f "$XRAY_DIR/config.json" ]]; then
  if validate_xray_file "$XRAY_DIR/config.json"; then
    pass "Конфигурация Xray корректна (xray run -test)"
  else
    fail "Конфигурация Xray некорректна"
  fi
  active=$(jq '[.inbounds[] | select(.tag=="vless-reality") | .settings.clients[]] | length' "$XRAY_DIR/config.json")
  pass "Активных VPN-клиентов в конфигурации: $active"
else
  fail "Нет $XRAY_DIR/config.json — выполните sudo ./install.sh"
fi

# 5. REALITY: TLS-рукопожатие через наш порт должно пройти (ответ проксируется с target)
out=$(timeout 12 openssl s_client -connect "127.0.0.1:$XRAY_PORT" -servername "$REALITY_SNI" \
        -tls1_3 </dev/null 2>/dev/null) || true
if grep -q 'TLSv1.3' <<<"$out"; then
  pass "REALITY отвечает: TLS 1.3 рукопожатие с SNI $REALITY_SNI проходит"
else
  fail "TLS-рукопожатие через порт $XRAY_PORT не прошло (проверьте доступность $REALITY_TARGET с сервера)"
fi

# 6. MTProto: TCP-соединение
if telegram_enabled; then
  if timeout 5 bash -c "exec 3<>/dev/tcp/127.0.0.1/$MTG_PORT" 2>/dev/null; then
    pass "MTProto-прокси принимает соединения"
  else
    fail "MTProto-прокси не принимает соединения на порту $MTG_PORT"
  fi
fi

# 7. Ошибки в логах за 15 минут (выводим только количество — без содержимого)
for svc in "${services[@]}"; do
  n=$(compose logs --since 15m --no-log-prefix "$svc" 2>/dev/null | grep -ciE 'error|fatal|panic' || true)
  if [[ ${n:-0} -eq 0 ]]; then
    pass "Логи $svc за 15 мин: ошибок нет"
  else
    warn "Логи $svc за 15 мин: строк с ошибками — $n (./manage.sh logs $svc)"
  fi
done

# 8. Время (REALITY чувствителен к рассинхронизации часов)
if have timedatectl; then
  if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || true) == yes ]]; then
    pass "Системное время синхронизировано (NTP)"
  else
    warn "Время не синхронизировано по NTP: timedatectl set-ntp true"
  fi
fi

# 9. Диск и память
free_mb=$(df -Pm "$PROJECT_DIR" | awk 'NR==2{print $4}')
if (( free_mb > 500 )); then pass "Свободно на диске: ${free_mb} МБ"; else warn "Мало места на диске: ${free_mb} МБ"; fi
mem_av=$(awk '/MemAvailable/{print int($2/1024)}' /proc/meminfo)
if (( mem_av > 64 )); then pass "Доступно памяти: ${mem_av} МБ"; else warn "Мало свободной памяти: ${mem_av} МБ"; fi

# 10. Firewall
if have ufw; then
  st=$(ufw status 2>/dev/null || true)
  if grep -q '^Status: active' <<<"$st"; then
    pass "UFW активен"
    grep -qE "^$XRAY_PORT/tcp[[:space:]]+ALLOW" <<<"$st" || warn "В UFW нет правила для $XRAY_PORT/tcp (./manage.sh firewall apply)"
    if telegram_enabled; then
      grep -qE "^$MTG_PORT/tcp[[:space:]]+ALLOW" <<<"$st" || warn "В UFW нет правила для $MTG_PORT/tcp (./manage.sh firewall apply)"
    fi
  else
    warn "UFW не активен (./manage.sh firewall apply)"
  fi
fi

# 11. BBR
cc=$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null || echo "?")
if [[ $cc == bbr ]]; then
  pass "TCP BBR включён"
elif [[ ${ENABLE_BBR:-yes} == yes ]]; then
  warn "TCP congestion control: $cc (BBR не включён)"
else
  pass "TCP congestion control: $cc (BBR отключён в настройках)"
fi

echo
if (( FAILS == 0 )); then
  log_ok "Итог: ошибок нет, предупреждений: $WARNS"
  exit 0
fi
log_error "Итог: ошибок: $FAILS, предупреждений: $WARNS"
exit 1
