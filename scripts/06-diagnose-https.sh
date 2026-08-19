#!/usr/bin/env bash
# Шаг 6 (по необходимости). Диагностика «HTTP работает, HTTPS висит».
# Запуск с твоего компьютера:  ssh coolify 'bash -s' < scripts/06-diagnose-https.sh
#
# Ничего не меняет и не перезапускает — только собирает факты:
#   1) слушает ли прокси порты 80 и 443 и кто именно;
#   2) отвечает ли 80/443 с самого сервера (в обход DNS и внешней сети);
#   3) куда указывает DNS доменов, которые прокси обслуживает;
#   4) что за приложение сыплет «port is missing» и чьё оно;
#   5) состояние файрвола и docker-цепочек для 443.
#
# После запуска решение принимается по сводке в конце.

set -u

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
ok()   { printf '\033[1;32m[+] %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }

PROXY_NAME="${PROXY_NAME:-coolify-proxy}"

# --- 1. кто слушает 80 и 443 -------------------------------------------------

say "Кто слушает порты 80 и 443"
ss -ltnp 2>/dev/null | awk 'NR==1 || /:(80|443)[[:space:]]/'
if ! ss -ltn 2>/dev/null | grep -qE ':443[[:space:]]'; then
  warn "443 никто не слушает — это и есть причина таймаута, перезапуск прокси обязателен."
fi

# --- 2. прокси-контейнер ------------------------------------------------------

say "Контейнер ${PROXY_NAME}"
docker ps --filter "name=${PROXY_NAME}" \
  --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'

# --- 3. проверка 80 и 443 с самого сервера ------------------------------------

say "HTTP с самого сервера (мимо DNS и внешней сети)"
code80=$(curl -s -o /dev/null -m 5 -w '%{http_code}' http://127.0.0.1/ || echo FAIL)
echo "  http://127.0.0.1/   -> ${code80}"
code443=$(curl -sk -o /dev/null -m 5 -w '%{http_code}' https://127.0.0.1/ || echo FAIL)
echo "  https://127.0.0.1/  -> ${code443}"
case "$code443" in
  FAIL|000) warn "443 не отвечает даже локально — проблема в прокси, не в сети/файрволе." ;;
  *)        ok  "443 локально отвечает (${code443}) — тогда снаружи мешает сеть/DNS/файрвол, а не Traefik." ;;
esac

# --- 4. домены из меток Traefik и их DNS --------------------------------------

say "Домены, которые прокси обслуживает, и куда указывает их DNS"
MYIP=$(curl -fsS -m 5 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')
echo "  IP этого сервера: ${MYIP}"
docker ps -q | while read -r cid; do
  docker inspect --format '{{range $k, $v := .Config.Labels}}{{$k}}={{$v}}{{"\n"}}{{end}}' "$cid" 2>/dev/null
done | grep -oE 'Host\(`[^`]+`\)' | grep -oE '[a-z0-9.-]+\.[a-z]{2,}' | sort -u | while read -r host; do
  resolved=$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')
  if [[ "$resolved" == "$MYIP" ]]; then
    echo "  ${host} -> ${resolved}  (сюда)"
  else
    warn "${host} -> ${resolved:-не резолвится}  — НЕ на этот сервер! Хендшейк «по домену» шёл не сюда."
  fi
done

# --- 5. кто сыплет «port is missing» ------------------------------------------

say "Ошибки в логе прокси за сегодня (сгруппированы)"
docker logs "$PROXY_NAME" --since 24h 2>&1 | grep -iE 'error|level=error' \
  | sed -E 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[^ ]* //' | sort | uniq -c | sort -rn | head -10

say "Чьи это UUID: контейнеры и их приложения"
docker ps -a --format '{{.Names}}\t{{.Status}}\t{{.Label "coolify.name"}}\t{{.Label "coolify.applicationId"}}' \
  | column -t -s $'\t'
warn "Сравни префикс из ошибок (например s10k4mg…) с именами контейнеров выше:"
warn "имя контейнера в Coolify начинается с UUID приложения."

# --- 6. файрвол и docker-цепочки для 443 --------------------------------------

say "Файрвол"
ufw status 2>/dev/null | grep -E '443|80/' || echo "  ufw неактивен или недоступен"
iptables -L DOCKER -n 2>/dev/null | grep -E '443' || echo "  в цепочке DOCKER правил про 443 нет"

# --- 7. сводка -----------------------------------------------------------------

say "Как читать результат"
cat <<'EOF'
  * 443 не слушается или локально FAIL  -> docker restart coolify-proxy,
    затем прогнать этот скрипт ещё раз.
  * 443 локально отвечает, а снаружи висит -> смотреть DNS выше: если домен
    указывает не на этот сервер, чинить DNS, прокси ни при чём.
  * «port is missing» с UUID твоего же воркера (без домена) -> в панели у этого
    приложения убрать домен/порт из настроек прокси, чтобы прекратить шторм.
EOF
