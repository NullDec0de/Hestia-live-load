# HestiaCP Live Load

**English** · [Русский](#русский)

Live terminal dashboard for **Ubuntu + HestiaCP** servers. See which account, domain, or database is stressing the server **right now** — CPU, RAM, HTTP requests, errors, and active MySQL/MariaDB queries.

Inspired by `htop`, but grouped by Hestia users and sites instead of raw processes.

## Features

- Per-account and per-domain CPU, memory, and process count
- HTTP load from nginx/apache domain access logs (requests per interval, 4xx/5xx)
- Active MySQL/MariaDB queries with approximate per-site SQL CPU share
- Per-core CPU meters, memory/swap bars, load average, disk usage
- Safe screen updates (diff render) — no flicker, no alternate-screen quirks
- **Bilingual UI:** `--ru` (default) and `--en`
- Optional hotkeys for sort, SQL panel, details, rescan

## Requirements

- Ubuntu (or compatible Linux) with [HestiaCP](https://hestiacp.com/)
- bash 4+
- `ps`, `/proc`, nginx or apache domain logs under `/var/log/*/domains/`
- `mysql` or `mariadb` client (reads credentials from `/usr/local/hestia/conf/mysql.conf`)
- **Recommended:** run as `root` / `sudo` for full `/proc`, logs, and MySQL visibility

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/NullDec0de/hestia-live-load/main/hestia-live-load.sh -o /usr/local/bin/hestia-live-load
chmod +x /usr/local/bin/hestia-live-load
```

Or clone this repository and run the script directly.

## Usage

```bash
sudo hestia-live-load.sh
sudo hestia-live-load.sh --en
sudo hestia-live-load.sh -i 1 -n 25
sudo hestia-live-load.sh --no-system --compact
```

### Options

| Option | Description |
|--------|-------------|
| `-i`, `--interval SEC` | Refresh interval in seconds (default: `2`) |
| `-n`, `--limit NUM` | Number of table rows (default: `14`) |
| `--ru` | Russian UI (default) |
| `--en` | English UI |
| `--no-color` | Disable colors |
| `--no-system` | Hide shared mysql/nginx/apache rows |
| `--no-sql` | Hide active MySQL query block |
| `--compact` | Hide detail lines under each row |
| `--classic` | Full screen redraw instead of diff render |
| `--keys` | Enable hotkeys `q/s/d/v/r/+/-` (default: off; use Ctrl+C to exit) |
| `-h`, `--help` | Show help |

### Hotkeys (with `--keys`)

| Key | Action |
|-----|--------|
| `q` | Quit |
| `s` | Cycle sort: score → cpu → sql → req → mem |
| `d` | Toggle SQL query block |
| `v` | Toggle row details |
| `r` | Rescan domains and DB map |
| `+` / `-` | More / fewer rows |

## How attribution works

1. **Processes** — matched via `/home/user/web/domain` paths, PHP-FPM pools, cwd, and Hestia user names.
2. **HTTP** — new lines in `/var/log/nginx/domains/*.log` and `/var/log/apache2/domains/*.log`.
3. **MySQL** — `INFORMATION_SCHEMA.PROCESSLIST`, mapped to sites via `wp-config.php`, `.env`, and other common CMS configs under `public_html`.
4. **SQL≈** — approximate share of `mariadbd` CPU attributed to each site by active query time.

The `mysql|database` row is the shared MariaDB daemon; use **SQL≈**, **SQL**, and the active-query table for per-site database load.

## License

MIT — see [LICENSE](LICENSE).

---

## Русский

[English](#hestiacp-live-load) · **Русский**

Живой терминальный дашборд для серверов **Ubuntu + HestiaCP**. Показывает, какой аккаунт, домен или база данных нагружает сервер **прямо сейчас** — CPU, RAM, HTTP-запросы, ошибки и активные запросы MySQL/MariaDB.

По духу похож на `htop`, но группирует нагрузку по пользователям и сайтам Hestia, а не по сырым процессам.

### Возможности

- CPU, память и число процессов по аккаунтам и доменам
- HTTP-нагрузка из access-log nginx/apache по доменам (запросы за интервал, 4xx/5xx)
- Активные запросы MySQL/MariaDB и примерная доля SQL CPU по сайтам
- Шкалы CPU по ядрам, память/swap, load average, занятость диска
- Безопасное обновление экрана (diff render) — без мерцания и alternate screen
- **Двуязычный интерфейс:** `--ru` (по умолчанию) и `--en`
- Опциональные горячие клавиши для сортировки, SQL-блока, деталей и пересканирования

### Требования

- Ubuntu (или совместимый Linux) с [HestiaCP](https://hestiacp.com/)
- bash 4+
- `ps`, `/proc`, логи доменов nginx/apache в `/var/log/*/domains/`
- клиент `mysql` или `mariadb` (учётные данные из `/usr/local/hestia/conf/mysql.conf`)
- **Рекомендуется:** запуск от `root` / `sudo` для полного доступа к `/proc`, логам и MySQL

### Установка

```bash
curl -fsSL https://raw.githubusercontent.com/NullDec0de/hestia-live-load/main/hestia-live-load.sh -o /usr/local/bin/hestia-live-load
chmod +x /usr/local/bin/hestia-live-load
```

Или клонируйте репозиторий и запускайте скрипт напрямую.

### Использование

```bash
sudo hestia-live-load.sh
sudo hestia-live-load.sh --en
sudo hestia-live-load.sh -i 1 -n 25
sudo hestia-live-load.sh --no-system --compact
```

#### Параметры

| Параметр | Описание |
|----------|----------|
| `-i`, `--interval SEC` | Интервал обновления в секундах (по умолчанию: `2`) |
| `-n`, `--limit NUM` | Число строк в таблице (по умолчанию: `14`) |
| `--ru` | Русский интерфейс (по умолчанию) |
| `--en` | Английский интерфейс |
| `--no-color` | Без цветов |
| `--no-system` | Скрыть общие строки mysql/nginx/apache |
| `--no-sql` | Скрыть блок активных MySQL-запросов |
| `--compact` | Скрыть подробности под строками |
| `--classic` | Полная перерисовка экрана вместо diff render |
| `--keys` | Включить hotkeys `q/s/d/v/r/+/-` (по умолчанию выкл.; выход — Ctrl+C) |
| `-h`, `--help` | Справка |

#### Горячие клавиши (с `--keys`)

| Клавиша | Действие |
|---------|----------|
| `q` | Выход |
| `s` | Сортировка: score → cpu → sql → req → mem |
| `d` | Показать/скрыть блок SQL-запросов |
| `v` | Показать/скрыть детали строк |
| `r` | Пересканировать домены и карту БД |
| `+` / `-` | Больше / меньше строк |

### Как определяется нагрузка

1. **Процессы** — по путям `/home/user/web/domain`, пулам PHP-FPM, cwd и именам пользователей Hestia.
2. **HTTP** — новые строки в `/var/log/nginx/domains/*.log` и `/var/log/apache2/domains/*.log`.
3. **MySQL** — `INFORMATION_SCHEMA.PROCESSLIST`, привязка к сайтам через `wp-config.php`, `.env` и другие типовые конфиги CMS в `public_html`.
4. **SQL≈** — примерная доля CPU `mariadbd`, распределённая по сайтам пропорционально времени активных запросов.

Строка `mysql|database` — общий процесс MariaDB; конкретный сайт смотрите в колонках **SQL≈**, **SQL** и в таблице активных запросов.

### Лицензия

MIT — см. [LICENSE](LICENSE).
