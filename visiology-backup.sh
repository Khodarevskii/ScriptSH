#!/bin/bash -e
#
# visiology-backup.sh - полный бэкап платформы Visiology (Docker Swarm).
#
# Postgres, Smart Forms, MinIO, docker secrets и пользовательские
# настройки снимаются теми же командами, что и штатный backup.sh. ClickHouse
# снимается отдельно: LVM-снапшот корня, копия каталога данных, временный
# сервер CH на этой копии и выгрузка в формате Native. Это даёт согласованный
# срез базы без остановки платформы.
#
# Скрипт размещается рядом со штатным backup.sh: ему нужны config.env,
# defaults.env и относительные каталоги extended-services, env-files,
# custom-configs.
#
# Результат - один архив <hostname>-backup-v<версия>-<дата>.tar.gz.
# Коды возврата: 0 - успех, 1 - ошибка, 3 - прогон уже выполняется.
#
# По завершении отправляется отчёт по почте - при любом исходе, включая аварию и
# отказ из-за уже идущего прогона. Адреса и параметры SMTP задаются в блоке
# "ОТЧЁТ ПО ПОЧТЕ" ниже; пустой MAIL_TO отправку отключает.
#
COMMAND_LINE="$0 $*"
error_output=/dev/null

# Разрешить неполный дамп ClickHouse и выгрузку одной конкретной ноды
ALLOW_PARTIAL_CH=0
CH_ONLY_NODE=""
CH_ONLY=0
# Копировать каталог данных ClickHouse целиком, а не только базу CH_DB
FULL_CH_COPY=0
# Отправить проверочное письмо и выйти, не запуская бэкап
TEST_MAIL=0

# Парсинг аргументов: -d/--debug (трассировка), -h/--help
while [ "$1" != "" ]; do
    case "$1" in
        "-?" | "-h" | "--help")
            echo "Usage: $0 [-d|--debug] [--ch-node ИМЯ] [--allow-partial-clickhouse]"
            echo "          [--full-ch-copy] [--ch-only] [--test-mail] [-h|--help]"
            echo "  -d, --debug   режим отладки (трассировка команд, показ ошибок)"
            echo "  -h, --help    эта справка"
            echo
            echo "  --ch-node ИМЯ выгрузить только ноду ClickHouse с этим именем"
            echo "                хоста (как в CLICKHOUSE_HOSTS, напр. clickhouse-1)."
            echo "                Нужно, когда ноды CH разнесены по разным хостам:"
            echo "                скрипт снимает LVM-снапшот ЛОКАЛЬНОГО корня и"
            echo "                чужие ноды снять не может."
            echo "  --ch-only     только ClickHouse: без postgres/minio/"
            echo "                секретов, без очистки backup/ и без упаковки."
            echo "                Режим для дополнительных хостов CH: на каждом"
            echo "                \"$0 --ch-only --ch-node ИМЯ\", затем каталоги"
            echo "                backup/clickhouse/ИМЯ переносятся к основному"
            echo "                хосту и пакуются вместе с ним."
            echo "  --test-mail   отправить проверочное письмо и выйти. Бэкап не"
            echo "                запускается, данные не трогаются."
            echo "  --full-ch-copy"
            echo "                копировать каталог данных ClickHouse целиком."
            echo "                По умолчанию копируются только каталоги базы,"
            echo "                которая выгружается; остальное - системные"
            echo "                журналы сервера, они в бэкап не входят и обычно"
            echo "                занимают в разы больше самих данных."
            echo "  --allow-partial-clickhouse"
            echo "                не прерывать бэкап, если часть нод CH недоступна"
            echo "                или часть таблиц не выгрузилась (словари,"
            echo "                Distributed - у временного CH нет доступа к их"
            echo "                источникам и к конфигу кластера)."
            echo "                Архив помечается файлом CLICKHOUSE-PARTIAL.txt"
            echo "                со списком того, что не попало."
            echo
            echo "Полный бэкап Visiology (postgres, smartforms, minio, секреты,"
            echo "custom) + консистентный ClickHouse через LVM-снапшот."
            echo "Keycloak не сохраняется: realm восстанавливается отдельно."
            echo
            echo "Коды возврата: 0 - успех, 1 - ошибка, 3 - предыдущий прогон"
            echo "ещё идёт, 20/127 - неверные аргументы."
            exit 0
            ;;
        "-d" | "--debug")
            set -x
            error_output=/dev/fd/1
            ;;
        "--allow-partial-clickhouse")
            ALLOW_PARTIAL_CH=1
            ;;
        "--ch-only")
            CH_ONLY=1
            ;;
        "--full-ch-copy")
            FULL_CH_COPY=1
            ;;
        "--test-mail")
            TEST_MAIL=1
            ;;
        "--ch-node")
            shift
            CH_ONLY_NODE="$1"
            [ -n "${CH_ONLY_NODE}" ] || { echo "--ch-node ждёт имя хоста CH, например clickhouse-1"; exit 20; }
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            echo "См. справку: $0 -h"
            exit 127
            ;;
    esac
    shift
done

# Ошибка в любом звене конвейера считается ошибкой шага.
set -o pipefail

# PATH задаётся явно: у cron он минимальный, а утилиты LVM лежат в /usr/sbin.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH}"

SCRIPT_DIR=$( dirname -- "$( readlink -f -- "$0")")

t_start=$(date +%s)
T_START_HUMAN=$(date '+%F %T')

########################################
# ОТЧЁТ ПО ПОЧТЕ (правится под контур)
########################################
# Пустой MAIL_TO отключает отправку. Получатели перечисляются через запятую.
MAIL_TO="user1@example.ru,user2@example.ru"
MAIL_FROM="bi@example.ru"
SMTP_HOST="mail.example.ru"
SMTP_PORT="25"
# Шифрование. Порт 25 и 587 - обычно STARTTLS, порт 465 - SSL с первого байта.
# Режим должен соответствовать порту: на 465 без SMTP_USE_SSL соединение просто
# висит до таймаута, потому что релей ждёт TLS, а клиент - текстовое приветствие.
SMTP_USE_TLS="false"      # STARTTLS после подключения (порт 25/587)
SMTP_USE_SSL="false"      # TLS сразу при подключении (порт 465)
SMTP_SKIP_VERIFY="true"   # не проверять сертификат релея (самоподписанный)
# Пароль пуст: релей контура принимает почту без авторизации. Вход выполняется,
# только если заданы и имя, и пароль.
SMTP_USER="bi@example.ru"
SMTP_PASSWORD=""

