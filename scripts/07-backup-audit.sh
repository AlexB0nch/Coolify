#!/usr/bin/env bash
# Аудит бэкапов. Запускается НА СЕРВЕРЕ:
#   ssh coolify 'bash -s' < scripts/07-backup-audit.sh
#
# Ничего не меняет — только читает базу самой панели. Отвечает на вопросы:
#   1) какие S3-хранилища заведены и рабочие ли они;
#   2) у каких баз есть расписание бэкапа, а у каких нет вообще;
#   3) что уходит в S3, что лежит рядом с базой, а что не сохраняется нигде;
#   4) когда бэкап последний раз отработал, чем закончился и долетел ли до S3;
#   5) что НЕ покрыто бэкапами — тома приложений и сервисов;
#   6) бэкапится ли сама база Coolify.
#
# Секреты не печатает: ключи и пароли S3 из s3_storages не читаются.
set -uo pipefail

hr()   { printf '\n\033[1;36m── %s ─────────────────────────\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }

ENV_FILE=/data/coolify/source/.env
[[ -r $ENV_FILE ]] || { echo "не найден $ENV_FILE — это точно хост Coolify?"; exit 1; }
val() { grep -E "^$1=" "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d "\"'"; }
DB_PASSWORD=$(val DB_PASSWORD)
DB_USER=$(val DB_USERNAME); DB_USER=${DB_USER:-coolify}
DB_NAME=$(val DB_DATABASE); DB_NAME=${DB_NAME:-coolify}

# Важно: без -i. Скрипт приезжает сюда через stdin (bash -s), и docker exec -i
# сожрал бы его остаток себе на вход.
psql_() { docker exec -e PGPASSWORD="$DB_PASSWORD" coolify-db \
            psql -U "$DB_USER" -d "$DB_NAME" -X -q "$@" </dev/null 2>&1; }
q()  { psql_ --no-align --pset=footer=off -c "$1"; }   # с заголовками
qv() { psql_ -tA -c "$1"; }                            # одно значение

# Схема backup-таблиц менялась между версиями Coolify: number_of_backups_locally
# переименован в database_backup_retention_amount_locally, disable_local_backup и
# s3_uploaded добавлены позже. Подставляем то, что реально есть в этой установке.
col() { # col <таблица> <колонка> <чем заменить, если её нет>
  [[ $(qv "SELECT 1 FROM information_schema.columns
           WHERE table_name='$1' AND column_name='$2' LIMIT 1;") == 1 ]] \
    && echo "$2" || echo "$3"
}
KEEP_LOCAL=$(col scheduled_database_backups database_backup_retention_amount_locally \
             "$(col scheduled_database_backups number_of_backups_locally "'n/a'")")
NO_LOCAL=$(col scheduled_database_backups disable_local_backup false)
S3_UP=$(col scheduled_database_backup_executions s3_uploaded "'n/a'")

# Все типы управляемых баз в одну витрину. Джойн со scheduled_database_backups
# идёт по morph-паре database_id + database_type; morph-карты в Coolify нет,
# поэтому в database_type лежит полное имя класса.
ALL_DB="
WITH d AS (
  SELECT id,uuid,name,environment_id,'App\\Models\\StandalonePostgresql' AS t,'postgresql' AS kind FROM standalone_postgresqls
  UNION ALL SELECT id,uuid,name,environment_id,'App\\Models\\StandaloneMysql','mysql' FROM standalone_mysqls
  UNION ALL SELECT id,uuid,name,environment_id,'App\\Models\\StandaloneMariadb','mariadb' FROM standalone_mariadbs
  UNION ALL SELECT id,uuid,name,environment_id,'App\\Models\\StandaloneMongodb','mongodb' FROM standalone_mongodbs
  UNION ALL SELECT id,uuid,name,environment_id,'App\\Models\\StandaloneRedis','redis' FROM standalone_redis
  UNION ALL SELECT id,uuid,name,environment_id,'App\\Models\\StandaloneKeydb','keydb' FROM standalone_keydbs
  UNION ALL SELECT id,uuid,name,environment_id,'App\\Models\\StandaloneDragonfly','dragonfly' FROM standalone_dragonflies
  UNION ALL SELECT id,uuid,name,environment_id,'App\\Models\\StandaloneClickhouse','clickhouse' FROM standalone_clickhouses
),
db AS (
  SELECT d.*, e.name AS env, p.name AS project
  FROM d LEFT JOIN environments e ON e.id=d.environment_id
         LEFT JOIN projects p ON p.id=e.project_id
)"

hr "S3-хранилища (Settings → S3 Storages)"
q "SELECT id, name, bucket, endpoint, region, is_usable FROM s3_storages ORDER BY id;" | sed 's/|/ | /g'
[[ $(qv "SELECT count(*) FROM s3_storages;") == 0 ]] && \
  warn "S3-хранилищ нет вообще — выгружать бэкапы некуда."
[[ $(qv "SELECT count(*) FROM s3_storages WHERE is_usable IS NOT TRUE;") != 0 ]] && \
  warn "Есть хранилище с is_usable = false: Coolify не достучался до бакета, выгрузка туда падает."

hr "Все проекты и их ресурсы"
q "$ALL_DB
SELECT COALESCE(project,'—') AS project, COALESCE(env,'—') AS env, kind AS type, name FROM db
UNION ALL
SELECT COALESCE(p.name,'—'), COALESCE(e.name,'—'), 'app', a.name
  FROM applications a LEFT JOIN environments e ON e.id=a.environment_id
       LEFT JOIN projects p ON p.id=e.project_id
UNION ALL
SELECT COALESCE(p.name,'—'), COALESCE(e.name,'—'), 'service', s.name
  FROM services s LEFT JOIN environments e ON e.id=s.environment_id
       LEFT JOIN projects p ON p.id=e.project_id
ORDER BY 1,2,3,4;" | sed 's/|/ | /g'

hr "Базы БЕЗ расписания бэкапа — это дыра"
q "$ALL_DB
SELECT COALESCE(db.project,'—') AS project, db.kind AS type, db.name, db.uuid
FROM db
WHERE NOT EXISTS (SELECT 1 FROM scheduled_database_backups b
                  WHERE b.database_id=db.id AND b.database_type=db.t)
ORDER BY 1,2,3;" | sed 's/|/ | /g'

hr "Расписания бэкапов: включено? уходит в S3? куда?"
q "$ALL_DB
SELECT COALESCE(db.project,'—') AS project, COALESCE(db.name,'?') AS database,
       b.enabled, b.frequency, b.save_s3 AS to_s3,
       COALESCE(s.name,'—') AS s3_target,
       $NO_LOCAL AS local_off, $KEEP_LOCAL AS keep_local
FROM scheduled_database_backups b
LEFT JOIN db ON db.id=b.database_id AND db.t=b.database_type
LEFT JOIN s3_storages s ON s.id=b.s3_storage_id
ORDER BY 1,2;" | sed 's/|/ | /g'

hr "Не доезжает до S3: выключено, или без выгрузки, или без назначенного бакета"
q "$ALL_DB
SELECT COALESCE(db.project,'—') AS project, COALESCE(db.name,'?') AS database,
       b.enabled, b.save_s3 AS to_s3, COALESCE(s.name,'нет') AS s3_target
FROM scheduled_database_backups b
LEFT JOIN db ON db.id=b.database_id AND db.t=b.database_type
LEFT JOIN s3_storages s ON s.id=b.s3_storage_id
WHERE b.enabled IS NOT TRUE OR b.save_s3 IS NOT TRUE OR b.s3_storage_id IS NULL
ORDER BY 1,2;" | sed 's/|/ | /g'
warn "Бэкап без S3 лежит на том же диске, что и база: при потере диска пропадёт вместе с ней."

hr "Не сохраняется НИГДЕ: локальные копии отключены и выгрузки в S3 нет"
q "$ALL_DB
SELECT COALESCE(db.project,'—') AS project, COALESCE(db.name,'?') AS database
FROM scheduled_database_backups b
LEFT JOIN db ON db.id=b.database_id AND db.t=b.database_type
WHERE b.enabled IS TRUE AND $NO_LOCAL IS TRUE
  AND (b.save_s3 IS NOT TRUE OR b.s3_storage_id IS NULL);" | sed 's/|/ | /g'

hr "Последний запуск каждого бэкапа: статус, возраст, долетел ли до S3"
q "$ALL_DB
SELECT COALESCE(db.name,'?') AS database, COALESCE(x.status,'не запускался НИ РАЗУ') AS status,
       to_char(x.created_at,'YYYY-MM-DD HH24:MI') AS last_run,
       date_trunc('minute', now()-x.created_at)::text AS age,
       $S3_UP AS in_s3, COALESCE(x.size,'—') AS size
FROM scheduled_database_backups b
LEFT JOIN db ON db.id=b.database_id AND db.t=b.database_type
LEFT JOIN LATERAL (SELECT * FROM scheduled_database_backup_executions e
                   WHERE e.scheduled_database_backup_id=b.id
                   ORDER BY e.created_at DESC LIMIT 1) x ON TRUE
ORDER BY x.created_at NULLS FIRST;" | sed 's/|/ | /g'
warn "Свежий success — единственное доказательство, что бэкап живой. Включённое расписание может падать месяцами."

hr "Провалившиеся запуски за последние 14 дней"
q "SELECT to_char(e.created_at,'MM-DD HH24:MI') AS at, e.scheduled_database_backup_id AS backup_id,
         e.status, left(COALESCE(e.message,''),120) AS message
  FROM scheduled_database_backup_executions e
  WHERE e.status <> 'success' AND e.created_at > now() - interval '14 days'
  ORDER BY e.created_at DESC LIMIT 40;" | sed 's/|/ | /g'

hr "Бэкап самой базы Coolify (Settings → Backup)"
q "SELECT b.enabled, b.frequency, b.save_s3 AS to_s3, COALESCE(s.name,'—') AS s3_target
   FROM scheduled_database_backups b
   JOIN standalone_postgresqls d
     ON d.id=b.database_id AND b.database_type='App\\Models\\StandalonePostgresql'
   LEFT JOIN s3_storages s ON s.id=b.s3_storage_id
   WHERE d.name='coolify-db';" | sed 's/|/ | /g'
[[ $(qv "SELECT count(*) FROM scheduled_database_backups b
         JOIN standalone_postgresqls d ON d.id=b.database_id
          AND b.database_type='App\\Models\\StandalonePostgresql'
         WHERE d.name='coolify-db';") == 0 ]] && \
  warn "База Coolify не бэкапится: потеряешь сами описания проектов, домены и переменные окружения."

hr "Тома приложений и сервисов — Coolify их НЕ бэкапит"
q "SELECT v.resource_type AS owner_type, v.name, v.mount_path,
          COALESCE(v.host_path,'(docker volume)') AS host_path
   FROM local_persistent_volumes v ORDER BY 1,2;" | sed 's/|/ | /g'
warn "Всё из этого списка (загрузки, картинки, конфиги) при потере диска не восстановится — нужен отдельный restic/rclone."

hr "Локальные копии бэкапов на диске"
du -sh /data/coolify/backups 2>/dev/null || echo "каталога /data/coolify/backups нет"
find /data/coolify/backups -type f -printf '%TY-%Tm-%Td %10s  %p\n' 2>/dev/null | sort | tail -25

hr "Хостовые бэкапы вне Coolify"
command -v restic borg rclone 2>/dev/null || echo "ни restic, ни borg, ни rclone не установлены"
ls -1 /etc/cron.d /etc/cron.daily 2>/dev/null | grep -iE 'backup|restic|borg|rclone' || echo "cron-заданий с бэкапом не видно"

hr "Место на диске (без него бэкапы падают)"
df -h / /data 2>/dev/null | awk '!seen[$0]++'
