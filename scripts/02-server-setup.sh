#!/usr/bin/env bash
# Шаг 2. Запускается НА СЕРВЕРЕ от root:
#   ssh coolify 'bash -s' < scripts/02-server-setup.sh
# либо scp-нуть файл и выполнить `bash 02-server-setup.sh`.
#
# Что делает:
#   - обновляет систему, ставит базовые пакеты;
#   - создаёт sudo-пользователя и переносит ему твой SSH-ключ;
#   - включает swap, если памяти мало;
#   - настраивает firewall (ufw) и fail2ban;
#   - включает автоматические security-обновления;
#   - ставит Coolify (он сам поставит Docker).
#
# Переменные:
#   NEW_USER=deploy  SKIP_COOLIFY=1  SWAP_SIZE=2G

set -euo pipefail

NEW_USER="${NEW_USER:-deploy}"
SWAP_SIZE="${SWAP_SIZE:-2G}"
SKIP_COOLIFY="${SKIP_COOLIFY:-0}"
COOLIFY_PORT="${COOLIFY_PORT:-8000}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запускать от root."
[[ -r /etc/os-release ]] || die "Не Linux?"
. /etc/os-release
[[ "${ID:-}" == "ubuntu" || "${ID_LIKE:-}" == *debian* ]] || die "Скрипт рассчитан на Ubuntu/Debian, тут: ${PRETTY_NAME:-unknown}"

say "Сервер: ${PRETTY_NAME} / $(uname -m) / RAM $(free -h | awk '/^Mem:/{print $2}') / диск $(df -h --output=avail / | tail -1 | tr -d ' ')"

DISK_FREE_GB=$(df -BG --output=avail / | tail -1 | tr -dc '0-9')
if [[ ${DISK_FREE_GB:-0} -lt 20 ]]; then
  warn "Свободно всего ${DISK_FREE_GB} ГБ. Coolify рекомендует 20 ГБ."
  warn "Установка пройдёт, но образы и сборки заполнят диск быстро — см. раздел"
  warn "про очистку в README, а лучше расширь диск у хостера."
fi

export DEBIAN_FRONTEND=noninteractive

# apt-локи: фоновые обновления Ubuntu (unattended-upgrades, apt-daily) держат
# /var/lib/dpkg/lock-frontend и роняют установщик Docker. Гасим их на время
# работы скрипта и возвращаем в конце.
say "Останавливаю фоновые обновления на время установки"
systemctl stop apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true
systemctl stop unattended-upgrades.service 2>/dev/null || true

wait_for_apt() {
  local i
  for i in $(seq 1 180); do
    if ! pgrep -x apt >/dev/null 2>&1 \
    && ! pgrep -x apt-get >/dev/null 2>&1 \
    && ! pgrep -x dpkg >/dev/null 2>&1 \
    && ! pgrep -x unattended-upgr >/dev/null 2>&1; then
      return 0
    fi
    [[ $((i % 6)) -eq 1 ]] && echo "  жду, пока освободится apt/dpkg..."
    sleep 5
  done
  die "apt/dpkg занят больше 15 минут. Посмотри 'ps aux | grep -E \"apt|dpkg\"' и запусти скрипт снова."
}

APT_OPTS=(-o DPkg::Lock::Timeout=600)

# --- система ---------------------------------------------------------------
say "Обновляю пакеты (это самая долгая часть)"
wait_for_apt
apt-get "${APT_OPTS[@]}" update -qq
apt-get "${APT_OPTS[@]}" upgrade -y -qq
apt-get "${APT_OPTS[@]}" install -y -qq \
  curl wget git jq ca-certificates gnupg \
  ufw fail2ban unattended-upgrades \
  htop tmux rsync

timedatectl set-timezone "${TZ_NAME:-UTC}" || true

# --- пользователь ----------------------------------------------------------
if id "$NEW_USER" >/dev/null 2>&1; then
  say "Пользователь $NEW_USER уже есть"
else
  say "Создаю пользователя $NEW_USER с правами sudo"
  adduser --disabled-password --gecos "" "$NEW_USER"
  usermod -aG sudo "$NEW_USER"
fi

if [[ -s /root/.ssh/authorized_keys ]]; then
  say "Копирую SSH-ключи root -> $NEW_USER"
  install -d -m 700 -o "$NEW_USER" -g "$NEW_USER" "/home/$NEW_USER/.ssh"
  install -m 600 -o "$NEW_USER" -g "$NEW_USER" /root/.ssh/authorized_keys "/home/$NEW_USER/.ssh/authorized_keys"
else
  warn "У root нет authorized_keys — сначала выполни шаг 1 (01-local-keys.sh)."
fi

# sudo без пароля: у пользователя нет пароля вообще (--disabled-password),
# иначе sudo станет невозможен
echo "$NEW_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$NEW_USER"
chmod 440 "/etc/sudoers.d/90-$NEW_USER"