# Хранить пароль в скрипте не обязательно: если файл ниже существует, значения
# из него перекрывают заданные выше. Формат KEY=VALUE, строки с # - комментарий.
# Права - 600.
#
# Файл разбирается построчно, а не через source: значение с пробелом (например
# список получателей через ", ") bash попытался бы выполнить как команду, а сам
# файл настроек получил бы право запускать что угодно. Ключи вне списка ниже
# игнорируются, чтобы файл не переопределял настройки самого бэкапа.
NOTIFY_ENV="${NOTIFY_ENV:-/etc/visiology-backup.env}"
if [ -r "${NOTIFY_ENV}" ]; then
    while IFS= read -r _line || [ -n "${_line}" ]; do
        _line="${_line%$'\r'}"
        case "${_line}" in ''|'#'*) continue ;; esac
        _key="${_line%%=*}"
        _val="${_line#*=}"
        case "${_key}" in
            MAIL_TO|MAIL_FROM|SMTP_HOST|SMTP_PORT|SMTP_USE_TLS|SMTP_USE_SSL|SMTP_SKIP_VERIFY|SMTP_USER|SMTP_PASSWORD) ;;
            *) continue ;;
        esac
        # Кавычки вокруг значения снимаются, как это делал бы source.
        case "${_val}" in
            \"*\") _val="${_val#\"}"; _val="${_val%\"}" ;;
            \'*\') _val="${_val#\'}"; _val="${_val%\'}" ;;
        esac
        printf -v "${_key}" '%s' "${_val}"
    done < "${NOTIFY_ENV}"
    unset _line _key _val
fi

# Путь к журналу нужен письму, чтобы приложить последние строки при аварии. Под
# cron поток вывода перенаправлен в файл, и его имя видно через /proc. Дескриптор
# сначала дублируется: внутри подстановки команд fd 1 - это её труба, а не файл.
exec 8>&1
LOG_PATH=$(readlink -f /proc/self/fd/8 2>/dev/null) || LOG_PATH=""
exec 8>&-
[ -f "${LOG_PATH}" ] || LOG_PATH=""

# Данные для письма, известные только к концу прогона.
NOTIFY_ARCHIVE=""
NOTIFY_ARCHIVE_SIZE=""

# Отправка отчёта. $1 - статус (ok|fail|running), далее - параметры прогона.
#
# Письмо собирает и отправляет встроенный обработчик на python3: разбор SMTP,
# STARTTLS и заголовки с кириллицей на чистом bash пришлось бы писать вручную,
# а python3 есть в любой поддерживаемой Ubuntu. Внешние пакеты не нужны -
# используется только стандартная библиотека.
#
# Настройки передаются переменными окружения, а не аргументами: пароль не должен
# попадать в argv, видимый через ps. Ошибка отправки не влияет на исход бэкапа.
notify() {
    local status="$1"; shift
    [ -n "${MAIL_TO}" ] || return 0
    if ! command -v python3 >/dev/null 2>&1; then
        echo "$(date '+%F %T') [visiology-backup] ВНИМАНИЕ: python3 не найден, отчёт не отправлен" >&2
        return 0
    fi

    local args=(--status "${status}")
    if [ -n "${LOG_PATH}" ]; then
        args+=(--log-file "${LOG_PATH}")
    fi

    (
        export MAIL_TO MAIL_FROM SMTP_HOST SMTP_PORT SMTP_USE_TLS SMTP_USE_SSL SMTP_SKIP_VERIFY SMTP_USER SMTP_PASSWORD
        timeout 90 python3 - "${args[@]}" "$@" <<'NOTIFY_PY'
"""Отчёт о прогоне visiology-backup.sh. Параметры - аргументами, SMTP - из окружения."""
import argparse
import logging
import os
import smtplib
import socket
import ssl
import sys
from datetime import datetime
from email.mime.multipart import MIMEMultipart
from email.mime.text import MIMEText

LOG_TAIL_LINES = 40
SMTP_TIMEOUT = 20

logging.basicConfig(level=logging.INFO, format="%(asctime)s [visiology-backup] %(levelname)s %(message)s")
log = logging.getLogger("notify")


def getenv_str(key: str, default: str = "") -> str:
    value = os.getenv(key)
    if value is None or not str(value).strip():
        return default
    return str(value).strip()


def is_yes(key: str) -> bool:
    return getenv_str(key, "false").lower() in ("1", "true", "yes")


def get_host_ip() -> str:
    """IP основного исходящего интерфейса; трафик при этом не идёт."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect(("8.8.8.8", 80))
            return s.getsockname()[0]
        finally:
            s.close()
    except Exception:
        pass
    try:
        return socket.gethostbyname(socket.gethostname())
    except Exception:
        return "unknown"


HOSTNAME = os.uname().nodename
HOST_IP = get_host_ip()


def send_email(subject: str, body: str) -> bool:
    mail_to = [a.strip() for a in getenv_str("MAIL_TO").split(",") if a.strip()]
    if not mail_to:
        log.warning("MAIL_TO пуст - отправка пропущена.")
        return False

    mail_from = getenv_str("MAIL_FROM", f"visiology-backup@{HOSTNAME}")
    smtp_user = getenv_str("SMTP_USER")
    smtp_password = getenv_str("SMTP_PASSWORD")

    msg = MIMEMultipart()
    msg["From"] = mail_from
    msg["To"] = ", ".join(mail_to)
    msg["Subject"] = subject
    msg.attach(MIMEText(body, "plain", "utf-8"))

    context = ssl.create_default_context()
    if is_yes("SMTP_SKIP_VERIFY"):
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE

    host = getenv_str("SMTP_HOST", "localhost")
    port = int(getenv_str("SMTP_PORT", "25"))
    use_ssl = is_yes("SMTP_USE_SSL")
    use_tls = is_yes("SMTP_USE_TLS")
    mode = "SSL" if use_ssl else ("STARTTLS" if use_tls else "без шифрования")

    try:
        # На порту 465 TLS начинается с первого байта, приветствия в открытом
        # виде там нет - нужен SMTP_SSL, обычный SMTP на нём ждёт до таймаута.
        if use_ssl:
            server = smtplib.SMTP_SSL(host, port, timeout=SMTP_TIMEOUT, context=context)
        else:
            server = smtplib.SMTP(host, port, timeout=SMTP_TIMEOUT)
            if use_tls:
                server.starttls(context=context)
        if smtp_user and smtp_password:
            server.login(smtp_user, smtp_password)
        server.sendmail(mail_from, mail_to, msg.as_string())
        server.quit()
        log.info(f"Отчёт отправлен: {mail_to}")
        return True
    except Exception as e:
        log.error(f"Не удалось отправить отчёт через {host}:{port} ({mode}): {e}")
        return False


def read_lines(path: str, tail: int = 0) -> list:
    """Строки файла; при tail > 0 - только последние. Ошибки чтения гасятся."""
    if not path or not os.path.isfile(path):
        return []
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            lines = [line.rstrip("\n") for line in fh]
    except OSError as e:
        log.warning(f"Не удалось прочитать {path}: {e}")
        return []
    return lines[-tail:] if tail else lines


def build_subject(args, notes_count: int) -> str:
    head = f"[Visiology backup] {HOSTNAME} ({HOST_IP})"
    if args.status == "test":
        return f"{head}: проверка отправки"
    if args.status == "running":
        return f"{head}: ПРОПУЩЕН - предыдущий прогон ещё идёт"
    if args.status == "fail":
        # Нулевой код при неуспехе означает обрыв до упаковки, а не ошибку шага.
        if args.rc == 0:
            return f"{head}: ПРОГОН НЕ ЗАВЕРШЁН - архив не собран"
        return f"{head}: ОШИБКА (код {args.rc})"
    size = f", {args.archive_size}" if args.archive_size else ""
    notes = f", замечаний: {notes_count}" if notes_count else ""
    return f"{head}: успешно за ~{args.elapsed_min} мин{size}{notes}"


def build_body(args, notes: list, log_tail: list) -> str:
    if args.status == "ok":
        result = "успешно"
        intro = "Резервное копирование Visiology завершено."
    elif args.status == "fail":
        result = f"ОШИБКА (код возврата {args.rc})" if args.rc else "прогон не завершён, архив не собран"
        intro = "ВНИМАНИЕ! Резервное копирование Visiology не выполнено."
    elif args.status == "test":
        result = "проверка отправки"
        intro = ("Проверочное письмо. Отправлено ключом --test-mail, "
                 "резервное копирование при этом не выполнялось.")
    else:
        result = "пропущен"
        intro = ("Запуск резервного копирования пропущен: предыдущий прогон ещё выполняется. "
                 "Проверьте, не завис ли он.")

    lines = [intro, "",
             f"Сервер:        {HOSTNAME}",
             f"IP-адрес:      {HOST_IP}",
             f"Результат:     {result}"]
    if args.mode:
        lines.append(f"Режим:         {args.mode}")
    if args.started:
        lines.append(f"Начало:        {args.started}")
    lines.append(f"Завершение:    {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
    if args.status in ("ok", "fail"):
        lines.append(f"Длительность:  ~{args.elapsed_min} мин")
    if args.archive:
        size = f" ({args.archive_size})" if args.archive_size else ""
        lines.append(f"Архив:         {args.archive}{size}")
    elif args.status == "fail":
        lines.append("Архив:         не собран")
    if args.log_file:
        lines.append(f"Журнал:        {args.log_file}")

    if notes:
        lines += ["", f"Замечания ({len(notes)}):", ""]
        lines += [f"   {note}" for note in notes]

    if log_tail:
        lines += ["", f"Последние строки журнала ({len(log_tail)}):", ""]
        lines += [f"   {line}" for line in log_tail]

    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description="Отчёт о прогоне visiology-backup.sh")
    parser.add_argument("--status", required=True, choices=("ok", "fail", "running", "test"))
    parser.add_argument("--rc", type=int, default=0, help="код возврата бэкапа")
    parser.add_argument("--started", default="", help="время старта прогона")
    parser.add_argument("--elapsed-min", default="0", help="длительность в минутах")
    parser.add_argument("--archive", default="", help="путь к собранному архиву")
    parser.add_argument("--archive-size", default="", help="размер архива")
    parser.add_argument("--mode", default="", help="особый режим прогона")
    parser.add_argument("--notes-file", default="", help="файл с замечаниями, по строке")
    parser.add_argument("--log-file", default="", help="журнал прогона")
    args = parser.parse_args()

    notes = [line for line in read_lines(args.notes_file) if line.strip()]
    # Хвост журнала прикладывается только к аварийному письму: при успехе он
    # ничего не добавляет, а объём письма увеличивает.
    log_tail = read_lines(args.log_file, LOG_TAIL_LINES) if args.status == "fail" else []

    send_email(build_subject(args, len(notes)), build_body(args, notes, log_tail))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        log.exception(f"Сбой при отправке отчёта: {e}")
        sys.exit(0)
NOTIFY_PY
    ) || true
}

# Проверка почты: письмо уходит тем же путём, что и настоящий отчёт. Стоит до
# захвата блокировки и до установки обработчика выхода - идущему прогону
# проверка не помешает, а на диске ничего не создаётся.
if [ "${TEST_MAIL}" = "1" ]; then
    if [ -z "${MAIL_TO}" ]; then
        echo "$(date '+%F %T') [visiology-backup] MAIL_TO пуст: отправка отключена" >&2
        exit 1
    fi
    echo "$(date '+%F %T') [visiology-backup] проверка отправки: ${SMTP_HOST}:${SMTP_PORT} -> ${MAIL_TO}"
    notify test --started "${T_START_HUMAN}"
    exit 0
fi

# Защита от параллельных запусков: прогон длится часами, и наложение расписания
# привело бы к попытке создать снапшот с уже занятым именем.
LOCK_DIR=/var/lock
[ -w "${LOCK_DIR}" ] || LOCK_DIR=/tmp
LOCK_FILE="${LOCK_DIR}/visiology-backup.lock"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo "$(date '+%F %T') [visiology-backup] предыдущий бэкап ещё выполняется (${LOCK_FILE}), выходим" >&2
    notify running --rc 3 --started "${T_START_HUMAN}"
    exit 3
fi

# Временный обработчик на время подготовки: до установки основного (cleanup)
# скрипт может упасть на чтении конфигов, и такой отказ тоже должен дойти
# письмом, иначе под cron он останется незамеченным.
trap 'rc=$?; [ "${rc}" -eq 0 ] || notify fail --rc "${rc}" --started "${T_START_HUMAN}"; exit "${rc}"' EXIT

pushd "${SCRIPT_DIR}" >/dev/null

source config.env
source defaults.env

# Версия: из конфигов (если там задана VI_VERSION), иначе значение по умолчанию.
# Правится под контур, т.к. версии на контурах разные.
VERSION="${VI_VERSION:-3.16.1}"

########################################
# КОНФИГУРАЦИЯ CH-БЛОКА (правится под контур)
########################################
VG_NAME="ubuntu-vg"
LV_NAME="ubuntu-lv"
SNAP_NAME="visiology_backup_snap"
SNAP_PV="/dev/sdg"
# Минимум свободного места на SNAP_PV под COW снапшота, МБ.
SNAP_MIN_MB=1024
# Нижние пороги свободного места, ГБ. Это защита от полного диска, а не
# расчёт под объём данных: реальная потребность зависит от размера базы.
BACKUP_MIN_GB=20
CH_COPY_MIN_GB=20

CH_IMAGE="cr.yandex/crpe1mi33uplrq7coc9d/visiology/release/original/clickhouse-server:24.8.11.51285-alpine"
CH_DB="visiology"
CH_TEMP_NAME="ch_temp_backup"     # префикс имени временных контейнеров

# Резервные значения на случай, если ни backup-service, ни Swarm опросить не
# удалось. В норме имя каталога и имя тома определяются автоматически.
CH_HOST_LABEL="clickhouse-1"
CH_VOLUME="visiology3_clickhouse_data"
CH_CPUS="4"
CH_MEMORY="16g"
CH_CPU_SHARES="512"
DUMP_PARALLEL="4"

SNAP_MNT="/mnt/vis_snap"
CH_COPY_DIR="/mnt/disk2/vis_ch_copy"   # копии данных CH: <CH_COPY_DIR>/<хост CH>

if command -v pigz >/dev/null 2>&1; then
    COMPRESSOR="pigz -p ${CH_CPUS}"
else
    COMPRESSOR="gzip"
fi

########################################
# Пути (как в штатном backup.sh)
########################################
MAIN_BACKUP_DIR="${BACKUP_DIR%/}/backup"
DV_CUSTOM_SCRIPTS_HOST_PATH="${MAIN_BACKUP_DIR}/dashboard-viewer"
DV_CUSTOM_SCRIPTS_CONTAINER_PATH="${PERSISTENT_STORAGE_FOLDER}/dashboard-viewer/customjs"
MN_FILES_HOST_PATH="${MAIN_BACKUP_DIR}/minio"
MN_FILES_CONTAINER_PATH="/data"
SECRETS_FILES_HOST_PATH="${MAIN_BACKUP_DIR}/secrets"
EXTENDED_SERVICES_PATH="extended-services"
ENV_FILES_PATH="env-files"
CUSTOM_CONFIGS_PATH="custom-configs"
COMMAND_FILE="command.txt"
LOG_TAG="[visiology-backup]"

# Замечания и причина аварии дублируются в файл: из него итоговое письмо
# собирает раздел "Замечания". Через файл, а не переменную, потому что die
# вызывается в том числе внутри подстановок команд, где присваивание пропадёт.
NOTIFY_NOTES=$(mktemp /tmp/visiology-backup-notes.XXXXXX) || NOTIFY_NOTES=/dev/null

log() { echo "$(date '+%F %T') ${LOG_TAG} $*"; }
warn() {
    echo "$(date '+%F %T') ${LOG_TAG} ВНИМАНИЕ: $*" >&2
    printf 'ВНИМАНИЕ: %s\n' "$*" >> "${NOTIFY_NOTES}" 2>/dev/null || true
}
die() {
    echo "$(date '+%F %T') ${LOG_TAG} ОШИБКА: $*" >&2
    printf 'ОШИБКА: %s\n' "$*" >> "${NOTIFY_NOTES}" 2>/dev/null || true
    exit 1
}

CH_STARTED=0
SNAP_MOUNTED=0
SNAP_CREATED=0
CH_COPY_CREATED=0
SNAP_FREE_MB=0

########################################
# Общие помощники
########################################

# Поиск контейнера по подстроке имени.
# Используется фильтр docker ps, а не grep по его выводу: grep совпадает в том
# числе по колонке IMAGE и при нескольких совпадениях возвращает несколько
# идентификаторов.
resolve_container() {
    docker ps --filter "name=$1" --format '{{.ID}}' | head -1
}

# То же, но с обязательным наличием контейнера.
require_container() {
    local cid
    cid=$(resolve_container "$1") || true
    [ -n "${cid}" ] || die "контейнер '$2' не найден (фильтр имени: $1)"
    printf '%s' "${cid}"
}


# Файл секрета для архива - побайтово, без нормализации: restore.sh передаёт его
# в docker secret create, и значение должно восстановиться без изменений.
copy_secret_file() {
    local cid="$1" name="$2" out="$3"
    docker exec -i "${cid}" cat "/run/secrets/${name}" > "${out}" \
        || die "не удалось прочитать секрет ${name} из контейнера ${cid}"
    [ -s "${out}" ] || die "секрет ${name} сохранён пустым: ${out}"
}

_umount_lazy() {
    local mp="$1"
    timeout 10 mountpoint -q "${mp}" 2>/dev/null || return 0
    local i
    for i in 1 2 3; do
        if sudo timeout 30 umount "${mp}" >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    # Ленивое размонтирование отцепляет файловую систему даже если она занята
    # и, в отличие от fuser, практически не блокируется.
    if sudo umount -l "${mp}" >/dev/null 2>&1; then
        sleep 1
        timeout 10 mountpoint -q "${mp}" 2>/dev/null || return 0
    fi
    # Последнее средство: fuser обходит /proc целиком и на занятой точке может
    # выполняться минутами, поэтому ограничен по времени. -k шлёт SIGKILL.
    sudo timeout 20 fuser -km "${mp}" >/dev/null 2>&1 || true
    sleep 1
    sudo timeout 30 umount -l "${mp}" >/dev/null 2>&1 || true
}

# Процессы, удерживающие снапшот. Выводятся в лог, чтобы причина неудачного
# удаления была видна (как правило это антивирус).
_snapshot_holders() {
    local dev="/dev/${VG_NAME}/${SNAP_NAME}"
    log "  кто держит ${SNAP_MNT} / ${dev}:"
    sudo timeout 15 fuser -vm "${dev}" 2>&1 | head -10 | while IFS= read -r l; do log "      ${l}"; done || true
    if command -v fuser >/dev/null 2>&1; then
        sudo timeout 15 fuser -vm "${SNAP_MNT}" 2>&1 | head -10 | while IFS= read -r l; do log "      ${l}"; done || true
    fi
    if command -v lsof >/dev/null 2>&1; then
        sudo timeout 15 lsof "${SNAP_MNT}" 2>/dev/null | head -10 | while IFS= read -r l; do log "      ${l}"; done || true
    fi
    sudo dmsetup info -c 2>/dev/null | grep -i "${SNAP_NAME}" | while IFS= read -r l; do log "      ${l}"; done || true
}

# Удаление снапшота. $1 - число попыток с интервалом 3 секунды.
_remove_snapshot() {
    sudo timeout 15 lvs "${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1 || return 0
    local attempts="${1:-40}" i
    for i in $(seq 1 "${attempts}"); do
        if sudo timeout 60 lvremove -y "${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1; then
            [ "${i}" -gt 1 ] && log "  снапшот удалён с попытки ${i}"
            return 0
        fi
        # держатели показываются один раз
        if [ "${i}" = "5" ]; then _snapshot_holders; fi
        # Ленивое размонтирование отцепляет только имя: файловая система живёт,
        # пока держатель не закроет дескрипторы, и всё это время том занят.
        # Точки монтирования уже нет, поэтому держатели освобождаются по устройству.
        if [ "${i}" = "10" ] || [ "${i}" = "25" ]; then
            log "  снапшот занят, освобождаю держателей по устройству"
            sudo timeout 20 fuser -km "/dev/${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1 || true
            sudo timeout 20 fuser -km "/dev/mapper/${VG_NAME//-/--}-${SNAP_NAME//-/--}" >/dev/null 2>&1 || true
        fi
        if [ "${i}" = "20" ]; then log "  снапшот всё ещё занят, продолжаю попытки..."; fi
        sudo timeout 30 lvchange -an "${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1 || true
        [ "${i}" -lt "${attempts}" ] && sleep 3
    done
    return 1
}

# Подготовка каталога копии к запуску временного сервера.
# При выборочном копировании в копию попадают только каталоги базы, а служебные
# подкаталоги сервер создаёт сам - но не может, если корень копии принадлежит
# root, а сам он работает под 101:101. Поэтому создаём их заранее и отдаём
# владение. Содержимое копии владельца не меняет: tar сохраняет исходного.
_prepare_ch_copy_dirs() {
    local dst="$1" d
    for d in tmp user_files format_schemas access flags metadata_dropped preprocessed_configs data metadata store; do
        sudo mkdir -p "${dst}/${d}"
        sudo chown 101:101 "${dst}/${d}"
    done
    sudo chown 101:101 "${dst}"

    # Каталоги store/<префикс> в списке не значатся, tar создаёт их от root.
    # Сервер пишет в них, когда заводит собственную базу system, поэтому владение
    # отдаём и здесь. Каталогов не больше 256, обход дешёвый.
    if [ -d "${dst}/store" ]; then
        sudo find "${dst}/store" -mindepth 1 -maxdepth 1 -type d -exec chown 101:101 {} +
    fi
}

# Запрос к работающему серверу ClickHouse. Учётные данные читает сам контейнер
# из /run/secrets, в argv они не попадают.
#   $1 - идентификатор контейнера, $2 - запрос
_ch_live_query() {
    local cid="$1" q="$2"
    docker exec -i "${cid}" sh -c 'U=$(cat /run/secrets/CLICKHOUSE_USER 2>/dev/null); P=$(cat /run/secrets/CLICKHOUSE_PASSWORD 2>/dev/null); if [ -n "$U" ]; then clickhouse-client -u "$U" --password "$P" -q "$1"; else clickhouse-client -q "$1"; fi' _ "${q}"
}

# Каталоги базы CH_DB на диске, относительно каталога данных ClickHouse.
# Список берётся у самого сервера (system.tables.data_paths и metadata_path
# базы), поэтому верен при любом движке базы, любой раскладке store/ и после
# переименований. Возвращает 1, если список получить не удалось.
ch_relative_paths() {
    local cid="$1" out
    out=$(_ch_live_query "${cid}" "SELECT arrayJoin(data_paths) FROM system.tables WHERE database = '${CH_DB}' UNION ALL SELECT metadata_path FROM system.databases WHERE name = '${CH_DB}' FORMAT TSVRaw" 2>/dev/null) || out=""
    [ -n "${out}" ] || return 1
    {
        printf '%s\n' "${out}"
        printf '/var/lib/clickhouse/metadata/%s.sql\n' "${CH_DB}"
        printf '/var/lib/clickhouse/metadata/%s\n' "${CH_DB}"
    } | sed -e 's#^/var/lib/clickhouse/##' -e 's#/$##' | grep -v '^$' | sort -u
}

# Удаление временных контейнеров CH (по одному на ноду).
# Конвейер обёрнут в $( ... || true): при pipefail пустой вывод grep возвращает
# 1, и голый конвейер под set -e прервал бы скрипт.
_rm_temp_ch_containers() {
    local names n
    names=$(sudo docker ps -a --format '{{.Names}}' 2>/dev/null | grep -E "^${CH_TEMP_NAME}" || true)
    for n in ${names}; do
        sudo docker rm -f "${n}" >/dev/null 2>&1 || true
    done
}

# Свободное место в ГБ на файловой системе каталога. Если каталога ещё нет,
# проверяется ближайший существующий родитель.
_free_gb() {
    local dir="$1"
    while [ ! -d "${dir}" ] && [ "${dir}" != "/" ]; do dir=$(dirname "${dir}"); done
    df -PBG "${dir}" 2>/dev/null | awk 'NR==2 {gsub(/G/,"",$4); print $4+0}'
}

# Условия, без которых прогон бессмысленен. Проверяются до сбора данных.
# Под cron особенно важны первые две: без пароля sudo и без доступа к docker
# прогон падал бы на первом же шаге с невнятной ошибкой.
preflight_checks() {
    sudo -n true 2>/dev/null \
        || die "sudo требует пароль. Под cron это тупик: задание должно стоять в crontab пользователя root."

    docker info >/dev/null 2>&1 \
        || die "демон docker недоступен. Проверьте: sudo systemctl status docker"

    local free
    free=$(_free_gb "${BACKUP_DIR}")
    [ -n "${free}" ] || die "не удалось определить свободное место в ${BACKUP_DIR}"
    [ "${free}" -ge "${BACKUP_MIN_GB}" ] \
        || die "в ${BACKUP_DIR} свободно ${free}G, порог ${BACKUP_MIN_GB}G. Здесь собирается backup/ и складывается архив."
    log "место: ${BACKUP_DIR} - ${free}G"

    free=$(_free_gb "${CH_COPY_DIR}")
    [ -n "${free}" ] || die "не удалось определить свободное место для ${CH_COPY_DIR}"
    [ "${free}" -ge "${CH_COPY_MIN_GB}" ] \
        || die "для ${CH_COPY_DIR} свободно ${free}G, порог ${CH_COPY_MIN_GB}G. Сюда копируются данные ClickHouse со снапшота."
    log "место: ${CH_COPY_DIR} - ${free}G"
}

# Состояние снапшота. COW ограничен, и при переполнении LVM помечает снапшот
# недействительным: чтение с него даёт мусор или ошибки, а копия молча
# получается неполной. Поэтому состояние проверяется после копирования.
_snapshot_is_valid() {
    local attr used
    attr=$(sudo timeout 15 lvs --noheadings -o lv_attr "${VG_NAME}/${SNAP_NAME}" 2>/dev/null | tr -d ' ') || attr=""
    [ -n "${attr}" ] || return 1
    # Поля lv_attr: [0] тип тома, [4] состояние. 'S' в типе - недействительный
    # снапшот, 'I' или 'S' в состоянии - то же самое.
    case "${attr}" in S*) return 1 ;; esac
    case "${attr:4:1}" in I|S) return 1 ;; esac

    used=$(sudo timeout 15 lvs --noheadings -o data_percent "${VG_NAME}/${SNAP_NAME}" 2>/dev/null | tr -d ' ' | cut -d. -f1) || used=""
    case "${used}" in ''|*[!0-9]*) return 0 ;; esac
    [ "${used}" -lt 100 ] || return 1
    return 0
}

# Проверка условий для снапшота: том, диск под COW и место на нём.
# Каждый отказ описывается отдельно - "нет места" и "диска нет" лечатся
# по-разному. Вызывается в начале прогона, чтобы не выяснять это через час
# работы, и повторно перед созданием снапшота, чтобы взять свежий объём.
# Результат: SNAP_FREE_MB.
check_snapshot_prereqs() {
    local vg free_mb

    sudo timeout 15 lvs "${VG_NAME}/${LV_NAME}" >/dev/null 2>&1 \
        || die "нет логического тома ${VG_NAME}/${LV_NAME}, снимать снапшот не с чего.
     Список томов: sudo lvs"

    [ -b "${SNAP_PV}" ] \
        || die "диск ${SNAP_PV} под снапшот не найден.
     Список дисков: lsblk. Имя задаётся переменной SNAP_PV в начале скрипта."

    vg=$(sudo timeout 15 pvs --noheadings -o vg_name "${SNAP_PV}" 2>/dev/null | tr -d ' ') || vg=""
    [ -n "${vg}" ] \
        || die "${SNAP_PV} не является физическим томом LVM.
     Включить его в группу: sudo pvcreate ${SNAP_PV} && sudo vgextend ${VG_NAME} ${SNAP_PV}
     ВНИМАНИЕ: pvcreate стирает начало диска, сначала проверьте, что он пуст: sudo blkid ${SNAP_PV}"

    [ "${vg}" = "${VG_NAME}" ] \
        || die "${SNAP_PV} входит в группу '${vg}', а снапшот снимается с '${VG_NAME}'.
     Снапшот может занимать место только в своей группе."

    free_mb=$(sudo timeout 15 pvs --noheadings -o pv_free --units m "${SNAP_PV}" 2>/dev/null | tr -d ' m<' | cut -d. -f1) || free_mb=""
    case "${free_mb}" in
        ''|*[!0-9]*) die "не удалось определить свободное место на ${SNAP_PV}. Проверьте: sudo pvs ${SNAP_PV}" ;;
    esac
    [ "${free_mb}" -gt "${SNAP_MIN_MB}" ] \
        || die "на ${SNAP_PV} свободно ${free_mb}М, нужно больше ${SNAP_MIN_MB}М под COW снапшота.
     Освободить место в группе или добавить диск: sudo vgextend ${VG_NAME} <диск>"

    SNAP_FREE_MB="${free_mb}"
}

cleanup() {
    # Код возврата снимается первой же командой. Раньше сброс сигналов стоял в
    # самом обработчике EXIT, перед вызовом cleanup, и $? показывал результат
    # этого сброса, то есть всегда 0: прерванный прогон уходил в отчёт как
    # успешный.
    local rc=$?
    trap '' INT TERM
    log "очистка..."

    # Порядок важен: сначала быстрые операции, освобождающие место (копия данных
    # CH сопоставима по объёму с самой базой), затем снапшот - единственный шаг,
    # способный подвиснуть.
    _rm_temp_ch_containers
    sudo rm -rf /tmp/vis_ch_conf >/dev/null 2>&1 || true
    if [ "${CH_COPY_CREATED}" = "1" ] || [ -d "${CH_COPY_DIR}" ]; then
        log "  удаляю копию данных CH (${CH_COPY_DIR})"
        sudo rm -rf "${CH_COPY_DIR}" >/dev/null 2>&1 || true
    fi

    # Снапшот удаляется последним. umount на снапшоте, удерживаемом антивирусом,
    # может уйти в непрерываемый сон, где ограничение по времени не работает,
    # поэтому команды ручной уборки выводятся до попытки, а не после.
    if [ "${SNAP_CREATED}" = "1" ] || sudo timeout 15 lvs "${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1; then
        log "  удаляю снапшот. При зависании его можно снять вручную:"
        log "    sudo umount -l ${SNAP_MNT}; sudo lvremove -y ${VG_NAME}/${SNAP_NAME}"

        if [ "${SNAP_MOUNTED}" = "1" ] || timeout 10 mountpoint -q "${SNAP_MNT}" 2>/dev/null; then
            _umount_lazy "${SNAP_MNT}"
        fi
        if _remove_snapshot; then
            log "  снапшот удалён"
        else
            _snapshot_holders
            warn "СНАПШОТ ${VG_NAME}/${SNAP_NAME} ОСТАЛСЯ и продолжит копить COW."
            warn "  Снять вручную (командами выше). Следующий прогон бэкапа"
            warn "  без этого не начнётся: одноимённый снапшот создать нельзя."
        fi
    fi
    sudo rmdir "${SNAP_MNT}" >/dev/null 2>&1 || true

    if [ "${rc}" -ne 0 ]; then
        log "завершено с ошибкой (код ${rc})."
    fi

    # Письмо уходит последним: к этому моменту известны и код возврата, и
    # результат уборки - предупреждение об оставшемся снапшоте тоже попадёт в
    # отчёт.
    local nargs=(--rc "${rc}"
                 --started "${T_START_HUMAN}"
                 --elapsed-min "$(( ( $(date +%s) - t_start ) / 60 ))"
                 --notes-file "${NOTIFY_NOTES}")
    if [ -n "${NOTIFY_ARCHIVE}" ]; then
        nargs+=(--archive "${NOTIFY_ARCHIVE}")
    fi
    if [ -n "${NOTIFY_ARCHIVE_SIZE}" ]; then
        nargs+=(--archive-size "${NOTIFY_ARCHIVE_SIZE}")
    fi
    if [ "${CH_ONLY}" = "1" ]; then
        nargs+=(--mode "только ClickHouse (--ch-only)")
    fi
    # Успешным прогон считается только тогда, когда архив действительно собран.
    # Нулевой код сам по себе этого не доказывает: прогон могли прервать до
    # упаковки. Исключение - режим --ch-only, он архив и не собирает.
    if [ "${rc}" -eq 0 ] && { [ "${CH_ONLY}" = "1" ] || [ -s "${NOTIFY_ARCHIVE}" ]; }; then
        notify ok "${nargs[@]}"
    else
        if [ "${rc}" -eq 0 ]; then
            printf '%s\n' "ОШИБКА: архив не сформирован, хотя прогон завершился без кода ошибки" >> "${NOTIFY_NOTES}" 2>/dev/null || true
        fi
        notify fail "${nargs[@]}"
    fi
    rm -f "${NOTIFY_NOTES}" >/dev/null 2>&1 || true

    exit "${rc}"
}

trap cleanup EXIT
# Прерывание помечается в замечаниях: иначе в отчёте будет только код 130.
trap 'printf "%s\n" "ОШИБКА: прогон прерван сигналом (Ctrl+C или kill)" >> "${NOTIFY_NOTES}" 2>/dev/null; exit 130' INT TERM

# Ноды ClickHouse.
# Имена каталогов в архиве равны значениям CLICKHOUSE_HOSTS сервиса
# backup-service: штатный код формирует путь как <каталог>/<host>, поэтому
# "clickhouse-1" - сетевое имя хоста, а не порядковый номер ноды.
# Имя тома и узел Swarm, где нода работает, запрашиваются у Docker.
# Формат строки: <хост CH>|<сервис>|<том>|<узел Swarm>
detect_ch_nodes() {
    local bs hosts h svc vol node
    bs=$(docker ps --filter "name=${PROJECT}_backup-service" --format '{{.ID}}' 2>/dev/null | head -1) || bs=""
    if [ -n "${bs}" ]; then
        hosts=$(docker exec -i "${bs}" printenv CLICKHOUSE_HOSTS 2>/dev/null | tr -d '\r') || hosts=""
    else
        hosts=""
    fi
    if [ -z "${hosts}" ]; then
        # Резервный путь: перечисление сервисов CH. Имена каталогов совпадут с
        # именами сервисов, что верно для штатной установки.
        hosts=$(docker service ls --format '{{.Name}}' 2>/dev/null \
                 | grep -E "^${PROJECT}_clickhouse" \
                 | grep -viE 'jdbc|bridge|keeper|zookeeper' \
                 | sed "s/^${PROJECT}_//" | sort) || hosts=""
    fi
    for h in ${hosts}; do
        svc="${PROJECT}_${h}"
        vol=$(docker service inspect "${svc}" --format \
            '{{range .Spec.TaskTemplate.ContainerSpec.Mounts}}{{if eq .Target "/var/lib/clickhouse"}}{{.Source}}{{end}}{{end}}' 2>/dev/null) || vol=""
        node=$(docker service ps "${svc}" --filter desired-state=running --format '{{.Node}}' 2>/dev/null | head -1) || node=""
        printf '%s|%s|%s|%s\n' "${h}" "${svc}" "${vol}" "${node}"
    done
}

# Выгрузка одной ноды CH с готовой копии данных.
#   $1 - имя хоста CH, оно же имя каталога в архиве
#   $2 - каталог с копией данных
# Повторяет поведение штатного дампа: SHOW TABLES с отсевом jemalloc и
# cache_queries_, затем на каждый объект SHOW CREATE TABLE в sql/<имя>.sql и
# SELECT * FORMAT Native в data/<имя>. Исключений для представлений и словарей
# штатный дамп не делает.
_dump_ch_node() {
    local host="$1" copy_dir="$2"
    local cname="${CH_TEMP_NAME}_$(printf '%s' "${host}" | tr -c 'A-Za-z0-9_.-' '_')"
    local ch_conf_dir="/tmp/vis_ch_conf"

    log "  ${host}: временный CH (${CH_CPUS} ядер, ${CH_MEMORY})"
    sudo docker rm -f "${cname}" >/dev/null 2>&1 || true
    sudo docker run -d \
        --name "${cname}" \
        --user 101:101 \
        --cpus="${CH_CPUS}" --memory="${CH_MEMORY}" --cpu-shares="${CH_CPU_SHARES}" \
        -v "${copy_dir}:/var/lib/clickhouse" \
        -v "${ch_conf_dir}/zz-backup-quiet.xml:/etc/clickhouse-server/config.d/zz-backup-quiet.xml:ro" \
        --ulimit nofile=262144:262144 \
        -e CLICKHOUSE_SKIP_USER_SETUP=1 \
        "${CH_IMAGE}" >/dev/null
    CH_STARTED=1

    local ok=0 i
    for i in $(seq 1 90); do
        if sudo docker exec "${cname}" clickhouse-client --query "SELECT 1" >/dev/null 2>&1; then
            ok=1; break
        fi
        if ! sudo docker ps --format '{{.Names}}' | grep -q "^${cname}$"; then
            sudo docker logs "${cname}" 2>&1 | tail -20 | while IFS= read -r l; do log "      ${l}"; done
            die "${host}: временный CH упал при старте"
        fi
        sleep 2
    done
    [ "${ok}" = "1" ] || { sudo docker logs "${cname}" 2>&1 | tail -20; die "${host}: временный CH не поднялся"; }

    sudo docker exec "${cname}" clickhouse-client --query "SYSTEM STOP MERGES" >/dev/null 2>&1 || true
    sudo docker exec "${cname}" clickhouse-client --query "SYSTEM STOP MOVES"  >/dev/null 2>&1 || true
    sudo docker exec "${cname}" clickhouse-client --query "EXISTS DATABASE ${CH_DB}" | grep -q 1 \
        || die "${host}: временный CH не видит базу ${CH_DB}"

    # Имя каталога = имя хоста из CLICKHOUSE_HOSTS: именно его ищет restore
    # (Backuper.py: backup_dir = join(self.config.backup_dir, host)).
    local ch_base="${MAIN_BACKUP_DIR}/clickhouse/${host}"
    local sql_dir="${ch_base}/sql"
    local data_dir="${ch_base}/data"
    sudo mkdir -p "${sql_dir}" "${data_dir}"
    sudo chown -R "$(id -u):$(id -g)" "${MAIN_BACKUP_DIR}/clickhouse"

    local tables_file
    tables_file=$(mktemp)
    sudo docker exec "${cname}" clickhouse-client -d "${CH_DB}" -q "SHOW TABLES FORMAT TSVRaw" \
        | grep -v 'jemalloc' | grep -v '^cache_queries_' > "${tables_file}" || true
    local total
    total=$(wc -l < "${tables_file}")
    [ "${total}" -gt 0 ] || die "${host}: не получен список таблиц"
    log "  ${host}: объектов к выгрузке: ${total}"

    local err_dir
    err_dir=$(mktemp -d)
    export CH_DB sql_dir data_dir err_dir cname
    _dump_one() {
        local table="$1"
        [ -n "${table}" ] || return 0
        if ! sudo docker exec "${cname}" clickhouse-client -d "${CH_DB}" \
                -q "SHOW CREATE TABLE \"${table}\"" --format TabSeparatedRaw \
                > "${sql_dir}/${table}.sql" 2>"${err_dir}/${table}.err"; then
            rm -f "${sql_dir}/${table}.sql" "${data_dir}/${table}"; return 1
        fi
        if ! sudo docker exec "${cname}" clickhouse-client -d "${CH_DB}" \
                -q "SELECT * FROM \"${table}\" FORMAT Native" \
                > "${data_dir}/${table}" 2>>"${err_dir}/${table}.err"; then
            # .sql удаляется вместе с данными: иначе объект считался бы
            # выгруженным при отсутствующем файле данных.
            rm -f "${data_dir}/${table}" "${sql_dir}/${table}.sql"; return 1
        fi
        rm -f "${err_dir}/${table}.err"; return 0
    }
    export -f _dump_one

    xargs -P "${DUMP_PARALLEL}" -I {} bash -c '_dump_one "$@"' _ {} < "${tables_file}" || true

    # Штатный restore определяет имя таблицы как <файл>.split('.')[0], то есть
    # обрезает его по первой точке.
    local dotted
    dotted=$(grep -c '\.' "${tables_file}") || dotted=0
    [ "${dotted}" -eq 0 ] || warn "${host}: таблиц с точкой в имени: ${dotted} - штатный restore восстановит их под усечённым именем"

    local done_sql done_data failed_cnt
    done_sql=$(find "${sql_dir}" -type f -name '*.sql' | wc -l)
    done_data=$(find "${data_dir}" -type f | wc -l)
    failed_cnt=$(find "${err_dir}" -type f -name '*.err' | wc -l)
    log "  ${host}: sql ${done_sql}, data ${done_data}, ожидалось по ${total}"

    # Выгрузка идёт с замороженной копии, где таблицы не могут исчезнуть, в
    # отличие от штатного дампа с работающей базы. Любое расхождение здесь -
    # ошибка, а не гонка.
    if [ "${failed_cnt}" -gt 0 ] || [ "${done_sql}" -ne "${total}" ] || [ "${done_data}" -ne "${total}" ]; then
        warn "${host}: схем не хватает $(( total - done_sql )), данных $(( total - done_data )), ошибок: ${failed_cnt}"
        warn "${host}: не выгрузились (первые 20):"
        find "${err_dir}" -type f -name '*.err' -printf '%f\n' 2>/dev/null | head -20 \
            | while IFS= read -r f; do warn "    ${f%.err}"; done
        # Типичные причины: словари, для которых у временного сервера нет доступа
        # к источникам, и Distributed-таблицы, требующие конфигурации кластера.
        if [ "${ALLOW_PARTIAL_CH}" = "1" ]; then
            {
                echo "${host}: выгружено схем ${done_sql}, данных ${done_data} из ${total}"
                find "${err_dir}" -type f -name '*.err' -printf '%f\n' 2>/dev/null \
                    | while IFS= read -r f; do echo "  не выгружено: ${f%.err}"; done
            } >> "${MAIN_BACKUP_DIR}/CLICKHOUSE-PARTIAL.txt"
            warn "${host}: продолжаю по --allow-partial-clickhouse, список в CLICKHOUSE-PARTIAL.txt"
        else
            rm -rf "${err_dir}" "${tables_file}"
            die "${host}: ClickHouse выгружен не полностью.
     Если в списке выше словари или Distributed-таблицы - это ожидаемо:
     временный CH не имеет доступа к их источникам и к конфигу кластера,
     штатный дамп такие объекты тоже пропускает.
     Собрать архив с этим списком осознанно: $0 --allow-partial-clickhouse"
        fi
    fi

    rm -rf "${err_dir}" "${tables_file}"
    sudo docker rm -f "${cname}" >/dev/null 2>&1 || true
}

dump_clickhouse() {
    log "ClickHouse: опрос нод..."

    local -a nodes=()
    mapfile -t nodes < <(detect_ch_nodes)
    if [ ${#nodes[@]} -eq 0 ]; then
        warn "не удалось определить ноды CH, беру значения из конфигурации: ${CH_HOST_LABEL} / ${CH_VOLUME}"
        nodes=("${CH_HOST_LABEL}|${PROJECT}_${CH_HOST_LABEL}|${CH_VOLUME}|$(hostname)")
    fi

    # CLICKHOUSE_COUNT задаётся в defaults.env при горизонтальном масштабировании.
    if [ -n "${CLICKHOUSE_COUNT:-}" ] && [ "${CLICKHOUSE_COUNT}" != "${#nodes[@]}" ]; then
        warn "CLICKHOUSE_COUNT=${CLICKHOUSE_COUNT}, а хостов CH найдено: ${#nodes[@]}"
    fi

    local local_name
    local_name=$(docker info --format '{{.Name}}' 2>/dev/null) || local_name=""
    [ -n "${local_name}" ] || local_name=$(hostname)

    local -a locals=() remotes=()
    local line chost svc vol node
    for line in "${nodes[@]}"; do
        IFS='|' read -r chost svc vol node <<< "${line}"
        [ -n "${vol}" ] || die "не удалось определить том данных для сервиса ${svc}"
        if [ -n "${CH_ONLY_NODE}" ] && [ "${chost}" != "${CH_ONLY_NODE}" ]; then
            log "  ${chost}: пропущена по --ch-node ${CH_ONLY_NODE}"
            continue
        fi
        if [ -z "${node}" ] || [ "${node}" = "${local_name}" ] || [ "${node}" = "$(hostname)" ]; then
            locals+=("${chost}|${vol}")
            log "  ${chost}: сервис ${svc}, том ${vol} - локальная"
        else
            remotes+=("${chost}|${svc}|${node}")
            warn "${chost}: сервис ${svc} работает на хосте ${node} - LVM-снапшот отсюда её не видит"
        fi
    done

    [ ${#locals[@]} -gt 0 ] || die "нет ни одной локальной ноды ClickHouse для выгрузки"

    # Список каталогов базы запрашивается у РАБОТАЮЩЕГО сервера, до снапшота.
    # Пустой файл означает "копировать том целиком".
    local ch_paths_file live_cid first_host
    ch_paths_file=$(mktemp)
    if [ "${FULL_CH_COPY}" = "1" ]; then
        log "  --full-ch-copy: копирую том целиком"
    else
        IFS='|' read -r first_host _ <<< "${locals[0]}"
        live_cid=$(resolve_container "${PROJECT}_${first_host}") || live_cid=""
        if [ -n "${live_cid}" ] && ch_relative_paths "${live_cid}" > "${ch_paths_file}" 2>/dev/null; then
            log "  каталогов базы ${CH_DB} к копированию: $(wc -l < "${ch_paths_file}")"
        else
            : > "${ch_paths_file}"
            warn "не удалось получить список каталогов базы у ${PROJECT}_${first_host}, копирую том целиком"
        fi
    fi

    log "ClickHouse: снапшот и выгрузка (${#locals[@]} нод)..."

    _rm_temp_ch_containers
    if sudo timeout 15 lvs "${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1; then
        # Остатки прошлого прогона. Убрать обязательно: lvcreate с тем же именем
        # не пройдёт. Если снапшот держит антивирус, здесь можно подвиснуть -
        # тогда снимайте вручную и запускайте заново.
        warn "остался снапшот ${VG_NAME}/${SNAP_NAME} от прошлого прогона, убираю"
        warn "  если встанет надолго: sudo umount -l ${SNAP_MNT}; sudo lvremove -y ${VG_NAME}/${SNAP_NAME}"
        _umount_lazy "${SNAP_MNT}"; _remove_snapshot || true
    fi

    # Объём берётся заново: между стартом прогона и этим моментом место могло
    # уйти, например под сборку самого бэкапа.
    check_snapshot_prereqs
    log "  снапшот (COW ${SNAP_FREE_MB}M)"
    sudo lvcreate -s -n "${SNAP_NAME}" -L "${SNAP_FREE_MB}M" "${VG_NAME}/${LV_NAME}" "${SNAP_PV}"
    SNAP_CREATED=1

    sudo mkdir -p "${SNAP_MNT}"
    sudo mount -o ro "/dev/${VG_NAME}/${SNAP_NAME}" "${SNAP_MNT}"
    SNAP_MOUNTED=1

    # Копия данных снимается со снапшота, дальнейшая выгрузка работает с ней.
    # Снапшот один на все локальные ноды, поэтому срез одномоментен для всех
    # шардов. Копия каждой ноды удаляется сразу после её выгрузки, чтобы не
    # требовать места под все ноды одновременно.
    log "  копирую данные CH..."
    sudo rm -rf "${CH_COPY_DIR}"
    sudo mkdir -p "${CH_COPY_DIR}"
    CH_COPY_CREATED=1
    for line in "${locals[@]}"; do
        IFS='|' read -r chost vol <<< "${line}"
        local src="${SNAP_MNT}/var/lib/docker/volumes/${vol}/_data"
        [ -d "${src}" ] || die "${chost}: в снапшоте нет данных тома ${vol}"
        sudo mkdir -p "${CH_COPY_DIR}/${chost}"

        # Копируем только каталоги базы CH_DB, а не весь том: остальное - это
        # системные журналы сервера (query_log, trace_log и прочие), которые в
        # выгрузку не входят, а по объёму обычно многократно превосходят данные.
        # Временному серверу они не нужны, свою system он создаёт при старте.
        if [ -s "${ch_paths_file}" ]; then
            if sudo tar -C "${src}" --files-from="${ch_paths_file}" --ignore-failed-read -cf - 2>/dev/null \
                 | sudo tar -C "${CH_COPY_DIR}/${chost}" -xf -; then
                _prepare_ch_copy_dirs "${CH_COPY_DIR}/${chost}"
                log "  ${chost}: копия готова, только база ${CH_DB} ($(sudo du -sh "${CH_COPY_DIR}/${chost}" 2>/dev/null | cut -f1))"
                continue
            fi
            warn "${chost}: копирование по списку не удалось, копирую том целиком"
            sudo rm -rf "${CH_COPY_DIR:?}/${chost}"
            sudo mkdir -p "${CH_COPY_DIR}/${chost}"
        fi
        sudo cp -a "${src}/." "${CH_COPY_DIR}/${chost}/"
        _prepare_ch_copy_dirs "${CH_COPY_DIR}/${chost}"
        log "  ${chost}: копия готова, том целиком ($(sudo du -sh "${CH_COPY_DIR}/${chost}" 2>/dev/null | cut -f1))"
    done

    # Снапшот проверяется до того, как копия пойдёт в дело: при переполнении COW
    # LVM помечает его недействительным, и скопированные данные окажутся
    # неполными без единой ошибки при копировании.
    if ! _snapshot_is_valid; then
        die "снапшот ${VG_NAME}/${SNAP_NAME} стал недействителен во время копирования (переполнен COW).
     Копия данных ClickHouse неполна, архив собирать нельзя.
     Увеличьте свободное место на ${SNAP_PV} или запускайте бэкап при меньшей нагрузке на запись."
    fi

    # Точка монтирования больше не нужна и отцепляется сразу, но в фоне: umount
    # на снапшоте, удерживаемом антивирусом, может уйти в непрерываемый сон, где
    # ограничение по времени не работает. Обработчики внутри подшелла сброшены,
    # иначе cleanup выполнился бы в фоне. Сам снапшот удаляет cleanup в конце.
    log "  отцепляю ${SNAP_MNT} в фоне; снапшот удаляется в конце прогона"
    ( trap - EXIT INT TERM; _umount_lazy "${SNAP_MNT}" ) >/dev/null 2>&1 &
    disown 2>/dev/null || true

    # Системные лог-таблицы отключаются, чтобы временный сервер не расходовал
    # ресурсы и не увеличивал копию данных.
    local ch_conf_dir="/tmp/vis_ch_conf"
    sudo rm -rf "${ch_conf_dir}"
    sudo mkdir -p "${ch_conf_dir}"
    sudo tee "${ch_conf_dir}/zz-backup-quiet.xml" >/dev/null <<'XMLEOF'
<clickhouse>
    <text_log remove="1"/>
    <metric_log remove="1"/>
    <asynchronous_metric_log remove="1"/>
    <query_log remove="1"/>
    <query_thread_log remove="1"/>
    <query_views_log remove="1"/>
    <part_log remove="1"/>
    <trace_log remove="1"/>
    <session_log remove="1"/>
    <crash_log remove="1"/>
    <processors_profile_log remove="1"/>
    <opentelemetry_span_log remove="1"/>
    <backup_log remove="1"/>
    <blob_storage_log remove="1"/>
    <logger>
        <level>error</level>
        <console>0</console>
    </logger>
</clickhouse>
XMLEOF

    # Права задаются явно, а не наследуются от umask: временный сервер работает
    # под пользователем 101 и должен прочитать этот файл. На стенде со строгим
    # umask (077) tee создаёт его с правами 600, и сервер падает при старте с
    # "Failed to merge config ... Access to file denied".
    sudo chmod 755 "${ch_conf_dir}"
    sudo chmod 644 "${ch_conf_dir}/zz-backup-quiet.xml"

    for line in "${locals[@]}"; do
        IFS='|' read -r chost vol <<< "${line}"
        _dump_ch_node "${chost}" "${CH_COPY_DIR}/${chost}"
        # копию удаляем сразу - на многонодовой установке иначе нужен суммарный объём
        sudo rm -rf "${CH_COPY_DIR:?}/${chost}" >/dev/null 2>&1 || true
    done

    rm -f "${ch_paths_file}"

    if [ ${#remotes[@]} -gt 0 ]; then
        local r rhost rsvc rnode
        for r in "${remotes[@]}"; do
            IFS='|' read -r rhost rsvc rnode <<< "${r}"
            if [ "${ALLOW_PARTIAL_CH}" = "1" ]; then
                echo "нода ${rhost} (${rsvc}) на хосте ${rnode} в архив НЕ попала" >> "${MAIN_BACKUP_DIR}/CLICKHOUSE-PARTIAL.txt"
            fi
        done
        if [ "${ALLOW_PARTIAL_CH}" = "1" ]; then
            warn "ClickHouse выгружен частично, см. ${MAIN_BACKUP_DIR}/CLICKHOUSE-PARTIAL.txt"
        else
            die "нод ClickHouse на других хостах: ${#remotes[@]}.
     Скрипт снимает LVM-снапшот ЛОКАЛЬНОГО корня и чужие ноды снять не может.
     Данные CH шардированы: архив без них будет неполным, а выглядеть будет успешным.
     Варианты:
       1) запустить скрипт на каждом хосте с --ch-only --ch-node <имя> и
          объединить каталоги backup/clickhouse/<имя> в один архив;
       2) осознанно собрать неполный архив: $0 --allow-partial-clickhouse"
        fi
    fi
}

########################################
# MAIN
########################################
log "=== СТАРТ полного бэкапа Visiology ==="

# Условия для снапшота проверяются до сбора данных: отказ на этом шаге
# обесценивает весь прогон, а выясняется он иначе только через час работы.
preflight_checks
check_snapshot_prereqs
log "снапшот: ${SNAP_PV} в группе ${VG_NAME}, свободно ${SNAP_FREE_MB}M"

if [ "${CH_ONLY}" = "1" ]; then
    # Режим дополнительного хоста CH: каталог backup/ не очищается, собирается
    # только ClickHouse - остальных сервисов на таком хосте нет.
    log "режим --ch-only: только ClickHouse"
    mkdir -p "${MAIN_BACKUP_DIR}"
else

rm -rf "${MAIN_BACKUP_DIR:?}"/*
mkdir -p "${MAIN_BACKUP_DIR}"
echo "${COMMAND_LINE}" > "${MAIN_BACKUP_DIR}/${COMMAND_FILE}"

log "backup-service: postgres, smartforms (без clickhouse)..."
container_id=$(require_container "${PROJECT}_backup-service" "backup-service")

# Код ответа проверяется явно. Без этого любая внутренняя ошибка сервиса, а он
# отдаёт на них 500, прошла бы незамеченной: curl без -f считает такой ответ
# успехом, и архив собрался бы без баз, отчитавшись успешным прогоном.
bs_code=$(docker exec "${container_id}" curl -sL -o /dev/null -w '%{http_code}' \
    --request POST --url http://127.0.0.1:8000 \
    --header 'Content-Type: application/json' \
    --data '{"command":"backup","databases":["postgres", "smartforms"],"is_cleanup":true}') || bs_code=""
case "${bs_code}" in
    2??) ;;
    "")  die "backup-service не ответил. Журнал: docker service logs --tail 50 ${PROJECT}_backup-service" ;;
    *)   die "backup-service вернул код ${bs_code}, дамп баз не выполнен.
     Журнал: docker service logs --tail 50 ${PROJECT}_backup-service" ;;
esac

# Ответ 200 сам по себе не доказывает, что файлы появились.
for _d in postgres smartforms; do
    [ -d "${MAIN_BACKUP_DIR}/${_d}" ] && [ -n "$(ls -A "${MAIN_BACKUP_DIR}/${_d}" 2>/dev/null)" ] \
        || die "backup-service отчитался успехом, но ${MAIN_BACKUP_DIR}/${_d} пуст"
done
unset _d
log "  postgres и smartforms выгружены"

log "custom scripts..."
mkdir -p "${DV_CUSTOM_SCRIPTS_HOST_PATH}"
cp -ra "${DV_CUSTOM_SCRIPTS_CONTAINER_PATH}" "${DV_CUSTOM_SCRIPTS_HOST_PATH}"

log "extended services, env, configs..."
cp -ra "${EXTENDED_SERVICES_PATH}" "${MAIN_BACKUP_DIR}/${EXTENDED_SERVICES_PATH}"
cp -ra "${ENV_FILES_PATH}"         "${MAIN_BACKUP_DIR}/${ENV_FILES_PATH}"
cp -ra "${CUSTOM_CONFIGS_PATH}"    "${MAIN_BACKUP_DIR}/${CUSTOM_CONFIGS_PATH}"

log "minio..."
mkdir -p "${MN_FILES_HOST_PATH}"
minio_container_id=$(require_container "${PROJECT}_minio" "minio")
if docker exec "${minio_container_id}" test -d "${MN_FILES_CONTAINER_PATH}/dev"; then
    docker cp "${minio_container_id}":${MN_FILES_CONTAINER_PATH}/dev "${MN_FILES_HOST_PATH}"
fi
if docker exec "${minio_container_id}" test -d "${MN_FILES_CONTAINER_PATH}/permanent"; then
    docker cp "${minio_container_id}":${MN_FILES_CONTAINER_PATH}/permanent "${MN_FILES_HOST_PATH}"
fi

log "секреты..."
mkdir -p "${SECRETS_FILES_HOST_PATH}"

# dm-secret (DATA_MANAGEMENT_SECRET_KEY)
dms_container_id=$(resolve_container "${PROJECT}_data-management-service") || true
if [ -n "${dms_container_id}" ]; then
    copy_secret_file "${dms_container_id}" DATA_MANAGEMENT_SECRET_KEY "${SECRETS_FILES_HOST_PATH}/dm-secret.txt"
    log "  dm-secret сохранён"
else
    log "  ! data-management-service не найден, dm-secret пропущен"
fi

# ai-secret (AI_API_KEY)
ai_agent_container_id=$(resolve_container "${PROJECT}_ai-agent") || true
if [ -n "${ai_agent_container_id}" ]; then
    copy_secret_file "${ai_agent_container_id}" AI_API_KEY "${SECRETS_FILES_HOST_PATH}/ai-secret.txt"
    log "  ai-secret сохранён"
else
    log "  ! ai-agent не найден, ai-secret пропущен"
fi

# onec-secret (ONEC_CONNECTOR_FERNET)
onec_container_id=$(resolve_container "${PROJECT}_onec-connector.1") || true
if [ -n "${onec_container_id}" ]; then
    copy_secret_file "${onec_container_id}" ONEC_CONNECTOR_FERNET "${SECRETS_FILES_HOST_PATH}/onec-secret.txt"
    log "  onec-secret сохранён"
else
    log "  ! onec-connector не найден, onec-secret пропущен"
fi

fi   # конец блока, пропускаемого при --ch-only

dump_clickhouse

if [ "${CH_ONLY}" = "1" ]; then
    t_end=$(date +%s)
    log "=== ГОТОВО за ~$(( (t_end - t_start) / 60 )) мин (только ClickHouse) ==="
    log "Каталоги: ${MAIN_BACKUP_DIR}/clickhouse/"
    log "Перенесите их на основной хост в ту же папку и упакуйте вместе с остальным бэкапом."
    exit 0
fi

archive_name="$(hostname)-backup-v${VERSION}-$(date '+%Y-%m-%d-%H-%M-%S').tar.gz"
backup_file_dir=$(dirname "$(readlink -f "${BACKUP_DIR}/${archive_name}")")
log "упаковка (${COMPRESSOR%% *})..."
sudo tar -cf - -C "${backup_file_dir}" backup | ${COMPRESSOR} > "${backup_file_dir}/${archive_name}"
NOTIFY_ARCHIVE="${backup_file_dir}/${archive_name}"
NOTIFY_ARCHIVE_SIZE=$(sudo du -h "${NOTIFY_ARCHIVE}" 2>/dev/null | cut -f1) || NOTIFY_ARCHIVE_SIZE=""
# Содержимое backup/ полностью повторяет собранный архив и занимает столько же
# места. Восстановление в нём не нуждается: restore.sh распаковывает архив
# заново. При аварии до этой точки каталог остаётся нетронутым для разбора.
freed=$(sudo du -sh "${MAIN_BACKUP_DIR}" 2>/dev/null | cut -f1) || freed=""
sudo rm -rf "${MAIN_BACKUP_DIR:?}"/*
log "каталог ${MAIN_BACKUP_DIR} очищен${freed:+, освобождено ${freed}}"

t_end=$(date +%s)
elapsed=$(( (t_end - t_start) / 60 ))
log "=== ГОТОВО за ~${elapsed} мин ==="
log "Архив: ${NOTIFY_ARCHIVE} (${NOTIFY_ARCHIVE_SIZE:-размер не определён})"
