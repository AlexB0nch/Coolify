# Coolify на 95.85.242.143

Разворачивание чистой Ubuntu-VPS в PaaS: SSH-ключи, базовая защита, Coolify.
Дальше новые сайты добавляются в UI за пару минут, TLS и поддомены — автоматом.

## Быстрый старт

Три команды у себя в терминале (macOS / Linux / WSL / Git Bash).
Пароль root спросят **один раз**, в первой команде.

> **Windows:** запускать надо именно в bash, а не в PowerShell — в PowerShell 5.1
> нет ни `&&`, ни перенаправления `< файл`. Набери `bash`, нажми Enter и все
> команды ниже выполняй уже внутри него. Если `ssh` в WSL не найден:
> `sudo apt update && sudo apt install -y openssh-client`.

```bash
git clone https://github.com/AlexB0nch/Coolify.git coolify-setup && cd coolify-setup

# 1. ключи: создать, залить на сервер, прописать алиас `coolify`
bash scripts/01-local-keys.sh

# 2. сервер: обновление, пользователь, swap, firewall, fail2ban, Coolify
ssh coolify 'bash -s' < scripts/02-server-setup.sh
```

Открываешь `http://95.85.242.143:8000`, **сразу** заводишь админа — регистрация
открыта до первого пользователя. Затем, убедившись, что `ssh coolify` пускает
без пароля:

```bash
# 3. закрыть вход по паролю
ssh coolify 'bash -s' < scripts/03-harden-ssh.sh
ssh coolify 'echo вход по ключу работает'   # проверка в новом окне
```

Диагностика в любой момент: `ssh coolify 'bash -s' < scripts/04-status.sh`

## Что делает каждый скрипт

| Скрипт | Где | Что |
|---|---|---|
| `01-local-keys.sh` | твой компьютер | ed25519-ключ `~/.ssh/coolify_ed25519`, заливка на сервер, алиас `coolify` в `~/.ssh/config`, проверка входа |
| `02-server-setup.sh` | сервер, root | apt upgrade, sudo-пользователь `deploy`, swap 2 ГБ при RAM < 4 ГБ, ufw (22/80/443/8000), fail2ban, unattended-upgrades, установка Coolify |
| `03-harden-ssh.sh` | сервер, root | `PasswordAuthentication no`, root — только по ключу |
| `04-status.sh` | сервер | состояние: память, диск, firewall, контейнеры, порты |

Переменные, если нужно отойти от умолчаний:

```bash
SERVER_IP=1.2.3.4 HOST_ALIAS=myserver bash scripts/01-local-keys.sh
ssh coolify 'NEW_USER=admin SWAP_SIZE=4G bash -s' < scripts/02-server-setup.sh
```

## DNS

Одна wildcard-запись закрывает все будущие проекты — новый сайт не требует
никаких действий в DNS:

```
A    coolify.твойдомен.ru   ->  95.85.242.143
A    *.твойдомен.ru         ->  95.85.242.143
A    твойдомен.ru           ->  95.85.242.143
```

После того как DNS разъехался (`dig coolify.твойдомен.ru +short`):
Coolify → **Settings → Instance Domain** → `https://coolify.твойдомен.ru`.
Панель переедет на HTTPS, и порт 8000 можно закрыть:

```bash
ssh coolify 'ufw delete allow 8000/tcp'
```

## Первый проект

1. **Sources** → подключить GitHub (Coolify создаст GitHub App, доступ по репозиториям).
2. **Projects → New → Application** → репозиторий, ветка `main`.
3. Build pack: Dockerfile / Nixpacks (Nixpacks сам определяет Python, Node и т.п.).
4. **Domains**: `проект.твойдомен.ru` — сертификат Let's Encrypt выпустится сам.
5. **Environment Variables** — то, что лежит в `.env`.
6. Deploy. Дальше push в `main` → автодеплой по вебхуку.

Внутренняя БД, если нужна: **New → Database → PostgreSQL**, подключается к
приложению по имени сервиса внутри общей docker-сети — наружу порт не открывать.

### Важно для сервисов с фоновым воркером

Если у приложения есть long polling или воркер уведомлений (например
Telegram-бот), воркер должен жить **строго в одном экземпляре**:

* держать один сервис, без масштабирования реплик;
* в настройках приложения включить **stop before deploy** (сначала гасим
  старый контейнер, потом поднимаем новый), а не rolling update с перекрытием —
  иначе на время деплоя работают два процесса и уведомления уходят дважды;
* healthcheck на такой сервис вешать по внутреннему признаку, а не по HTTP-порту,
  которого у воркера нет.

Веб-часть и воркер лучше развести на два приложения в одном проекте: у веба —
домен и HTTPS, у воркера — только исходящие соединения.

## Что стоит знать про эту конфигурацию

**ufw и Docker.** Docker пишет свои правила в iptables в обход ufw, поэтому
опубликованный наружу порт контейнера (`ports: 8080:8080`) будет доступен из
интернета, даже если ufw его не разрешал. Практический вывод: не публикуй порты
приложений вообще — пусть трафик идёт только через встроенный в Coolify Traefik
по доменам. Базы данных держи без публикации портов.

**root по SSH остаётся включённым (только по ключу).** Это не недосмотр:
Coolify управляет собственным хостом по SSH под root и складывает свой ключ в
`/root/.ssh/authorized_keys`. Полный `PermitRootLogin no` ломает деплой.

**Бэкапы.** В Coolify: **Settings → Backup** — регулярный дамп его собственной
БД, плюс у каждой управляемой базы своя вкладка Backups с расписанием и выгрузкой
в S3. Настрой это до того, как на сервере окажется что-то ценное.

**Ресурсы.** Coolify в покое занимает ~1 ГБ RAM. Сборка образов — самая
прожорливая часть, поэтому скрипт добавляет swap при RAM < 4 ГБ. Для нескольких
лёгких сайтов 4 ГБ комфортно, на 2 ГБ жить можно, но сборки лучше делать не
одновременно.

## Если что-то пошло не так

```bash
ssh coolify 'bash -s' < scripts/04-status.sh          # общая картина
ssh coolify 'docker logs -n 100 coolify'              # логи панели
ssh coolify 'docker ps -a'                            # что упало
ssh coolify 'docker logs -n 100 coolify-proxy'        # Traefik: TLS, роутинг доменов
ssh coolify 'journalctl -u ssh -n 50'                 # проблемы с SSH
```

Сертификат не выпускается — почти всегда DNS ещё не разъехался или домен ведёт
не на этот IP: проверь `dig +short домен` и что порт 80 открыт (Let's Encrypt
ходит по HTTP-01).

Заблокировал себе SSH — заходи через веб-консоль (VNC) хостера и откатывай:
`rm /etc/ssh/sshd_config.d/99-hardening.conf && systemctl restart ssh`.
