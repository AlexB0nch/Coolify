#!/usr/bin/env bash
# Шаг 6. Бэкапы: расписания в Coolify, копия дампов к себе, проверка восстановления.
#
# Пять подкоманд:
#   plan    — (по умолчанию) какие базы есть и что у них с бэкапами. Ничего не меняет.
#   setup   — создать или обновить расписания через API Coolify.
#   status  — что реально лежит на сервере: объём, свежесть, последние файлы.
#   pull    — забрать дампы с сервера к себе (rsync). Это и есть «внешнее хранилище».
#   verify  — поднять последний PostgreSQL-дамп в одноразовом контейнере и убедиться,
#             что он читается. Бэкап, который ни разу не восстанавливали, бэкапом не является.
#
# Использование:
#   bash scripts/06-backups.sh plan
#   S3_UUID=<uuid> BACKUP_NOW=1 bash scripts/06-backups.sh setup
#   bash scripts/06-backups.sh status
#   bash scripts/06-backups.sh pull
#   bash scripts/06-backups.sh verify
#
# plan и setup ходят в API — нужен токен: Coolify → Keys & Tokens → API tokens,
# права на чтение и запись. Передавать переменной COOLIFY_TOKEN либо ввести по
# запросу (в историю командной строки он тогда не попадёт).
# status, pull и verify работают по ssh и через docker, токен им не нужен.
#
# Что скрипт НЕ делает:
#   * не трогает бэкап самой базы Coolify — её расписание живёт в UI
#     (Settings → Backup), в API этого эндпоинта нет. plan напомнит про него.
#   * не бэкапит тома приложений — только базы данных, как и сама Coolify.

set -euo pipefail

COOLIFY_URL="${COOLIFY_URL:-http://95.85.242.143:8000}"
COOLIFY_URL="${COOLIFY_URL%/}"
API="${COOLIFY_URL}/api/v1"

HOST_ALIAS="${HOST_ALIAS:-coolify}"
REMOTE_DIR="${REMOTE_DIR:-/data/coolify/backups}"
LOCAL_DIR="${LOCAL_DIR:-$HOME/coolify-backups}"

# расписание и сколько хранить; локально короче, в S3 длиннее — место там дешевле
FREQUENCY="${FREQUENCY:-0 3 * * *}"
KEEP_LOCAL="${KEEP_LOCAL:-7}"
KEEP_DAYS_LOCAL="${KEEP_DAYS_LOCAL:-14}"
KEEP_S3="${KEEP_S3:-30}"
KEEP_DAYS_S3="${KEEP_DAYS_S3:-60}"
S3_UUID="${S3_UUID:-}"
BACKUP_NOW="${BACKUP_NOW:-0}"

VERIFY_IMAGE="${VERIFY_IMAGE:-postgres:17-alpine}"
STALE_HOURS="${STALE_HOURS:-48}"

CMD="${1:-plan}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

# --- API, те же помощники, что в 05-deploy-worker.sh -----------------------

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

need_token() {
  command -v curl >/dev/null    || die "нет curl."
  command -v python3 >/dev/null || die "нет python3 — он нужен для разбора ответов API."
  if [[ -z "${COOLIFY_TOKEN:-}" ]]; then
    printf 'API-токен Coolify (ввод скрыт): '
    read -rs COOLIFY_TOKEN
    printf '\n'
  fi
  [[ -n "${COOLIFY_TOKEN:-}" ]] || die "пустой токен."
  api GET /teams/current
  api_ok || die "API ответил ${CODE}. Проверь URL панели и токен. Ответ: ${RESP}"
}

