#!/usr/bin/env bash
# Восстановление Coolify на НОВОМ сервере из бэкапа его БД в S3.
# Запускается НА СЕРВЕРЕ под root, после 02-server-setup.sh (Coolify уже стоит):
#
#   S3_ENDPOINT=https://s3.example.com S3_BUCKET=my-bucket \
#     bash scripts/07-restore-from-s3.sh
#
# или, если дамп уже лежит на сервере:
#
#   BACKUP_FILE=/root/pg-dump-coolify-....dmp bash scripts/07-restore-from-s3.sh
#
# Скрипт спросит скрытым вводом то, чего нет в переменных: ключи S3 и APP_KEY
# старого Coolify (строка APP_KEY= из старого /data/coolify/source/.env).
# Без старого APP_KEY восстановление бессмысленно: переменные окружения
# приложений, приватные ключи и настройки S3 в дампе зашифрованы им.
#
# Переменные:
#   BACKUP_FILE      готовый .dmp на сервере — тогда S3 не нужен
#   S3_ENDPOINT      https-адрес S3 (для AWS можно не задавать)
#   S3_BUCKET        бакет
#   S3_PREFIX        где искать внутри бакета (по умолчанию — весь бакет)
#   S3_REGION        регион, по умолчанию us-east-1
#   AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY  ключи S3
#   S3_KEY           конкретный объект; по умолчанию берётся самый свежий *.dmp
#   OLD_APP_KEY      APP_KEY старого Coolify (base64:...)
#   COOLIFY_VERSION  версия для повторного запуска установщика; по умолчанию
#                    та, что сейчас стоит
#
# Что делает: скачивает дамп, проверяет его, останавливает coolify и
# coolify-redis (coolify-db остаётся), прописывает старый APP_KEY, делает
# pg_restore, перезапускает установщик (он поднимает контейнеры и прогоняет
# миграции), затем выгружает ключи из восстановленной БД на диск и добавляет
# ключ localhost в /root/.ssh/authorized_keys.
#
# Бэкап самого Coolify НЕ содержит данных приложений и их баз — только
# настройки панели. Базы проектов восстанавливаются потом, каждая из своей
# вкладки Backups (см. docs/переезд-на-новый-сервер.md).
set -euo pipefail

