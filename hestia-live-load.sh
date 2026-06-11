#!/usr/bin/env bash
# hestia-live-load.sh — live dashboard for Ubuntu + HestiaCP
# Shows which Hestia account/domain/database is loading the server right now.

set -u
shopt -s nullglob
 
INTERVAL=2
LIMIT=14
LOG_TAIL=300
NO_COLOR=0
SHOW_SYSTEM=1
SHOW_SQL=1
SHOW_DETAILS=1
SORT_MODE="score"   # score | cpu | sql | req | mem
UI_LANG="ru"        # ru | en
DIFF_RENDER=1       
KEYS=0               # 0 = no keyboard reading; 1 = hotkeys
DB_SCAN_EVERY=60
DOMAIN_SCAN_EVERY=15

usage() {
  cat <<USAGE
Usage: sudo $0 [options]

Options:
  -i, --interval SEC   Update interval. Default: 2
  -n, --limit NUM      Number of rows. Default: 14
      --ru             Russian UI. Default
      --en             English UI
      --no-color       No colors
      --no-system      Hide common mysql/nginx/apache rows
      --no-sql         Hide active MySQL query block
      --compact        Hide details under rows
      --classic        Classic full redraw
      --keys           Enable hotkeys q/s/d/v/r/+/-; disabled for stability
  -h, --help           Help

Hotkeys while running:
  By default hotkeys are disabled: exit Ctrl+C.
  With --keys: q exit, s sorting, d SQL, v details, r rescan, +/- rows

Examples:
  sudo $0
  sudo $0 -i 1 -n 25
  sudo $0 --no-system
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -i|--interval) INTERVAL="${2:-2}"; shift 2 ;;
    -n|--limit) LIMIT="${2:-14}"; shift 2 ;;
    --ru) UI_LANG="ru"; shift ;;
    --en) UI_LANG="en"; shift ;;
    --no-color) NO_COLOR=1; shift ;;
    --no-system) SHOW_SYSTEM=0; shift ;;
    --no-sql) SHOW_SQL=0; shift ;;
    --compact) SHOW_DETAILS=0; shift ;;
    --classic) DIFF_RENDER=0; shift ;;
    --keys) KEYS=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

if ! [[ "$INTERVAL" =~ ^[0-9]+$ ]] || (( INTERVAL < 1 )); then
  echo "Interval must be an integer >= 1" >&2
  exit 1
fi
if ! [[ "$LIMIT" =~ ^[0-9]+$ ]] || (( LIMIT < 1 )); then
  echo "Limit must be an integer >= 1" >&2
  exit 1
fi

if [[ $NO_COLOR -eq 0 && -t 1 ]] && command -v tput >/dev/null 2>&1; then
  BOLD="$(tput bold)"; DIM="$(tput dim)"; RESET="$(tput sgr0)"
  RED="$(tput setaf 1)"; GREEN="$(tput setaf 2)"; YELLOW="$(tput setaf 3)"
  BLUE="$(tput setaf 4)"; MAGENTA="$(tput setaf 5)"; CYAN="$(tput setaf 6)"; WHITE="$(tput setaf 7)"
else
  BOLD=""; DIM=""; RESET=""; RED=""; GREEN=""; YELLOW=""; BLUE=""; MAGENTA=""; CYAN=""; WHITE=""
fi

HZ="$(getconf CLK_TCK 2>/dev/null || echo 100)"
CORES="$(nproc 2>/dev/null || grep -c '^processor' /proc/cpuinfo 2>/dev/null || echo 1)"
HOST="$(hostname -f 2>/dev/null || hostname 2>/dev/null || echo server)"
MYSQL_BIN="$(command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null || true)"

# Persistent state between refreshes.
declare -A PREV_TICKS LOG_POS DOMAIN_USER DB_SITE DB_ACCOUNT
declare -A PREV_CORE_TOTAL PREV_CORE_IDLE
declare -a PREV_SCREEN=()
PREV_CPU_TOTAL=""
PREV_CPU_IDLE=""
SQL_DETAIL_LINES=""
MYSQL_ACCESS_ERROR=0
MYSQL_ACCESS_NOTE=""
SORT_MODES=(score cpu sql req mem)
SORT_INDEX=0
STTY_OLD=""
CLEANED_UP=0

# per-refresh arrays they are reset in reset_metrics().
declare -A CPU10 RSSKB PIDS ACCOUNT SITE TOPCPU10 TOPCMD HITS ERRORS HTTP4XX HTTP5XX LASTREQ DBQ DBMAXTIME DBSUMTIME DBCPU10 DBNAME SQLTOP SQLSTATE SQLUSER