# Разбирает GET /databases в строки, разделённые табом:
#   uuid  имя  тип  uuid_расписания  расписание  s3  включено
# Тип определяем по характерным полям, а если их нет — по имени образа.
parse_databases() {
  python3 -c '
import sys, json

MARKS = [
    ("postgresql", ("postgres_db", "postgres_user", "postgres_password")),
    ("mysql",      ("mysql_database", "mysql_root_password")),
    ("mariadb",    ("mariadb_database", "mariadb_root_password")),
    ("mongodb",    ("mongo_initdb_database", "mongo_conf")),
    ("clickhouse", ("clickhouse_db", "clickhouse_admin_user")),
    ("redis",      ("redis_password", "redis_conf")),
    ("keydb",      ("keydb_password", "keydb_conf")),
    ("dragonfly",  ("dragonfly_password",)),
]
BY_IMAGE = [
    ("postgresql", "postgres"), ("mariadb", "mariadb"), ("mysql", "mysql"),
    ("mongodb", "mongo"), ("clickhouse", "clickhouse"), ("keydb", "keydb"),
    ("dragonfly", "dragonfly"), ("redis", "redis"),
]

def kind(db):
    for name, fields in MARKS:
        if any(f in db for f in fields):
            return name
    image = (db.get("image") or "").lower()
    for name, needle in BY_IMAGE:
        if needle in image:
            return name
    return "unknown"

def clean(v):
    return str(v).replace("\t", " ").replace("\n", " ") if v is not None else ""

try:
    dbs = json.load(sys.stdin)
except Exception:
    raise SystemExit(0)
if not isinstance(dbs, list):
    raise SystemExit(0)

for db in dbs:
    cfgs = db.get("backup_configs") or []
    cfg = cfgs[0] if cfgs else {}
    print("\t".join(clean(x) for x in (
        db.get("uuid", ""),
        db.get("name", ""),
        kind(db),
        cfg.get("uuid", ""),
        cfg.get("frequency", ""),
        "s3" if cfg.get("save_s3") else ("local" if cfg else ""),
        "" if not cfg else ("on" if cfg.get("enabled") else "off"),
    )))
' 2>/dev/null || true
}

# Типы, которые Coolify умеет дампить. Redis, KeyDB и Dragonfly — кеши,
# расписания бэкапов для них нет: терять там нечего, а класть некуда.
BACKUPABLE_RE='^(postgresql|mysql|mariadb|mongodb|clickhouse)$'
backupable() {
  case "$1" in
    postgresql|mysql|mariadb|mongodb|clickhouse) return 0 ;;
    *) return 1 ;;
  esac
}

# Печатает таблицу по строкам из parse_databases. Именно python, а не printf:
# printf в bash выравнивает по байтам, и кириллица разъезжает.
render_table() {
  python3 -c '
import sys

BACKUPABLE = {"postgresql", "mysql", "mariadb", "mongodb", "clickhouse"}
CACHES = {"redis", "keydb", "dragonfly"}
HEAD = ["ИМЯ", "ТИП", "РАСПИСАНИЕ", "КУДА", "СОСТОЯНИЕ"]

rows = []
for line in sys.stdin.read().splitlines():
    if not line.strip():
        continue
    f = (line.split("\t") + [""] * 7)[:7]
    _, name, kind, bk_uuid, freq, dest, enabled = f
    if kind in CACHES:
        rows.append([name, kind, "-", "-", "кеш, бэкапить нечего"])
    elif kind not in BACKUPABLE:
        rows.append([name, kind, "-", "-", "тип не распознан, настрой в UI"])
    elif not bk_uuid:
        rows.append([name, kind, "-", "-", "БЭКАПА НЕТ"])
    else:
        rows.append([name, kind, freq,
                     "S3 + диск" if dest == "s3" else "только диск",
                     "включено" if enabled == "on" else "ВЫКЛЮЧЕНО"])

if not rows:
    raise SystemExit(0)
w = [max(len(r[i]) for r in [HEAD] + rows) for i in range(5)]
sep = "  "
print()
print(sep.join(HEAD[i].ljust(w[i]) for i in range(5)).rstrip())
print(sep.join("-" * w[i] for i in range(5)))
for r in rows:
    print(sep.join(r[i].ljust(w[i]) for i in range(5)).rstrip())
'
}

# newest_dump КАТАЛОГ ШАБЛОН [ШАБЛОН ...] — самый свежий файл по времени изменения.
# Сортировать по имени нельзя: в разных подкаталогах свои временные метки.
newest_dump() {
  local dir="$1"; shift
  local args=() p
  for p in "$@"; do args+=(-o -name "$p"); done
  find "$dir" -type f \( "${args[@]:1}" \) -print0 2>/dev/null \
    | xargs -0 ls -t 2>/dev/null | head -1 || true
}