# --- swap ------------------------------------------------------------------
MEM_MB=$(awk '/MemTotal/{print int($2/1024)}' /proc/meminfo)
if [[ $(swapon --show --noheadings | wc -l) -gt 0 ]]; then
  say "Swap уже есть — пропускаю"
elif [[ $MEM_MB -lt 4096 ]]; then
  say "RAM ${MEM_MB}MB — создаю swap $SWAP_SIZE (Coolify собирает образы, памяти может не хватить)"
  fallocate -l "$SWAP_SIZE" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl -w vm.swappiness=10 >/dev/null
  grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
else
  say "RAM ${MEM_MB}MB — swap не нужен"
fi

# --- firewall --------------------------------------------------------------
say "Настраиваю ufw (22, 80, 443, ${COOLIFY_PORT})"
ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw allow 443/udp comment 'HTTP/3' >/dev/null
ufw allow "${COOLIFY_PORT}"/tcp comment 'Coolify UI' >/dev/null
ufw --force enable >/dev/null
ufw status verbose

# --- fail2ban --------------------------------------------------------------
say "Включаю fail2ban для SSH"
# IP, с которого сейчас пришли по SSH, вносим в исключения: иначе одна серия
# неудачных попыток запирает администратора снаружи, и чинить приходится
# через веб-консоль хостера. Можно задать явно: ADMIN_IP=1.2.3.4
ADMIN_IP="${ADMIN_IP:-${SSH_CLIENT%% *}}"
IGNORE_IP="127.0.0.1/8 ::1"
if [[ -n "${ADMIN_IP:-}" ]]; then
  IGNORE_IP="$IGNORE_IP $ADMIN_IP"
  say "  твой IP $ADMIN_IP добавлен в исключения fail2ban"
else
  warn "  не определил твой IP — сможешь забанить сам себя. Задай ADMIN_IP=..."
fi
cat > /etc/fail2ban/jail.d/sshd.local <<EOF
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
ignoreip = ${IGNORE_IP}
EOF
systemctl enable --now fail2ban >/dev/null
systemctl restart fail2ban

# --- Coolify ---------------------------------------------------------------
# Ставится ДО включения автообновлений: установщик Docker внутри ходит в apt,
# а параллельный unattended-upgrade забирает dpkg-лок и валит установку.
if [[ "$SKIP_COOLIFY" == "1" ]]; then
  warn "SKIP_COOLIFY=1 — установку Coolify пропускаю"