tr_ui() {
  local key="$1"
  if [[ "$UI_LANG" == "en" ]]; then
    case "$key" in
      title) echo "HestiaCP Live Load" ;;
      account) echo "ACCOUNT" ;;
      site) echo "SITE / SOURCE" ;;
      cpu) echo "CPU" ;;
      sqlcpu) echo "SQL≈" ;;
      mem) echo "MEM" ;;
      pids) echo "PIDS" ;;
      req) echo "REQ/Δ" ;;
      err) echo "ERR" ;;
      sql) echo "SQL" ;;
      top) echo "TOP PROCESS / SQL" ;;
      active_sql) echo "Active MySQL / MariaDB queries" ;;
      no_activity) echo "No Hestia-related activity detected in this interval." ;;
      controls) echo "Ctrl+C exit | --keys enables q/s/d/v/r/+/-" ;;
      legend) echo "CPU = process CPU; SQL≈ = approximate share of mariadbd CPU by active DB queries; SQL = active queries / longest seconds; REQ/Δ = new access-log lines." ;;
      mysql_fail) echo "MySQL PROCESSLIST is unavailable. Run as root or check /usr/local/hestia/conf/mysql.conf." ;;
      db_col) echo "DATABASE" ;;
      time_col) echo "TIME" ;;
      mysql_user) echo "MYSQL USER" ;;
      state_col) echo "STATE" ;;
      sql_col) echo "SQL" ;;
      note_footer) echo "Note: mysql/database is the shared MariaDB daemon. Use SQL≈/SQL columns and the active query block for per-site attribution." ;;
      *) echo "$key" ;;
    esac
  else
    case "$key" in
      title) echo "HestiaCP Live Load" ;;
      account) echo "АККАУНТ" ;;
      site) echo "САЙТ / ИСТОЧНИК" ;;
      cpu) echo "CPU" ;;
      sqlcpu) echo "SQL≈" ;;
      mem) echo "RAM" ;;
      pids) echo "PID" ;;
      req) echo "REQ/Δ" ;;
      err) echo "ERR" ;;
      sql) echo "SQL" ;;
      top) echo "ТОП ПРОЦЕСС / SQL" ;;
      active_sql) echo "Активные MySQL / MariaDB запросы" ;;
      no_activity) echo "За этот интервал активность Hestia-сайтов не найдена." ;;
      controls) echo "Ctrl+C выход | --keys включает q/s/d/v/r/+/-" ;;
      legend) echo "CPU = CPU процессов; SQL≈ = примерная доля CPU mariadbd по активным запросам; SQL = активные запросы / самый долгий в сек.; REQ/Δ = новые строки access-log." ;;
      mysql_fail) echo "PROCESSLIST MySQL недоступен. Запусти от root или проверь /usr/local/hestia/conf/mysql.conf." ;;
      db_col) echo "БАЗА" ;;
      time_col) echo "ВРЕМЯ" ;;
      mysql_user) echo "MYSQL USER" ;;
      state_col) echo "СОСТОЯНИЕ" ;;
      sql_col) echo "SQL" ;;
      note_footer) echo "Важно: строка mysql/database — это общий процесс MariaDB. Конкретный сайт смотри в колонках SQL≈/SQL и в блоке активных запросов." ;;
      *) echo "$key" ;;
    esac
  fi
}

cleanup() {
  if (( CLEANED_UP == 1 )); then
    return 0
  fi
  CLEANED_UP=1
  if [[ -n "${STTY_OLD:-}" && -t 0 ]]; then
    stty "$STTY_OLD" 2>/dev/null || true
  fi
  if [[ -t 1 ]]; then
    printf '\033[?25h\033[0m\n'
  fi
}
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

init_keyboard() {
  if [[ -t 1 ]]; then
    printf '\033[2J\033[H\033[?25l'
  fi
  if [[ "$KEYS" -eq 1 && -t 0 ]]; then
    STTY_OLD="$(stty -g 2>/dev/null || true)"
    stty -echo -icanon time 0 min 0 2>/dev/null || true
  fi
}

reset_metrics() {
  CPU10=(); RSSKB=(); PIDS=(); ACCOUNT=(); SITE=(); TOPCPU10=(); TOPCMD=()
  HITS=(); ERRORS=(); HTTP4XX=(); HTTP5XX=(); LASTREQ=()
  DBQ=(); DBMAXTIME=(); DBSUMTIME=(); DBCPU10=(); DBNAME=(); SQLTOP=(); SQLSTATE=(); SQLUSER=()
  SQL_DETAIL_LINES=""
  MYSQL_ACCESS_ERROR=0
  MYSQL_ACCESS_NOTE=""
}

