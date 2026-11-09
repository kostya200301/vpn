# shellcheck shell=bash
# =====================================================================
#  Общие функции для install.sh, manage.sh и scripts/*.sh.
#  Подключается через: source "<project>/lib/common.sh"
# =====================================================================

if [[ -n "${VPN_COMMON_LOADED:-}" ]]; then
  return 0
fi
VPN_COMMON_LOADED=1

set -Eeuo pipefail
umask 077

# ---------- Пути ----------
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ENV_FILE:-$PROJECT_DIR/.env}"
ENV_EXAMPLE="$PROJECT_DIR/.env.example"
COMPOSE_FILE="$PROJECT_DIR/docker-compose.yml"
DATA_DIR="$PROJECT_DIR/data"
CLIENTS_DB="$DATA_DIR/clients.json"
XRAY_DIR="$DATA_DIR/xray"
MTG_DIR="$DATA_DIR/mtproto"
EXPORT_DIR="$DATA_DIR/export"
BACKUP_DIR="$PROJECT_DIR/backups"
SCRIPTS_DIR="$PROJECT_DIR/scripts"
XRAY_TEMPLATE="$PROJECT_DIR/config/xray/config.template.json"
MTG_TEMPLATE="$PROJECT_DIR/config/mtproto/config.template.toml"
SYSCTL_FILE="/etc/sysctl.d/99-vpn-server.conf"

# Внутренние параметры контейнеров (должны совпадать с docker-compose.yml)
XRAY_UID=65532
MTG_UID=65534
XRAY_INTERNAL_PORT=10443
MTG_INTERNAL_PORT=3128
XRAY_CONTAINER="vpn-xray"
MTG_CONTAINER="vpn-mtproto"
VLESS_FLOW="xtls-rprx-vision"

# ---------- Вывод ----------
if [[ -t 1 ]]; then
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'; C_BLUE=$'\e[34m'
  C_BOLD=$'\e[1m'; C_RESET=$'\e[0m'
else
  C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_BOLD=""; C_RESET=""
fi

log_info()  { printf '%s[i]%s %s\n' "$C_BLUE" "$C_RESET" "$*"; }
log_ok()    { printf '%s[✓]%s %s\n' "$C_GREEN" "$C_RESET" "$*"; }
log_warn()  { printf '%s[!]%s %s\n' "$C_YELLOW" "$C_RESET" "$*" >&2; }
log_error() { printf '%s[✗]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; }
die()       { log_error "$*"; exit 1; }
step()      { printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"; }

# Сообщение об ошибке без вывода самой команды (она может содержать секреты).
on_error() {
  local code=$? line=${1:-?}
  log_error "Сбой: $(basename "$0"), строка $line (код $code). Подробности — в сообщениях выше."
  exit "$code"
}
trap 'on_error $LINENO' ERR

have() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [[ ${EUID} -ne 0 && -z "${VPN_CI:-}" ]]; then
    die "Нужны права root. Запустите: sudo $0 $*"
  fi
}

require_cmd() {
  local c
  for c in "$@"; do
    have "$c" || die "Не найдена команда '$c'. Запустите sudo ./install.sh, он установит зависимости."
  done
}

is_interactive() { [[ -t 0 && -z "${VPN_NONINTERACTIVE:-}" ]]; }

# ask VAR "Вопрос" "значение по умолчанию"
ask() {
  local __var=$1 prompt=$2 def=${3:-} ans=""
  if is_interactive; then
    read -r -p "$prompt [$def]: " ans || true
  fi
  printf -v "$__var" '%s' "${ans:-$def}"
}

# ask_yn "Вопрос" Y|N  -> код 0 = да
ask_yn() {
  local prompt=$1 def=${2:-Y} ans="" hint="y/N"
  [[ $def == [Yy] ]] && hint="Y/n"
  if ! is_interactive; then
    [[ $def == [Yy] ]]
    return
  fi
  read -r -p "$prompt [$hint]: " ans || true
  ans=${ans:-$def}
  [[ $ans == [YyДд]* ]]
}

# ---------- .env ----------
load_env() {
  [[ -f "$ENV_FILE" ]] || die "Файл .env не найден. Сначала выполните установку: sudo ./install.sh"
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
  : "${XRAY_PORT:=443}" "${MTG_PORT:=8443}" "${SERVER_LABEL:=DE}" "${CLIENT_FINGERPRINT:=chrome}"
  : "${BACKUP_KEEP:=10}" "${COMPOSE_PROFILES:=}" "${FIREWALL_MANAGE:=yes}" "${ENABLE_BBR:=yes}"
  export XRAY_PORT MTG_PORT SERVER_LABEL CLIENT_FINGERPRINT BACKUP_KEEP COMPOSE_PROFILES
}

# set_env KEY VALUE — безопасно меняет/добавляет строку в .env (права 600).
set_env() {
  local key=$1 val=$2 tmp
  [[ $key =~ ^[A-Z][A-Z0-9_]*$ ]] || die "Некорректное имя переменной: $key"
  [[ $val =~ ^[A-Za-z0-9._:/@+=,_-]*$ ]] || die "Недопустимые символы в значении $key"
  [[ -f "$ENV_FILE" ]] || { : > "$ENV_FILE"; chmod 600 "$ENV_FILE"; }
  tmp=$(mktemp "$ENV_FILE.XXXXXX")
  awk -v k="$key" -v v="$val" '
    BEGIN { done = 0 }
    index($0, k "=") == 1 { if (!done) { print k "=" v; done = 1 }; next }
    { print }
    END { if (!done) print k "=" v }
  ' "$ENV_FILE" > "$tmp"
  chmod 600 "$tmp"
  mv -f "$tmp" "$ENV_FILE"
  printf -v "$key" '%s' "$val"
  export "${key?}"
}

telegram_enabled() { [[ ",${COMPOSE_PROFILES:-}," == *",telegram,"* ]]; }

# ---------- Docker Compose ----------
compose() {
  local args=(--project-directory "$PROJECT_DIR" -f "$COMPOSE_FILE")
  [[ -f "$ENV_FILE" ]] && args+=(--env-file "$ENV_FILE")
  docker compose "${args[@]}" "$@"
}

# Образ сервиса с учётом переопределения в .env
image_of() {
  local svc=$1 img
  img=$(compose --profile telegram config --format json 2>/dev/null \
        | jq -r --arg s "$svc" '.services[$s].image // empty')
  [[ -n "$img" ]] || die "Не удалось определить образ сервиса '$svc' из docker-compose.yml"
  printf '%s\n' "$img"
}

container_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || true)" == "true" ]]
}

