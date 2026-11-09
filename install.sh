#!/usr/bin/env bash
# =====================================================================
#  Установка VPN-сервера: Xray (VLESS + REALITY) + MTProto-прокси Telegram.
#
#  sudo ./install.sh                  — установка (интерактивный мастер)
#  sudo ./install.sh -y               — без вопросов, со значениями по умолчанию
#  sudo ./install.sh --reconfigure    — заново пройти мастер (ключи и клиенты сохраняются)
#  sudo ./install.sh --skip-firewall  — не трогать UFW
#  sudo ./install.sh --force          — продолжить на неподдерживаемой ОС
#
#  Повторный запуск безопасен: существующие ключи, секреты и клиенты не меняются.
# =====================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

RECONFIGURE=0
SKIP_FIREWALL=0
FORCE=0
for arg in "$@"; do
  case "$arg" in
    -y|--yes|--non-interactive) VPN_NONINTERACTIVE=1 ;;
    --reconfigure) RECONFIGURE=1 ;;
    --skip-firewall) SKIP_FIREWALL=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg (см. --help)" ;;
  esac
done
export VPN_NONINTERACTIVE="${VPN_NONINTERACTIVE:-}"

TOTAL=12
n=0
next_step() { n=$((n + 1)); step "[$n/$TOTAL] $*"; }

# ---------------------------------------------------------------------
check_os() {
  [[ -f /etc/os-release ]] || die "Не удалось определить ОС (/etc/os-release отсутствует)."
  # shellcheck disable=SC1091
  . /etc/os-release
  OS_ID=${ID:-}
  OS_VER=${VERSION_ID:-}
  OS_CODENAME=${VERSION_CODENAME:-}
  case "$OS_ID:$OS_VER" in
    ubuntu:22.04|ubuntu:24.04|debian:12|debian:13)
      log_ok "ОС: ${PRETTY_NAME:-$OS_ID $OS_VER} — поддерживается"
      ;;
    ubuntu:*|debian:*)
      log_warn "ОС ${PRETTY_NAME:-$OS_ID $OS_VER} не тестировалась (поддерживаются Ubuntu 22.04/24.04, Debian 12/13)."
      if [[ $FORCE -eq 0 ]] && ! ask_yn "Продолжить на свой риск?" N; then
        die "Установка прервана. Используйте --force, чтобы продолжить."
      fi
      ;;
    *)
      [[ $FORCE -eq 1 ]] || die "ОС ${PRETTY_NAME:-$OS_ID} не поддерживается. Нужна Ubuntu 22.04/24.04 или Debian 12/13 (--force — на свой риск)."
      log_warn "Неподдерживаемая ОС — продолжаю из-за --force."
      ;;
  esac
  have apt-get || die "Нужен apt-get (Debian/Ubuntu)."
  have systemctl || die "Нужен systemd."
}

check_requirements() {
  local arch mem_mb disk_mb virt
  arch=$(uname -m)
  case "$arch" in
    x86_64|aarch64) log_ok "Архитектура: $arch" ;;
    *) die "Архитектура $arch не поддерживается (нужна x86_64 или aarch64)." ;;
  esac
  mem_mb=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
  if (( mem_mb < 400 )); then
    die "Мало памяти: ${mem_mb} МБ (минимум 512 МБ)."
  elif (( mem_mb < 900 )); then
    log_warn "Память: ${mem_mb} МБ — хватит, но рекомендуется от 1 ГБ."
  else
    log_ok "Память: ${mem_mb} МБ"
  fi
  disk_mb=$(df -Pm "$PROJECT_DIR" | awk 'NR==2{print $4}')
  (( disk_mb >= 1500 )) || die "Мало места на диске: ${disk_mb} МБ (нужно от 1.5 ГБ)."
  log_ok "Свободно на диске: ${disk_mb} МБ"
  virt=$(systemd-detect-virt 2>/dev/null || true)
  case "$virt" in
    openvz|lxc|lxc-libvirt)
      log_warn "Виртуализация $virt: Docker может работать ограниченно. Рекомендуется KVM."
      ;;
    *) log_ok "Виртуализация: ${virt:-none}" ;;
  esac
}

