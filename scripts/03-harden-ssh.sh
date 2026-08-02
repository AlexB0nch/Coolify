#!/usr/bin/env bash
# Шаг 3. Запускается НА СЕРВЕРЕ от root, ПОСЛЕ того как ты убедился,
# что вход по ключу работает (`ssh coolify` пускает без пароля).
#
# Отключает вход по паролю. Root остаётся доступен ТОЛЬКО по ключу
# (prohibit-password) — полностью запрещать root нельзя: Coolify
# управляет собственным хостом по SSH под root.
#
# ВАЖНО: не закрывай текущую SSH-сессию, пока не проверишь вход в новом окне.

set -euo pipefail

say()  { printf '\n\033[1;36m==> %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m[x] %s\033[0m\n' "$*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Запускать от root."

[[ -s /root/.ssh/authorized_keys ]] || \
  die "В /root/.ssh/authorized_keys пусто. Отключать пароль нельзя — потеряешь доступ."

say "Найдено ключей у root: $(grep -c '^ssh-' /root/.ssh/authorized_keys || true)"

CONF=/etc/ssh/sshd_config.d/99-hardening.conf
say "Пишу $CONF"
cat > "$CONF" <<'EOF'
# Управляется скриптом 03-harden-ssh.sh
PubkeyAuthentication yes
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PermitRootLogin prohibit-password
PermitEmptyPasswords no
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
EOF

# в некоторых образах пароль включён напрямую в основном конфиге и
# перебивает drop-in по принципу "первое значение выигрывает"
sed -i -E 's/^[[:space:]]*(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)[[:space:]]/#&/I' \
  /etc/ssh/sshd_config
# то же самое в облачных drop-in'ах провайдера
for f in /etc/ssh/sshd_config.d/*.conf; do
  [[ "$f" == "$CONF" ]] && continue
  [[ -f "$f" ]] || continue
  sed -i -E 's/^[[:space:]]*(PasswordAuthentication|PermitRootLogin|KbdInteractiveAuthentication)[[:space:]]/#&/I' "$f"
done

say "Проверяю конфиг"
sshd -t || die "sshd_config сломан — ничего не перезапускаю, поправь и запусти снова."

say "Действующие настройки после изменений:"
sshd -T | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication|kbdinteractiveauthentication)'

systemctl restart ssh 2>/dev/null || systemctl restart sshd
say "SSH перезапущен. Открой НОВОЕ окно терминала и проверь: ssh coolify"
echo "Если новый вход работает — эту сессию можно закрывать."
