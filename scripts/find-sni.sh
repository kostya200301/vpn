#!/usr/bin/env bash
# Поиск сайта для маскировки REALITY среди соседей VPS по сети и его применение.
#
# Зачем: SNI чужого бренда (www.microsoft.com) на IP обычного хостинга — заметный
# признак для DPI мобильных операторов. Сайт из той же подсети, что и VPS,
# выглядит естественно: SNI и IP «из одного места».
#
#   find-sni.sh                    — сканировать /24 вокруг IP сервера, выбрать, применить
#   find-sni.sh --dry-run          — только показать найденные варианты
#   find-sni.sh --auto             — без вопросов применить лучший вариант
#   find-sni.sh --cidr 1.2.3.0/23  — своя подсеть (префикс от /20 до /30)
#   find-sni.sh --threads 32       — число параллельных проверок
#
# Критерии кандидата (требования REALITY к target):
#   TLS 1.3 + HTTP/2 (ALPN h2), валидный сертификат для домена (проверка цепочки
#   и имени), домен без '*'. Выше в списке — домены, чей DNS указывает на тот же IP.
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

DRY_RUN=0
AUTO=0
CIDR=""
THREADS=32
TIMEOUT=5
while (( $# )); do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --auto) AUTO=1; VPN_NONINTERACTIVE=1 ;;
    --cidr) CIDR=${2:-}; shift ;;
    --threads) THREADS=${2:-}; shift ;;
    -h|--help) sed -n '2,18p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $1 (см. --help)" ;;
  esac
  shift
done
[[ $THREADS =~ ^[0-9]+$ ]] && (( THREADS >= 1 && THREADS <= 128 )) || die "--threads: от 1 до 128"

require_root
require_cmd openssl jq xargs getent timeout
load_env

# ---------- Подсеть ----------
ip2int() { local a b c d; IFS=. read -r a b c d <<<"$1"; echo $(( (a << 24) | (b << 16) | (c << 8) | d )); }
int2ip() { echo "$(( ($1 >> 24) & 255 )).$(( ($1 >> 16) & 255 )).$(( ($1 >> 8) & 255 )).$(( $1 & 255 ))"; }

SELF_IP=""
if is_ipv4 "${SERVER_ADDRESS:-}"; then SELF_IP=$SERVER_ADDRESS; else SELF_IP=$(detect_public_ip || true); fi
if [[ -z "$CIDR" ]]; then
  is_ipv4 "${SELF_IP:-}" || die "Не удалось определить IPv4 сервера. Укажите подсеть: --cidr 1.2.3.0/24"
  CIDR="${SELF_IP%.*}.0/24"
fi
[[ $CIDR =~ ^([0-9.]+)/([0-9]+)$ ]] || die "Неверный формат --cidr (пример: 1.2.3.0/24)"
NET=${BASH_REMATCH[1]}; PREFIX=${BASH_REMATCH[2]}
is_ipv4 "$NET" && (( PREFIX >= 20 && PREFIX <= 30 )) || die "Поддерживаются подсети от /20 до /30."
MASK=$(( (0xFFFFFFFF << (32 - PREFIX)) & 0xFFFFFFFF ))
START=$(( $(ip2int "$NET") & MASK ))
END=$(( START | (~MASK & 0xFFFFFFFF) ))

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
for (( i = START + 1; i < END; i++ )); do
  ip=$(int2ip "$i")
  [[ $ip == "${SELF_IP:-}" ]] || echo "$ip"
done > "$WORK/ips"

step "Сканирование $CIDR ($(wc -l < "$WORK/ips") адресов, $THREADS потоков, до ~$(( $(wc -l < "$WORK/ips") * TIMEOUT / THREADS + 5 )) сек)"

