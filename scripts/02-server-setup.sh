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

# --- система ---------------------------------------------------------------
say "Обновляю пакеты (это самая долгая часть)"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get upgrade -y -qq
apt-get install -y -qq \
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
cat > /etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled  = true
backend  = systemd
maxretry = 5
findtime = 10m
bantime  = 1h
EOF
systemctl enable --now fail2ban >/dev/null
systemctl restart fail2ban

# --- автообновления безопасности -------------------------------------------
say "Включаю unattended-upgrades"
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF

# --- Coolify ---------------------------------------------------------------
if [[ "$SKIP_COOLIFY" == "1" ]]; then
  warn "SKIP_COOLIFY=1 — установку Coolify пропускаю"
else
  say "Ставлю Coolify (официальный установщик, он же поставит Docker)"
  curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /tmp/coolify-install.sh
  bash /tmp/coolify-install.sh
fi

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
