#!/usr/bin/env bash
# Шаг 7. Запускается НА ТВОЁМ КОМПЬЮТЕРЕ (macOS / Linux / WSL / Git Bash).
#
# Разворачивает через API Coolify проект PPPP Bot Hub — ресурс типа
# Docker Compose из приватного репозитория AlexB0nch/pppp:
#   1) находит сервер и источник (GitHub App или ключ на чтение);
#   2) создаёт проект и приложение с build pack "dockercompose",
#      compose-файл — docker-compose.coolify.yml (НЕ docker-compose.yml);
#   3) вешает домен ТОЛЬКО на сервис nginx (порт 80), остальные сервисы —
#      backend, frontend, waha — остаются внутри compose-сети;
#   4) генерирует секреты, кладёт их в локальный файл с правами 600 и
#      заливает весь набор переменных окружения;
#   5) запускает деплой, ждёт его окончания и прогоняет проверки из ТЗ.
#
# Идемпотентен: повторный запуск переиспользует проект/приложение/секреты,
# переменные обновляет, ничего не удаляет.
#
# Использование:
#   COOLIFY_URL=https://coolify.твойдомен.ru bash scripts/07-deploy-pppp.sh
#
# Только проверки, без создания и деплоя:
#   CHECKS_ONLY=1 bash scripts/07-deploy-pppp.sh
#
# Токен: Coolify → Keys & Tokens → API tokens, права на чтение и запись.
# Передавать переменной COOLIFY_TOKEN либо ввести по запросу (тогда он не
# попадёт в историю командной строки).

set -euo pipefail

COOLIFY_URL="${COOLIFY_URL:-http://95.85.242.143:8000}"
COOLIFY_URL="${COOLIFY_URL%/}"
API="${COOLIFY_URL}/api/v1"

DOMAIN="${DOMAIN:-pppp.alexshein.com}"
SERVER_IP="${SERVER_IP:-95.85.242.143}"
APP_NAME="${APP_NAME:-pppp-bot-hub}"
PROJECT_NAME="${PROJECT_NAME:-pppp}"
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-production}"
GIT_REPO="${GIT_REPO:-AlexB0nch/pppp}"          # для GitHub App — owner/repo
GIT_REPO_SSH="${GIT_REPO_SSH:-git@github.com:AlexB0nch/pppp.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
COMPOSE_LOCATION="${COMPOSE_LOCATION:-/docker-compose.coolify.yml}"
WEB_SERVICE="${WEB_SERVICE:-nginx}"             # какому сервису отдать домен
SECRETS_FILE="${SECRETS_FILE:-$HOME/.coolify-pppp-secrets.env}"
KEY_NAME="${KEY_NAME:-deploy-${APP_NAME}}"
KEY_PATH="${KEY_PATH:-$HOME/.ssh/coolify_deploy_pppp}"
SERVER_UUID="${SERVER_UUID:-}"
GITHUB_APP_UUID="${GITHUB_APP_UUID:-}"
SOURCE="${SOURCE:-auto}"                        # auto | github-app | deploy-key
SSH_HOST="${SSH_HOST:-coolify}"                 # алиас из scripts/01-local-keys.sh
DEPLOY="${DEPLOY:-1}"
WAIT_SECONDS="${WAIT_SECONDS:-900}"
CHECKS_ONLY="${CHECKS_ONLY:-0}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

command -v curl >/dev/null || die "нет curl."

# В Git Bash под Windows команда называется python, а не python3.
PY=""
for c in python3 python py; do
  if command -v "$c" >/dev/null && "$c" -c 'import sys; sys.exit(0 if sys.version_info[0] == 3 else 1)' 2>/dev/null; then
    PY="$c"; break
  fi
done
[[ -n "$PY" ]] || die "нет python 3 — он нужен для разбора ответов API."

# --- helpers ---------------------------------------------------------------

CODE=""; RESP=""
api() { # api METHOD PATH [JSON]
  local method="$1" path="$2" body="${3:-}" raw
  if [[ -n "$body" ]]; then
    raw=$(curl -sS -X "$method" "${API}${path}" \
      -H "Authorization: Bearer ${COOLIFY_TOKEN}" \
      -H 'Content-Type: application/json' -H 'Accept: application/json' \
      --data-binary "$body" -w $'\n%{http_code}') || die "curl не смог достучаться до ${API}"
  else
    raw=$(curl -sS -X "$method" "${API}${path}" \
      -H "Authorization: Bearer ${COOLIFY_TOKEN}" \
      -H 'Accept: application/json' -w $'\n%{http_code}') || die "curl не смог достучаться до ${API}"
  fi
  CODE="${raw##*$'\n'}"
  RESP="${raw%$'\n'*}"
}

api_ok() { [[ "$CODE" =~ ^2 ]]; }

# jget '<python-выражение над d>' — JSON приходит на stdin
jget() {
  "$PY" -c 'import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
try:
    v = eval(sys.argv[1])
except Exception:
    v = None
print("" if v is None else v)' "$1" 2>/dev/null || true
}