# ---------- Сеть ----------
is_ipv4() { [[ $1 =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; }

valid_port() { [[ $1 =~ ^[0-9]+$ ]] && (( $1 >= 1 && $1 <= 65535 )); }

valid_host() {
  [[ $1 =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]] || is_ipv4 "$1" || [[ $1 =~ ^[0-9A-Fa-f:]+$ ]]
}

detect_public_ip() {
  local ip u
  for u in https://api.ipify.org https://ifconfig.me/ip https://ipv4.icanhazip.com; do
    ip=$(curl -4 -fsS --max-time 6 "$u" 2>/dev/null | tr -d '[:space:]') || true
    if is_ipv4 "${ip:-}"; then printf '%s\n' "$ip"; return 0; fi
  done
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}') || true
  [[ -n "${ip:-}" ]] && printf '%s\n' "$ip"
}

# Кто слушает TCP-порт (пусто — порт свободен)
port_owner() {
  ss -Hltnp "( sport = :$1 )" 2>/dev/null \
    | sed -n 's/.*users:(("\([^"]*\)".*/\1/p' | head -n1
}
port_busy() { ss -Hltn "( sport = :$1 )" 2>/dev/null | grep -q .; }

# Порты SSH, которые нельзя закрывать
ssh_ports() {
  {
    if have sshd; then sshd -T 2>/dev/null | awk '$1=="port"{print $2}'; fi
    if [[ -n "${SSH_CONNECTION:-}" ]]; then awk '{print $4}' <<<"$SSH_CONNECTION"; fi
    ss -Hltnp 2>/dev/null | awk '/"sshd"/ {n=split($4,a,":"); print a[n]}'
  } | grep -E '^[0-9]+$' | sort -un || true
}

# Сайт поддерживает TLS 1.3 + HTTP/2? (требование REALITY к target)
check_tls13_h2() {
  local host=$1 out
  out=$(timeout 12 openssl s_client -connect "$host:443" -servername "$host" \
          -tls1_3 -alpn h2 </dev/null 2>/dev/null) || true
  grep -q 'TLSv1.3' <<<"$out" && grep -q 'ALPN protocol: h2' <<<"$out"
}

# ---------- Права на файлы ----------
fix_permissions() {
  [[ -f "$ENV_FILE" ]] && chmod 600 "$ENV_FILE"
  mkdir -p "$DATA_DIR" "$XRAY_DIR" "$MTG_DIR" "$EXPORT_DIR" "$BACKUP_DIR"
  chmod 700 "$DATA_DIR" "$EXPORT_DIR" "$BACKUP_DIR"
  chmod 750 "$XRAY_DIR" "$MTG_DIR"
  [[ -f "$CLIENTS_DB" ]] && chmod 600 "$CLIENTS_DB"
  [[ -f "$XRAY_DIR/config.json" ]] && chmod 640 "$XRAY_DIR/config.json"
  [[ -f "$MTG_DIR/config.toml" ]] && chmod 640 "$MTG_DIR/config.toml"
  if [[ ${EUID} -eq 0 ]]; then
    chown -R "0:$XRAY_UID" "$XRAY_DIR"
    chown -R "0:$MTG_UID" "$MTG_DIR"
  fi
  return 0
}

# ---------- Клиенты (data/clients.json) ----------
clients_init() {
  mkdir -p "$DATA_DIR"
  if [[ ! -f "$CLIENTS_DB" ]]; then
    printf '[]\n' > "$CLIENTS_DB"
    chmod 600 "$CLIENTS_DB"
  fi
}

# stdin (JSON) -> clients.json атомарно
clients_write() {
  local tmp
  tmp=$(mktemp "$CLIENTS_DB.XXXXXX")
  cat > "$tmp"
  if ! jq -e 'type == "array"' "$tmp" >/dev/null 2>&1; then
    rm -f "$tmp"
    die "Внутренняя ошибка: некорректный список клиентов, изменения не сохранены."
  fi
  chmod 600 "$tmp"
  mv -f "$tmp" "$CLIENTS_DB"
}

validate_client_name() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]] || \
    die "Некорректное имя '$1'. Разрешены латиница, цифры, '-', '_' (до 32 символов), например: iphone, win-laptop."
}