# ---------- Этап 1: какие IP отвечают TLS 1.3 + h2, и какие домены в их сертификатах ----------
probe_ip() {
  local ip=$1 out
  out=$(timeout "$TIMEOUT" openssl s_client -connect "$ip:443" -tls1_3 -alpn h2 </dev/null 2>/dev/null) || true
  grep -q 'TLSv1.3' <<<"$out" || return 0
  grep -q 'ALPN protocol: h2' <<<"$out" || return 0
  {
    openssl x509 -noout -ext subjectAltName 2>/dev/null <<<"$out" | grep -o 'DNS:[^,[:space:]]*' | cut -c5-
    openssl x509 -noout -subject -nameopt multiline 2>/dev/null <<<"$out" | sed -n 's/^ *commonName *= *//p'
  } | tr 'A-Z' 'a-z' | grep -vE '^\*|^$' | grep -E '^[a-z0-9.-]+\.[a-z]{2,}$' | awk '!seen[$0]++' | head -n 3 \
    | while IFS= read -r d; do printf '%s %s\n' "$ip" "$d"; done
}
export -f probe_ip
export TIMEOUT

xargs -a "$WORK/ips" -P "$THREADS" -I{} bash -c 'probe_ip "$1"' _ {} > "$WORK/raw" 2>/dev/null || true
sort -u "$WORK/raw" -o "$WORK/raw"
log_info "Ответили TLS 1.3 + h2: $(cut -d' ' -f1 "$WORK/raw" | sort -u | wc -l) IP, доменов-кандидатов: $(wc -l < "$WORK/raw")"

# ---------- Этап 2: проверка домена (SNI, цепочка сертификата, имя) + DNS ----------
verify_pair() {
  local ip=$1 dom=$2 out dns="нет"
  out=$(timeout "$TIMEOUT" openssl s_client -connect "$ip:443" -servername "$dom" -tls1_3 -alpn h2 \
          -verify_return_error -verify_hostname "$dom" ${VPN_SNI_CAFILE:+-CAfile "$VPN_SNI_CAFILE"} \
          </dev/null 2>/dev/null) || return 0
  grep -q 'TLSv1.3' <<<"$out" && grep -q 'ALPN protocol: h2' <<<"$out" \
    && grep -q 'Verify return code: 0 (ok)' <<<"$out" || return 0
  getent ahostsv4 "$dom" 2>/dev/null | awk '{print $1}' | grep -qxF "$ip" && dns="да"
  printf '%s %s %s\n' "$dns" "$dom" "$ip"
}
export -f verify_pair
[[ -n "${VPN_SNI_CAFILE:-}" ]] && export VPN_SNI_CAFILE

: > "$WORK/ok"
if [[ -s "$WORK/raw" ]]; then
  xargs -a "$WORK/raw" -P "$THREADS" -L1 bash -c 'verify_pair "$1" "$2"' _ > "$WORK/ok" 2>/dev/null || true
fi
# Сначала DNS-совпадения, затем короткие домены; один домен — один раз
sort -t' ' -k1,1r "$WORK/ok" | awk '!seen[$2]++' \
  | awk '{print ($1=="да"?0:1), length($2), $0}' | sort -n -k1,1 -k2,2 | cut -d' ' -f3- > "$WORK/cand"

COUNT=$(wc -l < "$WORK/cand")
if (( COUNT == 0 )); then
  log_warn "В $CIDR не найдено подходящих сайтов."
  log_info "Попробуйте подсеть шире: sudo ./manage.sh find-sni --cidr ${NET%.*}.0/22"
  log_info "Или задайте домен вручную: sudo ./install.sh --reconfigure"
  exit 1
fi

echo
printf '%s%-4s %-50s %-16s %s%s\n' "$C_BOLD" "N" "ДОМЕН" "IP" "DNS → этот IP" "$C_RESET"
n=0
while read -r dns dom ip; do
  n=$((n + 1))
  printf '%-4s %-45s %-16s %s\n' "$n" "$dom" "$ip" "$dns"
  (( n >= 30 )) && break
