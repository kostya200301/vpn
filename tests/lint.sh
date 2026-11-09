#!/usr/bin/env bash
# Статические проверки (без root и без запуска контейнеров):
# синтаксис bash, shellcheck (если установлен), docker-compose.yml, шаблоны, .gitignore.
set -Eeuo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

fail=0
ok()  { printf '[OK]   %s\n' "$*"; }
bad() { printf '[FAIL] %s\n' "$*"; fail=1; }

mapfile -t SH < <(ls install.sh manage.sh lib/*.sh scripts/*.sh tests/*.sh)

for f in "${SH[@]}"; do
  if bash -n "$f"; then ok "bash -n $f"; else bad "bash -n $f"; fi
done

if command -v shellcheck >/dev/null; then
  if shellcheck -x -S warning "${SH[@]}"; then ok "shellcheck"; else bad "shellcheck"; fi
else
  printf '[SKIP] shellcheck не установлен\n'
fi

for f in install.sh manage.sh scripts/*.sh tests/*.sh; do
  head -n1 "$f" | grep -q '^#!/usr/bin/env bash' || bad "нет shebang: $f"
done

tmp_env=$(mktemp)
cp .env.example "$tmp_env"
if docker compose -f docker-compose.yml --env-file "$tmp_env" --profile telegram config -q; then
  ok "docker compose config"
else
  bad "docker compose config"
fi
imgs=$(docker compose -f docker-compose.yml --env-file "$tmp_env" --profile telegram config --format json | jq -r '.services[].image')
rm -f "$tmp_env"
while IFS= read -r i; do
  [[ $i =~ :(latest|stable|master)$ || $i != *:* ]] && bad "образ без закреплённой версии: $i" || ok "версия закреплена: $i"
done <<<"$imgs"

if jq -e '.inbounds[] | select(.tag=="vless-reality") | .streamSettings.security == "reality"' \
     config/xray/config.template.json >/dev/null; then
  ok "шаблон Xray: валидный JSON, inbound vless-reality"
else
  bad "шаблон Xray"
fi
grep -q '__MTG_SECRET__' config/mtproto/config.template.toml && ok "шаблон mtg" || bad "шаблон mtg"

for p in .env data/clients.json data/xray/config.json data/mtproto/config.toml backups/vpn-backup-1.tar.gz; do
  if git check-ignore -q --no-index "$p" 2>/dev/null; then ok "git игнорирует $p"; else bad "git НЕ игнорирует $p"; fi
done

exit "$fail"
