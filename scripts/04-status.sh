#!/usr/bin/env bash
# Диагностика. Запускается НА СЕРВЕРЕ: ssh coolify 'bash -s' < scripts/04-status.sh
set -uo pipefail

hr() { printf '\n\033[1;36m── %s ─────────────────────────\033[0m\n' "$*"; }

hr "Система";      hostnamectl 2>/dev/null | sed -n '1,6p'; uptime
hr "Память/диск";  free -h; df -h / /var/lib/docker 2>/dev/null | sort -u
hr "Swap";         swapon --show || echo "swap нет"
hr "Firewall";     ufw status verbose 2>/dev/null || echo "ufw не установлен"
hr "fail2ban";     fail2ban-client status sshd 2>/dev/null || echo "не настроен"
hr "SSH-политика"; sshd -T 2>/dev/null | grep -Ei '^(passwordauthentication|permitrootlogin|pubkeyauthentication)'
hr "Docker";       docker --version 2>/dev/null || echo "нет docker"
hr "Контейнеры";   docker ps --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}' 2>/dev/null
hr "Coolify";      docker ps --filter name=coolify --format '{{.Names}}: {{.Status}}' 2>/dev/null
hr "Порты";        ss -tulpn 2>/dev/null | grep -E ':(22|80|443|8000)\b'
hr "Обновления";   apt-get -s upgrade 2>/dev/null | grep -c '^Inst' | xargs -I{} echo "пакетов к обновлению: {}"
