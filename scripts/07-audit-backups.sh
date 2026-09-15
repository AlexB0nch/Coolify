#!/usr/bin/env bash
# Шаг 7 (по необходимости). Аудит бэкапов: что бэкапится, куда и когда в последний раз.
# Запуск с твоего компьютера:  ssh coolify 'bash -s' < scripts/07-audit-backups.sh
#
# Ничего не меняет и не перезапускает — только читает собственную базу Coolify:
#   1) какие S3-хранилища заведены и помечены рабочими;
#   2) все базы данных по проектам: есть ли задание бэкапа, включено ли оно,
#      уходит ли копия в S3, чем закончился последний запуск;
#   3) все задания целиком, включая бэкап самой БД Coolify (Settings → Backup);
#   4) постоянные тома приложений и сервисов — бэкап баз их НЕ покрывает;
#   5) сводка: что именно сейчас не бэкапится и что чинить в первую очередь.
#
# Код выхода: 0 — дыр не найдено, 1 — есть что чинить.

set -u

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
bad()  { printf '\033[1;31m[-] %s\033[0m\n' "$*"; }

# Счётчики для итоговой сводки
NO_JOB=0        # база вообще без задания бэкапа
JOB_OFF=0       # задание есть, но выключено
NO_S3=0         # бэкап только на диск сервера, в S3 не уходит
LAST_FAIL=0     # последний запуск завершился неуспешно
NEVER_RUN=0     # задание включено, но не отработало ни разу
STALE=0         # последняя успешная копия старше 48 часов
PROBLEMS=()     # человекочитаемый список проблем

note() { PROBLEMS+=("$*"); }

# --- 0. добираемся до базы Coolify -------------------------------------------

command -v docker >/dev/null 2>&1 || { bad "docker не найден — это точно сервер с Coolify?"; exit 1; }

DB_CONT=$(docker ps --format '{{.Names}}' | grep -x 'coolify-db' || true)
[ -z "$DB_CONT" ] && DB_CONT=$(docker ps --format '{{.Names}}' | grep -E 'coolify.*(db|postgres)' | head -1 || true)
if [ -z "$DB_CONT" ]; then
  bad "Контейнер с базой Coolify не найден. Запущенные контейнеры:"
  docker ps --format '  {{.Names}}\t{{.Status}}'
  exit 1
fi

PGUSER=$(docker exec "$DB_CONT" printenv POSTGRES_USER 2>/dev/null || echo coolify)
PGDB=$(docker exec "$DB_CONT" printenv POSTGRES_DB 2>/dev/null || echo coolify)

# Одна точка входа в psql: без заголовков, поля через |
q() { docker exec -i "$DB_CONT" psql -U "$PGUSER" -d "$PGDB" -At -F '|' -c "$1" 2>/dev/null; }

if ! q 'select 1' | grep -q 1; then
  bad "Не читается база Coolify в контейнере ${DB_CONT} (user=${PGUSER}, db=${PGDB})."
  exit 1
fi

has_table() { [ -n "$(q "select 1 from information_schema.tables where table_schema='public' and table_name='$1'")" ]; }
has_col()   { [ -n "$(q "select 1 from information_schema.columns where table_schema='public' and table_name='$1' and column_name='$2'")" ]; }

echo "База Coolify: контейнер ${DB_CONT}, db=${PGDB}"

# --- 1. S3-хранилища ----------------------------------------------------------

say "S3-хранилища (Settings → S3 Storages)"
S3_COUNT=$(q "select count(*) from s3_storages")
if [ "${S3_COUNT:-0}" = "0" ]; then
  bad "Не заведено ни одного S3-хранилища — выгружать копии некуда."
  note "Завести S3-хранилище: Settings → S3 Storages → Add."
else
  q "select id, coalesce(name,'—'), coalesce(endpoint,'—'), coalesce(bucket,'—'),
            case when coalesce(is_usable,true) then 'рабочее' else 'ПОМЕЧЕНО НЕРАБОЧИМ' end
     from s3_storages order by id" |
  while IFS='|' read -r id name endpoint bucket usable; do
    printf '  #%-3s %-24s %-40s bucket=%-20s %s\n' "$id" "$name" "$endpoint" "$bucket" "$usable"
  done
  # is_usable проверяем отдельно, чтобы поднять флаг в сводке
  BROKEN_S3=$(q "select count(*) from s3_storages where coalesce(is_usable,true) = false")
  if [ "${BROKEN_S3:-0}" != "0" ]; then
    bad "Хранилищ, помеченных нерабочими: ${BROKEN_S3} — Coolify не сможет туда выгрузить."
    note "Починить доступ к S3 (${BROKEN_S3} шт.): ключи, endpoint, права на bucket."
  fi
fi

# --- 2. базы данных по проектам ----------------------------------------------

say "Базы данных по проектам: покрытие бэкапом"
printf '  %-18s %-12s %-22s %-12s %s\n' ПРОЕКТ ОКРУЖЕНИЕ БАЗА ТИП СОСТОЯНИЕ
printf '  %s\n' "------------------------------------------------------------------------------------"

