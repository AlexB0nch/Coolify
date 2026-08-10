#!/usr/bin/env bash
# Шаг 5. Запускается НА ТВОЁМ КОМПЬЮТЕРЕ (macOS / Linux / WSL / Git Bash).
#
# Разворачивает через API Coolify фоновый воркер из приватного GitHub-репозитория:
#   1) генерирует SSH-ключ на чтение репозитория и кладёт его в Coolify;
#   2) создаёт проект (если его ещё нет);
#   3) создаёт приложение: build pack Dockerfile, без домена и без порта,
#      healthcheck выключен, лимиты памяти и CPU выставлены;
#   4) заливает переменные окружения из файла;
#   5) печатает, что осталось вставить в GitHub: deploy key и вебхук.
#
# Ничего не удаляет и не меняет уже существующие ресурсы: повторный запуск
# переиспользует созданное раньше. Деплой сам не запускает — только по DEPLOY=1.
#
# Использование:
#   COOLIFY_URL=https://coolify.твойдомен.ru ENV_FILE=~/dd-cheki.env \
#     bash scripts/05-deploy-worker.sh
#
# Токен: Coolify → Keys & Tokens → API tokens, права на чтение и запись.
# Передавать переменной COOLIFY_TOKEN либо ввести по запросу (в историю
# командной строки он тогда не попадёт).

set -euo pipefail

COOLIFY_URL="${COOLIFY_URL:-http://95.85.242.143:8000}"
COOLIFY_URL="${COOLIFY_URL%/}"
API="${COOLIFY_URL}/api/v1"

APP_NAME="${APP_NAME:-dd-cheki}"
PROJECT_NAME="${PROJECT_NAME:-wife}"
ENVIRONMENT_NAME="${ENVIRONMENT_NAME:-production}"
GIT_REPO="${GIT_REPO:-git@github.com:z05052025/dd-cheki.git}"
GIT_BRANCH="${GIT_BRANCH:-main}"
ENV_FILE="${ENV_FILE:-./${APP_NAME}.env}"
KEY_NAME="${KEY_NAME:-deploy-${APP_NAME}}"
KEY_PATH="${KEY_PATH:-$HOME/.ssh/coolify_deploy_${APP_NAME}}"
MEMORY="${MEMORY:-1g}"
CPUS="${CPUS:-1}"
SERVER_UUID="${SERVER_UUID:-}"
DESTINATION_UUID="${DESTINATION_UUID:-}"
PORTS_EXPOSES="${PORTS_EXPOSES:-}"
DEPLOY="${DEPLOY:-0}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

command -v curl >/dev/null    || die "нет curl."
command -v python3 >/dev/null || die "нет python3 — он нужен для разбора ответов API."
command -v ssh-keygen >/dev/null || die "нет ssh-keygen."

if [[ -z "${COOLIFY_TOKEN:-}" ]]; then
  printf 'API-токен Coolify (ввод скрыт): '
  read -rs COOLIFY_TOKEN
  printf '\n'
fi
[[ -n "$COOLIFY_TOKEN" ]] || die "пустой токен."

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
  python3 -c 'import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
v = eval(sys.argv[1])
print("" if v is None else v)' "$1" 2>/dev/null || true
}

# jfind — uuid элемента массива по полю name
jfind() {
  NEEDLE="$1" python3 -c 'import sys, json, os
try:
    d = json.load(sys.stdin)
except Exception:
    print(""); raise SystemExit
n = os.environ["NEEDLE"]
if not isinstance(d, list):
    print(""); raise SystemExit
print(next((x.get("uuid", "") for x in d if x.get("name") == n), ""))' 2>/dev/null || true
}

rand_hex() {
  if command -v openssl >/dev/null; then openssl rand -hex 16
  else python3 -c 'import secrets; print(secrets.token_hex(16))'; fi
}

# --- 0. токен и сервер -----------------------------------------------------

say "Проверяю токен на ${API}"
api GET /teams/current
api_ok || die "API ответил ${CODE}. Проверь URL панели и токен. Ответ: ${RESP}"
ok "Токен рабочий, команда: $(printf '%s' "$RESP" | jget 'd.get("name","?")')"

if [[ -z "$SERVER_UUID" ]]; then
  api GET /servers
  api_ok || die "не удалось получить список серверов: ${CODE} ${RESP}"
  count=$(printf '%s' "$RESP" | jget 'len(d) if isinstance(d, list) else 0')
  if [[ "$count" == "1" ]]; then
    SERVER_UUID=$(printf '%s' "$RESP" | jget 'd[0]["uuid"]')
    ok "Сервер: $(printf '%s' "$RESP" | jget 'd[0].get("name","?")') (${SERVER_UUID})"
  else
    printf '%s' "$RESP" | jget '"\n".join("  %s  %s  %s" % (x.get("uuid",""), x.get("name",""), x.get("ip","")) for x in d)'
    die "серверов ${count}, выбери нужный: SERVER_UUID=<uuid> bash scripts/05-deploy-worker.sh"
  fi