shorten() {
  local s="${1:-}" w="${2:-20}"
  if (( ${#s} > w )); then
    printf '%s…' "${s:0:$((w-1))}"
  else
    printf '%s' "$s"
  fi
}

fmt_cpu() {
  local v="${1:-0}"
  (( v < 0 )) && v=0
  printf '%d.%d%%' "$((v / 10))" "$((v % 10))"
}

fmt_mem() {
  local kb="${1:-0}"
  awk -v k="$kb" 'BEGIN { if (k >= 1048576) printf "%.1fG", k/1048576; else if (k >= 1024) printf "%.0fM", k/1024; else printf "%dK", k }'
}

cpu10_from_ps() {
  local p="${1:-0.0}"
  if [[ "$p" == *.* ]]; then
    local a="${p%.*}" b="${p#*.}"
    b="${b:0:1}"
    [[ -z "$a" ]] && a=0
    [[ -z "$b" ]] && b=0
    printf '%d' $((10#$a * 10 + 10#$b))
  else
    printf '%d' $((10#$p * 10))
  fi
}

get_proc_ticks() {
  local pid="$1" stat rest state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime
  [[ -r "/proc/$pid/stat" ]] || { echo 0; return; }
  stat="$(<"/proc/$pid/stat")" || { echo 0; return; }
  rest="${stat##*) }"
  read -r state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime _ <<< "$rest"
  echo $(( ${utime:-0} + ${stime:-0} ))
}

build_domain_map() {
  DOMAIN_USER=()
  local path user domain
  for path in /home/*/web/*; do
    [[ -d "$path" ]] || continue
    [[ "$path" =~ ^/home/([^/]+)/web/([^/]+)$ ]] || continue
    user="${BASH_REMATCH[1]}"
    domain="${BASH_REMATCH[2]}"
    DOMAIN_USER["$domain"]="$user"
  done
}

is_hestia_user() {
  local u="${1:-}"
  [[ -n "$u" && ( -d "/home/$u/web" || -f "/usr/local/hestia/data/users/$u/user.conf" ) ]]
}

resolve_domain_account() {
  local domain="${1:-}" d base
  [[ -z "$domain" ]] && return 1

  if [[ -n "${DOMAIN_USER[$domain]:-}" ]]; then
    printf '%s|%s' "${DOMAIN_USER[$domain]}" "$domain"
    return 0
  fi

  d="${domain#www.}"
  if [[ -n "${DOMAIN_USER[$d]:-}" ]]; then
    printf '%s|%s' "${DOMAIN_USER[$d]}" "$d"
    return 0
  fi

  for base in "${!DOMAIN_USER[@]}"; do
    if [[ "$domain" == *".$base" ]]; then
      printf '%s|%s' "${DOMAIN_USER[$base]}" "$domain"
      return 0
    fi
  done
  return 1
}

add_db_map() {
  local db="${1:-}" account="${2:-}" domain="${3:-}"
  db="${db//$'\r'/}"
  db="${db//$'\n'/}"
  db="${db#\`}"; db="${db%\`}"
  db="${db#\'}"; db="${db%\'}"
  db="${db#\"}"; db="${db%\"}"
  [[ -n "$db" && -n "$account" && -n "$domain" ]] || return 0
  [[ "$db" == "DB_DATABASE" || "$db" == "database" || "$db" == "localhost" ]] && return 0
  [[ "$db" == *'$'* || "$db" == *'{'* || "$db" == *'}'* ]] && return 0
  DB_ACCOUNT["$db"]="$account"
  DB_SITE["$db"]="$domain"
}

extract_db_names_from_file() {
  local file="$1" account="$2" domain="$3" db
  [[ -r "$file" ]] || return 0

  while IFS= read -r db; do
    add_db_map "$db" "$account" "$domain"
  done < <(
    LC_ALL=C grep -aE "DB_NAME|DB_DATABASE|_DB_NAME_|database_name|['\"]database['\"]|public[[:space:]]+\$db|dbname" "$file" 2>/dev/null | head -n 60 | \
    sed -nE \
      -e "s/.*DB_NAME['\"]?[[:space:]]*,[[:space:]]*['\"]([^'\"]+).*/\1/p" \
      -e "s/.*DB_DATABASE['\"]?[[:space:]]*,[[:space:]]*['\"]([^'\"]+).*/\1/p" \
      -e "s/.*_DB_NAME_['\"]?[[:space:]]*,[[:space:]]*['\"]([^'\"]+).*/\1/p" \
      -e "s/^DB_DATABASE=[\"']?([^\"'#[:space:]]+).*/\1/p" \
      -e "s/.*public[[:space:]]+\$db[[:space:]]*=[[:space:]]*['\"]([^'\"]+).*/\1/p" \
      -e "s/.*['\"]database['\"][[:space:]]*=>[[:space:]]*['\"]([^'\"]+).*/\1/p" \
      -e "s/.*['\"]database_name['\"][[:space:]]*=>[[:space:]]*['\"]([^'\"]+).*/\1/p" \
      -e "s/.*['\"]dbname['\"][[:space:]]*=>[[:space:]]*['\"]([^'\"]+).*/\1/p"
  )
}

build_db_map() {
  DB_SITE=(); DB_ACCOUNT=()
  local path account domain root f
  for path in /home/*/web/*; do
    [[ -d "$path" ]] || continue
    [[ "$path" =~ ^/home/([^/]+)/web/([^/]+)$ ]] || continue
    account="${BASH_REMATCH[1]}"
    domain="${BASH_REMATCH[2]}"
    root="$path/public_html"
    [[ -d "$root" ]] || continue

    for f in \
      "$root/wp-config.php" \
      "$root/.env" \
      "$root/config.php" \
      "$root/admin/config.php" \
      "$root/configuration.php" \
      "$root/bitrix/.settings.php" \
      "$root/bitrix/php_interface/dbconn.php" \
      "$root/app/etc/env.php" \
      "$root/app/config/parameters.php" \
      "$root/config/settings.inc.php" \
      "$root/sites/default/settings.php"; do
      [[ -f "$f" ]] && extract_db_names_from_file "$f" "$account" "$domain"
    done
  done
}

resolve_db_owner_site() {
  local db="${1:-}" account site
  if [[ -n "$db" && -n "${DB_SITE[$db]:-}" ]]; then
    printf '%s|%s' "${DB_ACCOUNT[$db]}" "${DB_SITE[$db]}"
    return 0
  fi
  if [[ "$db" == *_* ]]; then
    account="${db%%_*}"
    if is_hestia_user "$account"; then
      printf '%s|db:%s' "$account" "$db"
      return 0
    fi
  fi
  return 1
}

ensure_key() {
  local account site key
  account="${1:-?}"
  site="${2:--}"
  key="$account|$site"
  ACCOUNT["$key"]="$account"
  SITE["$key"]="$site"
  CPU10["$key"]="${CPU10[$key]:-0}"
  RSSKB["$key"]="${RSSKB[$key]:-0}"
  PIDS["$key"]="${PIDS[$key]:-0}"
  TOPCPU10["$key"]="${TOPCPU10[$key]:-0}"
  TOPCMD["$key"]="${TOPCMD[$key]:--}"
  HITS["$key"]="${HITS[$key]:-0}"
  ERRORS["$key"]="${ERRORS[$key]:-0}"
  HTTP4XX["$key"]="${HTTP4XX[$key]:-0}"
  HTTP5XX["$key"]="${HTTP5XX[$key]:-0}"
  LASTREQ["$key"]="${LASTREQ[$key]:-}"
  DBQ["$key"]="${DBQ[$key]:-0}"
  DBMAXTIME["$key"]="${DBMAXTIME[$key]:-0}"
  DBSUMTIME["$key"]="${DBSUMTIME[$key]:-0}"
  DBCPU10["$key"]="${DBCPU10[$key]:-0}"
  DBNAME["$key"]="${DBNAME[$key]:--}"
  SQLTOP["$key"]="${SQLTOP[$key]:--}"
  SQLSTATE["$key"]="${SQLSTATE[$key]:--}"
  SQLUSER["$key"]="${SQLUSER[$key]:--}"
}

add_proc_metric() {
  local account site cpu rss cmd key
  account="${1:-?}"
  site="${2:--}"
  cpu="${3:-0}"
  rss="${4:-0}"
  cmd="${5:--}"
  key="$account|$site"
  ensure_key "$account" "$site"
  CPU10["$key"]=$(( ${CPU10[$key]:-0} + cpu ))
  RSSKB["$key"]=$(( ${RSSKB[$key]:-0} + rss ))
  PIDS["$key"]=$(( ${PIDS[$key]:-0} + 1 ))
  if (( cpu > ${TOPCPU10[$key]:-0} )); then
    TOPCPU10["$key"]="$cpu"
    TOPCMD["$key"]="$cmd"
  fi
}

extract_owner_site_from_text() {
  local text="${1:-}"
  if [[ "$text" =~ /home/([^/[:space:]]+)/web/([^/[:space:]]+) ]]; then
    printf '%s|%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

extract_pool_from_php_fpm() {
  local args="${1:-}" pool resolved
  if [[ "$args" =~ pool[[:space:]]+([^][:space:]]+) ]]; then
    pool="${BASH_REMATCH[1]}"
    pool="${pool%]}"
    if resolved="$(resolve_domain_account "$pool")"; then
      printf '%s' "$resolved"
      return 0
    fi
    printf 'php-fpm|pool:%s' "$pool"
    return 0
  fi
  return 1
}

classify_process() {
  local pid="$1" puser="$2" comm="$3" args="${4:-}" owner_site cwd resolved

  if owner_site="$(extract_owner_site_from_text "$args")"; then
    printf '%s' "$owner_site"
    return 0
  fi

  if [[ "$comm" == *php-fpm* || "$args" == *"php-fpm:"* ]]; then
    if owner_site="$(extract_pool_from_php_fpm "$args")"; then
      printf '%s' "$owner_site"
      return 0
    fi
  fi

  cwd="$(readlink -f "/proc/$pid/cwd" 2>/dev/null || true)"
  if [[ -n "$cwd" ]] && owner_site="$(extract_owner_site_from_text "$cwd")"; then
    printf '%s' "$owner_site"
    return 0
  fi

  # PHP-FPM/CLI/cron/node/python processes usually run as the Hestia user.
  if is_hestia_user "$puser"; then
    printf '%s|-' "$puser"
    return 0
  fi

  if [[ $SHOW_SYSTEM -eq 1 ]]; then
    case "$comm" in
      mysqld|mariadbd) printf 'mysql|database'; return 0 ;;
      nginx) printf 'www-data|nginx-shared'; return 0 ;;
      apache2|httpd) printf 'www-data|apache-shared'; return 0 ;;
      *php-fpm*) printf 'php-fpm|pool-unknown'; return 0 ;;
    esac
  fi

  return 1
}

collect_processes() {
  local pid puser pcpu rss comm args ticks prev delta cpu owner_site account site key cmd
  declare -A NEW_TICKS=()

  while read -r pid puser pcpu rss comm args; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    [[ "$rss" =~ ^[0-9]+$ ]] || rss=0

    owner_site="$(classify_process "$pid" "$puser" "$comm" "${args:-}")" || continue
    account="${owner_site%%|*}"
    site="${owner_site#*|}"

    ticks="$(get_proc_ticks "$pid")"
    NEW_TICKS["$pid"]="$ticks"
    prev="${PREV_TICKS[$pid]:-}"

    if [[ -n "$prev" && "$ticks" =~ ^[0-9]+$ && "$prev" =~ ^[0-9]+$ && "$ticks" -ge "$prev" ]]; then
      delta=$((ticks - prev))
      cpu=$(( (delta * 1000) / (HZ * INTERVAL) ))
    else
      cpu="$(cpu10_from_ps "$pcpu")"
    fi

    cmd="$comm ${args:-}"
    add_proc_metric "$account" "$site" "$cpu" "$rss" "$cmd"
  done < <(ps -eo pid=,user=,pcpu=,rss=,comm=,args= --no-headers 2>/dev/null)

  PREV_TICKS=()
  local p
  for p in "${!NEW_TICKS[@]}"; do
    PREV_TICKS["$p"]="${NEW_TICKS[$p]}"
  done
}

log_domain_from_file() {
  local file="$1" base
  base="$(basename "$file")"
  base="${base%.gz}"
  base="${base%.ssl.error.log}"
  base="${base%.error.log}"
  base="${base%.ssl.log}"
  base="${base%.log}"
  printf '%s' "$base"
}

count_nonempty_lines() {
  awk 'NF { c++ } END { print c + 0 }'
}

init_log_positions() {
  local log
  for log in /var/log/nginx/domains/*.log /var/log/apache2/domains/*.log; do
    [[ -f "$log" ]] || continue
    LOG_POS["$log"]="$(stat -c '%s' "$log" 2>/dev/null || echo 0)"
  done
}

collect_logs() {
  local log size prev bytes data lines domain account key is_error last_req c4 c5 resolved
  for log in /var/log/nginx/domains/*.log /var/log/apache2/domains/*.log; do
    [[ -f "$log" ]] || continue
    [[ "$log" == *bytes* ]] && continue

    is_error=0
    [[ "$(basename "$log")" == *.error.log ]] && is_error=1

    size="$(stat -c '%s' "$log" 2>/dev/null || echo 0)"
    prev="${LOG_POS[$log]:-}"

    if [[ -z "$prev" ]]; then
      data="$(tail -n "$LOG_TAIL" "$log" 2>/dev/null || true)"
    elif (( size >= prev )); then
      bytes=$((size - prev))
      if (( bytes > 0 && bytes < 2097152 )); then
        data="$(tail -c "$bytes" "$log" 2>/dev/null || true)"
      elif (( bytes >= 2097152 )); then
        data="$(tail -n "$LOG_TAIL" "$log" 2>/dev/null || true)"
      else
        data=""
      fi
    else
      # Log rotation/truncation.
      data="$(tail -n "$LOG_TAIL" "$log" 2>/dev/null || true)"
    fi
    LOG_POS["$log"]="$size"

    [[ -n "$data" ]] || continue
    lines="$(printf '%s\n' "$data" | count_nonempty_lines)"
    (( lines > 0 )) || continue

    domain="$(log_domain_from_file "$log")"
    if resolved="$(resolve_domain_account "$domain")"; then
      account="${resolved%%|*}"
      domain="${resolved#*|}"
    else
      account="${DOMAIN_USER[$domain]:-?}"
    fi
    key="$account|$domain"
    ensure_key "$account" "$domain"

    if (( is_error == 1 )); then
      ERRORS["$key"]=$(( ${ERRORS[$key]:-0} + lines ))
      last_req="$(printf '%s\n' "$data" | tail -n 1 | cut -c1-140)"
      LASTREQ["$key"]="error: $last_req"
    else
      HITS["$key"]=$(( ${HITS[$key]:-0} + lines ))
      c4="$(printf '%s\n' "$data" | grep -aEc '" [4][0-9][0-9] ' || true)"
      c5="$(printf '%s\n' "$data" | grep -aEc '" [5][0-9][0-9] ' || true)"
      HTTP4XX["$key"]=$(( ${HTTP4XX[$key]:-0} + c4 ))
      HTTP5XX["$key"]=$(( ${HTTP5XX[$key]:-0} + c5 ))
      last_req="$(printf '%s\n' "$data" | awk 'match($0,/"[A-Z]+ [^"]+"/){r=substr($0,RSTART+1,RLENGTH-2)} END{print r}' | cut -c1-140)"
      [[ -n "$last_req" ]] && LASTREQ["$key"]="$last_req"
    fi
  done
}

load_mysql_args() {
  MYSQL_ARGS=()
  local conf="/usr/local/hestia/conf/mysql.conf" host user pass
  if [[ -r "$conf" ]]; then
    host="$(grep -E "^HOST='?" "$conf" 2>/dev/null | head -n1 | sed -E "s/^HOST=['\"]?([^'\"]+)['\"]?.*/\1/")"
    user="$(grep -E "^USER='?" "$conf" 2>/dev/null | head -n1 | sed -E "s/^USER=['\"]?([^'\"]+)['\"]?.*/\1/")"
    pass="$(grep -E "^PASSWORD='?" "$conf" 2>/dev/null | head -n1 | sed -E "s/^PASSWORD=['\"]?([^'\"]*)['\"]?.*/\1/")"
    [[ -n "${user:-}" ]] && MYSQL_ARGS+=(-u "$user")
    [[ -n "${pass:-}" ]] && MYSQL_ARGS+=(-p"$pass")
    [[ -n "${host:-}" ]] && MYSQL_ARGS+=(-h "$host")
  fi
}

collect_mysql_processlist() {
  [[ -n "$MYSQL_BIN" ]] || return 0

  local id user host db command time state info rest owner_site account site key db_cpu_weight sql_short state_short q
  q="SELECT ID,USER,HOST,IFNULL(DB,''),COMMAND,IFNULL(TIME,0),IFNULL(STATE,''),LEFT(REPLACE(REPLACE(REPLACE(IFNULL(INFO,''),CHAR(10),' '),CHAR(13),' '),CHAR(9),' '),240) FROM INFORMATION_SCHEMA.PROCESSLIST WHERE COMMAND <> 'Sleep' ORDER BY TIME DESC"

  local output rc
  output="$(timeout 2 "$MYSQL_BIN" "${MYSQL_ARGS[@]:-}" --batch --raw --skip-column-names -e "$q" 2>&1)"
  rc=$?
  if (( rc != 0 )); then
    MYSQL_ACCESS_ERROR=1
    MYSQL_ACCESS_NOTE="$(printf '%s' "$output" | head -n1 | cut -c1-160)"
    return 0
  fi

  while IFS=$'\t' read -r id user host db command time state info rest; do
    [[ -n "${id:-}" ]] || continue
    [[ "${command:-}" != "Sleep" ]] || continue
    [[ "$time" =~ ^[0-9]+$ ]] || time=0
    db="${db:-}"
    info="${info:-}"
    state="${state:-}"

    if [[ -n "$db" ]] && owner_site="$(resolve_db_owner_site "$db")"; then
      account="${owner_site%%|*}"
      site="${owner_site#*|}"
    else
      account="mysql"
      site="database"
    fi

    key="$account|$site"
    ensure_key "$account" "$site"
    DBQ["$key"]=$(( ${DBQ[$key]:-0} + 1 ))
    DBSUMTIME["$key"]=$(( ${DBSUMTIME[$key]:-0} + time + 1 ))
    DBNAME["$key"]="${db:-?}"
    SQLUSER["$key"]="${user:-?}"

    if (( time >= ${DBMAXTIME[$key]:-0} )); then
      DBMAXTIME["$key"]="$time"
      SQLSTATE["$key"]="${state:--}"
      SQLTOP["$key"]="${info:--}"
    fi

    sql_short="$(shorten "${info:--}" 120)"
    state_short="$(shorten "${state:--}" 38)"
    printf -v SQL_DETAIL_LINES '%s%012d|%s|%s|%s|%s|%s|%s|%s\n' \
      "$SQL_DETAIL_LINES" "$((time + 1))" "$account" "$site" "${db:-?}" "$time" "${user:-?}" "$state_short" "$sql_short"
  done <<< "$output"
}

distribute_mysql_cpu() {
  local mysql_key="mysql|database" total_cpu sum key share
  total_cpu="${CPU10[$mysql_key]:-0}"
  (( total_cpu > 0 )) || return 0
  sum=0
  for key in "${!DBSUMTIME[@]}"; do
    (( sum += ${DBSUMTIME[$key]:-0} ))
  done
  (( sum > 0 )) || return 0
  for key in "${!DBSUMTIME[@]}"; do
    share=$(( total_cpu * ${DBSUMTIME[$key]:-0} / sum ))
    DBCPU10["$key"]="$share"
  done
}

read_mem() {
  awk '
    /^MemTotal:/ { mt=$2 }
    /^MemAvailable:/ { ma=$2 }
    /^SwapTotal:/ { st=$2 }
    /^SwapFree:/ { sf=$2 }
    END {
      mu=mt-ma; su=st-sf;
      if (mt<1) mt=1; sden=st; if (sden<1) sden=1;
      printf "%d %d %.0f %d %d %.0f", mu, mt, mu*100/mt, su, st, su*100/sden
    }' /proc/meminfo
}

read_cpu_percent() {
  local cpu user nice system idle iowait irq softirq steal guest guest_nice total idle_all diff_total diff_idle usage
  read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
  idle_all=$((idle + iowait))
  total=$((user + nice + system + idle + iowait + irq + softirq + steal))
  if [[ -n "$PREV_CPU_TOTAL" && -n "$PREV_CPU_IDLE" ]]; then
    diff_total=$((total - PREV_CPU_TOTAL))
    diff_idle=$((idle_all - PREV_CPU_IDLE))
    if (( diff_total > 0 )); then
      usage=$(( (100 * (diff_total - diff_idle)) / diff_total ))
    else
      usage=0
    fi
  else
    usage=0
  fi
  PREV_CPU_TOTAL="$total"
  PREV_CPU_IDLE="$idle_all"
  echo "$usage"
}

severity_color() {
  local cpu="$1" sqlcpu="$2" errs="$3" http5="$4"
  if (( cpu >= 1000 || sqlcpu >= 1000 || errs > 0 || http5 > 0 )); then printf '%s' "$RED"
  elif (( cpu >= 300 || sqlcpu >= 300 )); then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"
  fi
}

print_bar() {
  local value="$1" max="$2" width="$3" filled empty i
  (( max < 1 )) && max=1
  filled=$(( value * width / max ))
  (( filled > width )) && filled="$width"
  empty=$(( width - filled ))
  for ((i=0; i<filled; i++)); do printf '█'; done
  for ((i=0; i<empty; i++)); do printf '░'; done
}

meter_color() {
  local p="${1:-0}"
  if   (( p >= 90 )); then printf '%s' "$RED"
  elif (( p >= 60 )); then printf '%s' "$YELLOW"
  else printf '%s' "$GREEN"
  fi
}

htop_meter() {
  local value="${1:-0}" max="${2:-100}" width="${3:-20}" text="${4:-}" col="${5:-$GREEN}" lab="${6:-}"
  (( max < 1 )) && max=1
  (( value < 0 )) && value=0
  (( value > max )) && value=max
  local filled=$(( value * width / max ))
  (( filled > width )) && filled=width
  local lablen=${#text}
  (( lablen > width )) && { text="${text:0:width}"; lablen=$width; }
  local textstart=$(( width - lablen ))
  local i ch out=""
  for ((i=0; i<width; i++)); do
    if (( i >= textstart )); then
      ch="${text:$((i-textstart)):1}"
    elif (( i < filled )); then
      ch='|'
    else
      ch=' '
    fi
    if (( i < filled )); then
      out+="${col}${ch}"
    else
      out+="${DIM}${ch}"
    fi
  done
  printf '%s%s%s[%s%s%s]%s' "$CYAN" "$lab" "$DIM" "$out" "$DIM" "$CYAN" "$RESET"
}

read_core_percents() {
  local cpu user nice system idle iowait irq softirq steal rest n idle_all total pct pt pi dt di
  while read -r cpu user nice system idle iowait irq softirq steal rest; do
    [[ "$cpu" =~ ^cpu[0-9]+$ ]] || continue
    n="${cpu#cpu}"
    idle_all=$(( idle + iowait ))
    total=$(( user + nice + system + idle + iowait + irq + softirq + steal ))
    pct=0
    pt="${PREV_CORE_TOTAL[$n]:-}"; pi="${PREV_CORE_IDLE[$n]:-}"
    if [[ -n "$pt" && -n "$pi" ]]; then
      dt=$(( total - pt )); di=$(( idle_all - pi ))
      (( dt > 0 )) && pct=$(( (100 * (dt - di)) / dt ))
    fi
    PREV_CORE_TOTAL[$n]="$total"
    PREV_CORE_IDLE[$n]="$idle_all"
    (( pct < 0 )) && pct=0
    (( pct > 100 )) && pct=100
    printf '%s %s\n' "$n" "$pct"
  done < /proc/stat
}

print_header() {
  local load mu mt mup su st sup now uptime_s uptime_fmt disk_line tasks
  local -a core_n=() core_p=()
  load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)"
  read -r mu mt mup su st sup <<< "$(read_mem)"
  now="$(date '+%Y-%m-%d %H:%M:%S %Z')"
  uptime_s="$(cut -d. -f1 /proc/uptime 2>/dev/null || echo 0)"
  uptime_fmt="$(printf '%02d:%02d:%02d' "$(( uptime_s/3600 ))" "$(( uptime_s%3600/60 ))" "$(( uptime_s%60 ))")"
  disk_line="$(df -hP / 2>/dev/null | awk 'NR==2{print $3"/"$2" ("$5")"}')"
  tasks="$(ls -d /proc/[0-9]* 2>/dev/null | wc -l)"

  local n p
  while read -r n p; do
    core_n+=("$n"); core_p+=("$p")
  done < <(read_core_percents)

  printf '%s%s%s %s—%s %s%s   %s%s%s\n' \
    "$BOLD" "$(tr_ui title)" "$RESET" "$DIM" "$RESET" "$WHITE" "$(shorten "$HOST" 32)" "$DIM" "$now" "$RESET"

  # Per-core CPU meters, по 2 шкалы в ряд (как htop).
  local ncores=${#core_n[@]} idx half col1 col2 c1 c2 cc1 cc2 cw=22
  (( ncores < 1 )) && ncores=0
  half=$(( (ncores + 1) / 2 ))
  for (( idx=0; idx<half; idx++ )); do
    c1=$idx; c2=$(( idx + half ))
    cc1="$(meter_color "${core_p[$c1]:-0}")"
    col1="$(htop_meter "${core_p[$c1]:-0}" 100 "$cw" "$(printf '%3s%%' "${core_p[$c1]:-0}")" "$cc1" "$(printf '%2s ' "${core_n[$c1]:-0}")")"
    if (( c2 < ncores )); then
      cc2="$(meter_color "${core_p[$c2]:-0}")"
      col2="$(htop_meter "${core_p[$c2]:-0}" 100 "$cw" "$(printf '%3s%%' "${core_p[$c2]:-0}")" "$cc2" "$(printf '%2s ' "${core_n[$c2]:-0}")")"
      printf '%s   %s\n' "$col1" "$col2"
    else
      printf '%s\n' "$col1"
    fi
  done

  # Память и swap.
  local memcol; memcol="$(meter_color "$mup")"
  printf '%s\n' "$(htop_meter "$mup" 100 40 "$(printf '%s/%s' "$(fmt_mem "$mu")" "$(fmt_mem "$mt")")" "$memcol" "Mem ")"
  if (( st > 0 )); then
    local swpcol; swpcol="$(meter_color "$sup")"
    printf '%s\n' "$(htop_meter "$sup" 100 40 "$(printf '%s/%s' "$(fmt_mem "$su")" "$(fmt_mem "$st")")" "$swpcol" "Swp ")"
  fi

  printf '%sTasks:%s %-5s %sLoad:%s %-18s %sUp:%s %s  %sDisk /:%s %s\n' \
    "$BOLD" "$RESET" "$tasks" "$BOLD" "$RESET" "$load" "$BOLD" "$RESET" "$uptime_fmt" "$BOLD" "$RESET" "${disk_line:--}"
  printf '%s%s%s  sort=%s  rows=%s  interval=%ss%s\n\n' "$DIM" "$(tr_ui controls)" "$RESET" "$SORT_MODE" "$LIMIT" "$INTERVAL" "$RESET"
}

score_for_key() {
  local key="$1" score cpu sql req err mem dbq
  cpu="${CPU10[$key]:-0}"; sql="${DBCPU10[$key]:-0}"; req="${HITS[$key]:-0}"; err="${ERRORS[$key]:-0}"; mem="${RSSKB[$key]:-0}"; dbq="${DBQ[$key]:-0}"
  case "$SORT_MODE" in
    cpu) score=$(( cpu * 1000000 + sql * 700000 + req * 1000 + mem / 10 )) ;;
    sql) score=$(( sql * 1000000 + dbq * 100000 + ${DBMAXTIME[$key]:-0} * 10000 + cpu * 1000 + req )) ;;
    req) score=$(( req * 1000000 + err * 400000 + ${HTTP5XX[$key]:-0} * 300000 + cpu * 1000 + sql * 1000 )) ;;
    mem) score=$(( mem * 100 + cpu * 1000 + sql * 1000 + req )) ;;
    *) score=$(( cpu * 1000000 + sql * 900000 + req * 12000 + err * 25000 + ${HTTP5XX[$key]:-0} * 30000 + dbq * 20000 + mem / 10 )) ;;
  esac
  printf '%012d' "$score"
}

print_table() {
  local key maxbar score color account site cpu sqlcpu rss pids hits errs http4 http5 dbq dbtime cmd rows i cpu_s sql_s mem_s req_s sql_cell last detail

  maxbar=1
  for key in "${!ACCOUNT[@]}"; do
    local combined=$(( ${CPU10[$key]:-0} + ${DBCPU10[$key]:-0} ))
    (( combined > maxbar )) && maxbar="$combined"
  done

  printf '%s%-3s %-13s %-28s %8s %8s %7s %4s %7s %4s %8s  %s%s\n' \
    "$BOLD" "#" "$(tr_ui account)" "$(tr_ui site)" "$(tr_ui cpu)" "$(tr_ui sqlcpu)" "$(tr_ui mem)" "$(tr_ui pids)" "$(tr_ui req)" "$(tr_ui err)" "$(tr_ui sql)" "$(tr_ui top)" "$RESET"
  printf '%s%s\n' "$DIM" "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────" "$RESET"

  rows="$({
    for key in "${!ACCOUNT[@]}"; do
      score="$(score_for_key "$key")"
      printf '%s|%s\n' "$score" "$key"
    done
  } | sort -r | head -n "$LIMIT")"

  i=0
  while IFS='|' read -r _ account site; do
    [[ -n "${account:-}" ]] || continue
    key="$account|$site"
    i=$((i + 1))
    cpu="${CPU10[$key]:-0}"; sqlcpu="${DBCPU10[$key]:-0}"; rss="${RSSKB[$key]:-0}"; pids="${PIDS[$key]:-0}"
    hits="${HITS[$key]:-0}"; errs="${ERRORS[$key]:-0}"; http4="${HTTP4XX[$key]:-0}"; http5="${HTTP5XX[$key]:-0}"
    dbq="${DBQ[$key]:-0}"; dbtime="${DBMAXTIME[$key]:-0}"
    cmd="${TOPCMD[$key]:--}"
    [[ "${SQLTOP[$key]:--}" != "-" ]] && cmd="SQL: ${SQLTOP[$key]}"
    color="$(severity_color "$cpu" "$sqlcpu" "$errs" "$http5")"
    cpu_s="$(fmt_cpu "$cpu")"
    sql_s="$(fmt_cpu "$sqlcpu")"
    mem_s="$(fmt_mem "$rss")"
    req_s="${hits}/${INTERVAL}s"
    if (( dbq > 0 )); then
      sql_cell="${dbq}/${dbtime}s"
    else
      sql_cell="-"
    fi

    printf '%s%-3s %-13s %-28s %8s %8s %7s %4s %7s %4s %8s  %s%s\n' \
      "$color" "$i" "$(shorten "$account" 13)" "$(shorten "$site" 28)" \
      "$cpu_s" "$sql_s" "$mem_s" "$pids" "$req_s" "$errs" "$sql_cell" "$(shorten "$cmd" 48)" "$RESET"

    printf '    %s' "$DIM"
    print_bar "$((cpu + sqlcpu))" "$maxbar" 44
    printf '%s' "$RESET"

    if (( SHOW_DETAILS == 1 )); then
      detail=""
      [[ "${DBNAME[$key]:--}" != "-" ]] && detail+=" db=${DBNAME[$key]} user=${SQLUSER[$key]:--} state=$(shorten "${SQLSTATE[$key]:--}" 34);"
      if (( http4 > 0 || http5 > 0 )); then detail+=" http=${http4}x4xx/${http5}x5xx;"; fi
      last="${LASTREQ[$key]:-}"
      [[ -n "$last" ]] && detail+=" last=$(shorten "$last" 72);"
      [[ -n "$detail" ]] && printf '  %s↳%s %s' "$CYAN" "$RESET" "$(shorten "$detail" 96)"
    fi
    printf '\n'
  done <<< "$rows"

  if (( i == 0 )); then
    printf '%s%s%s\n' "$DIM" "$(tr_ui no_activity)" "$RESET"
  fi

  if (( MYSQL_ACCESS_ERROR == 1 )); then
    printf '\n%s⚠ %s%s\n' "$YELLOW" "$(tr_ui mysql_fail)" "$RESET"
    [[ -n "$MYSQL_ACCESS_NOTE" ]] && printf '%s%s%s\n' "$DIM" "$MYSQL_ACCESS_NOTE" "$RESET"
  fi
}