# jfind — uuid элемента массива по полю name
jfind() {
  NEEDLE="$1" "$PY" -c 'import sys, json, os
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
n = os.environ["NEEDLE"]
if not isinstance(d, list):
    print(""); raise SystemExit
print(next((x.get("uuid", "") for x in d if x.get("name") == n), ""))' 2>/dev/null || true
}

rand_hex() { # rand_hex <байт>
  if command -v openssl >/dev/null; then openssl rand -hex "$1"
  else "$PY" -c "import secrets, sys; print(secrets.token_hex(int(sys.argv[1])))" "$1"; fi
}

# --- 0. DNS ----------------------------------------------------------------
# Проверка до всего остального: Let's Encrypt ходит на адрес из A-записи.
# Лишняя A-запись = половина запросов (и половина ACME-проверок) уходит не на
# тот сервер, сертификат не выписывается, а браузер через раз видит чужой сайт.

say "DNS ${DOMAIN}"
DNS_IPS=""
if command -v dig >/dev/null; then
  DNS_IPS=$(dig +short A "$DOMAIN" | grep -E '^[0-9.]+$' || true)
elif command -v getent >/dev/null; then
  DNS_IPS=$(getent ahostsv4 "$DOMAIN" | awk '{print $1}' | sort -u || true)
elif command -v nslookup >/dev/null; then
  # Git Bash: ни dig, ни getent нет, зато есть nslookup из Windows.
  # Первый Address — адрес самого DNS-сервера, поэтому берём то, что после Name.
  DNS_IPS=$(nslookup "$DOMAIN" 2>/dev/null | awk '/^Name/{f=1} f && /Address/{print $NF}' | grep -E '^[0-9.]+$' | sort -u || true)
fi
if [[ -z "$DNS_IPS" ]]; then
  warn "не удалось разрешить имя — проверь DNS вручную."
else
  echo "$DNS_IPS" | sed 's/^/    /'
  dns_count=$(printf '%s\n' "$DNS_IPS" | grep -c . || true)
  if [[ "$dns_count" -gt 1 ]]; then
    warn "A-записей больше одной. Домен должен указывать РОВНО на ${SERVER_IP},"
    warn "иначе Let's Encrypt не выпишет сертификат, а трафик будет через раз"
    warn "уходить на другой сервер. Удали лишние записи и запусти скрипт заново."
    [[ "${IGNORE_DNS:-0}" == "1" ]] || die "остановился на DNS (обойти: IGNORE_DNS=1)."
  elif [[ "$DNS_IPS" != "$SERVER_IP" ]]; then
    warn "домен указывает на ${DNS_IPS}, а сервер Coolify — ${SERVER_IP}."
    [[ "${IGNORE_DNS:-0}" == "1" ]] || die "остановился на DNS (обойти: IGNORE_DNS=1)."
  else
    ok "A-запись одна и указывает на ${SERVER_IP}"
  fi
fi

# --- проверки после деплоя (функция, вызывается в конце и при CHECKS_ONLY) --

