#!/usr/bin/env bash
# Генерация криптографических параметров и запись их в .env.
# По умолчанию заполняет только ОТСУТСТВУЮЩИЕ значения (безопасно для повторного запуска).
#
#   generate-keys.sh                 — сгенерировать недостающие ключи
#   generate-keys.sh --rotate-reality — новая пара x25519 (все клиенты должны обновить ссылки!)
#   generate-keys.sh --rotate-mtg     — новый секрет MTProto (старая ссылка Telegram перестанет работать)
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"

ROTATE_REALITY=0
ROTATE_MTG=0
for arg in "$@"; do
  case "$arg" in
    --rotate-reality) ROTATE_REALITY=1 ;;
    --rotate-mtg) ROTATE_MTG=1 ;;
    -h|--help) sed -n '2,8p' "$0"; exit 0 ;;
    *) die "Неизвестный параметр: $arg" ;;
  esac
done

require_root
require_cmd docker jq openssl
load_env

# Разбор вывода `xray x25519`. Поддерживаются оба формата:
#   старый: "Private key: ..." / "Public key: ..."
#   новый:  "PrivateKey: ..."  / "Password: ..." (Password = публичный ключ для клиента)
parse_x25519() {
  local want=$1
  awk -v want="$want" '
    {
      line = tolower($0); sub(/^[ \t]+/, "", line)
      val = $0; sub(/^[^:]*:[ \t]*/, "", val); gsub(/[ \t\r]/, "", val)
      if (want == "private" && line ~ /^private ?key/) { print val; exit }
      if (want == "public" && (line ~ /^public ?key/ || line ~ /^password/)) { print val; exit }
    }'
}

gen_reality() {
  local img out priv pub check
  img=$(image_of xray)
  log_info "Генерация ключей REALITY (x25519) образом $img"
  out=$(docker run --rm --network none "$img" x25519)
  priv=$(parse_x25519 private <<<"$out")
  pub=$(parse_x25519 public <<<"$out")
  [[ $priv =~ ^[A-Za-z0-9_-]{43}$ && $pub =~ ^[A-Za-z0-9_-]{43}$ ]] \
    || die "Не удалось разобрать вывод 'xray x25519'."
  # Контроль: публичный ключ, вычисленный из приватного, должен совпасть
  check=$(docker run --rm --network none "$img" x25519 -i "$priv" | parse_x25519 public)
  [[ $check == "$pub" ]] || die "Проверка пары ключей x25519 не прошла."
  set_env REALITY_PRIVATE_KEY "$priv"
  set_env REALITY_PUBLIC_KEY "$pub"
  log_ok "Ключи REALITY сгенерированы."
}

gen_mtg() {
  local img secret
  img=$(image_of mtproto)
  [[ -n "${MTG_DOMAIN:-}" ]] || set_env MTG_DOMAIN "${REALITY_SNI:-www.microsoft.com}"
  log_info "Генерация секрета MTProto (FakeTLS, домен $MTG_DOMAIN) образом $img"
  secret=$(docker run --rm --network none "$img" generate-secret --hex "$MTG_DOMAIN" | tr -d '[:space:]')
  [[ $secret =~ ^ee[0-9a-f]{34,}$ ]] || die "mtg вернул некорректный секрет."
  set_env MTG_SECRET "$secret"
  log_ok "Секрет MTProto сгенерирован."
}

if [[ $ROTATE_REALITY -eq 1 || -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]]; then
  gen_reality
else
  log_ok "Ключи REALITY уже есть — оставляю без изменений."
fi

if telegram_enabled || [[ $ROTATE_MTG -eq 1 ]]; then
  if [[ $ROTATE_MTG -eq 1 || -z "${MTG_SECRET:-}" ]]; then
    gen_mtg
  else
    log_ok "Секрет MTProto уже есть — оставляю без изменений."
  fi
fi