coolify_db_hint() {
  cat <<EOF

$(printf '\033[1;33m')База самой Coolify — отдельно, руками, один раз.$(printf '\033[0m')
В ней проекты, приложения, переменные окружения (там боевые секреты), SSH-ключи
и вебхуки. Весит десятки мегабайт, а потеряешь — собирать панель заново.
Эндпоинта в API для неё нет, поэтому:

  ${COOLIFY_URL}/settings/backup

Частота, локальное хранение и то же самое S3-хранилище, что и у баз проектов.
EOF
}

s3_hint() {
  cat <<EOF

$(printf '\033[1;33m')S3 не задан — дампы останутся лежать на том же сервере.$(printf '\033[0m')
От «удалил не ту таблицу» это спасает, от «диск умер» — нет.

Хранилище добавляется в ${COOLIFY_URL}/storages (кнопка + Add), после чего его
uuid виден в адресной строке: /storages/<uuid>. Дальше:

  S3_UUID=<uuid> bash scripts/06-backups.sh setup

Годится любое S3-совместимое: Cloudflare R2, Backblaze B2, Yandex Object
Storage, Hetzner. Держи его у ДРУГОГО провайдера, не у того, где VPS, — иначе
проблема с аккаунтом уносит и сервер, и бэкапы разом.
EOF
}

# --- plan ------------------------------------------------------------------

cmd_plan() {
  need_token
  say "Базы данных и их расписания"
  api GET /databases
  api_ok || die "не удалось получить список баз: ${CODE} ${RESP}"

  local rows total=0 without=0 local_only=0 have_coolify_db=0
  rows="$(printf '%s' "$RESP" | parse_databases)"

  if [[ -z "$rows" ]]; then
    warn "Управляемых баз в проектах нет — бэкапить пока нечего."
    warn "Воркеру без состояния (dd-cheki) бэкап и не нужен: временные файлы, всё в Битриксе."
  else
    printf '%s\n' "$rows" | render_table
    total=$(printf '%s\n' "$rows" | grep -c . || true)
    without=$(awk -F'\t' -v re="$BACKUPABLE_RE" '$3 ~ re && $4 == "" {n++} END {print n + 0}' <<<"$rows")
    local_only=$(awk -F'\t' '$6 == "local" {n++} END {print n + 0}' <<<"$rows")
    have_coolify_db=$(awk -F'\t' '$2 == "coolify-db" {f = 1} END {print f + 0}' <<<"$rows")
  fi

  echo
  if [[ "$without" -gt 0 ]]; then
    warn "Без расписания: ${without}. Завести: bash scripts/06-backups.sh setup"
  elif [[ "$total" -gt 0 ]]; then
    ok "У всех баз, которые можно дампить, расписание есть."
  fi
  [[ "$local_only" -gt 0 ]] && warn "Только локально: ${local_only}. Это копия на том же диске, что и оригинал."

  [[ -z "$S3_UUID" || "$local_only" -gt 0 ]] && s3_hint
  [[ "$have_coolify_db" -eq 0 ]] && coolify_db_hint

  cat <<EOF

Дальше по шагам:
  1. bash scripts/06-backups.sh setup   — расписания для баз проектов
  2. bash scripts/06-backups.sh status  — убедиться, что дампы реально появились
  3. bash scripts/06-backups.sh pull    — копия к себе, потом в cron
  4. bash scripts/06-backups.sh verify  — проверить, что дамп восстанавливается
  5. ${COOLIFY_URL}/settings/backup — база самой Coolify, руками
EOF
}

# --- setup -----------------------------------------------------------------

