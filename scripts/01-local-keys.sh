#!/usr/bin/env bash
# Шаг 1. Запускается НА ТВОЁМ КОМПЬЮТЕРЕ (macOS / Linux / WSL / Git Bash).
#
# Что делает:
#   1) создаёт отдельный SSH-ключ для этого сервера;
#   2) заливает публичную часть на сервер (вот здесь ты один раз введёшь пароль root);
#   3) прописывает алиас в ~/.ssh/config, чтобы дальше ходить просто `ssh coolify`;
#   4) проверяет, что вход по ключу работает.
#
# Использование:
#   bash scripts/01-local-keys.sh
#   SERVER_IP=1.2.3.4 SSH_USER=root bash scripts/01-local-keys.sh

set -euo pipefail

SERVER_IP="${SERVER_IP:-95.85.242.143}"
SSH_USER="${SSH_USER:-root}"
SSH_PORT="${SSH_PORT:-22}"
HOST_ALIAS="${HOST_ALIAS:-coolify}"
KEY_PATH="${KEY_PATH:-$HOME/.ssh/coolify_ed25519}"

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[1;33m[!] %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

command -v ssh >/dev/null || die "нет ssh. На Windows запусти это в WSL или Git Bash."
command -v ssh-keygen >/dev/null || die "нет ssh-keygen."

mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"

# --- 1. ключ ---------------------------------------------------------------
if [[ -f "$KEY_PATH" ]]; then
  say "Ключ $KEY_PATH уже есть — использую его."
else
  say "Создаю SSH-ключ $KEY_PATH"
  echo "Можно задать парольную фразу (безопаснее) или просто нажать Enter дважды."
  ssh-keygen -t ed25519 -a 100 -f "$KEY_PATH" -C "coolify@${SERVER_IP}"
fi
chmod 600 "$KEY_PATH"

# --- 2. заливаем ключ на сервер --------------------------------------------
say "Заливаю публичный ключ на ${SSH_USER}@${SERVER_IP} — сейчас будет запрошен ПАРОЛЬ сервера"
if command -v ssh-copy-id >/dev/null 2>&1; then
  ssh-copy-id -i "${KEY_PATH}.pub" -p "$SSH_PORT" "${SSH_USER}@${SERVER_IP}"
else
  # ssh-copy-id может отсутствовать (например, в Git Bash) — делаем то же руками
  ssh -p "$SSH_PORT" "${SSH_USER}@${SERVER_IP}" \
    "umask 077; mkdir -p ~/.ssh; touch ~/.ssh/authorized_keys; \
     grep -qxF '$(cat "${KEY_PATH}.pub")' ~/.ssh/authorized_keys || echo '$(cat "${KEY_PATH}.pub")' >> ~/.ssh/authorized_keys"
fi

# --- 3. ~/.ssh/config ------------------------------------------------------
CONFIG="$HOME/.ssh/config"
touch "$CONFIG"; chmod 600 "$CONFIG"
if grep -qE "^Host[[:space:]]+${HOST_ALIAS}\$" "$CONFIG"; then
  warn "В ~/.ssh/config уже есть запись 'Host ${HOST_ALIAS}' — оставляю как есть."
else
  say "Добавляю алиас '${HOST_ALIAS}' в ~/.ssh/config"
  cat >> "$CONFIG" <<EOF

Host ${HOST_ALIAS}
    HostName ${SERVER_IP}
    User ${SSH_USER}
    Port ${SSH_PORT}
    IdentityFile ${KEY_PATH}
    IdentitiesOnly yes
    ServerAliveInterval 30
EOF
fi

# --- 4. проверка -----------------------------------------------------------
say "Проверяю вход по ключу (пароль спрашивать не должен)"
if ssh -o BatchMode=yes -o StrictHostKeyChecking=accept-new "${HOST_ALIAS}" 'echo OK; hostnamectl 2>/dev/null | head -3; free -h | head -2'; then
  say "Готово. Дальше: ssh ${HOST_ALIAS}"
  echo "Скопировать скрипт установки на сервер:"
  echo "  scp scripts/02-server-setup.sh ${HOST_ALIAS}:/root/"
  echo "  ssh ${HOST_ALIAS} 'bash /root/02-server-setup.sh'"
else
  die "Вход по ключу не сработал. Проверь пароль/IP и запусти скрипт ещё раз."
fi