print_sql_table() {
  (( SHOW_SQL == 1 )) || return 0
  [[ -n "$SQL_DETAIL_LINES" ]] || return 0
  local line score account site db time user state info i
  printf '\n%s%s%s\n' "$BOLD" "$(tr_ui active_sql)" "$RESET"
  printf '%s%-3s %-13s %-27s %-24s %6s %-12s %-30s %s%s\n' "$BOLD" "#" "$(tr_ui account)" "$(tr_ui site)" "$(tr_ui db_col)" "$(tr_ui time_col)" "$(tr_ui mysql_user)" "$(tr_ui state_col)" "$(tr_ui sql_col)" "$RESET"
  printf '%s%s\n' "$DIM" "────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────" "$RESET"
  i=0
  while IFS='|' read -r score account site db time user state info; do
    [[ -n "${account:-}" ]] || continue
    i=$((i + 1))
    printf '%-3s %-13s %-27s %-24s %6ss %-12s %-30s %s\n' \
      "$i" "$(shorten "$account" 13)" "$(shorten "$site" 27)" "$(shorten "$db" 24)" "$time" "$(shorten "$user" 12)" "$(shorten "$state" 30)" "$(shorten "$info" 68)"
    (( i >= 8 )) && break
  done < <(printf '%s' "$SQL_DETAIL_LINES" | sort -t'|' -k1,1nr)
}