cmd_setup() {
  need_token
  say "Расписания бэкапов: ${FREQUENCY}, локально ${KEEP_LOCAL} шт / ${KEEP_DAYS_LOCAL} дн"
  if [[ -n "$S3_UUID" ]]; then
    ok "S3: ${S3_UUID}, хранить ${KEEP_S3} шт / ${KEEP_DAYS_S3} дн"
  else
    warn "S3 не задан — расписания будут только локальные."
  fi

  api GET /databases
  api_ok || die "не удалось получить список баз: ${CODE} ${RESP}"

  local rows payload created=0 updated=0 skipped=0 no_api=0
  rows="$(printf '%s' "$RESP" | parse_databases)"
  [[ -z "$rows" ]] && { warn "Управляемых баз нет — настраивать нечего."; coolify_db_hint; return 0; }

  payload=$(FREQUENCY="$FREQUENCY" KEEP_LOCAL="$KEEP_LOCAL" KEEP_DAYS_LOCAL="$KEEP_DAYS_LOCAL" \
            KEEP_S3="$KEEP_S3" KEEP_DAYS_S3="$KEEP_DAYS_S3" S3_UUID="$S3_UUID" \
            BACKUP_NOW="$BACKUP_NOW" python3 -c '
import json, os
e = os.environ
b = {
    "frequency": e["FREQUENCY"],
    "enabled": True,
    "database_backup_retention_amount_locally": int(e["KEEP_LOCAL"]),
    "database_backup_retention_days_locally": int(e["KEEP_DAYS_LOCAL"]),
}
if e["S3_UUID"]:
    b["save_s3"] = True
    b["s3_storage_uuid"] = e["S3_UUID"]
    b["database_backup_retention_amount_s3"] = int(e["KEEP_S3"])
    b["database_backup_retention_days_s3"] = int(e["KEEP_DAYS_S3"])
if e["BACKUP_NOW"] == "1":
    b["backup_now"] = True
print(json.dumps(b))')

  while IFS=$'\t' read -r uuid name kind bk_uuid freq dest enabled; do
    [[ -z "$uuid" ]] && continue
    if ! backupable "$kind"; then
      skipped=$((skipped + 1))
      case "$kind" in
        redis|keydb|dragonfly) warn "${name} (${kind}) — кеш, пропускаю: дампить нечего." ;;
        *) warn "${name} (${kind}) — тип не распознан, пропускаю. Настрой вручную во вкладке Backups." ;;
      esac
      continue
    fi
    # databases_to_backup не передаём: Coolify сам подставит основную базу ресурса
    if [[ -z "$bk_uuid" ]]; then
      api POST "/databases/${uuid}/backups" "$payload"
      if api_ok; then created=$((created + 1)); ok "${name} — расписание создано"
      else
        warn "${name} — не удалось создать (${CODE}): ${RESP}"
        [[ "$CODE" == "404" || "$CODE" == "405" ]] && no_api=1
      fi
    else
      # POST здесь плодил бы дубли: он всегда создаёт новое расписание
      api PATCH "/databases/${uuid}/backups/${bk_uuid}" "$payload"
      if api_ok; then updated=$((updated + 1)); ok "${name} — расписание обновлено"
      else
        warn "${name} — не удалось обновить (${CODE}): ${RESP}"
        [[ "$CODE" == "404" || "$CODE" == "405" ]] && no_api=1
      fi
    fi
  done <<<"$rows"

  echo
  ok "Создано: ${created}, обновлено: ${updated}, пропущено: ${skipped}"

  if [[ "$no_api" -eq 1 ]]; then
    cat <<EOF

$(printf '\033[1;33m')API ответил 404/405 на эндпоинты бэкапов.$(printf '\033[0m')
Скорее всего панель старее, чем /databases/{uuid}/backups. Тогда всё то же самое
делается руками и одинаково хорошо работает: у каждой базы вкладка Backups →
Add, там частота, S3 и сроки хранения. Либо обнови Coolify и запусти setup снова.
EOF
  fi
  [[ "$BACKUP_NOW" == "1" ]] && ok "BACKUP_NOW=1 — прогон запущен сразу, проверь через минуту: bash scripts/06-backups.sh status"
  [[ -z "$S3_UUID" ]] && s3_hint
  coolify_db_hint
}

# --- status ----------------------------------------------------------------