say()  { printf '\033[1;32m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Нужен root."
command -v docker >/dev/null || die "Docker не найден — сначала scripts/02-server-setup.sh."

ENV_FILE=/data/coolify/source/.env
[[ -f "$ENV_FILE" ]] || die "$ENV_FILE не найден — Coolify не установлен."
docker ps --format '{{.Names}}' | grep -qx coolify-db \
  || die "Контейнер coolify-db не запущен. Проверь: docker ps -a"

WORK=/data/coolify/backups/restore
install -d -m 700 "$WORK"

ask_secret() {  # ask_secret ИМЯ "подсказка"
  local __name=$1 __prompt=$2 __val
  if [[ -z "${!__name:-}" ]]; then
    read -rsp "$__prompt: " __val </dev/tty; echo
    [[ -n "$__val" ]] || die "$__name пустой."
    printf -v "$__name" '%s' "$__val"
  fi
}

# --- 1. дамп -----------------------------------------------------------------
if [[ -n "${BACKUP_FILE:-}" ]]; then
  [[ -s "$BACKUP_FILE" ]] || die "$BACKUP_FILE пустой или не существует."
else
  [[ -n "${S3_BUCKET:-}" ]] || die "Задай S3_BUCKET (или BACKUP_FILE)."
  ask_secret AWS_ACCESS_KEY_ID "S3 access key"
  ask_secret AWS_SECRET_ACCESS_KEY "S3 secret key"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY
  AWS=(docker run --rm -e AWS_ACCESS_KEY_ID -e AWS_SECRET_ACCESS_KEY
       -e AWS_DEFAULT_REGION="${S3_REGION:-us-east-1}" -v "$WORK:/out"
       amazon/aws-cli)
  [[ -n "${S3_ENDPOINT:-}" ]] && AWS+=(--endpoint-url "$S3_ENDPOINT")

  if [[ -z "${S3_KEY:-}" ]]; then
    say "Ищу самый свежий *.dmp в s3://$S3_BUCKET/${S3_PREFIX:-}"
    LISTING=$("${AWS[@]}" s3 ls --recursive "s3://$S3_BUCKET/${S3_PREFIX:-}") \
      || die "Не смог прочитать бакет — проверь endpoint, бакет и ключи."
    # формат строки: ДАТА ВРЕМЯ РАЗМЕР КЛЮЧ; coolify-дампы предпочтительнее
    S3_KEY=$(printf '%s\n' "$LISTING" | grep -E '\.dmp$' | grep -i 'coolify' \
             | sort -k1,2 | tail -1 | awk '{ $1=$2=$3=""; sub(/^ +/,""); print }')
    if [[ -z "$S3_KEY" ]]; then
      printf '%s\n' "$LISTING" | tail -30
      die "Не нашёл *.dmp бэкапа Coolify. Укажи объект явно: S3_KEY=путь/файл.dmp"
    fi
    say "Найден: $S3_KEY"
    printf '%s\n' "$LISTING" | grep -E '\.dmp$' | sort -k1,2 | tail -5 | sed 's/^/    /'
  fi
  BACKUP_FILE="$WORK/$(basename "$S3_KEY")"
  say "Скачиваю в $BACKUP_FILE"
  "${AWS[@]}" s3 cp "s3://$S3_BUCKET/$S3_KEY" "/out/$(basename "$S3_KEY")" >/dev/null
  [[ -s "$BACKUP_FILE" ]] || die "Скачанный файл пустой."
fi
ls -lh "$BACKUP_FILE"

say "Проверяю, что это дамп pg_dump --format=custom"
docker exec -i coolify-db pg_restore --list < "$BACKUP_FILE" >/dev/null \
  || die "pg_restore не читает файл — это не custom-формат или файл битый."

# --- 2. APP_KEY ----------------------------------------------------------------
ask_secret OLD_APP_KEY "APP_KEY старого Coolify (base64:...)"
OLD_APP_KEY=${OLD_APP_KEY#APP_KEY=}
[[ "$OLD_APP_KEY" == base64:* ]] || warn "APP_KEY обычно начинается с base64: — проверь, что вставил то."

CUR_VERSION=$(docker inspect coolify --format '{{.Config.Image}}' 2>/dev/null | awk -F: '{print $NF}')
COOLIFY_VERSION="${COOLIFY_VERSION:-$CUR_VERSION}"
say "Установленная версия: ${CUR_VERSION:-?}, установщик перезапущу с: ${COOLIFY_VERSION:-latest}"

STAMP=$(date +%Y%m%d-%H%M%S)
cp -a "$ENV_FILE" "$ENV_FILE.before-restore-$STAMP"
say "Копия текущего .env: $ENV_FILE.before-restore-$STAMP"
docker exec coolify-db pg_dump --format=custom --no-acl --no-owner -U coolify coolify \
  > "$WORK/fresh-install-$STAMP.dmp"
say "Копия БД свежей установки (для отката): $WORK/fresh-install-$STAMP.dmp"

# --- 3. restore ------------------------------------------------------------------
say "Останавливаю coolify, coolify-redis, coolify-realtime (coolify-db остаётся)"
for c in coolify coolify-redis coolify-realtime; do
  docker stop "$c" >/dev/null 2>&1 || true
done

if grep -q '^APP_KEY=' "$ENV_FILE"; then
  # | как разделитель: в base64 бывают / и +, но не |
  sed -i "s|^APP_KEY=.*|APP_KEY=${OLD_APP_KEY}|" "$ENV_FILE"
else
  echo "APP_KEY=${OLD_APP_KEY}" >> "$ENV_FILE"
fi
say "APP_KEY в $ENV_FILE заменён на старый"

say "pg_restore в coolify-db"
docker exec -i coolify-db pg_restore --clean --if-exists --exit-on-error \
  --no-acl --no-owner --username=coolify --dbname=coolify < "$BACKUP_FILE" \
  || die "pg_restore упал. Контейнеры оставлены остановленными. Откат: верни
   $ENV_FILE.before-restore-$STAMP и восстанови $WORK/fresh-install-$STAMP.dmp той же командой."

# --- 4. установщик: поднимает контейнеры и прогоняет миграции -------------------
AK=/root/.ssh/authorized_keys
[[ -s "$AK" ]] && cp "$AK" "$WORK/authorized_keys.before-$STAMP"
say "Перезапускаю установщик Coolify ${COOLIFY_VERSION:-latest}"
curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/coolify-install.sh
bash /tmp/coolify-install.sh ${COOLIFY_VERSION:+"$COOLIFY_VERSION"}

# установщик бывает перетирает authorized_keys — возвращаем потерянное
if [[ -f "$WORK/authorized_keys.before-$STAMP" ]]; then
  while IFS= read -r line; do
    [[ -n "$line" ]] && ! grep -qxF "$line" "$AK" && echo "$line" >> "$AK"
  done < "$WORK/authorized_keys.before-$STAMP"
fi

say "Жду, пока панель поднимется"
for _ in $(seq 1 60); do
  docker exec coolify php artisan --version >/dev/null 2>&1 && break
  sleep 5
done

# --- 5. SSH-ключи из восстановленной БД -----------------------------------------
# Файлы /data/coolify/ssh/keys со старого сервера потеряны вместе с ним, но
# сами ключи лежат в БД (зашифрованы APP_KEY). Выгружаем их на диск и пускаем
# ключ сервера localhost в authorized_keys — иначе Coolify не сможет управлять
# собственным хостом.
say "Выгружаю приватные ключи из БД и прописываю ключ localhost"
PUB=$(docker exec coolify php artisan tinker --execute='
  foreach (\App\Models\PrivateKey::all() as $k) {
    try { $k->storeInFileSystem(); } catch (\Throwable $e) {}
  }
  $s = \App\Models\Server::find(0);
  echo $s && $s->privateKey ? trim($s->privateKey->getPublicKey()) : "";
' 2>/dev/null | grep -E '^(ssh-|ecdsa-)' | tail -1 || true)

if [[ -n "$PUB" ]]; then
  grep -qxF "$PUB" "$AK" 2>/dev/null || echo "$PUB" >> "$AK"
  chmod 600 "$AK"
  say "Ключ localhost добавлен в $AK"
else
  warn "Не смог достать публичный ключ localhost автоматически."
  warn "Возьми его в панели: Keys & Tokens -> Private Keys -> ключ сервера localhost"
  warn "-> публичная часть, и допиши строкой в $AK. Затем Servers -> localhost -> Validate."
  warn "Если панель пишет про 'MAC is invalid' — APP_KEY не тот."
fi

IP=$(curl -fsS -m 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
cat <<EOF

$(say "Готово. Дальше руками:")
  1) http://${IP}:8000 — войти СТАРЫМ логином/паролем (они в восстановленной БД).
  2) Servers -> localhost -> Validate & configure. Если IP в карточке старый —
     поменять на host.docker.internal или ${IP}.
  3) Проверить, что переменные окружения у приложений читаются (нет ошибки
     про MAC/encryption) — значит APP_KEY правильный.
  4) DNS: A-записи домена, coolify.* и *.* -> ${IP}.
  5) Базы проектов: у каждой БД вкладка Backups -> восстановить из S3, затем
     Redeploy приложений. Порядок — в docs/переезд-на-новый-сервер.md.
  6) Keys & Tokens -> API tokens: старый токен снова действует (он в БД),
     если нет — выпустить новый.
EOF