client_exists() { jq -e --arg n "$1" 'any(.[]; .name == $n)' "$CLIENTS_DB" >/dev/null; }
client_get()    { jq -c --arg n "$1" 'first(.[] | select(.name == $n)) // empty' "$CLIENTS_DB"; }
clients_active_count() { jq '[.[] | select(.enabled)] | length' "$CLIENTS_DB"; }
client_names()  { jq -r '.[].name' "$CLIENTS_DB"; }

client_add() {
  local name=$1 uuid sid now
  uuid=$(tr 'A-F' 'a-f' < /proc/sys/kernel/random/uuid)
  sid=$(openssl rand -hex 8)
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg n "$name" --arg u "$uuid" --arg s "$sid" --arg t "$now" \
    '. + [{name: $n, uuid: $u, short_id: $s, enabled: true, created_at: $t}]' \
    "$CLIENTS_DB" | clients_write
}

client_set_enabled() {
  local name=$1 state=$2
  jq --arg n "$name" --argjson e "$state" \
    'map(if .name == $n then .enabled = $e else . end)' "$CLIENTS_DB" | clients_write
}

client_delete() {
  jq --arg n "$1" 'map(select(.name != $n))' "$CLIENTS_DB" | clients_write
}

# Ссылка vless:// (стандарт обмена ссылками Xray, VLESS + REALITY + Vision)
client_link() {
  local name=$1 c uuid sid host
  c=$(client_get "$name")
  [[ -n "$c" ]] || die "Клиент '$name' не найден."
  uuid=$(jq -r .uuid <<<"$c")
  sid=$(jq -r .short_id <<<"$c")
  host=$SERVER_ADDRESS
  [[ $host == *:* ]] && host="[$host]"
  printf 'vless://%s@%s:%s?encryption=none&flow=%s&security=reality&sni=%s&fp=%s&pbk=%s&sid=%s&spx=%%2F&type=tcp&headerType=none#%s-%s\n' \
    "$uuid" "$host" "$XRAY_PORT" "$VLESS_FLOW" "$REALITY_SNI" "$CLIENT_FINGERPRINT" \
    "$REALITY_PUBLIC_KEY" "$sid" "$SERVER_LABEL" "$name"
}

print_qr() {
  if have qrencode; then
    qrencode -t ansiutf8 -m 2 "$1"
  else
    log_warn "qrencode не установлен — QR-код не показан (apt-get install qrencode)."
  fi
}

# ---------- Telegram ----------
telegram_links() {
  printf 'tg://proxy?server=%s&port=%s&secret=%s\n' "$SERVER_ADDRESS" "$MTG_PORT" "$MTG_SECRET"
  printf 'https://t.me/proxy?server=%s&port=%s&secret=%s\n' "$SERVER_ADDRESS" "$MTG_PORT" "$MTG_SECRET"
}

# ---------- Генерация конфигураций ----------
require_reality_env() {
  local v
  for v in SERVER_ADDRESS XRAY_PORT REALITY_SNI REALITY_TARGET REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY CLIENT_FINGERPRINT; do
    [[ -n "${!v:-}" ]] || die "В .env не задан $v. Выполните: sudo ./install.sh"
  done
}