run_checks() {
  say "Проверки снаружи"
  printf '\n$ curl -fsS https://%s/health\n' "$DOMAIN"
  curl -fsS "https://${DOMAIN}/health" || warn "не 200 (или сеть не пустила)"
  printf '\n\n$ curl -sI https://%s/ | head -1\n' "$DOMAIN"
  curl -sI "https://${DOMAIN}/" | head -1 || true
  printf '\n$ curl -sI https://%s/docs | head -1\n' "$DOMAIN"
  curl -sI "https://${DOMAIN}/docs" | head -1 || true
  printf '\n$ curl -sI https://%s/styles.css | grep -i content-type\n' "$DOMAIN"
  curl -sI "https://${DOMAIN}/styles.css" | grep -i content-type || warn "content-type не найден"
  printf '\n$ curl -sI http://%s/ | head -1\n' "$DOMAIN"
  curl -sI "http://${DOMAIN}/" | head -1 || true
  printf '\n$ openssl s_client -connect %s:443 ... | openssl x509 -noout -issuer -dates\n' "$DOMAIN"
  if command -v openssl >/dev/null; then
    openssl s_client -connect "${DOMAIN}:443" -servername "$DOMAIN" </dev/null 2>/dev/null \
      | openssl x509 -noout -issuer -dates || warn "сертификат не отдался"
  else
    warn "нет openssl — проверку сертификата пропускаю"
  fi

  say "Проверки на сервере (по ssh ${SSH_HOST})"
  if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$SSH_HOST" true 2>/dev/null; then
    warn "ssh ${SSH_HOST} не отвечает — выполни это вручную на сервере:"
    cat <<'EOF'
    docker ps --format 'table {{.Names}}\t{{.Status}}'
    docker exec <backend> alembic current
    docker exec <backend> python -c "from app.core.config import settings; print(settings.database_url)"
EOF
    return 0
  fi

  printf '\n$ docker ps (контейнеры ресурса)\n'
  ssh "$SSH_HOST" "docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'NAMES|${APP_UUID:-pppp}' || docker ps --format 'table {{.Names}}\t{{.Status}}'" || true

  BACKEND_CT=$(ssh "$SSH_HOST" "docker ps --format '{{.Names}}' | grep -E 'backend' | head -1" 2>/dev/null || true)
  if [[ -z "$BACKEND_CT" ]]; then
    warn "контейнер backend не найден — деплой не дошёл до старта, смотри логи."
    return 0
  fi
  ok "backend: ${BACKEND_CT}"

  printf '\n$ alembic current\n'
  ssh "$SSH_HOST" "docker exec ${BACKEND_CT} alembic current" || warn "alembic не ответил"

  printf '\n$ python -c "from app.core.config import settings; print(settings.database_url)"\n'
  DBURL=$(ssh "$SSH_HOST" "docker exec ${BACKEND_CT} python -c \"from app.core.config import settings; print(settings.database_url)\"" 2>&1 || true)
  # пароль в отчёт не тащим
  printf '%s\n' "$DBURL" | sed -E 's#(://[^:]+:)[^@]+@#\1***@#'
  if grep -qi sqlite <<<"$DBURL"; then
    warn "ВНУТРИ КОНТЕЙНЕРА SQLITE. Переменные не доехали: в compose у backend"
    warn "должен быть блок environment: с DATABASE_URL. Чинить до всего остального —"
    warn "в этом режиме данные стираются при каждом redeploy."
  elif grep -q '^postgresql' <<<"$DBURL"; then
    ok "база — postgres, как и должно быть"
  fi

  # Тот же капкан, что и в docs/postmortem-https-skillcheck.md: без метки
  # traefik.docker.network прокси выбирает сеть контейнера наугад и HTTPS виснет.
  printf '\n$ метка traefik.docker.network у %s\n' "$WEB_SERVICE"
  NGINX_CT=$(ssh "$SSH_HOST" "docker ps --format '{{.Names}}' | grep -E '${WEB_SERVICE}' | head -1" 2>/dev/null || true)
  if [[ -n "$NGINX_CT" ]]; then
    NET_LABEL=$(ssh "$SSH_HOST" "docker inspect -f '{{index .Config.Labels \"traefik.docker.network\"}}' ${NGINX_CT}" 2>/dev/null || true)
    NETS=$(ssh "$SSH_HOST" "docker inspect -f '{{range \$k, \$v := .NetworkSettings.Networks}}{{\$k}} {{end}}' ${NGINX_CT}" 2>/dev/null || true)
    echo "    сети:  ${NETS}"
    echo "    метка: ${NET_LABEL:-<нет>}"
    net_count=$(printf '%s' "$NETS" | wc -w | tr -d ' ')
    if [[ -z "$NET_LABEL" && "$net_count" -gt 1 ]]; then
      warn "метки нет, а сетей ${net_count} — ровно та ситуация из постмортема:"
      warn "Traefik может выбрать IP из сети, куда прокси не подключён, и HTTPS зависнет."
      warn "Диагностика: ssh ${SSH_HOST} 'bash -s' < scripts/06-diagnose-https.sh"
    fi
  fi
}

# --- токен -----------------------------------------------------------------

if [[ -z "${COOLIFY_TOKEN:-}" && "$CHECKS_ONLY" != "1" ]]; then
  printf 'API-токен Coolify (ввод скрыт): '
  read -rs COOLIFY_TOKEN
  printf '\n'
fi

if [[ "$CHECKS_ONLY" == "1" ]]; then
  run_checks
  exit 0
fi

[[ -n "${COOLIFY_TOKEN:-}" ]] || die "пустой токен."

say "Проверяю токен на ${API}"
api GET /teams/current
api_ok || die "API ответил ${CODE}. Проверь URL панели и токен. Ответ: ${RESP}"
ok "Токен рабочий, команда: $(printf '%s' "$RESP" | jget 'd.get("name","?")')"
api GET /version
api_ok && ok "Версия Coolify: ${RESP}"

# --- 1. сервер -------------------------------------------------------------

if [[ -z "$SERVER_UUID" ]]; then
  api GET /servers
  api_ok || die "не удалось получить список серверов: ${CODE} ${RESP}"
  count=$(printf '%s' "$RESP" | jget 'len(d) if isinstance(d, list) else 0')
  if [[ "$count" == "1" ]]; then
    SERVER_UUID=$(printf '%s' "$RESP" | jget 'd[0]["uuid"]')
    ok "Сервер: $(printf '%s' "$RESP" | jget 'd[0].get("name","?")') (${SERVER_UUID})"
  else
    printf '%s' "$RESP" | jget '"\n".join("  %s  %s  %s" % (x.get("uuid",""), x.get("name",""), x.get("ip","")) for x in d)'
    die "серверов ${count}, выбери нужный: SERVER_UUID=<uuid> bash scripts/07-deploy-pppp.sh"
  fi
fi

# --- 2. источник: GitHub App или ключ на чтение ------------------------------
# GitHub App даёт автодеплой из коробки (Coolify сам ставит вебхук).
# Без него — ключ на чтение + вебхук руками, инструкция печатается в конце.