else
  # Установщик Coolify по умолчанию отдаёт Docker пул 10.0.0.0/8 — весь
  # приватный диапазон 10.x. Многие хостеры маршрутизируют VPS через адреса
  # оттуда, и тогда docker0 забирает себе IP шлюза, после чего сервер теряет
  # сеть целиком и чинить можно только из VNC-консоли. Выбираем пул, который
  # не пересекается с уже существующими маршрутами и адресами.
  say "Подбираю диапазон адресов для Docker, не конфликтующий с сетью хостера"
  DOCKER_POOL=$(python3 - <<'PY'
import ipaddress, subprocess

used = []
def add(net):
    try: used.append(ipaddress.ip_network(net, strict=False))
    except ValueError: pass

for line in subprocess.run(['ip','-o','route'], capture_output=True, text=True).stdout.splitlines():
    t = line.split()
    if not t: continue
    if t[0] == 'default':
        if 'via' in t: add(t[t.index('via')+1] + '/24')   # подсеть шлюза целиком
    else:
        add(t[0])
for line in subprocess.run(['ip','-o','-4','addr'], capture_output=True, text=True).stdout.splitlines():
    t = line.split()
    if 'inet' in t: add(t[t.index('inet')+1])

used = [u for u in used if u.version == 4]
for cand in ('172.28.0.0/14', '172.16.0.0/14', '192.168.128.0/17', '10.192.0.0/12'):
    c = ipaddress.ip_network(cand)
    if not any(c.overlaps(u) for u in used):
        print(cand); break
PY
)
  [[ -n "$DOCKER_POOL" ]] || die "Не нашёл свободный диапазон для Docker. Разбирайся руками: ip route"
  say "  выбран пул $DOCKER_POOL (по умолчанию установщик взял бы 10.0.0.0/8)"
  export DOCKER_ADDRESS_POOL_BASE="$DOCKER_POOL"
  export DOCKER_ADDRESS_POOL_SIZE=24
  export DOCKER_POOL_FORCE_OVERRIDE=true

  # Установщик проверяет только наличие бинарника docker, а со следующего шага
  # обращается к демону и молча падает, если тот остановлен.
  if command -v docker >/dev/null && ! docker info >/dev/null 2>&1; then
    say "Docker установлен, но демон не запущен — запускаю"
    systemctl start docker
    docker info >/dev/null 2>&1 || die "Демон Docker не поднимается: systemctl status docker"
  fi

  # Установщик перезаписывает /root/.ssh/authorized_keys, добавляя туда свой
  # ключ для управления хостом, и может потерять наш. Сохраняем и вернём.
  AK=/root/.ssh/authorized_keys
  [[ -s "$AK" ]] && cp "$AK" /tmp/authorized_keys.before-coolify

  say "Ставлю Coolify (официальный установщик, он же поставит Docker)"
  wait_for_apt
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/coolify-install.sh

  # Установщик падает с первой же неудачной попытки скачать образ, а обрывы и
  # лимиты Docker Hub — обычное дело. Он идемпотентен, поэтому просто повторяем.
  ok=0
  for attempt in 1 2 3; do
    say "Попытка установки Coolify ${attempt}/3"
    if bash /tmp/coolify-install.sh; then ok=1; break; fi
    warn "Попытка ${attempt} не удалась."
    df -h / | tail -1
    docker system df 2>/dev/null || true
    [[ $attempt -lt 3 ]] && { warn "Повтор через 20 секунд..."; sleep 20; }
  done

  if [[ $ok -ne 1 ]]; then
    echo
    warn "Установщик Coolify не отработал за 3 попытки. Настоящую причину покажет:"
    warn "  docker pull coollabsio/coolify:latest"
    warn "Чаще всего это: кончилось место на диске (df -h /) либо лимит"
    warn "анонимных загрузок Docker Hub (тогда помогает 'docker login')."
    die "Останавливаюсь."
  fi
  command -v docker >/dev/null || die "Docker так и не установился — перезапусти скрипт."

  # Возвращаем ключи, которые мог потерять установщик
  if [[ -f /tmp/authorized_keys.before-coolify ]]; then
    restored=0
    while read -r key; do
      [[ -z "$key" ]] && continue
      grep -qxF "$key" "$AK" 2>/dev/null || { echo "$key" >> "$AK"; restored=1; }
    done < /tmp/authorized_keys.before-coolify
    [[ $restored -eq 1 ]] && say "Вернул SSH-ключи, потерянные установщиком Coolify"
    chmod 600 "$AK"
  fi

  # Проверяем, что сеть жива: если Docker всё-таки перехватил маршрут, сервер
  # станет недоступен снаружи, и починить можно будет только из VNC-консоли.
  say "Проверяю сетевую связность после установки Docker"
  if ping -c 2 -W 3 1.1.1.1 >/dev/null 2>&1 || ping -c 2 -W 3 8.8.8.8 >/dev/null 2>&1; then
    say "  сеть в порядке"
  else
    warn "СЕРВЕР ПОТЕРЯЛ СЕТЬ. Почти наверняка мост Docker занял подсеть шлюза."
    warn "Маршруты сейчас:"; ip route
    warn "Чинить из VNC-консоли хостера:"
    warn "  systemctl stop docker docker.socket"
    warn "  ip link del docker0"
    warn "  ip link del \$(ip -br link | awk '/^br-/{print \$1}')"
    die "Останавливаюсь, пока не сделал хуже."
  fi
fi

# --- автообновления безопасности -------------------------------------------
say "Включаю unattended-upgrades и фоновые apt-таймеры"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
systemctl start apt-daily.timer apt-daily-upgrade.timer 2>/dev/null || true

# --- еженедельная чистка Docker --------------------------------------------
# На маленьком диске мусор от сборок съедает место за считанные недели.
say "Ставлю еженедельную очистку неиспользуемых образов Docker"
cat > /etc/cron.weekly/docker-prune <<'EOF'
#!/bin/sh
# Удаляет образы/слои, не связанные ни с одним контейнером.
# Тома (данные баз) НЕ трогает.
docker image prune -af --filter 'until=168h' >/dev/null 2>&1
docker builder prune -af --filter 'until=168h' >/dev/null 2>&1
EOF
chmod +x /etc/cron.weekly/docker-prune

IP=$(curl -fsS --max-time 10 https://api.ipify.org 2>/dev/null || hostname -I | awk '{print $1}')

cat <<EOF

============================================================
Сервер готов.

  Панель Coolify:  http://${IP}:${COOLIFY_PORT}
  Открой её ПРЯМО СЕЙЧАС и заведи админа — регистрация открыта
  до первого созданного пользователя.

  Вход по SSH:     ssh ${NEW_USER}@${IP}   (или ssh coolify)

Дальше:
  1) создай админа в панели;
  2) наведи DNS: A-запись @ и *.домен -> ${IP};
  3) в Coolify: Settings -> Instance Domain -> coolify.твойдомен
     (получишь HTTPS на саму панель, после этого порт ${COOLIFY_PORT} можно закрыть:
      ufw delete allow ${COOLIFY_PORT}/tcp);
  4) закрой парольный вход: bash 03-harden-ssh.sh
============================================================
EOF