print_footer() {
  printf '\n%s%s%s\n' "$BOLD" "$(tr_ui legend)" "$RESET"
  printf '%s%s%s\n' "$BOLD" "$(tr_ui note_footer)" "$RESET"
}


render_screen() {
  print_header
  print_table
  print_sql_table
  print_footer
}

draw_screen() {
  local screen="${1:-}" row max_rows

  if [[ ! -t 1 ]]; then
    printf '%s' "$screen"
    return 0
  fi
  if [[ "$DIFF_RENDER" -ne 1 ]]; then
    printf '\033[H%s\033[J' "$screen"
    return 0
  fi

  local -a cur=()
  mapfile -t cur <<< "$screen"

  local -a prev=()
  if [[ -n "${PREV_SCREEN[*]:-}" ]]; then
    prev=("${PREV_SCREEN[@]}")
  fi

  local cur_len=${#cur[@]} prev_len=${#prev[@]}
  if (( cur_len > prev_len )); then
    max_rows=$cur_len
  else
    max_rows=$prev_len
  fi

  for ((row=0; row<max_rows; row++)); do
    if (( row >= cur_len )); then
      printf '\033[%d;1H\033[2K' "$((row + 1))"
    elif [[ "${prev[$row]:-__EMPTY__}" != "${cur[$row]}" ]]; then
      printf '\033[%d;1H\033[2K%s' "$((row + 1))" "${cur[$row]}"
    fi
  done

  PREV_SCREEN=("${cur[@]}")
  printf '\033[J\033[%d;1H' "$(( cur_len + 1 ))"
}

handle_key() {
  local k=""
  if [[ "$KEYS" -ne 1 || ! -t 0 ]]; then
    sleep "$INTERVAL"
    return 0
  fi
  if read -r -s -n1 -t "$INTERVAL" k; then
    case "$k" in
      q|Q) cleanup; exit 0 ;;
      s|S)
        SORT_INDEX=$(( (SORT_INDEX + 1) % ${#SORT_MODES[@]} ))
        SORT_MODE="${SORT_MODES[$SORT_INDEX]}"
        ;;
      d|D) SHOW_SQL=$((1 - SHOW_SQL)) ;;
      v|V) SHOW_DETAILS=$((1 - SHOW_DETAILS)) ;;
      r|R) build_domain_map; build_db_map ;;
      +|=) LIMIT=$((LIMIT + 1)) ;;
      -|_) (( LIMIT > 1 )) && LIMIT=$((LIMIT - 1)) ;;
    esac
  fi
}

if [[ $EUID -ne 0 ]]; then
  echo "Warning: run with sudo/root for accurate /proc, logs and MySQL visibility." >&2
  sleep 1
fi

load_mysql_args
build_domain_map
build_db_map
init_log_positions
init_keyboard
iteration=0

while true; do
  reset_metrics
  if (( iteration % DOMAIN_SCAN_EVERY == 0 )); then
    build_domain_map
  fi
  if (( iteration % DB_SCAN_EVERY == 0 )); then
    build_db_map
  fi

  collect_processes
  collect_logs
  collect_mysql_processlist
  distribute_mysql_cpu

  screen="$(render_screen)"
  draw_screen "$screen"

  iteration=$((iteration + 1))
  handle_key
done