DB_TABLES=$(q "select table_name from information_schema.tables
               where table_schema='public' and table_name like 'standalone!_%' escape '!'
               order by table_name")

TOTAL_DBS=0

for tbl in $DB_TABLES; do
  has_col "$tbl" environment_id || continue          # не ресурсная таблица — пропускаем
  # sfx — то, по чему ищется класс в scheduled_database_backups.database_type
  # (standalone_postgresqls -> postgresql, standalone_dragonflies -> dragonfl),
  # disp — человеческое имя типа для таблицы на экране.
  sfx=$(printf '%s' "${tbl#standalone_}" | sed -e 's/ies$//' -e 's/s$//')
  case "${tbl#standalone_}" in
    postgresqls) disp=postgresql ;; mysqls)      disp=mysql ;;
    mariadbs)    disp=mariadb    ;; mongodbs)    disp=mongodb ;;
    redis)       disp=redis      ;; keydbs)      disp=keydb ;;
    dragonflies) disp=dragonfly  ;; clickhouses) disp=clickhouse ;;
    *)           disp="${tbl#standalone_}" ;;
  esac
  del=""
  has_col "$tbl" deleted_at && del="where d.deleted_at is null"

  rows=$(q "
    select coalesce(p.name,'—'),
           coalesce(e.name,'—'),
           coalesce(nullif(d.name,''), d.uuid),
           '${disp}',
           coalesce(b.id::text,''),
           coalesce(b.enabled::text,''),
           coalesce(nullif(b.frequency,''),'—'),
           coalesce(b.save_s3::text,''),
           coalesce(s.name,''),
           coalesce(x.status,''),
           coalesce(to_char(x.created_at,'YYYY-MM-DD HH24:MI'),''),
           coalesce((extract(epoch from (now()-x.created_at))/3600)::bigint::text,'')
    from ${tbl} d
    left join environments e on e.id = d.environment_id
    left join projects p on p.id = e.project_id
    left join scheduled_database_backups b
           on b.database_id = d.id and lower(b.database_type) like '%${sfx}%'
    left join s3_storages s on s.id = b.s3_storage_id
    left join lateral (
      select status, created_at from scheduled_database_backup_executions
      where scheduled_database_backup_id = b.id order by created_at desc limit 1
    ) x on true
    ${del}
    order by 1,2,3")

  [ -z "$rows" ] && continue

  while IFS='|' read -r proj env name type jid enabled freq saves3 s3name status when hours; do
    [ -z "$name" ] && continue
    TOTAL_DBS=$((TOTAL_DBS+1))
    where="${proj} / ${env} / ${name}"

    if [ -z "$jid" ]; then
      state=$(printf '\033[1;31mБЭКАПА НЕТ\033[0m')
      NO_JOB=$((NO_JOB+1)); note "Нет задания бэкапа: ${where} (${type})"
    elif [ "$enabled" != "t" ]; then
      state=$(printf '\033[1;31mзадание ВЫКЛЮЧЕНО\033[0m (%s)' "$freq")
      JOB_OFF=$((JOB_OFF+1)); note "Задание бэкапа выключено: ${where}"
    else
      if [ "$saves3" = "t" ] && [ -n "$s3name" ]; then
        dest="S3:${s3name}"
      elif [ "$saves3" = "t" ]; then
        dest=$(printf '\033[1;31mS3 включён, но хранилище не выбрано\033[0m')
        NO_S3=$((NO_S3+1)); note "Бэкап включён, но S3-хранилище не выбрано: ${where}"
      else
        dest=$(printf '\033[1;31mтолько локально\033[0m')
        NO_S3=$((NO_S3+1)); note "Копии не уходят в S3, лежат на том же сервере: ${where}"
      fi

      case "$status" in
        "")        run=$(printf '\033[1;33mни разу не запускалось\033[0m')
                   NEVER_RUN=$((NEVER_RUN+1)); note "Задание есть, но не отработало ни разу: ${where}" ;;
        success)   if [ -n "$hours" ] && [ "$hours" -gt 48 ] 2>/dev/null; then
                     run=$(printf '\033[1;31mпоследняя копия %s (%s ч назад)\033[0m' "$when" "$hours")
                     STALE=$((STALE+1)); note "Свежих копий нет более 48 часов: ${where} (последняя ${when})"
                   else
                     run="ок ${when}"
                   fi ;;
        *)         run=$(printf '\033[1;31mпоследний запуск: %s (%s)\033[0m' "$status" "$when")
                   LAST_FAIL=$((LAST_FAIL+1)); note "Последний бэкап завершился неуспешно (${status}): ${where}" ;;
      esac
      state="${freq} -> ${dest}; ${run}"
    fi

    printf '  %-18.18s %-12.12s %-22.22s %-12.12s %b\n' "$proj" "$env" "$name" "$type" "$state"
  done <<< "$rows"