say "Источник для приватного репозитория"
SOURCE_MODE=""
if [[ "$SOURCE" == "deploy-key" ]]; then
  # Принудительно, в обход GitHub App: например, когда панель не может выпустить
  # для него installation-токен и отвечает 500 на создание любого приложения.
  GITHUB_APP_UUID=""
elif [[ -z "$GITHUB_APP_UUID" ]]; then
  api GET /github-apps
  if api_ok; then
    # Источников в панели может быть несколько, и каждый видит только те
    # репозитории, на которые установлен. Брать первый попавшийся нельзя:
    # чужое приложение ответит 404 на наш репозиторий. Поэтому кандидаты —
    # все с заполненным app_id (встроенный Public GitHub его не имеет), а
    # выбирается тот, который действительно видит GIT_REPO.
    CANDIDATES=$(printf '%s' "$RESP" | "$PY" -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
items = d if isinstance(d, list) else (d.get("data") or [])
for x in items:
    if isinstance(x, dict) and x.get("app_id"):
        print("%s\t%s\t%s" % (x.get("uuid", ""), x.get("id", ""), x.get("name", "")))' 2>/dev/null || true)

    while IFS=$'\t' read -r cand_uuid cand_id cand_name; do
      [[ -n "$cand_uuid" ]] || continue
      if [[ -z "$cand_id" || "$cand_id" == "0" ]]; then
        # Без числового id список репозиториев не запросить — оставляем как
        # запасной вариант, вдруг других кандидатов не окажется.
        [[ -z "${FALLBACK_UUID:-}" ]] && FALLBACK_UUID="$cand_uuid"
        continue
      fi
      api GET "/github-apps/${cand_id}/repositories"
      if api_ok && printf '%s' "$RESP" | NEEDLE="$GIT_REPO" "$PY" -c '
import sys, json, os
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
items = d.get("repositories") if isinstance(d, dict) else d
names = [(i.get("full_name") or "").lower() for i in (items or []) if isinstance(i, dict)]
sys.exit(0 if os.environ["NEEDLE"].lower() in names else 1)' 2>/dev/null; then
        GITHUB_APP_UUID="$cand_uuid"
        ok "Приложение '${cand_name}' видит ${GIT_REPO}"
        break
      fi
      warn "приложение '${cand_name}' репозиторий ${GIT_REPO} не видит — пропускаю"
    done <<<"$CANDIDATES"

    if [[ -z "$GITHUB_APP_UUID" && -n "${FALLBACK_UUID:-}" ]]; then
      GITHUB_APP_UUID="$FALLBACK_UUID"
      warn "проверить доступ через API не вышло — беру приложение ${GITHUB_APP_UUID}"
    fi
    if [[ -z "$GITHUB_APP_UUID" && -n "$CANDIDATES" ]]; then
      die "ни одно из приложений не видит ${GIT_REPO}. Установи нужное на этот
репозиторий (Sources → приложение → Repositories) либо укажи его явно:
GITHUB_APP_UUID=<uuid> bash scripts/07-deploy-pppp.sh"
    fi
  fi
fi
if [[ -n "$GITHUB_APP_UUID" ]]; then
  SOURCE_MODE="github-app"
  ok "GitHub App: ${GITHUB_APP_UUID}"
else
  SOURCE_MODE="deploy-key"
  warn "Настоящего GitHub App в панели нет (встроенный 'Public GitHub' не в счёт:"
  warn "приватный репозиторий он не отдаст). Иду через ключ на чтение."
  api GET /security/keys
  api_ok || die "не удалось получить список ключей: ${CODE} ${RESP}"
  KEY_UUID=$(printf '%s' "$RESP" | jfind "$KEY_NAME")
  KEY_JUST_CREATED=0
  if [[ -n "$KEY_UUID" ]]; then
    ok "Ключ '${KEY_NAME}' уже в Coolify (${KEY_UUID})"
  else
    KEY_JUST_CREATED=1
    command -v ssh-keygen >/dev/null || die "нет ssh-keygen."
    [[ -f "$KEY_PATH" ]] || ssh-keygen -t ed25519 -a 100 -N '' -f "$KEY_PATH" -C "coolify-deploy-pppp" >/dev/null
    chmod 600 "$KEY_PATH"
    payload=$(KEY_NAME="$KEY_NAME" PRIV="$(cat "$KEY_PATH")" "$PY" -c '
import json, os
print(json.dumps({
    "name": os.environ["KEY_NAME"],
    "description": "read-only deploy key for pppp",
    "private_key": os.environ["PRIV"],
}))')
    api POST /security/keys "$payload"
    api_ok || die "не удалось загрузить ключ: ${CODE} ${RESP}"
    KEY_UUID=$(printf '%s' "$RESP" | jget 'd["uuid"]')
    ok "Ключ загружен (${KEY_UUID})"
  fi
fi

# --- 3. проект -------------------------------------------------------------

say "Проект '${PROJECT_NAME}'"
api GET /projects
api_ok || die "не удалось получить список проектов: ${CODE} ${RESP}"
PROJECT_UUID=$(printf '%s' "$RESP" | jfind "$PROJECT_NAME")
if [[ -n "$PROJECT_UUID" ]]; then
  ok "Уже есть (${PROJECT_UUID})"
else
  payload=$(PROJECT_NAME="$PROJECT_NAME" "$PY" -c '
import json, os
print(json.dumps({"name": os.environ["PROJECT_NAME"], "description": "PPPP Bot Hub, создан scripts/07-deploy-pppp.sh"}))')
  api POST /projects "$payload"
  api_ok || die "не удалось создать проект: ${CODE} ${RESP}"
  PROJECT_UUID=$(printf '%s' "$RESP" | jget 'd["uuid"]')
  ok "Создан (${PROJECT_UUID})"
fi

api GET "/projects/${PROJECT_UUID}"
ENVIRONMENT_UUID=""
if api_ok; then
  ENVIRONMENT_UUID=$(ENV_NAME="$ENVIRONMENT_NAME" "$PY" -c '
import sys, json, os
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
envs = d.get("environments") or []
name = os.environ["ENV_NAME"]
hit = next((e for e in envs if e.get("name") == name), None) or (envs[0] if envs else None)
print((hit or {}).get("uuid", ""))' <<<"$RESP" 2>/dev/null || true)
fi
[[ -n "$ENVIRONMENT_UUID" ]] && ok "Окружение: ${ENVIRONMENT_UUID}"

# --- 4. секреты ------------------------------------------------------------
# Генерируются один раз и живут в файле с правами 600: при повторном запуске
# пароль в DATABASE_URL обязан совпасть с тем, с которым уже создан том postgres.

say "Секреты"
if [[ -f "$SECRETS_FILE" ]]; then
  # shellcheck disable=SC1090
  source "$SECRETS_FILE"
  ok "Беру из ${SECRETS_FILE} (созданы раньше)"
else
  umask 077
  POSTGRES_PASSWORD="$(rand_hex 24)"
  SECRET_KEY="$(rand_hex 32)"
  WAHA_API_KEY="$(rand_hex 24)"
  WAHA_WEBHOOK_SECRET="$(rand_hex 32)"
  cat >"$SECRETS_FILE" <<EOF
# Секреты PPPP Bot Hub. Создан $(date -u +%FT%TZ) скриптом 07-deploy-pppp.sh.
# Не коммитить. Нужен при повторном запуске: пароль обязан совпасть с тем,
# с которым инициализирован том postgres_data.
POSTGRES_PASSWORD='${POSTGRES_PASSWORD}'
SECRET_KEY='${SECRET_KEY}'
WAHA_API_KEY='${WAHA_API_KEY}'
WAHA_WEBHOOK_SECRET='${WAHA_WEBHOOK_SECRET}'
EOF
  chmod 600 "$SECRETS_FILE"
  ok "Сгенерированы и сохранены в ${SECRETS_FILE} (chmod 600)"
fi
DATABASE_URL="postgresql+psycopg://postgres:${POSTGRES_PASSWORD}@db:5432/pppp_bot_hub"

# --- 5. приложение ---------------------------------------------------------

say "Ресурс '${APP_NAME}' (Docker Compose)"
api GET /applications
api_ok || die "не удалось получить список приложений: ${CODE} ${RESP}"
APP_UUID=$(printf '%s' "$RESP" | jfind "$APP_NAME")
WEBHOOK_SECRET=""

# Домен вешается только на сервис nginx: он внутренний edge и сам роутит пути.
# backend/frontend/waha домена не получают — WAHA обязана остаться внутри сети.
compose_domains_json=$(DOMAIN="$DOMAIN" WEB_SERVICE="$WEB_SERVICE" "$PY" -c '
import json, os
print(json.dumps([{"name": os.environ["WEB_SERVICE"], "domain": "https://" + os.environ["DOMAIN"]}]))')

if [[ -n "$APP_UUID" ]]; then
  ok "Уже есть (${APP_UUID}) — привожу настройки к нужным и обновляю переменные."
  payload=$(DOMAIN="$DOMAIN" WEB_SERVICE="$WEB_SERVICE" COMPOSE_LOCATION="$COMPOSE_LOCATION" \
    GIT_BRANCH="$GIT_BRANCH" "$PY" -c '
import json, os
e = os.environ
print(json.dumps({
    "build_pack": "dockercompose",
    "docker_compose_location": e["COMPOSE_LOCATION"],
    "docker_compose_domains": [{"name": e["WEB_SERVICE"], "domain": "https://" + e["DOMAIN"]}],
    "git_branch": e["GIT_BRANCH"],
    "is_auto_deploy_enabled": True,
    "is_force_https_enabled": True,
    "connect_to_docker_network": True,
}))')
  api PATCH "/applications/${APP_UUID}" "$payload"
  api_ok || warn "не удалось обновить настройки (${CODE}): ${RESP}"
else
  WEBHOOK_SECRET="$(rand_hex 16)"
  # build_payload <with_domains> <with_network> [ports_exposes]
  # Старые сборки Coolify отвечают 500 на docker_compose_domains при создании:
  # сервисов компоуза они ещё не знают, файл будет распарсен позже
  # (LoadComposeFile). Поэтому есть откат: создать ресурс без доменов и без
  # предопределённой сети, дождаться разбора compose и дослать это через PATCH.
  build_payload() {
    WITH_DOMAINS="$1" WITH_NETWORK="$2" \
    PROJECT_UUID="$PROJECT_UUID" SERVER_UUID="$SERVER_UUID" \
    ENVIRONMENT_NAME="$ENVIRONMENT_NAME" ENVIRONMENT_UUID="$ENVIRONMENT_UUID" \
    SOURCE_MODE="$SOURCE_MODE" GITHUB_APP_UUID="${GITHUB_APP_UUID:-}" KEY_UUID="${KEY_UUID:-}" \
    GIT_REPO="$GIT_REPO" GIT_REPO_SSH="$GIT_REPO_SSH" GIT_BRANCH="$GIT_BRANCH" \
    APP_NAME="$APP_NAME" DOMAIN="$DOMAIN" WEB_SERVICE="$WEB_SERVICE" \
    COMPOSE_LOCATION="$COMPOSE_LOCATION" WEBHOOK_SECRET="$WEBHOOK_SECRET" \
    PORTS="${3:-}" "$PY" -c '
import json, os
e = os.environ
b = {
    "project_uuid": e["PROJECT_UUID"],
    "server_uuid": e["SERVER_UUID"],
    "environment_name": e["ENVIRONMENT_NAME"],
    "git_branch": e["GIT_BRANCH"],
    "build_pack": "dockercompose",
    "docker_compose_location": e["COMPOSE_LOCATION"],
    "name": e["APP_NAME"],
    "description": "PPPP Bot Hub: nginx + frontend + backend + db + redis + waha",
    "is_auto_deploy_enabled": True,
    "is_force_https_enabled": True,
    "instant_deploy": False,
}
if e["WITH_DOMAINS"] == "1":
    # домен — только сервису nginx, порт 80; TLS терминирует Traefik
    b["docker_compose_domains"] = [{"name": e["WEB_SERVICE"], "domain": "https://" + e["DOMAIN"]}]
if e["WITH_NETWORK"] == "1":
    # контейнеры подключаются к общей сети coolify, где живёт прокси
    b["connect_to_docker_network"] = True
if e["SOURCE_MODE"] == "github-app":
    b["github_app_uuid"] = e["GITHUB_APP_UUID"]
    b["git_repository"] = e["GIT_REPO"]
else:
    b["private_key_uuid"] = e["KEY_UUID"]
    b["git_repository"] = e["GIT_REPO_SSH"]
    b["manual_webhook_secret_github"] = e["WEBHOOK_SECRET"]
if e.get("ENVIRONMENT_UUID"):
    b["environment_uuid"] = e["ENVIRONMENT_UUID"]
if e.get("PORTS"):
    b["ports_exposes"] = e["PORTS"]
print(json.dumps(b))'
  }

  if [[ "$SOURCE_MODE" == "github-app" ]]; then
    ENDPOINT=/applications/private-github-app
  else
    ENDPOINT=/applications/private-deploy-key
  fi

  # Попытки от полной к самой скромной. NEEDS_PATCH=1 значит, что домен и сеть
  # ресурс при создании не принял и их надо дослать после разбора compose.
  NEEDS_PATCH=0
  api POST "$ENDPOINT" "$(build_payload 1 1)"

  if ! api_ok && grep -qi 'ports_exposes' <<<"$RESP"; then
    warn "API требует ports_exposes. Повторяю с 80 — наружу порт всё равно не"
    warn "публикуется (это делает ports_mappings), в compose только expose."
    api POST "$ENDPOINT" "$(build_payload 1 1 80)"
  fi

  if ! api_ok; then
    warn "Создание с доменом и предопределённой сетью не прошло (${CODE}):"
    printf '%s\n' "$RESP" | head -5
    warn "Пробую без них — домен назначу отдельным запросом, когда Coolify"
    warn "разберёт compose-файл и узнает про сервис ${WEB_SERVICE}."
    NEEDS_PATCH=1
    api POST "$ENDPOINT" "$(build_payload 0 0)"
    if ! api_ok && grep -qi 'ports_exposes' <<<"$RESP"; then
      api POST "$ENDPOINT" "$(build_payload 0 0 80)"
    fi
  fi

  api_ok || die "не удалось создать ресурс: ${CODE} ${RESP}"
  APP_UUID=$(printf '%s' "$RESP" | jget 'd["uuid"]')
  ok "Создан (${APP_UUID})"

  if [[ "$NEEDS_PATCH" == "1" ]]; then
    say "Досылаю домен и предопределённую сеть"
    # LoadComposeFile ставится в очередь при создании; дать ему дочитать файл
    sleep 15
    patch_payload() { # patch_payload <with_network>
      WITH_NETWORK="$1" DOMAIN="$DOMAIN" WEB_SERVICE="$WEB_SERVICE" "$PY" -c '
import json, os
e = os.environ
b = {"docker_compose_domains": [{"name": e["WEB_SERVICE"], "domain": "https://" + e["DOMAIN"]}]}
if e["WITH_NETWORK"] == "1":
    b["connect_to_docker_network"] = True
print(json.dumps(b))'
    }
    api PATCH "/applications/${APP_UUID}" "$(patch_payload 1)"
    if ! api_ok; then
      warn "с предопределённой сетью не прошло (${CODE}) — повторяю только с доменом"
      api PATCH "/applications/${APP_UUID}" "$(patch_payload 0)"
    fi
    if api_ok; then
      ok "Домен назначен"
    else
      warn "не удалось назначить домен через API (${CODE}): ${RESP}"
      warn "Сделай это в панели: ресурс → Configuration → Domains → у сервиса"
      warn "${WEB_SERVICE} вписать https://${DOMAIN}, у остальных оставить пусто."
    fi
  fi
fi

# --- 6. переменные окружения -----------------------------------------------
# Список — из .env.coolify.example репозитория pppp. Значения по умолчанию в
# compose есть у всех, кроме DATABASE_URL, SECRET_KEY и POSTGRES_PASSWORD, но
# заводим весь набор явно: так видно, что реально уехало в контейнеры.

say "Переменные окружения"
set_env() { # set_env KEY VALUE
  local payload
  payload=$(K="$1" V="$2" "$PY" -c '
import json, os
print(json.dumps({"key": os.environ["K"], "value": os.environ["V"], "is_preview": False}))')
  api POST "/applications/${APP_UUID}/envs" "$payload"
  if api_ok; then
    ok "$1 — добавлена"
  else
    api PATCH "/applications/${APP_UUID}/envs" "$payload"
    if api_ok; then ok "$1 — обновлена"
    else warn "$1 — не удалось (${CODE}): ${RESP}"; fi
  fi
}

# LLM_PROVIDER=stub: ключа DeepSeek сейчас нет, приложение поднимается с
# детерминированной заглушкой. Появится ключ — LLM_PROVIDER=deepseek,
# LLM_API_KEY=<ключ>, redeploy.
LLM_PROVIDER="${LLM_PROVIDER:-stub}"

set_env POSTGRES_PASSWORD "$POSTGRES_PASSWORD"
set_env SECRET_KEY        "$SECRET_KEY"
set_env DATABASE_URL      "$DATABASE_URL"
set_env APP_NAME          "PPPP Bot Hub API"
set_env ENVIRONMENT       "production"
set_env API_V1_PREFIX     "/api/v1"
set_env JWT_ALGORITHM     "HS256"
set_env ACCESS_TOKEN_EXPIRE_MINUTES  "30"
set_env REFRESH_TOKEN_EXPIRE_MINUTES "10080"
set_env REDIS_URL         "redis://redis:6379/0"
set_env LLM_PROVIDER      "$LLM_PROVIDER"
set_env LLM_API_KEY       "${LLM_API_KEY:-}"
set_env LLM_BASE_URL      "https://api.deepseek.com"
set_env LLM_MODEL         "deepseek-chat"
set_env LLM_TIMEOUT_SECONDS "30"
set_env TELEGRAM_WEBHOOK_BASE "https://${DOMAIN}/api/v1/webhook/telegram"
set_env WHATSAPP_WEBHOOK_BASE "https://${DOMAIN}/api/v1/webhook/whatsapp"
set_env MAX_WEBHOOK_BASE      "https://${DOMAIN}/api/v1/webhook/max"
set_env FRONTEND_BASE_URL     "https://${DOMAIN}"
set_env WHATSAPP_ENABLED      "false"
set_env WHATSAPP_ACCESS_TOKEN "${WHATSAPP_ACCESS_TOKEN:-}"
set_env WHATSAPP_APP_SECRET   "${WHATSAPP_APP_SECRET:-}"
set_env WHATSAPP_VERIFY_TOKEN "${WHATSAPP_VERIFY_TOKEN:-}"
set_env WHATSAPP_API_VERSION  "v19.0"
set_env WHATSAPP_GRAPH_BASE   "https://graph.facebook.com"
set_env WHATSAPP_HTTP_TIMEOUT "20"
set_env WAHA_BASE_URL         "http://waha:3000"
set_env WAHA_API_KEY          "$WAHA_API_KEY"
set_env WAHA_WEBHOOK_SECRET   "$WAHA_WEBHOOK_SECRET"
set_env WAHA_ENVIRONMENT      "production"
set_env WAHA_FORCE_DEFAULT_SESSION "false"
set_env WA_QR_RATE_LIMIT_PER_MINUTE "20"
set_env WA_QR_RATE_LIMIT_PER_DAY    "1000"
set_env WA_QR_RATE_LIMIT_PREFIX     "waqr:rl"
set_env WA_QR_HEALTHCHECK_FAILED_THRESHOLD_MINUTES "5"

# --- 7. проверка, что домен висит там, где надо -----------------------------

say "Кому достался домен"
api GET "/applications/${APP_UUID}"
if api_ok; then
  printf '%s' "$RESP" | "$PY" -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
raw = d.get("docker_compose_domains")
if isinstance(raw, str):
    try:
        raw = json.loads(raw)
    except Exception:
        raw = []
items = raw or []
if isinstance(items, dict):
    items = [{"name": k, **(v if isinstance(v, dict) else {"domain": v})} for k, v in items.items()]
for i in items:
    print("    %-10s %s" % (i.get("name", "?"), i.get("domain", "")))
print("    fqdn (общий):", d.get("fqdn") or "<пусто>")
' || true
  BAD=$(printf '%s' "$RESP" | WEB_SERVICE="$WEB_SERVICE" "$PY" -c '
import sys, json, os
try:
    d = json.load(sys.stdin)
except Exception:
    raise SystemExit
web = os.environ.get("WEB_SERVICE", "nginx")
raw = d.get("docker_compose_domains")
if isinstance(raw, str):
    try:
        raw = json.loads(raw)
    except Exception:
        raw = []
items = raw or []
if isinstance(items, dict):
    items = [{"name": k, **(v if isinstance(v, dict) else {"domain": v})} for k, v in items.items()]
bad = [i.get("name") for i in items if i.get("name") != web and i.get("domain")]
print(",".join(x for x in bad if x))' 2>/dev/null || true)
  if [[ -n "$BAD" ]]; then
    warn "домен назначен ещё и на: ${BAD}. Убрать в UI — Configuration → Domains."
  else
    ok "домен только у ${WEB_SERVICE}; backend, frontend и waha снаружи не видны"
  fi
fi

# --- 8. деплой -------------------------------------------------------------

if [[ "$DEPLOY" == "1" && "${KEY_JUST_CREATED:-0}" == "1" ]]; then
  warn "Ключ на чтение создан только что и в GitHub его ещё нет — деплой сейчас"
  warn "упадёт на git clone. Добавь ключ и вебхук (напечатаны ниже) и запусти"
  warn "скрипт ещё раз: он подхватит созданное и задеплоит."
  DEPLOY=0
fi

if [[ "$DEPLOY" != "1" ]]; then
  warn "DEPLOY=0 — деплой не запускаю."
else
  say "Запускаю деплой"
  api POST "/deploy?uuid=${APP_UUID}"
  api_ok || die "не удалось поставить деплой в очередь: ${CODE} ${RESP}"
  DEPLOY_UUID=$(printf '%s' "$RESP" | jget '(d.get("deployments") or [{}])[0].get("deployment_uuid","")')
  ok "В очереди${DEPLOY_UUID:+ (${DEPLOY_UUID})}"

  if [[ -n "$DEPLOY_UUID" ]]; then
    say "Жду окончания (до ${WAIT_SECONDS}s; сборка frontend и backend не быстрая)"
    waited=0
    while (( waited < WAIT_SECONDS )); do
      api GET "/deployments/${DEPLOY_UUID}"
      STATUS=$(printf '%s' "$RESP" | jget 'd.get("status","")')
      printf '\r    %s (%ds)   ' "${STATUS:-?}" "$waited"
      case "$STATUS" in
        finished|failed|cancelled-by-user) break ;;
      esac
      sleep 10; waited=$((waited + 10))
    done
    printf '\n'
    if [[ "$STATUS" == "finished" ]]; then
      ok "Деплой завершён"
    else
      warn "Статус деплоя: ${STATUS:-неизвестен}. Логи:"
      warn "  ${COOLIFY_URL}/project/${PROJECT_UUID}"
      printf '%s' "$RESP" | jget 'd.get("logs","")' | tail -60
    fi
    # backend поднимается healthy не раньше start_period=40s, nginx ждёт его
    say "Пауза 60s: backend становится healthy, nginx стартует после него"
    sleep 60
  fi
fi

# --- 9. проверки -----------------------------------------------------------

run_checks

# --- 10. что осталось руками ------------------------------------------------

cat <<EOF

$(printf '\033[1;32m')Ресурс: ${COOLIFY_URL}/project/${PROJECT_UUID}$(printf '\033[0m')
UUID приложения: ${APP_UUID}

Секреты (SECRET_KEY, POSTGRES_PASSWORD, WAHA_*) сгенерированы и заведены в
Coolify. Локальная копия — ${SECRETS_FILE} (chmod 600). В отчёты не копировать.

LLM_PROVIDER=stub. Появится ключ DeepSeek: LLM_PROVIDER=deepseek,
LLM_API_KEY=<ключ>, redeploy.
EOF

if [[ "$SOURCE_MODE" == "deploy-key" ]]; then
  cat <<EOF

Автодеплой через GitHub App не настроен (App не подключён к Coolify), поэтому
осталось два действия в репозитории AlexB0nch/pppp:

1. Settings → Deploy keys → Add deploy key, "Allow write access" НЕ ставить:
EOF
  [[ -f "${KEY_PATH}.pub" ]] && printf '\n%s\n' "$(cat "${KEY_PATH}.pub")"
  cat <<EOF

2. Settings → Webhooks → Add webhook
   Payload URL:   ${COOLIFY_URL}/webhooks/source/github/events/manual
   Content type:  application/json
   Secret:        ${WEBHOOK_SECRET:-смотри вкладку Webhooks у ресурса}
   События:       Just the push event
EOF
fi
