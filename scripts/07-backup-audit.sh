#!/usr/bin/env bash
# Аудит бэкапов. Запускается НА СЕРВЕРЕ:
#   ssh coolify 'bash -s' < scripts/07-backup-audit.sh
#
# Ничего не меняет — только читает. Отвечает на вопросы:
#   1) какие S3-хранилища заведены и рабочие ли они;
#   2) у каких баз есть расписание бэкапа, а у каких нет вообще;
#   3) какие бэкапы уходят в S3, а какие лежат только на этом же диске;
#   4) когда последний раз бэкап реально отработал и чем закончился;
#   5) что НЕ покрыто бэкапами — тома приложений и сервисов;
#   6) бэкапится ли сама база Coolify.
set -uo pipefail

hr() { printf '\n\033[1;36m── %s ─────────────────────────\033[0m\n' "$*"; }
warn() { printf '\033[1;33m%s\033[0m\n' "$*"; }

ENV_FILE=/data/coolify/source/.env
[[ -r $ENV_FILE ]] || { echo "не найден $ENV_FILE — это точно хост Coolify?"; exit 1; }
DB_PASSWORD=$(grep -E '^DB_PASSWORD=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"'"'"'')
DB_USER=$(grep -E '^DB_USERNAME=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"'"'"'')
DB_NAME=$(grep -E '^DB_DATABASE=' "$ENV_FILE" | head -1 | cut -d= -f2- | tr -d '"'"'"'')
DB_USER=${DB_USER:-coolify}; DB_NAME=${DB_NAME:-coolify}

q() { docker exec -e PGPASSWORD="$DB_PASSWORD" -i coolify-db \
        psql -U "$DB_USER" -d "$DB_NAME" -X -q --no-align --pset=footer=off -c "$1" 2>&1; }

# Все типы управляемых баз в одну витрину: id, morph-класс, имя, проект/окружение.
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
q "SELECT id, name, bucket, endpoint, region, COALESCE(is_usable::text,'?') AS usable FROM s3_storages ORDER BY id;" \
  | sed 's/|/ | /g'
[[ $(q "SELECT count(*) FROM s3_storages;") == 0 ]] && warn "S3-хранилищ нет вообще — выгружать бэкапы некуда."

hr "Проекты и ресурсы (всё, что вообще есть)"
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
WHERE NOT EXISTS (
  SELECT 1 FROM scheduled_database_backups b
  WHERE b.database_id=db.id AND b.database_type=db.t
) ORDER BY 1,2,3;" | sed 's/|/ | /g'

hr "Расписания бэкапов: включено? уходит в S3? куда?"
q "$ALL_DB
SELECT COALESCE(db.project,'—') AS project, COALESCE(db.name,'(база Coolify?)') AS database,
       b.enabled, b.frequency, b.save_s3 AS to_s3,
       COALESCE(s.name,'— только локально') AS s3_target,
       b.number_of_backups_locally AS keep_local
FROM scheduled_database_backups b
LEFT JOIN db ON db.id=b.database_id AND db.t=b.database_type
LEFT JOIN s3_storages s ON s.id=b.s3_storage_id
ORDER BY 1,2;" | sed 's/|/ | /g'

hr "Расписания, которые выключены или НЕ выгружаются в S3"
q "$ALL_DB
SELECT COALESCE(db.project,'—') AS project, COALESCE(db.name,'?') AS database,
       b.enabled, b.save_s3 AS to_s3, COALESCE(s.name,'нет') AS s3_target
FROM scheduled_database_backups b
LEFT JOIN db ON db.id=b.database_id AND db.t=b.database_type
LEFT JOIN s3_storages s ON s.id=b.s3_storage_id
WHERE b.enabled IS NOT TRUE OR b.save_s3 IS NOT TRUE OR b.s3_storage_id IS NULL
ORDER BY 1,2;" | sed 's/|/ | /g'

hr "Последний запуск каждого бэкапа (статус и возраст)"
q "$ALL_DB
SELECT COALESCE(db.name,'(база Coolify?)') AS database, x.status,
       to_char(x.created_at,'YYYY-MM-DD HH24:MI') AS last_run,
       date_trunc('minute', now()-x.created_at)::text AS age,
       COALESCE(x.size::text,'—') AS bytes
FROM scheduled_database_backups b
LEFT JOIN db ON db.id=b.database_id AND db.t=b.database_type
LEFT JOIN LATERAL (
  SELECT * FROM scheduled_database_backup_executions e
  WHERE e.scheduled_database_backup_id=b.id ORDER BY e.created_at DESC LIMIT 1
) x ON TRUE
ORDER BY x.created_at NULLS FIRST;" | sed 's/|/ | /g'

hr "Провалившиеся запуски за последние 14 дней"
q "SELECT to_char(e.created_at,'MM-DD HH24:MI') AS at, e.scheduled_database_backup_id AS backup_id,
         e.status, left(COALESCE(e.message,''),120) AS message
  FROM scheduled_database_backup_executions e
  WHERE e.status <> 'success' AND e.created_at > now() - interval '14 days'
  ORDER BY e.created_at DESC LIMIT 40;" | sed 's/|/ | /g'

hr "Тома приложений и сервисов — Coolify их НЕ бэкапит"
q "SELECT v.resource_type AS owner_type, v.name, v.mount_path, COALESCE(v.host_path,'(docker volume)') AS host_path
   FROM local_persistent_volumes v ORDER BY 1,2;" | sed 's/|/ | /g'
warn "Всё из этого списка (загрузки, картинки, конфиги) при потере диска не восстановится."

hr "Бэкап самой базы Coolify (Settings → Backup)"
q "SELECT b.id, b.enabled, b.frequency, b.save_s3, COALESCE(s.name,'—') AS s3_target
   FROM scheduled_database_backups b LEFT JOIN s3_storages s ON s.id=b.s3_storage_id
   WHERE b.database_type='App\\Models\\StandalonePostgresql'
     AND b.database_id NOT IN (SELECT id FROM standalone_postgresqls);" | sed 's/|/ | /g'

hr "Локальные копии бэкапов на диске"
du -sh /data/coolify/backups 2>/dev/null || echo "каталога /data/coolify/backups нет"
find /data/coolify/backups -type f -printf '%TY-%Tm-%Td %10s  %p\n' 2>/dev/null | sort | tail -25

hr "Хостовые бэкапы вне Coolify (restic/borg/rclone/cron)"
command -v restic borg rclone 2>/dev/null || echo "ни restic, ни borg, ни rclone не установлены"
ls -1 /etc/cron.d /etc/cron.daily 2>/dev/null | grep -iE 'backup|restic|borg|rclone' || echo "cron-заданий с бэкапом не видно"

hr "Место на диске (бэкапы упадут, если его нет)"
df -h / /data 2>/dev/null | sort -u
