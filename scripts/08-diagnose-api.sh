#!/usr/bin/env bash
# Шаг 8 (по необходимости). Почему POST /applications/... отвечает 500.
#
# Запуск с твоего компьютера, рядом с 07-deploy-pppp.sh:
#   COOLIFY_URL=https://coolify.твойдомен.ru bash scripts/08-diagnose-api.sh
#
# Ничего не создаёт насовсем: пробный ресурс называется pppp-apitest-<хвост>
# и удаляется сразу после проверки. Существующие проекты и ресурсы не трогает.
#
# Делает две вещи:
#   1) проверяет здоровье GitHub App — если Coolify не может выпустить
#      installation-токен, он отвечает 500 на любое создание приложения,
#      с каким угодно телом запроса;
#   2) лесенкой шлёт создание ресурса, добавляя по одному полю, и печатает
#      код с ответом на каждом шаге. Первое тело, на котором код меняется с
#      2xx на 5xx, и есть виновник.

set -euo pipefail

COOLIFY_URL="${COOLIFY_URL:-http://95.85.242.143:8000}"
COOLIFY_URL="${COOLIFY_URL%/}"
API="${COOLIFY_URL}/api/v1"

PROJECT_NAME="${PROJECT_NAME:-pppp}"
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-production}"
GIT_REPO="${GIT_REPO:-AlexB0nch/pppp}"
GIT_BRANCH="${GIT_BRANCH:-main}"
COMPOSE_LOCATION="${COMPOSE_LOCATION:-/docker-compose.coolify.yml}"
DOMAIN="${DOMAIN:-pppp.alexshein.com}"
WEB_SERVICE="${WEB_SERVICE:-nginx}"
SERVER_UUID="${SERVER_UUID:-}"
GITHUB_APP_UUID="${GITHUB_APP_UUID:-}"
SSH_HOST="${SSH_HOST:-coolify}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "нет curl."
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null && "$c" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null; then
    PY="$c"; break
  fi
done
[[ -n "$PY" ]] || die "нет python 3."