install_packages() {
  local pkgs=(ca-certificates curl gnupg jq qrencode openssl iproute2 tar bsdextrautils git)
  [[ $SKIP_FIREWALL -eq 0 ]] && pkgs+=(ufw)
  local missing=()
  local p
  for p in "${pkgs[@]}"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  if (( ${#missing[@]} == 0 )); then
    log_ok "Все системные пакеты уже установлены."
    return
  fi
  log_info "Устанавливаю: ${missing[*]}"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  apt-get install -y -qq "${missing[@]}" >/dev/null
  log_ok "Пакеты установлены."
}

install_docker() {
  if have docker && docker compose version >/dev/null 2>&1; then
    log_ok "Docker уже установлен: $(docker --version | cut -d, -f1), $(docker compose version --short 2>/dev/null | sed 's/^/Compose /')"
  else
    if have docker; then
      log_info "Docker есть, но нет плагина Compose — устанавливаю."
    else
      log_info "Docker не найден — устанавливаю из официального репозитория Docker."
    fi
    export DEBIAN_FRONTEND=noninteractive
    install -m 0755 -d /etc/apt/keyrings
    curl -fsSL "https://download.docker.com/linux/$OS_ID/gpg" -o /etc/apt/keyrings/docker.asc
    chmod a+r /etc/apt/keyrings/docker.asc
    printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/%s %s stable\n' \
      "$(dpkg --print-architecture)" "$OS_ID" "$OS_CODENAME" > /etc/apt/sources.list.d/docker.list
    apt-get update -qq
    if have docker; then
      apt-get install -y -qq docker-compose-plugin >/dev/null
    else
      apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin >/dev/null
    fi
    log_ok "Docker установлен: $(docker --version | cut -d, -f1)"
  fi
  systemctl enable --now docker >/dev/null 2>&1 || die "Не удалось запустить Docker (systemctl status docker)."
  docker info >/dev/null 2>&1 || die "Docker daemon не отвечает."
  log_ok "Docker запущен и включён в автозапуск."
}

ensure_time_sync() {
  if have timedatectl; then
    if [[ $(timedatectl show -p NTPSynchronized --value 2>/dev/null || true) != yes ]]; then
      timedatectl set-ntp true 2>/dev/null || true
      log_info "Включена синхронизация времени (NTP) — важно для REALITY."
    fi
  fi
}

prepare_dirs() {
  mkdir -p "$DATA_DIR" "$XRAY_DIR" "$MTG_DIR" "$EXPORT_DIR" "$BACKUP_DIR"
  touch "$DATA_DIR/.gitkeep" "$BACKUP_DIR/.gitkeep"
  chmod +x "$PROJECT_DIR"/install.sh "$PROJECT_DIR"/manage.sh "$SCRIPTS_DIR"/*.sh
  fix_permissions
  log_ok "Каталоги готовы: data/ (700), backups/ (700)"
}

# ---------------------------------------------------------------------
ask_reality_target() {
  local cur=${REALITY_SNI:-www.microsoft.com} d
  while true; do
    ask d "Сайт для маскировки REALITY (TLS 1.3 + HTTP/2)" "$cur"
    valid_host "$d" && ! is_ipv4 "$d" || { log_warn "Нужно доменное имя."; is_interactive || die "Некорректный REALITY_SNI"; continue; }
    log_info "Проверяю $d (TLS 1.3 + h2)..."
    if check_tls13_h2 "$d"; then
      log_ok "$d подходит."
      break
    fi
    log_warn "$d не прошёл проверку TLS 1.3 + h2 (или недоступен с сервера)."
    if ! is_interactive; then
      log_warn "Продолжаю с $d — проверьте позже: ./manage.sh health"
      break
    fi
    ask_yn "Всё равно использовать $d?" N && break
  done
  set_env REALITY_SNI "$d"
  set_env REALITY_TARGET "$d:443"
}

wizard() {
  local v
  echo
  echo "${C_BOLD}Мастер настройки${C_RESET} (Enter — значение по умолчанию)"

  v=${SERVER_ADDRESS:-}
  if [[ -z "$v" ]]; then
    log_info "Определяю публичный IP сервера..."
    v=$(detect_public_ip || true)
  fi
  while true; do
    ask v "Публичный IP или домен сервера" "$v"
    valid_host "${v:-}" && break
    log_warn "Некорректный адрес."
    is_interactive || die "Не удалось определить адрес сервера. Задайте SERVER_ADDRESS в .env и повторите."
    v=""
  done
  set_env SERVER_ADDRESS "$v"

  while true; do
    ask v "Порт VPN (TCP)" "${XRAY_PORT:-443}"
    valid_port "$v" && break
    log_warn "Некорректный порт."; is_interactive || die "Некорректный XRAY_PORT"
  done
  set_env XRAY_PORT "$v"

  ask_reality_target

  while true; do
    ask v "Метка сервера в названии подключения" "${SERVER_LABEL:-DE}"
    [[ $v =~ ^[A-Za-z0-9_-]{1,16}$ ]] && break
    log_warn "Только латиница/цифры/-/_ (до 16)."; is_interactive || die "Некорректный SERVER_LABEL"
  done
  set_env SERVER_LABEL "$v"

  if ask_yn "Включить MTProto-прокси для Telegram?" Y; then
    set_env COMPOSE_PROFILES telegram
    while true; do
      ask v "Порт Telegram Proxy (TCP)" "${MTG_PORT:-8443}"
      if valid_port "$v" && [[ $v != "$XRAY_PORT" ]]; then break; fi
      log_warn "Некорректный порт или совпадает с портом VPN."; is_interactive || die "Некорректный MTG_PORT"
    done
    set_env MTG_PORT "$v"
    while true; do
      ask v "Домен маскировки FakeTLS для Telegram" "${MTG_DOMAIN:-$REALITY_SNI}"
      valid_host "$v" && ! is_ipv4 "$v" && break
      log_warn "Нужно доменное имя."; is_interactive || die "Некорректный MTG_DOMAIN"
    done
    if [[ -n "${MTG_SECRET:-}" && "$v" != "${MTG_DOMAIN:-}" ]]; then
      log_info "Домен изменён — секрет Telegram будет перегенерирован."
      set_env MTG_SECRET ""
    fi
    set_env MTG_DOMAIN "$v"
  else
    set_env COMPOSE_PROFILES ""
  fi

  if [[ $SKIP_FIREWALL -eq 0 ]]; then
    if ask_yn "Настроить firewall UFW (SSH будет разрешён первым)?" Y; then
      set_env FIREWALL_MANAGE yes
    else
      set_env FIREWALL_MANAGE no
    fi
  fi
  if ask_yn "Включить TCP BBR (ускорение)?" Y; then set_env ENABLE_BBR yes; else set_env ENABLE_BBR no; fi
}

configure_env() {
  local fresh=0
  if [[ ! -f "$ENV_FILE" ]]; then
    cp "$ENV_EXAMPLE" "$ENV_FILE"
    chmod 600 "$ENV_FILE"
    fresh=1
  fi
  load_env
  # Заполняем отсутствующие ключи (новые версии проекта могут добавлять параметры)
  local k
  while IFS='=' read -r k _; do
    [[ $k =~ ^[A-Z][A-Z0-9_]*$ ]] || continue
    grep -q "^$k=" "$ENV_FILE" || set_env "$k" "$(grep "^$k=" "$ENV_EXAMPLE" | head -n1 | cut -d= -f2-)"
  done < <(grep -E '^[A-Z][A-Z0-9_]*=' "$ENV_EXAMPLE")

  if [[ $fresh -eq 1 || $RECONFIGURE -eq 1 || -z "${SERVER_ADDRESS:-}" ]]; then
    wizard
  else
    log_ok "Найден существующий .env — настройки сохранены (изменить: --reconfigure)."
  fi
  load_env
}

pull_images() {
  local svcs=(xray)
  telegram_enabled && svcs+=(mtproto)
  local s
  for s in "${svcs[@]}"; do log_info "Образ $s: $(image_of "$s")"; done
  compose pull --quiet "${svcs[@]}" || die "Не удалось загрузить образы Docker (проверьте интернет/DNS)."
  log_ok "Образы загружены."
}

ensure_first_client() {
  clients_init
  if [[ $(jq length "$CLIENTS_DB") -gt 0 ]]; then
    log_ok "Клиентов уже есть: $(jq length "$CLIENTS_DB") (активных: $(clients_active_count))"
    if (( $(clients_active_count) == 0 )); then
      die "Все клиенты отключены. Включите один: ./manage.sh enable-client <имя>"
    fi
    return
  fi
  local name
  while true; do
    ask name "Имя первого устройства" "phone"
    [[ $name =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] && break
    log_warn "Латиница, цифры, '-', '_' (до 32)."; is_interactive || die "Некорректное имя"
  done
  client_add "$name"
  log_ok "Создан клиент '$name' (уникальные UUID и shortId)."
}

enable_bbr() {
  [[ ${ENABLE_BBR:-yes} == yes ]] || { log_info "BBR: пропущено по настройке."; return; }
  if [[ $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null) == bbr ]]; then
    log_ok "TCP BBR уже включён."
    return
  fi
  modprobe tcp_bbr 2>/dev/null || true
  if grep -qw bbr /proc/sys/net/ipv4/tcp_available_congestion_control 2>/dev/null; then
    printf 'net.core.default_qdisc=fq\nnet.ipv4.tcp_congestion_control=bbr\n' > "$SYSCTL_FILE"
    sysctl -q -p "$SYSCTL_FILE" || true
    log_ok "TCP BBR включён ($SYSCTL_FILE)."
  else
    log_warn "Ядро не поддерживает BBR — пропускаю."
  fi
}

check_ports() {
  local p owner
  local ports=("$XRAY_PORT")
  telegram_enabled && ports+=("$MTG_PORT")
  for p in "${ports[@]}"; do
    if port_busy "$p"; then
      owner=$(port_owner "$p")
      # Порт держит docker-proxy нашего же проекта — это нормально при повторной установке
      if [[ $owner == docker-proxy ]] && compose ps -q 2>/dev/null | grep -q .; then
        log_ok "Порт $p/tcp уже используется этим проектом."
        continue
      fi
      die "Порт $p/tcp занят процессом '${owner:-неизвестно}'. Освободите его или выберите другой: sudo ./install.sh --reconfigure"
    fi
    log_ok "Порт $p/tcp свободен."
  done
  local s
  while IFS= read -r s; do
    if [[ $s == "$XRAY_PORT" ]] || { telegram_enabled && [[ $s == "$MTG_PORT" ]]; }; then
      die "Порт $s используется SSH. Выберите другой порт VPN: sudo ./install.sh --reconfigure"
    fi
  done < <(ssh_ports)
}

start_services() {
  compose up -d --remove-orphans --force-recreate
  wait_container_stable "$XRAY_CONTAINER" || { compose logs --tail 30 xray >&2 || true; die "Xray не запустился."; }
  log_ok "Xray запущен."
  if telegram_enabled; then
    wait_container_stable "$MTG_CONTAINER" || { compose logs --tail 30 mtproto >&2 || true; die "mtg не запустился."; }
    log_ok "MTProto-прокси запущен."
  else
    compose --profile telegram rm -sf mtproto >/dev/null 2>&1 || true
  fi
}

print_summary() {
  local first
  first=$(jq -r 'first(.[] | select(.enabled) | .name)' "$CLIENTS_DB")
  echo
  echo "${C_GREEN}${C_BOLD}=============================================================${C_RESET}"
  echo "${C_GREEN}${C_BOLD}  Установка завершена${C_RESET}"
  echo "${C_GREEN}${C_BOLD}=============================================================${C_RESET}"
  echo
  echo "${C_BOLD}VPN для HAPP — устройство '$first':${C_RESET}"
  echo
  print_client_links "$first" 1
  echo
  echo "Отсканируйте QR в HAPP (кнопка «+» → QR-код) или скопируйте ссылку"
  echo "и в HAPP нажмите «+» → «Вставить из буфера обмена»."
  mobile_profile_enabled && echo "Профиль «-mob» — для мобильного интернета (дробление ClientHello против DPI оператора)."
  if telegram_enabled; then
    echo
    echo "${C_BOLD}Telegram Proxy:${C_RESET}"
    telegram_links
    echo
    print_qr "$(telegram_links | tail -n1)"
  fi
  echo
  echo "${C_BOLD}Дальше:${C_RESET}"
  echo "  sudo ./manage.sh add-client laptop   — подключение для нового устройства"
  echo "  sudo ./manage.sh list-clients        — список устройств"
  echo "  sudo ./manage.sh show-config phone   — ссылка и QR существующего устройства"
  echo "  sudo ./manage.sh health              — диагностика"
  echo "  sudo ./manage.sh                     — меню управления"
  echo
  log_warn "Ссылки выше — это секреты. Не публикуйте их и не делитесь скриншотами терминала."
}

# ---------------------------------------------------------------------
main() {
  require_root
  echo "${C_BOLD}VPN Server installer${C_RESET} — Xray VLESS+REALITY и MTProto для Telegram"

  next_step "Проверка операционной системы";          check_os
  next_step "Проверка системных требований";          check_requirements
  next_step "Установка системных пакетов";            install_packages
  next_step "Проверка и установка Docker";            install_docker; ensure_time_sync
  next_step "Структура каталогов";                    prepare_dirs
  next_step "Параметры установки";                    configure_env
  next_step "Загрузка Docker-образов";                pull_images
  next_step "Генерация ключей и секретов";            "$SCRIPTS_DIR/generate-keys.sh"; load_env; ensure_first_client
  next_step "Генерация конфигураций Xray и MTProto";  render_all; log_ok "Конфигурации созданы и проверены (xray run -test)."
  next_step "Сеть: порты, firewall, BBR"
  check_ports
  if [[ $SKIP_FIREWALL -eq 0 && ${FIREWALL_MANAGE:-yes} == yes ]]; then
    "$SCRIPTS_DIR/firewall.sh" apply
  else
    log_info "Firewall: пропущено."
  fi
  enable_bbr
  next_step "Запуск контейнеров";                     start_services
  next_step "Проверка работоспособности"
  "$SCRIPTS_DIR/health-check.sh" --quiet || log_warn "Есть проблемы — подробнее: sudo ./manage.sh health"

  print_summary
}

# Запуск только при прямом вызове (при source — для тестов — только функции)
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