fi

# --- 1. ключ на чтение репозитория -----------------------------------------

say "SSH-ключ для доступа к репозиторию"
api GET /security/keys
api_ok || die "не удалось получить список ключей: ${CODE} ${RESP}"
KEY_UUID=$(printf '%s' "$RESP" | jfind "$KEY_NAME")

if [[ -n "$KEY_UUID" ]]; then
  ok "Ключ '${KEY_NAME}' в Coolify уже есть (${KEY_UUID})"
else
  if [[ ! -f "$KEY_PATH" ]]; then
    say "Генерирую ${KEY_PATH}"
    ssh-keygen -t ed25519 -a 100 -N '' -f "$KEY_PATH" -C "coolify-deploy-${APP_NAME}" >/dev/null
  else
    warn "Локальный ключ ${KEY_PATH} уже есть — беру его."
  fi
  chmod 600 "$KEY_PATH"
  payload=$(KEY_NAME="$KEY_NAME" APP_NAME="$APP_NAME" PRIV="$(cat "$KEY_PATH")" python3 -c '
import json, os
print(json.dumps({
    "name": os.environ["KEY_NAME"],
    "description": "read-only deploy key for %s" % os.environ["APP_NAME"],
    "private_key": os.environ["PRIV"],
}))')
  api POST /security/keys "$payload"
  api_ok || die "не удалось загрузить ключ: ${CODE} ${RESP}"
  KEY_UUID=$(printf '%s' "$RESP" | jget 'd["uuid"]')
  ok "Ключ загружен в Coolify (${KEY_UUID})"
fi

# --- 2. проект -------------------------------------------------------------

say "Проект '${PROJECT_NAME}'"
api GET /projects
api_ok || die "не удалось получить список проектов: ${CODE} ${RESP}"
PROJECT_UUID=$(printf '%s' "$RESP" | jfind "$PROJECT_NAME")

if [[ -n "$PROJECT_UUID" ]]; then
  ok "Уже есть (${PROJECT_UUID})"
else
  payload=$(PROJECT_NAME="$PROJECT_NAME" python3 -c '
import json, os
print(json.dumps({"name": os.environ["PROJECT_NAME"], "description": "создан scripts/05-deploy-worker.sh"}))')
  api POST /projects "$payload"
  api_ok || die "не удалось создать проект: ${CODE} ${RESP}"
  PROJECT_UUID=$(printf '%s' "$RESP" | jget 'd["uuid"]')
  ok "Создан (${PROJECT_UUID})"
fi

api GET "/projects/${PROJECT_UUID}"
ENVIRONMENT_UUID=""
if api_ok; then
  ENVIRONMENT_UUID=$(ENV_NAME="$ENVIRONMENT_NAME" python3 -c '
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

# --- 3. приложение ---------------------------------------------------------

say "Приложение '${APP_NAME}'"
api GET /applications
api_ok || die "не удалось получить список приложений: ${CODE} ${RESP}"
APP_UUID=$(printf '%s' "$RESP" | jfind "$APP_NAME")
WEBHOOK_SECRET=""

if [[ -n "$APP_UUID" ]]; then
  ok "Уже есть (${APP_UUID}) — создание пропускаю, обновлю только переменные."
else
  WEBHOOK_SECRET="$(rand_hex)"
  build_payload() { # build_payload [ports_exposes]
    PROJECT_UUID="$PROJECT_UUID" SERVER_UUID="$SERVER_UUID" \
    ENVIRONMENT_NAME="$ENVIRONMENT_NAME" ENVIRONMENT_UUID="$ENVIRONMENT_UUID" \
    KEY_UUID="$KEY_UUID" GIT_REPO="$GIT_REPO" GIT_BRANCH="$GIT_BRANCH" \
    APP_NAME="$APP_NAME" MEMORY="$MEMORY" CPUS="$CPUS" \
    DESTINATION_UUID="$DESTINATION_UUID" WEBHOOK_SECRET="$WEBHOOK_SECRET" \
    PORTS="${1:-}" python3 -c '
import json, os
e = os.environ
b = {
    "project_uuid": e["PROJECT_UUID"],
    "server_uuid": e["SERVER_UUID"],
    "environment_name": e["ENVIRONMENT_NAME"],
    "private_key_uuid": e["KEY_UUID"],
    "git_repository": e["GIT_REPO"],
    "git_branch": e["GIT_BRANCH"],
    "build_pack": "dockerfile",
    "name": e["APP_NAME"],
    "description": "фоновый воркер, без домена и без открытых портов",
    # порта нет: HTTP-проверка живости пометила бы контейнер unhealthy
    "health_check_enabled": False,
    "limits_memory": e["MEMORY"],
    "limits_cpus": e["CPUS"],
    "is_auto_deploy_enabled": True,
    "manual_webhook_secret_github": e["WEBHOOK_SECRET"],
    "instant_deploy": False,
}
if e.get("ENVIRONMENT_UUID"):
    b["environment_uuid"] = e["ENVIRONMENT_UUID"]
if e.get("DESTINATION_UUID"):
    b["destination_uuid"] = e["DESTINATION_UUID"]
if e.get("PORTS"):
    b["ports_exposes"] = e["PORTS"]
print(json.dumps(b))'
  }

  api POST /applications/private-deploy-key "$(build_payload "$PORTS_EXPOSES")"
  if ! api_ok && [[ -z "$PORTS_EXPOSES" ]] && grep -qi 'ports_exposes' <<<"$RESP"; then
    warn "API требует ports_exposes. Повторяю с 3000: наружу порт не публикуется"
    warn "(это делает ports_mappings), домена нет, так что на воркер это не влияет."
    api POST /applications/private-deploy-key "$(build_payload 3000)"
  fi
  api_ok || die "не удалось создать приложение: ${CODE} ${RESP}"
  APP_UUID=$(printf '%s' "$RESP" | jget 'd["uuid"]')
  ok "Создано (${APP_UUID})"
fi

# --- 4. переменные окружения -----------------------------------------------

say "Переменные окружения из ${ENV_FILE}"
if [[ ! -f "$ENV_FILE" ]]; then
  warn "Файла нет — переменные не заливаю. Формат: KEY=VALUE, по одной в строке."
  warn "Не клади его в репозиторий: там боевой BITRIX_WEBHOOK."
else
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"                      # файл мог прийти из Windows
    [[ -z "${line// }" ]] && continue
    [[ "${line#"${line%%[![:space:]]*}"}" == \#* ]] && continue
    [[ "$line" != *=* ]] && { warn "пропускаю строку без '=': ${line}"; continue; }
    k="${line%%=*}"; v="${line#*=}"
    k="$(printf '%s' "$k" | tr -d '[:space:]')"
    [[ -z "$k" ]] && continue
    # снимаем кавычки, если значение целиком в них
    if [[ "$v" == \"*\" || "$v" == \'*\' ]]; then v="${v:1:${#v}-2}"; fi

    payload=$(K="$k" V="$v" python3 -c '
import json, os
print(json.dumps({"key": os.environ["K"], "value": os.environ["V"], "is_preview": False}))')
    api POST "/applications/${APP_UUID}/envs" "$payload"
    if api_ok; then
      ok "${k} — добавлена"
    else
      api PATCH "/applications/${APP_UUID}/envs" "$payload"
      if api_ok; then ok "${k} — обновлена"
      else warn "${k} — не удалось (${CODE}): ${RESP}"; fi
    fi
  done < "$ENV_FILE"
fi

# --- 5. что осталось руками ------------------------------------------------

PUBKEY=""
[[ -f "${KEY_PATH}.pub" ]] && PUBKEY="$(cat "${KEY_PATH}.pub")"

# git@github.com:owner/repo.git и https://github.com/owner/repo.git → owner/repo
REPO_SLUG="${GIT_REPO%.git}"
REPO_SLUG="${REPO_SLUG##*:}"
REPO_SLUG="${REPO_SLUG#https://github.com/}"

cat <<EOF

$(printf '\033[1;32m')Приложение готово: ${COOLIFY_URL}/project/${PROJECT_UUID}$(printf '\033[0m')

Осталось четыре действия, которые через API не делаются.

1. Владелец репозитория добавляет ключ на чтение:
   github.com/${REPO_SLUG} → Settings → Deploy keys → Add deploy key,
   галочку "Allow write access" НЕ ставить.
EOF

if [[ -n "$PUBKEY" ]]; then
  printf '\n%s\n' "$PUBKEY"
else
  printf '\n   Публичная часть: Coolify → Keys & Tokens → %s\n' "$KEY_NAME"
fi

cat <<EOF

2. Он же добавляет вебхук: Settings → Webhooks → Add webhook
   Payload URL:   ${COOLIFY_URL}/webhooks/source/github/events/manual
   Content type:  application/json
EOF

if [[ -n "$WEBHOOK_SECRET" ]]; then
  printf '   Secret:        %s\n' "$WEBHOOK_SECRET"
else
  printf '   Secret:        смотри вкладку Webhooks у приложения\n'
fi

cat <<EOF
   События:       Just the push event

3. В панели, вкладка Advanced у приложения, секция Container: включить
   "Consistent Container Names". Это единственная настройка из чек-листа,
   которой нет в API. Она выключает rolling update — иначе во время деплоя
   полминуты живут два воркера и разбирают одни и те же файлы.

4. Deploy. Первый прогон с DRY_RUN=1, дальше по логам.
EOF

if [[ "$DEPLOY" == "1" ]]; then
  say "DEPLOY=1 — запускаю деплой"
  api POST "/deploy?uuid=${APP_UUID}"
  api_ok && ok "Деплой поставлен в очередь: ${RESP}" || warn "не удалось запустить: ${CODE} ${RESP}"
fi