cmd_status() {
  command -v ssh >/dev/null || die "нет ssh."
  say "Что лежит в ${REMOTE_DIR} на ${HOST_ALIAS}"
  ssh -o BatchMode=yes "$HOST_ALIAS" "REMOTE_DIR='${REMOTE_DIR}' STALE_HOURS='${STALE_HOURS}' bash -s" <<'REMOTE'
set -u
if [[ ! -d "$REMOTE_DIR" ]]; then
  echo "Каталога $REMOTE_DIR нет — ни одного бэкапа ещё не отработало."
  exit 0
fi
echo "Занято всего: $(du -sh "$REMOTE_DIR" 2>/dev/null | cut -f1)"
echo "Свободно на диске: $(df -h "$REMOTE_DIR" | awk 'NR==2 {print $4" из "$2}')"
count=$(find "$REMOTE_DIR" -type f | wc -l)
echo "Файлов: $count"
if [[ "$count" -eq 0 ]]; then
  echo "Пусто. Расписание есть, но ни один прогон не дошёл до конца — смотри вкладку Backups у базы."
  exit 0
fi
echo
echo "Последние 15 файлов:"
find "$REMOTE_DIR" -type f -printf '%TY-%Tm-%Td %TH:%TM  %10s  %p\n' 2>/dev/null \
  | sort -r | head -15 \
  || ls -lt --time-style=long-iso "$REMOTE_DIR"/*/*/* 2>/dev/null | head -15
echo
fresh=$(find "$REMOTE_DIR" -type f -mmin "-$((STALE_HOURS * 60))" | wc -l)
if [[ "$fresh" -eq 0 ]]; then
  echo "[!] За последние ${STALE_HOURS} ч ни одного нового файла. Расписание молчит или падает."
else
  echo "[+] Свежих файлов за ${STALE_HOURS} ч: ${fresh}"
fi
REMOTE
  cat <<EOF

Раскладка каталога:
  ${REMOTE_DIR}/coolify/coolify-db-<адрес>/       — база самой панели; для локального
                                                    сервера адрес — hostdockerinternal
  ${REMOTE_DIR}/databases/<команда>-<id>/<база>/  — базы проектов

Имена говорят о формате, он важен при восстановлении:
  pg-dump-<база>-<время>.dmp   — pg_dump --format=custom, разворачивать pg_restore
  pg-dump-all-<время>.gz       — pg_dumpall, обычный SQL под gzip, разворачивать psql
  mysql-dump-*.dmp / *.gz, mariadb-dump-*, mongo-dump-*.tar.gz — по своим утилитам
EOF
}

# --- pull ------------------------------------------------------------------

cmd_pull() {
  command -v rsync >/dev/null || die "нет rsync. macOS/Linux — уже есть; Windows — ставь в WSL: sudo apt install rsync"
  mkdir -p "$LOCAL_DIR"
  say "Забираю ${HOST_ALIAS}:${REMOTE_DIR}/ → ${LOCAL_DIR}/"
  # без --delete: на сервере старое подчищает ретенция Coolify, а локальная копия
  # для того и нужна, чтобы жить дольше сервера
  rsync -az --info=stats1 -e ssh "${HOST_ALIAS}:${REMOTE_DIR}/" "${LOCAL_DIR}/"
  ok "Локально: $(du -sh "$LOCAL_DIR" 2>/dev/null | cut -f1) в ${LOCAL_DIR}"

  local newest
  newest="$(newest_dump "$LOCAL_DIR" '*dump*' '*backup*')"
  [[ -n "$newest" ]] && ok "Самый свежий дамп: ${newest}"

  cat <<EOF

В cron у себя, чтобы копия обновлялась сама (crontab -e):

  0 4 * * * cd "$(pwd)" && HOST_ALIAS=${HOST_ALIAS} bash scripts/06-backups.sh pull >> ${LOCAL_DIR}/pull.log 2>&1

Ноутбук, который ночью выключен, для этого плохая площадка — тогда лучше S3 в
самой Coolify: там расписание отрабатывает на сервере и от твоей машины не зависит.
EOF
}

# --- verify ----------------------------------------------------------------