done

[ "$TOTAL_DBS" = "0" ] && warn "Управляемых баз данных в Coolify не найдено."

# --- 3. все задания бэкапа, включая саму БД Coolify ---------------------------

say "Все задания бэкапа целиком (сюда же попадает Settings → Backup самого Coolify)"
q "select b.id,
          case when b.enabled then 'вкл' else 'ВЫКЛ' end,
          coalesce(nullif(b.frequency,''),'—'),
          case when coalesce(b.save_s3,false) then coalesce(s.name,'S3 без хранилища') else 'локально' end,
          coalesce(b.database_type,'—'),
          coalesce(b.database_id::text,'—'),
          coalesce(x.status,'не запускалось'),
          coalesce(to_char(x.created_at,'YYYY-MM-DD HH24:MI'),'—')
   from scheduled_database_backups b
   left join s3_storages s on s.id = b.s3_storage_id
   left join lateral (
     select status, created_at from scheduled_database_backup_executions
     where scheduled_database_backup_id = b.id order by created_at desc limit 1
   ) x on true
   order by b.id" |
while IFS='|' read -r id en freq dest dtype did status when; do
  printf '  #%-3s %-4s %-14s %-22s %-34s id=%-4s %s %s\n' \
         "$id" "$en" "$freq" "$dest" "${dtype##*\\}" "$did" "$status" "$when"
done

FAILS7=$(q "select count(*) from scheduled_database_backup_executions
            where lower(coalesce(status,'')) <> 'success' and created_at > now() - interval '7 days'")
if [ "${FAILS7:-0}" != "0" ]; then
  warn "Неуспешных запусков за последние 7 дней: ${FAILS7}"
  q "select coalesce(to_char(created_at,'YYYY-MM-DD HH24:MI'),'—'), scheduled_database_backup_id,
            coalesce(status,'—'), left(coalesce(message,''),90)
     from scheduled_database_backup_executions
     where lower(coalesce(status,'')) <> 'success' and created_at > now() - interval '7 days'
     order by created_at desc limit 15" |
  while IFS='|' read -r when jid status msg; do
    printf '    %s  задание #%-4s %-10s %s\n' "$when" "$jid" "$status" "$msg"
  done
fi

# --- 4. постоянные тома: бэкап баз их не покрывает ----------------------------

say "Постоянные тома приложений и сервисов (бэкап баз их НЕ покрывает)"
if has_table local_persistent_volumes; then
  VOLS=$(q "select count(*) from local_persistent_volumes")
  if [ "${VOLS:-0}" = "0" ]; then
    ok "Постоянных томов нет — терять вне баз нечего."
  else
    q "select coalesce(resource_type,'—'), coalesce(name,'—'), coalesce(mount_path,'—')
       from local_persistent_volumes order by 1,2" |
    while IFS='|' read -r rtype name mount; do
      printf '  %-28s %-34s %s\n' "${rtype##*\\}" "$name" "$mount"
    done
    warn "Томов: ${VOLS}. Загруженные файлы, конфиги и данные неуправляемых БД внутри
      них не попадают ни в один дамп выше — для них нужен отдельный бэкап
      (например, cron с rclone/restic на тот же S3)."
    note "Постоянные тома (${VOLS} шт.) не бэкапятся вообще — нужен отдельный процесс."
  fi
else
  warn "Таблицы local_persistent_volumes нет — версия Coolify другая, проверь тома руками."
fi

# --- 5. сводка ----------------------------------------------------------------

say "Сводка"
printf '  баз данных всего:              %s\n' "$TOTAL_DBS"
printf '  без задания бэкапа:            %s\n' "$NO_JOB"
printf '  задание выключено:             %s\n' "$JOB_OFF"
printf '  копии не уходят в S3:          %s\n' "$NO_S3"
printf '  ни разу не отрабатывало:       %s\n' "$NEVER_RUN"
printf '  последний запуск с ошибкой:    %s\n' "$LAST_FAIL"
printf '  свежей копии нет > 48 часов:   %s\n' "$STALE"

if [ "${#PROBLEMS[@]}" -eq 0 ]; then
  echo
  ok "Дыр не найдено: у каждой базы есть включённое задание, копии уходят в S3 и свежие."
  exit 0
fi

echo
bad "Что чинить (${#PROBLEMS[@]}):"
for p in "${PROBLEMS[@]}"; do echo "    • $p"; done
echo
echo "  Где чинить в панели:"
echo "    база -> вкладка Backups -> Add / Enable, частота, Save to S3 + выбрать хранилище;"
echo "    сама БД Coolify -> Settings -> Backup;"
echo "    хранилища -> Settings -> S3 Storages."
echo
echo "  Проверка, что копии реально долетели (а не только задание зелёное):"
echo "    посмотреть объекты в bucket за последние сутки — нулевой размер файла"
echo "    означает, что дамп упал, а статус мог остаться success."
exit 1