CODE=""; RESP=""
api() {
  local method="$1" path="$2" body="${3:-}" raw
  if [[ -n "$body" ]]; then
    raw=$(curl -sS -X "$method" "${API}${path}" \
      -H "Authorization: Bearer ${COOLIFY_TOKEN}" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      --data-binary "$body" -w $'\n%{http_code}') || die "curl не достучался до ${API}"
  else
    raw=$(curl -sS -X "$method" "${API}${path}" \
      -H "Authorization: Bearer ${COOLIFY_TOKEN}" \
      -H 'Accept: application/json' -w $'\n%{http_code}') || die "curl не достучался до ${API}"
  fi
  CODE="${raw##*$'\n'}"; RESP="${raw%$'\n'*}"
}
api_ok() { [[ "$CODE" =~ ^2 ]]; }
jget() { "$PY" -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
try: v = eval(sys.argv[1])
except Exception: v = None
print("" if v is None else v)' "$1" 2>/dev/null || true; }
short() { printf '%s' "$1" | tr -d '\n' | cut -c1-220; }

if [[ -z "${COOLIFY_TOKEN:-}" ]]; then
  printf 'API-токен Coolify (ввод скрыт): '; read -rs COOLIFY_TOKEN; printf '\n'
fi

say "Панель"
api GET /teams/current
api_ok || die "токен не принят: ${CODE} $(short "$RESP")"
api GET /version
echo "    версия: ${RESP}"

if [[ -z "$SERVER_UUID" ]]; then
  api GET /servers
  SERVER_UUID=$(printf '%s' "$RESP" | jget 'd[0]["uuid"]')
fi
echo "    сервер: ${SERVER_UUID}"

api GET /projects
PROJECT_UUID=$(NEEDLE="$PROJECT_NAME" "$PY" -c 'import sys, json, os
d = json.load(sys.stdin)
print(next((x["uuid"] for x in d if x.get("name") == os.environ["NEEDLE"]), ""))' <<<"$RESP")
[[ -n "$PROJECT_UUID" ]] || die "проект '${PROJECT_NAME}' не найден — сначала прогони 07-deploy-pppp.sh."
echo "    проект: ${PROJECT_UUID}"

# --- 1. здоровье GitHub App -------------------------------------------------
# Если Coolify не может выпустить installation-токен, create_private_gh_app_application
# падает до разбора тела запроса — отсюда 500 на что угодно.

say "GitHub App"
api GET /github-apps
echo "    список (${CODE}): $(short "$RESP")"
if [[ -z "$GITHUB_APP_UUID" ]]; then
  # Встроенный "Public GitHub" не в счёт: у него нет ни app_id, ни ключа, и
  # выпуск installation-токена для него роняет API пятисоткой. Берём настоящее
  # приложение — с заполненным app_id.
  GITHUB_APP_UUID=$(printf '%s' "$RESP" | "$PY" -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
items = d if isinstance(d, list) else (d.get("data") or [])
usable = [x for x in items if isinstance(x, dict) and x.get("app_id")]
usable.sort(key=lambda x: 0 if x.get("installation_id") else 1)
print(usable[0]["uuid"] if usable else "")' 2>/dev/null || true)
fi

GH_OK=0
if [[ -z "$GITHUB_APP_UUID" ]]; then
  warn "Настоящего GitHub App нет, только встроенный Public GitHub."
  warn "Остаётся путь через ключ на чтение: SOURCE=deploy-key в 07-deploy-pppp.sh."
else
  echo "    uuid: ${GITHUB_APP_UUID}"
  api GET "/github-apps/${GITHUB_APP_UUID}/repositories"
  if api_ok; then
    ok "репозитории отдаются — токен установки выпускается"
    printf '%s' "$RESP" | "$PY" -c 'import sys, json
try: d = json.load(sys.stdin)
except Exception: raise SystemExit
items = d.get("repositories") if isinstance(d, dict) else d
items = items or []
names = [i.get("full_name") or i.get("name") for i in items if isinstance(i, dict)]
print("    видит репозиториев:", len(names))
hit = [n for n in names if n and n.lower().endswith("/pppp")]
print("    pppp среди них:", hit or "НЕТ — приложение не установлено на этот репозиторий")' || true
    GH_OK=1
  else
    warn "репозитории не отдаются (${CODE}): $(short "$RESP")"
    warn "Это и есть причина 500: Coolify не может работать с этим GitHub App."
  fi

  api GET "/github-apps/${GITHUB_APP_UUID}/repositories/${GIT_REPO%%/*}/${GIT_REPO#*/}/branches"
  echo "    ветки ${GIT_REPO} (${CODE}): $(short "$RESP")"
fi

# --- 2. лесенка тел запроса -------------------------------------------------

say "Создание ресурса: по одному полю за раз"
SUFFIX=$("$PY" -c 'import secrets; print(secrets.token_hex(3))')
TEST_NAME=""
CREATED=""

payload() { # payload <вариант>
  VARIANT="$1" PROJECT_UUID="$PROJECT_UUID" SERVER_UUID="$SERVER_UUID" \
  ENVIRONMENT_NAME="$ENVIRONMENT_NAME" GITHUB_APP_UUID="${GITHUB_APP_UUID:-}" \
  GIT_REPO="$GIT_REPO" GIT_BRANCH="$GIT_BRANCH" TEST_NAME="$TEST_NAME" \
  COMPOSE_LOCATION="$COMPOSE_LOCATION" DOMAIN="$DOMAIN" WEB_SERVICE="$WEB_SERVICE" "$PY" -c '
import json, os
e = os.environ
v = e["VARIANT"]
b = {
    "project_uuid": e["PROJECT_UUID"],
    "server_uuid": e["SERVER_UUID"],
    "environment_name": e["ENVIRONMENT_NAME"],
    "github_app_uuid": e["GITHUB_APP_UUID"],
    "git_repository": e["GIT_REPO"],
    "git_branch": e["GIT_BRANCH"],
    "name": e["TEST_NAME"],
    "instant_deploy": False,
}
if v == "nixpacks":
    b["build_pack"] = "nixpacks"
    b["ports_exposes"] = "3000"
    print(json.dumps(b)); raise SystemExit
b["build_pack"] = "dockercompose"
if v in ("compose-loc", "flags", "network", "domains"):
    b["docker_compose_location"] = e["COMPOSE_LOCATION"]
if v in ("flags", "network", "domains"):
    b["is_auto_deploy_enabled"] = True
    b["is_force_https_enabled"] = True
if v in ("network", "domains"):
    b["connect_to_docker_network"] = True
if v == "domains":
    b["docker_compose_domains"] = [{"name": e["WEB_SERVICE"], "domain": "https://" + e["DOMAIN"]}]
print(json.dumps(b))'
}

# Прогоняются все варианты подряд, а не до первого успеха: важно увидеть,
# на каком именно добавленном поле код меняется с 2xx на 5xx. Имя у каждого
# своё, иначе созданные ресурсы столкнулись бы между собой.
for variant in nixpacks bare compose-loc flags network domains; do
  TEST_NAME="pppp-apitest-${SUFFIX}-${variant}"
  api POST /applications/private-github-app "$(payload "$variant")"
  printf '    %-12s -> %s  %s\n' "$variant" "$CODE" "$(short "$RESP")"
  if api_ok; then
    uuid=$(printf '%s' "$RESP" | jget 'd.get("uuid","")')
    [[ -n "$uuid" ]] && CREATED="${CREATED} ${uuid}"
  fi
done

if [[ -n "${CREATED// }" ]]; then
  say "Убираю пробные ресурсы"
  for u in $CREATED; do
    api DELETE "/applications/${u}"
    printf '    %s -> %s\n' "$u" "$CODE"
  done
fi

# --- 3. исключение из логов панели ------------------------------------------

say "Последняя ошибка в логах Coolify"
if ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" true 2>/dev/null; then
  ssh "$SSH_HOST" "docker exec coolify tail -n 400 storage/logs/laravel.log 2>/dev/null | grep -n 'production.ERROR' | tail -5" || \
    warn "лог не прочитался — возможно, контейнер называется иначе (docker ps)"
else
  warn "ssh ${SSH_HOST} недоступен. На сервере это выглядит так:"
  cat <<'EOF'
    docker exec coolify tail -n 400 storage/logs/laravel.log | grep production.ERROR | tail -5
EOF
fi

printf '\n\033[1;32mВывод целиком пришли — по нему видно, какое поле или какой источник ломает API.\033[0m\n'