cmd_verify() {
  command -v docker >/dev/null || die "нет docker — он нужен, чтобы поднять чистый PostgreSQL под проверку."
  local file="${2:-}"
  [[ -z "$file" ]] && file="${DUMP_FILE:-}"

  if [[ -z "$file" ]]; then
    [[ -d "$LOCAL_DIR" ]] || die "нет ${LOCAL_DIR}. Сначала: bash scripts/06-backups.sh pull"
    file="$(newest_dump "$LOCAL_DIR" 'pg-dump-*.dmp' 'pg-dump-all-*.gz')"
    [[ -n "$file" ]] || die "в ${LOCAL_DIR} нет PostgreSQL-дампов. Проверить другой файл: bash scripts/06-backups.sh verify /путь/к/дампу"
  fi
  [[ -f "$file" ]] || die "файла нет: ${file}"

  case "$(basename "$file")" in
    pg-dump-all-*.gz|pg-dump-*.dmp) ;;
    mongo-dump-*|mysql-dump-*|mariadb-dump-*|clickhouse-backup-*)
      die "verify умеет только PostgreSQL. Для ${file##*/} поднимай образ той же СУБД и разворачивай её родной утилитой." ;;
    *) warn "Непонятное имя файла — пробую как PostgreSQL." ;;
  esac

  # имя контейнера — глобальное, а не local: trap срабатывает уже после выхода
  # из функции, и переменную функции там было бы не видно
  VERIFY_CNAME="coolify-verify-$$"
  trap 'docker rm -f "${VERIFY_CNAME:-}" >/dev/null 2>&1 || true' EXIT

  say "Поднимаю одноразовый ${VERIFY_IMAGE}"
  docker run -d --name "$VERIFY_CNAME" -e POSTGRES_PASSWORD=verify -e POSTGRES_DB=verify "$VERIFY_IMAGE" >/dev/null

  local i=0
  until docker exec "$VERIFY_CNAME" pg_isready -U postgres -q 2>/dev/null; do
    i=$((i + 1)); [[ "$i" -gt 60 ]] && die "PostgreSQL в контейнере не поднялся за 60 с. Логи: docker logs ${VERIFY_CNAME}"
    sleep 1
  done
  ok "Контейнер готов"

  say "Восстанавливаю ${file##*/} ($(du -h "$file" | cut -f1))"
  local target="verify"
  if [[ "$(basename "$file")" == pg-dump-all-*.gz ]]; then
    # pg_dumpall — обычный SQL с ролями и CREATE DATABASE. Данные лягут не в ту
    # базу, к которой подключается psql, а в созданные дампом — их и проверяем.
    gunzip -c "$file" | docker exec -i "$VERIFY_CNAME" psql -U postgres -d postgres -q >/dev/null \
      || warn "psql ругался по ходу — смотри вывод выше, часть объектов могла не встать."
    say "Базы, приехавшие из дампа"
    docker exec "$VERIFY_CNAME" psql -U postgres -d postgres -c \
      "select datname as \"база\", pg_size_pretty(pg_database_size(datname)) as \"размер\"
         from pg_database
        where not datistemplate and datname <> 'postgres'
        order by pg_database_size(datname) desc;"
    target="$(docker exec "$VERIFY_CNAME" psql -U postgres -d postgres -tAc \
      "select datname from pg_database
        where not datistemplate and datname <> 'postgres'
        order by pg_database_size(datname) desc limit 1;" | tr -d '\r')"
    [[ -n "$target" ]] || die "Дамп не создал ни одной базы. Файл пустой или битый."
    ok "Смотрю самую крупную: ${target}"
  else
    # .dmp — формат custom, только pg_restore; --no-owner, ролей исходного сервера тут нет
    docker exec -i "$VERIFY_CNAME" pg_restore -U postgres -d verify --no-owner --no-acl >/dev/null <"$file" \
      || warn "pg_restore ругался по ходу — смотри вывод выше, часть объектов могла не встать."
  fi

  say "Что получилось"
  docker exec "$VERIFY_CNAME" psql -U postgres -d "$target" -c \
    "select table_schema as \"схема\", count(*) as \"таблиц\"
       from information_schema.tables
      where table_schema not in ('pg_catalog','information_schema')
      group by table_schema order by 2 desc;"
  docker exec "$VERIFY_CNAME" psql -U postgres -d "$target" -c \
    "select schemaname||'.'||relname as \"таблица\", n_live_tup as \"строк, по статистике\"
       from pg_stat_user_tables order by n_live_tup desc limit 15;"

  local tables
  tables="$(docker exec "$VERIFY_CNAME" psql -U postgres -d "$target" -tAc \
    "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema');")"
  echo
  if [[ "${tables:-0}" -gt 0 ]]; then
    ok "Дамп восстанавливается: таблиц ${tables}. Теперь это бэкап, а не файл на диске."
  else
    die "Таблиц ноль. Дамп пустой или битый — разбирайся до того, как он понадобится."
  fi
}

# --- разбор команды --------------------------------------------------------

case "$CMD" in
  plan)    cmd_plan ;;
  setup)   cmd_setup ;;
  status)  cmd_status ;;
  pull)    cmd_pull ;;
  verify)  cmd_verify "$@" ;;
  -h|--help|help)
    sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)
    die "неизвестная команда '${CMD}'. Есть: plan, setup, status, pull, verify." ;;
esac