# Проверка конфига Xray самим Xray (xray run -test) в изолированном контейнере
validate_xray_file() {
  local f=$1 img errf
  if [[ -n "${VPN_SKIP_DOCKER_VALIDATION:-}" ]]; then
    log_warn "Проверка конфигурации Xray пропущена (VPN_SKIP_DOCKER_VALIDATION)."
    return 0
  fi
  img=$(image_of xray)
  errf=$(mktemp)
  if docker run --rm --network none --user "$XRAY_UID:$XRAY_UID" \
       -v "$(dirname "$f"):/etc/xray:ro" "$img" \
       run -test -c "/etc/xray/$(basename "$f")" >/dev/null 2>"$errf"; then
    rm -f "$errf"
    return 0
  fi
  log_error "Xray отклонил конфигурацию:"
  grep -v -i -E 'privateKey|"id"' "$errf" | tail -n 15 >&2 || true
  rm -f "$errf"
  return 1
}

render_xray_config() {
  local cand active
  require_reality_env
  clients_init
  active=$(clients_active_count)
  (( active > 0 )) || die "Нет ни одного активного клиента — Xray нельзя запустить без клиентов."
  mkdir -p "$XRAY_DIR"
  cand="$XRAY_DIR/config.candidate.json"
  jq -e 'any(.inbounds[]; .tag == "vless-reality")' "$XRAY_TEMPLATE" >/dev/null \
    || die "Шаблон $XRAY_TEMPLATE повреждён: нет inbound 'vless-reality'."
  jq --slurpfile clients "$CLIENTS_DB" \
     --arg target "$REALITY_TARGET" --arg sni "$REALITY_SNI" \
     --arg pk "$REALITY_PRIVATE_KEY" --arg flow "$VLESS_FLOW" \
     --argjson port "$XRAY_INTERNAL_PORT" '
    ($clients[0] | map(select(.enabled))) as $active
    | .inbounds |= map(
        if .tag == "vless-reality" then
          .port = $port
          | .settings.clients = ($active | map({id: .uuid, email: .name, flow: $flow}))
          | .streamSettings.realitySettings.target = $target
          | .streamSettings.realitySettings.serverNames = [$sni]
          | .streamSettings.realitySettings.privateKey = $pk
          | .streamSettings.realitySettings.shortIds = ($active | map(.short_id))
        else . end)
  ' "$XRAY_TEMPLATE" > "$cand"
  chmod 640 "$cand"
  [[ ${EUID} -eq 0 ]] && chown "0:$XRAY_UID" "$cand"
  if ! validate_xray_file "$cand"; then
    rm -f "$cand"
    die "Новая конфигурация Xray не применена (текущая осталась без изменений)."
  fi
  mv -f "$cand" "$XRAY_DIR/config.json"
}

render_mtg_config() {
  local tmp
  [[ ${MTG_SECRET:-} =~ ^ee[0-9a-f]{34,}$ ]] || die "MTG_SECRET в .env отсутствует или некорректен. Выполните: sudo ./manage.sh telegram-rotate"
  mkdir -p "$MTG_DIR"
  tmp=$(mktemp "$MTG_DIR/config.XXXXXX")
  sed -e "s/__MTG_SECRET__/$MTG_SECRET/" -e "s/__MTG_BIND_PORT__/$MTG_INTERNAL_PORT/" \
    "$MTG_TEMPLATE" > "$tmp"
  chmod 640 "$tmp"
  [[ ${EUID} -eq 0 ]] && chown "0:$MTG_UID" "$tmp"
  mv -f "$tmp" "$MTG_DIR/config.toml"
}

render_all() {
  render_xray_config
  if telegram_enabled; then render_mtg_config; fi
  fix_permissions
}

# Перезапуск сервиса, чтобы он перечитал конфигурацию
apply_service() {
  local svc=$1
  if [[ -n "${VPN_NO_RESTART:-}" ]]; then return 0; fi
  if compose ps --status running --services 2>/dev/null | grep -qx "$svc"; then
    compose restart "$svc" >/dev/null
  else
    compose up -d "$svc" >/dev/null
  fi
}

# Ждём, пока контейнер стабильно работает (не перезапускается)
wait_container_stable() {
  local name=$1 i rc1 rc2
  for i in 1 2 3 4 5 6 7 8 9 10; do
    if container_running "$name"; then
      rc1=$(docker inspect -f '{{.RestartCount}}' "$name")
      sleep 3
      rc2=$(docker inspect -f '{{.RestartCount}}' "$name")
      if container_running "$name" && [[ $rc1 == "$rc2" ]]; then return 0; fi
    fi
    sleep 1
  done
  return 1
}