done < "$WORK/cand"
(( COUNT > 30 )) && log_info "Показаны первые 30 из $COUNT."
echo
log_info "Текущий сайт маскировки: ${REALITY_SNI:-—}"
echo "Совет: выбирайте домен с «DNS → этот IP = да», похожий на сайт настоящей компании,"
echo "а не на служебное имя хостинга (srv123.hoster.net, *.cloud и т. п.)."

(( DRY_RUN == 1 )) && exit 0

# ---------- Выбор ----------
if (( AUTO == 1 )); then
  choice=1
else
  is_interactive || die "Нет терминала: используйте --auto или --dry-run."
  ask choice "Номер сайта для маскировки (0 — отмена)" "1"
fi
[[ $choice =~ ^[0-9]+$ ]] || die "Неверный номер."
(( choice == 0 )) && { log_info "Отменено, ничего не изменено."; exit 0; }
(( choice >= 1 && choice <= COUNT && choice <= 30 )) || die "Нет варианта с номером $choice."
read -r dns DOMAIN IP < <(sed -n "${choice}p" "$WORK/cand")

# target: домен, если его DNS указывает на проверенный IP, иначе сам IP
# (так fallback гарантированно уходит на сервер, чей сертификат мы проверили)
if [[ $dns == "да" ]]; then TARGET="$DOMAIN:443"; else TARGET="$IP:443"; fi

if (( AUTO == 0 )); then
  echo
  log_warn "После смены сайта ВСЕ устройства нужно переподключить: старые ссылки перестанут работать."
  ask_yn "Применить $DOMAIN (target $TARGET)?" Y || { log_info "Отменено, ничего не изменено."; exit 0; }
fi

# ---------- Применение ----------
step "Применение"
BACKUP=$("$SCRIPTS_DIR/backup.sh" --quiet)
log_ok "Резервная копия: $BACKUP"
OLD_SNI=${REALITY_SNI:-}
OLD_TARGET=${REALITY_TARGET:-}
set_env REALITY_SNI "$DOMAIN"
set_env REALITY_TARGET "$TARGET"
if ! ( render_xray_config ); then
  set_env REALITY_SNI "$OLD_SNI"
  set_env REALITY_TARGET "$OLD_TARGET"
  die "Конфигурация не применена, прежние настройки восстановлены."
fi
fix_permissions
apply_service xray
if [[ -z "${VPN_NO_RESTART:-}" ]]; then
  wait_container_stable "$XRAY_CONTAINER" || die "Xray не запустился. Откат: sudo ./manage.sh restore $BACKUP"
  out=$(timeout 12 openssl s_client -connect "127.0.0.1:$XRAY_PORT" -servername "$DOMAIN" -tls1_3 </dev/null 2>/dev/null) || true
  if grep -q 'TLSv1.3' <<<"$out"; then
    log_ok "REALITY отвечает с новым SNI $DOMAIN."
  else
    log_warn "Проверочное TLS-рукопожатие не прошло — проверьте: sudo ./manage.sh health"
  fi
fi
log_ok "Сайт маскировки: $OLD_SNI → $DOMAIN"

if telegram_enabled && (( AUTO == 0 )); then
  if ask_yn "Использовать $DOMAIN и для Telegram Proxy? (секрет сменится, ссылку Telegram тоже придётся обновить)" N; then
    "$SCRIPTS_DIR/telegram.sh" rotate "$DOMAIN" </dev/null || log_warn "Не удалось сменить домен Telegram."
  fi
fi

echo
echo "${C_BOLD}Новые ссылки — удалите старые подключения в HAPP и добавьте эти:${C_RESET}"
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  print_client_links "$name" 0 | sed 's/^/  /'
  echo
done < <(jq -r '.[] | select(.enabled) | .name' "$CLIENTS_DB")
echo "QR-код устройства: sudo ./manage.sh show-config <имя>"
echo "Вернуть как было:  sudo ./manage.sh restore $BACKUP"
