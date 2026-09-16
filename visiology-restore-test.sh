#!/bin/bash
#
# visiology-restore-test.sh - разворачивает последнюю резервную копию и
# проверяет, что платформа после этого действительно работает.
#
# Для восстановления скрипт должен лежать рядом со штатным restore.sh - он
# вызывает его из своего каталога. Для одних только проверок (--tests-only)
# место не имеет значения: config.env и defaults.env читаются, если лежат
# рядом, а без них берутся значения по умолчанию, одинаковые на всех контурах.
#
# Зачем это нужно отдельным скриптом. Штатный restore.sh не проверяет результат
# вообще: в нём нет set -e, у curl к backup-service нет ключа -f, а код возврата
# этого curl нигде не читается. Строка "Restore completed successfully!" стоит в
# самом конце и печатается безусловно. То есть ответ 500 от backup-service -
# ровно та авария, из-за которой не поднимаются Hangfire и ClickHouse, -
# проходит молча и выглядит как успех. Здесь вывод restore.sh разбирается и
# состояние платформы проверяется независимо.
#
# Перед восстановлением прикладные службы гасятся, после - поднимаются с
# прежним числом реплик. Штатный restore.sh этого не делает, и платформа
# продолжает писать в базы, пока их наполняет pg_restore.
#
# Проверки: службы Swarm, состояние healthcheck контейнеров, живость и
# наполнение Postgres и ClickHouse, отклик платформы по HTTP и - если задан
# --login-user - вход пользователя с получением настоящего токена.
#
# Коды возврата: 0 - всё прошло, 1 - есть отказавшие проверки, 2 - ошибка
# запуска (не найден архив, отказ восстановления).
#
# set -e намеренно не включён. Скрипт-проверяльщик обязан дойти до конца и
# сообщить обо всех отказах сразу, а не падать на первом.
set -o pipefail

SCRIPT_DIR=$( dirname -- "$( readlink -f -- "$0")")
LOG_TAG="[restore-test]"

########################################
# Значения по умолчанию
########################################
# Файл состояния прошлого прогона: счётчики таблиц, чтобы было видно, как
# изменилось наполнение баз между восстановлениями. Лежит вне каталога
# платформы, чтобы не попадаться под чужие очистки.
STATE_FILE="/var/tmp/visiology-restore-test.state"

# Сколько ждать, пока службы поднимутся после восстановления, секунд.
WAIT_SERVICES=900
# Предел на один HTTP-запрос, секунд.
HTTP_TIMEOUT=15
# Во сколько раз свободного места должно быть больше размера архива.
# Восстановление распаковывает рядом каталог примерно того же объёма.
SPACE_FACTOR_X10=25

# Запасной путь к Keycloak, если платформа не сообщила свой. Обычно он не
# нужен: фактический адрес читается из переменных окружения служб.
KEYCLOAK_PREFIX="/v3/keycloak"
# Клиент и набор прав для проверки входа - как в рабочем примере получения
# токена. Прямой вход по логину и паролю у этого клиента разрешён, браузер не
# нужен.
LOGIN_CLIENT="visiology_designer"
LOGIN_SCOPE="openid data_management_service formula_engine workspace_service dashboard_service forms_service groups"

# Гасить ли прикладные службы на время восстановления. По умолчанию да.
#
# Штатный restore.sh этого не делает: платформа продолжает писать в базы, пока
# pg_restore их наполняет. Отсюда нарушения внешних ключей Hangfire и
# недовосстановленные таблицы ClickHouse при внешне успешном прогоне.
#
# Поведение вендора возвращается ключом --no-stop-services - он нужен, чтобы
# воспроизвести поломку намеренно и сравнить два прогона на одном архиве.
STOP_SERVICES=1

# Службы, которые остаются работать при --stop-services. Это слой данных (без
# него восстанавливать некуда), сама машинерия восстановления и наблюдение,
# которое в базы платформы не пишет. Сопоставление по вхождению подстроки.
KEEP_RUNNING="postgres clickhouse smart-forms-db etl-db minio backup-service jdbc-bridge cadvisor node-exporter otelcol promtail prometheus loki tempo"

# Здесь запоминается, сколько реплик было у каждой погашенной службы.
SERVICES_STATE_FILE="/var/tmp/visiology-restore-test.services"

# Службы, по которым судят о готовности платформы. Ждать все подряд
# бессмысленно: одна вечно лежащая второстепенная служба задержала бы прогон на
# весь отведённый срок, ничего при этом не значая. Если поднялись эти - система
# встала. Остальные всё равно попадут в отчёт проверками, просто их не ждут.
ESSENTIAL_SERVICES="postgres clickhouse keycloak edge backup-service dashboard-service dashboard-viewer visiology-designer workspace-service formula-engine data-management-service smart-forms"

# Службы, которые не проверяются: отключены осознанно и их состояние ни о чём
# не говорит. Список через запятую, имена без префикса проекта.
IGNORE_SERVICES=""

LOGIN_USER=""
LOGIN_PASSWORD=""
PASSWORD_FILE=""

# Выполнять ли после восстановления цикл, которого требует сам restore.sh:
# остановка платформы, перегенерация конфигураций, запуск. Без него платформа
# работает на прежних настройках, а восстановленные файлы лежат неприменёнными -
# сколько ни жди, штатной работы не будет.
APPLY_CONFIGS=1

# Отправлять ли отчёт по почте и откуда брать настройки. Файл тот же, что у
# бэкапа: держать два файла с одними и теми же параметрами SMTP - значит
# однажды поправить один и забыть другой.
SEND_MAIL=1
TEST_MAIL=0
MAIL_ENV="${MAIL_ENV:-/etc/visiology-backup.env}"

# Оставить распакованный каталог после прогона. Нужен разве что для разбора.
KEEP_BACKUP_DIR=0

ARCHIVE=""
DO_RESTORE=1
DO_TESTS=1
ASSUME_YES=0
HTTP_URL=""
ANY_VERSION=0
EXTRA_ARGS=()

########################################
# Вывод
########################################
log()  { echo "$(date '+%F %T') ${LOG_TAG} $*"; }
warn() { echo "$(date '+%F %T') ${LOG_TAG} ВНИМАНИЕ: $*"; }
die()  { echo "$(date '+%F %T') ${LOG_TAG} ОШИБКА: $*" >&2; exit 2; }

# Счётчики проверок. Отказ одной проверки не прерывает остальные: смысл прогона
# в полной картине, а не в первом отличии.
CHECKS_OK=0
CHECKS_FAIL=0
CHECKS_WARN=0
FAILED_LIST=()

check_ok()   { CHECKS_OK=$((CHECKS_OK + 1));   echo "    [ ОК ]     $*"; }
check_warn() { CHECKS_WARN=$((CHECKS_WARN + 1)); echo "    [ ! ]      $*"; }
check_fail() {
    CHECKS_FAIL=$((CHECKS_FAIL + 1))
    FAILED_LIST+=("$*")
    echo "    [ОТКАЗ]    $*"
}

print_help() {
    cat <<'HELP'
Использование: visiology-restore-test.sh [ключи] [-- ключи для restore.sh]

  -h, --help          эта справка
  -d, --debug         трассировка выполнения
      --archive ПУТЬ  развернуть конкретный архив вместо самого свежего
      --tests-only    не разворачивать, только проверить платформу
      --restore-only  развернуть и выйти, проверки не запускать
      --yes           не спрашивать подтверждения (для неинтерактивного запуска)
      --any-version   развернуть архив от другой версии платформы
                      несовпадение станет замечанием вместо отказа
      --url АДРЕС     базовый адрес для HTTP-проверок
                      по умолчанию 127.0.0.1, сначала https, затем http
      --wait СЕК      сколько ждать подъёма служб после восстановления
                      по умолчанию 900
      --no-stop-services  не гасить службы перед восстановлением, как это
                      делает штатный restore.sh. По умолчанию прикладные службы
                      гасятся и поднимаются после: пока они работают, платформа
                      пишет в базы во время восстановления
      --stop-services гасить службы (поведение по умолчанию, ключ оставлен
                      для явности)
      --keep-running СПИСОК  что не гасить, через запятую; по умолчанию базы,
                      backup-service и службы наблюдения
      --no-apply-configs  не выполнять после восстановления остановку
                      платформы, перегенерацию конфигураций и запуск. По
                      умолчанию они выполняются - этого требует сам restore.sh,
                      и без них платформа остаётся на прежних настройках
      --no-mail       не отправлять отчёт по почте
      --test-mail     отправить проверочное письмо и выйти
      --keep-backup-dir   не чистить распакованный каталог после прогона
      --essential СПИСОК  по каким службам судить о готовности платформы,
                      через запятую. Остальных не ждут, но проверяют
      --ignore СПИСОК не проверять эти службы, через запятую и без префикса
                      проекта: --ignore prometheus,grafana
      --login-user ИМЯ    проверить, что этот пользователь может войти
      --password-file ПУТЬ  файл с его паролем, первая строка

Проверка входа выполняется, только если задан --login-user. Пароль берётся из
файла, из переменной окружения VIS_PASSWORD или спрашивается с клавиатуры.
Аргументом командной строки пароль не принимается: аргументы процесса видны в
выводе ps любому пользователю системы.

Всё, что указано после --, передаётся штатному restore.sh без изменений:

  visiology-restore-test.sh -- --with-custom-settings false

Архив ищется в каталоге скрипта, в BACKUP_DIR платформы и в подкаталогах
первого уровня в обоих. Берётся самый свежий по метке времени в имени.
HELP
}

########################################
# Разбор аргументов
########################################
while [ "$1" != "" ]; do
    case "$1" in
        -h|--help)     print_help; exit 0 ;;
        -d|--debug)    set -x ;;
        --archive)     shift; ARCHIVE="$1" ;;
        --tests-only)  DO_RESTORE=0 ;;
        --restore-only) DO_TESTS=0 ;;
        --yes)         ASSUME_YES=1 ;;
        --any-version) ANY_VERSION=1 ;;
        --url)         shift; HTTP_URL="$1" ;;
        --wait)        shift; WAIT_SERVICES="$1" ;;
        --stop-services) STOP_SERVICES=1 ;;
        --no-stop-services) STOP_SERVICES=0 ;;
        --keep-running) shift; KEEP_RUNNING=$(printf '%s' "$1" | tr ',' ' ') ;;
        --no-apply-configs) APPLY_CONFIGS=0 ;;
        --no-mail)     SEND_MAIL=0 ;;
        --test-mail)   TEST_MAIL=1 ;;
        --keep-backup-dir) KEEP_BACKUP_DIR=1 ;;
        --essential)   shift; ESSENTIAL_SERVICES=$(printf '%s' "$1" | tr ',' ' ') ;;
        --ignore)      shift; IGNORE_SERVICES="$1" ;;
        --login-user)  shift; LOGIN_USER="$1" ;;
        --password-file) shift; PASSWORD_FILE="$1" ;;
        --)            shift; EXTRA_ARGS=("$@"); break ;;
        *)             echo "Неизвестный ключ: $1" >&2; print_help; exit 2 ;;
    esac
    shift
done

########################################
# Настройки платформы
########################################
# Если рядом лежат config.env и defaults.env платформы - берём значения оттуда.
# Так их не приходится дублировать, и они не разойдутся с тем, чем пользуются
# сами backup.sh и restore.sh.
#
# Но обязательными эти файлы не сделаны. Все нужные значения либо одинаковы на
# всех контурах, либо определяются на месте, поэтому проверки можно гонять и с
# копии скрипта, лежащей где угодно. Требовать конфигурацию платформы ради
# пяти известных строк значило бы придумать себе лишний повод для отказа.
if [ -f "${SCRIPT_DIR}/config.env" ]; then
    # В config.env есть своя переменная SCRIPT_DIR со значением "." - вендорские
    # скрипты переходят в свой каталог и пользуются ей как точкой отсчёта. При
    # чтении настроек она затирает нашу, и скрипт начинает считать, что лежит
    # в текущем каталоге: ищет там restore.sh, env-files и архивы. Поэтому
    # собственное значение сохраняется и возвращается после чтения.
    _SELF_DIR="${SCRIPT_DIR}"
    pushd "${SCRIPT_DIR}" >/dev/null || die "не удалось перейти в ${SCRIPT_DIR}"
    # shellcheck disable=SC1091
    source config.env
    # shellcheck disable=SC1091
    [ -f defaults.env ] && source defaults.env
    popd >/dev/null || true
    SCRIPT_DIR="${_SELF_DIR}"
    unset _SELF_DIR
else
    log "config.env рядом не найден, беру значения по умолчанию"
fi

########################################
# Настройки почты
########################################
# Файл разбирается построчно, а не через source: значение с пробелом - список
# получателей через ", " - bash попытался бы выполнить как команду, а сам файл
# настроек получил бы право запускать что угодно. Берём только ключи почты:
# остальное этому скрипту не нужно.
if [ -r "${MAIL_ENV}" ]; then
    while IFS= read -r _line || [ -n "${_line}" ]; do
        _line="${_line%$'\r'}"
        case "${_line}" in ''|'#'*) continue ;; esac
        _key="${_line%%=*}"
        _val="${_line#*=}"
        case "${_key}" in
            MAIL_TO|MAIL_FROM|SMTP_HOST|SMTP_PORT|SMTP_USE_TLS|SMTP_USE_SSL|SMTP_SKIP_VERIFY|SMTP_USER|SMTP_PASSWORD) ;;
            *) continue ;;
        esac
        case "${_val}" in
            \"*\") _val="${_val#\"}"; _val="${_val%\"}" ;;
            \'*\') _val="${_val#\'}"; _val="${_val%\'}" ;;
        esac
        printf -v "${_key}" '%s' "${_val}"
    done < "${MAIL_ENV}"
    unset _line _key _val
fi

: "${MAIL_TO:=}"
: "${MAIL_FROM:=visiology-restore-test@localhost}"
: "${SMTP_HOST:=localhost}"
: "${SMTP_PORT:=25}"
: "${SMTP_USE_TLS:=false}"
: "${SMTP_USE_SSL:=false}"
: "${SMTP_SKIP_VERIFY:=true}"
: "${SMTP_USER:=}"
: "${SMTP_PASSWORD:=}"

# Путь к журналу нужен письму, чтобы приложить последние строки при аварии. Под
# cron поток вывода перенаправлен в файл, и его имя видно через /proc. Дескриптор
# сначала дублируется: внутри подстановки команд fd 1 - это её труба, а не файл.
exec 8>&1
LOG_PATH=$(readlink -f /proc/self/fd/8 2>/dev/null) || LOG_PATH=""
exec 8>&-
[ -f "${LOG_PATH}" ] || LOG_PATH=""

# Имя стека спрашиваем у самого docker: он знает его точно, а совпадение с
# config.env не гарантировано, если стек переименовывали.
if [ -z "${PROJECT}" ]; then
    PROJECT=$(sudo docker service ls --format '{{.Name}}' 2>/dev/null \
              | grep -m1 '_' | cut -d_ -f1)
    [ -n "${PROJECT}" ] && log "имя стека определено по docker: ${PROJECT}"
fi

: "${PROJECT:=visiology3}"
: "${CH_DB:=visiology}"
# Так же, как в backup.sh: из конфигов, иначе то же запасное значение. Архивы
# именуются этой величиной, поэтому сверка имеет смысл только при совпадающем
# источнике.
VERSION="${VI_VERSION:-3.16.1}"
RESTORE_SH="${SCRIPT_DIR}/restore.sh"

# Без BACKUP_DIR ищем архив там, где лежим.
[ -n "${BACKUP_DIR}" ] || BACKUP_DIR="${SCRIPT_DIR}"

# В config.env пути заданы относительно: BACKUP_DIR=. означает "каталог
# скрипта", потому что вендорские скрипты переходят в него перед работой. Мы же
# настройки читаем и возвращаемся обратно, поэтому точку нужно раскрыть явно -
# иначе она укажет на каталог, откуда запустили, и проверки места, поиск архива
# и очистка будут работать не там.
case "${BACKUP_DIR}" in
    /*) ;;
    *)  BACKUP_DIR="${SCRIPT_DIR}/${BACKUP_DIR}" ;;
esac
BACKUP_DIR=$(readlink -f -- "${BACKUP_DIR}" 2>/dev/null || printf '%s' "${BACKUP_DIR}")

# Пароль для проверки входа. Три источника, по убыванию удобства для расписания:
# файл, окружение, клавиатура. Аргументом командной строки пароль не
# принимается - аргументы процесса видны в выводе ps любому пользователю.
if [ -n "${LOGIN_USER}" ]; then
    if [ -n "${PASSWORD_FILE}" ]; then
        [ -r "${PASSWORD_FILE}" ] || die "файл с паролем недоступен для чтения: ${PASSWORD_FILE}"
        # Права проверяем, но не правим: файл чужой, и молча менять на него
        # права - хуже, чем предупредить.
        _pmode=$(stat -c %a -- "${PASSWORD_FILE}" 2>/dev/null)
        case "${_pmode}" in
            600|400) ;;
            *) warn "у ${PASSWORD_FILE} права ${_pmode}, пароль доступен посторонним. Нужно: chmod 600" ;;
        esac
        LOGIN_PASSWORD=$(head -n1 -- "${PASSWORD_FILE}" | tr -d '\r\n')
    elif [ -n "${VIS_PASSWORD}" ]; then
        LOGIN_PASSWORD="${VIS_PASSWORD}"
    elif [ -t 0 ]; then
        printf "Пароль для %s: " "${LOGIN_USER}" >&2
        read -r -s LOGIN_PASSWORD
        printf "\n" >&2
    fi
    [ -n "${LOGIN_PASSWORD}" ] \
        || die "для проверки входа нужен пароль ${LOGIN_USER}: --password-file, VIS_PASSWORD или ввод с клавиатуры"
fi

########################################
# Вспомогательное
########################################
# Имя контейнера службы в Swarm: <служба>.<слот>.<идентификатор>. Точка после
# имени службы обязательна в шаблоне, иначе фильтр по "..._postgres" поймает и
# "..._postgres-visiology", и проверяться будет не та база.
# Переменные окружения всех служб платформы одним вызовом. Перебор служб по
# одной занимал бы секунды: их два с половиной десятка.
_platform_env() {
    local ids
    ids=$(sudo docker service ls -q --filter "name=${PROJECT}_" 2>/dev/null | tr '\n' ' ')
    [ -n "${ids}" ] || return 1
    # shellcheck disable=SC2086
    sudo timeout 30 docker service inspect ${ids} \
        --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' 2>/dev/null
}

# Значение переменной из окружения служб платформы.
_platform_env_value() {
    printf '%s\n' "${PLATFORM_ENV}" | sed -n "s/^$1=//p" | head -1 | tr -d '\r'
}

resolve_container() {
    sudo docker ps --filter "name=^$1\\." --format '{{.ID}}' 2>/dev/null | head -1
}

# Все контейнеры платформы, чьё имя начинается с указанного шаблона.
# Возвращает строки "идентификатор имя-службы". Узлов может быть несколько:
# ClickHouse у вас развёрнут как clickhouse-1, баз Postgres тоже больше одной.
_containers_like() {
    local id name
    for id in $(sudo docker ps --filter "name=^$1" --format '{{.ID}}' 2>/dev/null); do
        name=$(sudo docker inspect --format '{{.Name}}' "${id}" 2>/dev/null | sed 's|^/||')
        # Из "visiology3_clickhouse-1.1.abc" оставляем "visiology3_clickhouse-1"
        printf '%s %s\n' "${id}" "${name%%.*}"
    done
}

# Значение переменной из окружения контейнера.
#
# Образы баз принимают учётные данные двумя способами: прямо в переменной либо
# через переменную с суффиксом _FILE, где лежит путь к файлу с секретом -
# именно так их и подкладывает Swarm. Поэтому обычных POSTGRES_USER и
# POSTGRES_PASSWORD в окружении может не быть вовсе, а быть POSTGRES_USER_FILE.
_container_value() {
    local cid="$1"; shift
    local k v path env_dump secrets
    env_dump=$(sudo timeout 10 docker inspect \
        --format '{{range .Config.Env}}{{println .}}{{end}}' "${cid}" 2>/dev/null)
    # Список секретов берём один раз: обращение в контейнер небесплатно, а
    # ключей проверяется несколько.
    secrets=$(sudo timeout 10 docker exec "${cid}" sh -c 'ls -1 /run/secrets/ 2>/dev/null' 2>/dev/null)

    for k in "$@"; do
        v=$(printf '%s\n' "${env_dump}" | sed -n "s/^${k}=//p" | head -1 | tr -d '\r')
        [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }

        path=$(printf '%s\n' "${env_dump}" | sed -n "s/^${k}_FILE=//p" | head -1 | tr -d '\r')
        if [ -n "${path}" ]; then
            v=$(sudo timeout 10 docker exec "${cid}" cat -- "${path}" 2>/dev/null \
                | head -1 | tr -d '\r\n')
            [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
        fi

        # Swarm монтирует секреты в /run/secrets под их собственными именами.
        # Переменной, указывающей на них, может не быть вовсе - тогда остаётся
        # только совпадение имени секрета с именем искомой настройки.
        if printf '%s\n' "${secrets}" | grep -qxF -- "${k}" 2>/dev/null; then
            v=$(sudo timeout 10 docker exec "${cid}" cat -- "/run/secrets/${k}" 2>/dev/null \
                | head -1 | tr -d '\r\n')
            [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
        fi
    done
    return 1
}

# То же, но с продолжением поиска в env-files платформы - каталоге, который
# backup.sh складывает в архив.
_find_env_value() {
    local cid="$1"; shift
    local k v

    v=$(_container_value "${cid}" "$@") && { printf '%s' "${v}"; return 0; }

    for k in "$@"; do
        v=$(grep -rhs "^[[:space:]]*${k}=" "${SCRIPT_DIR}/env-files/" 2>/dev/null \
            | head -1 | cut -d= -f2- | tr -d '"'"'"'\r')
        [ -n "${v}" ] && { printf '%s' "${v}"; return 0; }
    done
    return 1
}

# Команда внутри контейнера с ограничением по времени. Без него прогон
# подвисает намертво: psql, столкнувшись с требованием пароля, ждёт ввода,
# которого в неинтерактивном запуске не будет никогда.
_dexec() {
    sudo timeout 30 docker exec "$@" 2>/dev/null
}

# Число реплик из docker: "1/1", но при ограничениях размещения - вида
# "1/1 (max 1 per node)". Примечание в скобках нужно отрезать, иначе в "сколько
# требуется" попадает текст и сравнение всегда даёт расхождение.
_reps_clean() {
    printf '%s' "${1%% *}"
}

_free_bytes() {
    df -PB1 "$1" 2>/dev/null | awk 'NR==2 {print $4}'
}

_human() {
    numfmt --to=iec --suffix=B "$1" 2>/dev/null || echo "$1 байт"
}

########################################
# Адреса платформы
########################################
# Платформа сама знает, под каким именем к ней обращаются: оно передано её
# службам переменными окружения при развёртывании. Это надёжнее любых догадок -
# в nginx имени нет (там default_server), в config.env тоже.
#
# KEYCLOAK_EXTERNAL_REALM_PATH ценнее прочего: это готовый путь к realm целиком,
# поэтому ни префикс, ни имя realm угадывать не приходится.
PLATFORM_ENV=$(_platform_env) || PLATFORM_ENV=""
PLATFORM_URL_ENV=$(_platform_env_value PLATFORM_URL)
REALM_PATH=$(_platform_env_value KEYCLOAK_EXTERNAL_REALM_PATH)

########################################
# Поиск архива
########################################
# Смотрим в двух местах и на уровень вглубь. Каталог скрипта - потому что
# доставка с боевого сервера настроена класть архив прямо туда. BACKUP_DIR -
# потому что туда пишет локальный бэкап, если он на этой машине тоже настроен.
# Подкаталоги первого уровня - потому что доставка умеет раскладывать архивы по
# папкам серверов, и тогда файл лежит на уровень ниже.
find_latest_archive() {
    local d
    {
        for d in "${SCRIPT_DIR}" "${BACKUP_DIR}"; do
            [ -n "${d}" ] && [ -d "${d}" ] || continue
            find "${d}" -maxdepth 2 -type f -name '*-backup-v*.tar.gz' 2>/dev/null
        done
    } | sort -u | while IFS= read -r f; do
        # Сортируем по метке времени из имени, а не по времени файла: копирование
        # без сохранения атрибутов сбрасывает mtime, а имя не меняется никогда.
        local ts
        ts=$(basename -- "${f}" | grep -oE '[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}-[0-9]{2}' | tail -1)
        [ -n "${ts}" ] || continue
        printf '%s\t%s\n' "${ts}" "${f}"
    done | sort -r | head -1 | cut -f2
}

########################################
# Проверки перед восстановлением
########################################
preflight() {
    log "проверки перед восстановлением"

    [ -x "${RESTORE_SH}" ] || [ -f "${RESTORE_SH}" ] \
        || die "не найден ${RESTORE_SH}"

    sudo docker info >/dev/null 2>&1 \
        || die "docker не отвечает - платформа не запущена или нет прав"

    [ -f "${ARCHIVE}" ] || die "архив не найден: ${ARCHIVE}"
    [ -s "${ARCHIVE}" ] || die "архив пустой: ${ARCHIVE}"

    # Версия в имени архива против версии контура. Развернуть архив от другой
    # версии платформы - это несколько часов работы и мусор в базах на выходе.
    local arch_ver
    arch_ver=$(basename -- "${ARCHIVE}" | sed -n 's/.*-backup-v\([0-9][0-9.]*\)-[0-9]\{4\}-.*/\1/p')
    if [ -z "${VERSION}" ]; then
        log "  версия контура неизвестна (нет config.env), сверка версий пропущена"
    elif [ -z "${arch_ver}" ]; then
        warn "не удалось определить версию из имени архива, проверка версии пропущена"
    elif [ "${arch_ver}" != "${VERSION}" ] && [ "${ANY_VERSION}" != "1" ]; then
        die "версия архива ${arch_ver} не совпадает с версией контура ${VERSION}.
     Развернуть архив от другой версии - несколько часов работы и мусор в базах
     на выходе, поэтому по умолчанию это отказ. Если так и задумано, добавьте
     --any-version."
    elif [ "${arch_ver}" != "${VERSION}" ]; then
        warn "версия архива ${arch_ver} не совпадает с версией контура ${VERSION}, продолжаю по --any-version"
    else
        log "  версия: ${arch_ver} - совпадает"
    fi

    # Места нужно на распакованный каталог backup/ плюс запас. Сам архив уже
    # лежит на диске, поэтому он в расчёт не входит.
    local asize free need
    asize=$(stat -c %s -- "${ARCHIVE}" 2>/dev/null) || asize=0
    free=$(_free_bytes "${BACKUP_DIR}")
    need=$(( asize * SPACE_FACTOR_X10 / 10 ))
    if [ -n "${free}" ] && [ "${free}" -lt "${need}" ]; then
        die "в ${BACKUP_DIR} свободно $(_human "${free}"), нужно около $(_human "${need}").
     Восстановление распаковывает каталог примерно того же объёма, что и архив."
    fi
    log "  место в ${BACKUP_DIR}: $(_human "${free:-0}") при потребности ~$(_human "${need}")"

    local bs_cid
    bs_cid=$(resolve_container "${PROJECT}_backup-service")
    [ -n "${bs_cid}" ] || die "контейнер ${PROJECT}_backup-service не найден - восстанавливать нечем"
    log "  backup-service: ${bs_cid}"
}

########################################
# Подтверждение
########################################
# Восстановление затирает данные. Скрипт запускается руками, поэтому защитой
# служит явное подтверждение с указанием машины и архива, а не флаг в файле
# настроек, который однажды окажется скопированным не туда.
confirm() {
    echo
    echo "  ЭТО ДЕЙСТВИЕ ЗАТРЁТ ДАННЫЕ ПЛАТФОРМЫ НА ЭТОМ СЕРВЕРЕ"
    echo
    echo "  сервер:   $(hostname)"
    echo "  контур:   Visiology ${VERSION:-версия неизвестна}, проект ${PROJECT}"
    echo "  архив:    ${ARCHIVE}"
    echo "  размер:   $(_human "$(stat -c %s -- "${ARCHIVE}" 2>/dev/null || echo 0)")"
    if [ "${STOP_SERVICES}" = "1" ]; then
        echo "  службы:   прикладные будут погашены и подняты после"
    else
        echo "  службы:   ОСТАНУТСЯ РАБОТАТЬ - как штатный restore.sh."
        echo "            Платформа будет писать в базы во время восстановления"
    fi
    if [ "${APPLY_CONFIGS}" = "1" ]; then
        echo "  после:    остановка платформы, перегенерация конфигураций, запуск"
    fi
    if [ ${#EXTRA_ARGS[@]} -gt 0 ]; then
        echo "  доп.ключи restore.sh: ${EXTRA_ARGS[*]}"
    fi
    echo

    if [ "${ASSUME_YES}" = "1" ]; then
        log "подтверждение пропущено (--yes)"
        return 0
    fi

    # Без терминала спросить не у кого. Молча продолжать нельзя: так теряют
    # боевые данные.
    if [ ! -t 0 ]; then
        die "нет терминала для подтверждения. Для неинтерактивного запуска добавьте --yes"
    fi

    printf '  Продолжить? Введите "да": '
    local answer
    read -r answer
    case "${answer}" in
        да|Да|ДА|yes|Yes|YES) return 0 ;;
        *) log "отменено"; exit 0 ;;
    esac
}

########################################
# Восстановление
########################################
# Вывод restore.sh разбирается здесь, потому что сам он о результате не
# сообщает. Ключевой признак - строки статуса HTTP из трассы curl: у него стоит
# -v, и ответ backup-service виден целиком, включая код.
run_restore() {
    local rlog rc
    rlog=$(mktemp /var/tmp/visiology-restore-XXXXXX.log) \
        || die "не удалось создать файл журнала восстановления"

    log "восстановление: ${ARCHIVE}"
    log "  полный вывод: ${rlog}"
    log "  это надолго, обычно около двух часов"

    local t0 t1
    t0=$(date +%s)
    sudo "${RESTORE_SH}" --archive-name "${ARCHIVE}" "${EXTRA_ARGS[@]}" > "${rlog}" 2>&1
    rc=$?
    t1=$(date +%s)
    log "  restore.sh завершился с кодом ${rc} за ~$(( (t1 - t0) / 60 )) мин"

    # Коды ответов backup-service. Ответ 4xx/5xx означает, что база не
    # восстановлена, хотя restore.sh об этом не скажет.
    local bad_http
    bad_http=$(grep -aoE '^< HTTP/[0-9.]+ [0-9]{3}' "${rlog}" 2>/dev/null \
               | awk '{print $3}' | grep -E '^[45]' | sort -u | tr '\n' ' ')

    # Известные признаки битого восстановления в выводе.
    local markers
    markers=$(grep -aiE 'violates foreign key|UNKNOWN_TABLE|Traceback \(most recent call last\)|FATAL:|could not connect' "${rlog}" 2>/dev/null | head -5)

    RESTORE_LOG="${rlog}"
    RESTORE_RC="${rc}"
    RESTORE_BAD_HTTP="${bad_http}"
    RESTORE_MARKERS="${markers}"

    if [ "${rc}" -ne 0 ]; then
        warn "restore.sh вернул ненулевой код ${rc}"
    fi
    if [ -n "${bad_http}" ]; then
        warn "backup-service ответил кодом: ${bad_http} - базы, скорее всего, не восстановлены"
    fi
    if [ -n "${markers}" ]; then
        warn "в выводе восстановления найдены признаки ошибок:"
        printf '%s\n' "${markers}" | sed 's/^/      /'
    fi

    # Красные подсказки restore.sh про перегенерацию конфигураций теряются в
    # многотысячном выводе tar -xvf, поэтому поднимаем их наверх.
    local hints
    hints=$(grep -aE 'prepare-config\.sh|run\.sh --restart|run\.sh --stop' "${rlog}" 2>/dev/null | sort -u)
    if [ -n "${hints}" ]; then
        log "  restore.sh просит выполнить вручную:"
        printf '%s\n' "${hints}" | sed 's/^/      /'
    fi
}

########################################
# Ожидание подъёма служб
########################################
_services_raw() {
    sudo docker service ls --format '{{.Name}}|{{.Replicas}}' 2>/dev/null \
        | grep "^${PROJECT}_" || true
}

# Ключевая ли это служба.
_is_essential() {
    local name="$1" pat
    for pat in ${ESSENTIAL_SERVICES}; do
        case "${name}" in *"${pat}"*) return 0 ;; esac
    done
    return 1
}

# Сколько ключевых служб ещё не набрали реплики.
#
# Считаются только они. Второстепенная служба, которая не поднимается по своим
# причинам, не должна задерживать прогон: в отчёт она всё равно попадёт, а
# ждать её - значит стоять до конца отведённого срока впустую.
_services_pending() {
    local name reps run want pending=0
    while IFS='|' read -r name reps; do
        [ -n "${name}" ] || continue
        _is_essential "${name}" || continue
        _is_ignored "${name}" && continue
        reps=$(_reps_clean "${reps}")
        run="${reps%%/*}"
        want="${reps##*/}"
        [ "${run}" = "${want}" ] || pending=$((pending + 1))
    done < <(_services_raw)
    printf '%s' "${pending}"
}

# Имена ключевых служб, которые ещё не готовы - для сообщения.
_services_pending_names() {
    local name reps run want
    while IFS='|' read -r name reps; do
        [ -n "${name}" ] || continue
        _is_essential "${name}" || continue
        _is_ignored "${name}" && continue
        reps=$(_reps_clean "${reps}")
        run="${reps%%/*}"
        want="${reps##*/}"
        [ "${run}" = "${want}" ] || printf '%s ' "${name#${PROJECT}_}"
    done < <(_services_raw)
}

wait_services() {
    local deadline pending left
    deadline=$(( $(date +%s) + WAIT_SERVICES ))

    log "жду подъёма ключевых служб (до ${WAIT_SERVICES} с)"
    while :; do
        pending=$(_services_pending)
        [ -n "${pending}" ] || pending=0
        if [ "${pending}" -eq 0 ]; then
            log "  ключевые службы поднялись"
            return 0
        fi
        left=$(( deadline - $(date +%s) ))
        if [ "${left}" -le 0 ]; then
            warn "по истечении ${WAIT_SERVICES} с не поднялись ключевые службы: $(_services_pending_names)"
            return 1
        fi
        log "  ещё поднимаются: $(_services_pending_names)(осталось ${left} с)"
        sleep 30
    done
}

########################################
# Отчёт по почте
########################################
# Письмо собирает и отправляет встроенный обработчик на python3: разбор SMTP,
# STARTTLS и заголовки с кириллицей на чистом bash пришлось бы писать вручную,
# а python3 есть в любой поддерживаемой Ubuntu. Внешние пакеты не нужны.
#
# Всё передаётся переменными окружения, а не аргументами: пароль не должен
# попадать в argv, видимый через ps. Ошибка отправки не влияет на исход прогона.
_mail_send() {
    local subject="$1" body_file="$2"

    [ -n "${MAIL_TO}" ] || return 0
    if ! command -v python3 >/dev/null 2>&1; then
        warn "python3 не найден, отчёт не отправлен"
        return 0
    fi

    (
        export MAIL_TO MAIL_FROM SMTP_HOST SMTP_PORT SMTP_USE_TLS SMTP_USE_SSL \
               SMTP_SKIP_VERIFY SMTP_USER SMTP_PASSWORD
        export MAIL_SUBJECT="${subject}" MAIL_BODY_FILE="${body_file}"
        timeout 90 python3 - <<'MAIL_PY'
"""Отправка отчёта visiology-restore-test.sh. Всё - из окружения."""
import os
import smtplib
import ssl
import sys
from email.message import EmailMessage


def flag(name, default=False):
    v = os.environ.get(name, "")
    if v == "":
        return default
    return v.strip().lower() in ("1", "true", "yes", "on", "da", "да")


def main():
    to = [a.strip() for a in os.environ.get("MAIL_TO", "").split(",") if a.strip()]
    if not to:
        return 0

    msg = EmailMessage()
    msg["From"] = os.environ.get("MAIL_FROM", "visiology-restore-test@localhost")
    msg["To"] = ", ".join(to)
    msg["Subject"] = os.environ.get("MAIL_SUBJECT", "visiology-restore-test")

    path = os.environ.get("MAIL_BODY_FILE", "")
    try:
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            body = fh.read()
    except OSError as e:
        body = "Не удалось прочитать тело письма: %s" % e
    msg.set_content(body)

    host = os.environ.get("SMTP_HOST", "localhost")
    port = int(os.environ.get("SMTP_PORT", "25") or 25)
    use_ssl = flag("SMTP_USE_SSL")
    use_tls = flag("SMTP_USE_TLS")
    # Внутренний релей обычно с самоподписанным сертификатом.
    ctx = ssl._create_unverified_context() if flag("SMTP_SKIP_VERIFY", True) \
        else ssl.create_default_context()

    try:
        if use_ssl:
            srv = smtplib.SMTP_SSL(host, port, timeout=20, context=ctx)
        else:
            srv = smtplib.SMTP(host, port, timeout=20)
        with srv:
            if use_tls and not use_ssl:
                srv.starttls(context=ctx)
            user = os.environ.get("SMTP_USER", "")
            if user:
                srv.login(user, os.environ.get("SMTP_PASSWORD", ""))
            srv.send_message(msg)
    except Exception as e:
        # Режим важнее текста ошибки: "timed out" без указания порта и режима
        # шифрования ничего не объясняет.
        mode = "SSL" if use_ssl else ("STARTTLS" if use_tls else "без шифрования")
        print("не удалось отправить отчёт через %s:%s (%s): %s"
              % (host, port, mode, e), file=sys.stderr)
        return 1
    return 0


sys.exit(main())
MAIL_PY
    ) 2>&1 | while IFS= read -r _l; do warn "${_l}"; done
    return 0
}

# Сборка и отправка отчёта. $1 - код возврата прогона.
send_report() {
    local rc="$1"
    [ "${SEND_MAIL}" = "1" ] || return 0
    [ -n "${MAIL_TO}" ] || return 0

    local body status_word
    body=$(mktemp /var/tmp/visiology-restore-mail-XXXXXX.txt) || return 0

    if [ "${rc}" -eq 0 ]; then
        status_word="успешно"
    elif [ "${rc}" -eq 130 ]; then
        status_word="ПРЕРВАНО"
    else
        status_word="С ОШИБКАМИ"
    fi

    {
        echo "Сервер:       $(hostname)"
        echo "Контур:       Visiology ${VERSION}, проект ${PROJECT}"
        echo "Начало:       ${T_START_HUMAN}"
        echo "Длительность: ~$(( ( $(date +%s) - T_START ) / 60 )) мин"
        echo "Результат:    ${status_word} (код ${rc})"
        echo

        if [ "${DO_RESTORE}" = "1" ]; then
            echo "ВОССТАНОВЛЕНИЕ"
            echo "  Архив:      ${ARCHIVE:-не выбран}"
            echo "  Код:        ${RESTORE_RC}"
            [ -n "${RESTORE_BAD_HTTP}" ] \
                && echo "  ВНИМАНИЕ:   backup-service отвечал кодами ${RESTORE_BAD_HTTP} - базы могли не восстановиться"
            [ -n "${RESTORE_MARKERS}" ] \
                && echo "  ВНИМАНИЕ:   в выводе есть признаки ошибок, см. журнал"
            if [ "${APPLIED_CONFIGS}" = "1" ]; then
                echo "  Настройки:  применены, платформа перезапущена"
            else
                echo "  Настройки:  НЕ применялись"
            fi
            [ -n "${RESTORE_LOG}" ] && echo "  Журнал:     ${RESTORE_LOG}"
            echo
        fi

        if [ "${DO_TESTS}" = "1" ]; then
            echo "ПРОВЕРКИ"
            echo "  Пройдено:   ${CHECKS_OK}"
            echo "  Замечаний:  ${CHECKS_WARN}"
            echo "  Отказов:    ${CHECKS_FAIL}"
            if [ "${CHECKS_FAIL}" -gt 0 ]; then
                echo
                echo "  Отказавшие проверки:"
                printf '    - %s\n' "${FAILED_LIST[@]}"
            fi
            echo
        fi

        if [ -n "${STATE_NOW}" ]; then
            echo "НАПОЛНЕНИЕ БАЗ"
            printf '%s\n' "${STATE_NOW}" | sed '/^$/d; s/^/  /'
            echo
        fi

        if [ -n "${LOG_PATH}" ]; then
            echo "Журнал прогона: ${LOG_PATH}"
            if [ "${rc}" -ne 0 ]; then
                echo
                echo "Последние строки журнала:"
                tail -n 40 -- "${LOG_PATH}" 2>/dev/null | sed 's/^/  /'
            fi
        fi
    } > "${body}"

    local subj="[visiology-restore-test] $(hostname): ${status_word}"
    [ "${DO_TESTS}" = "1" ] && [ "${CHECKS_FAIL}" -gt 0 ] \
        && subj="${subj}, отказов ${CHECKS_FAIL}"

    _mail_send "${subj}" "${body}"
    rm -f "${body}"
}

########################################
# Применение восстановленных конфигураций
########################################
# restore.sh заменяет env-files, extended-services и custom-configs на диске, но
# сам их не применяет - он лишь печатает три команды и заканчивает работу. Пока
# они не выполнены, платформа работает на прежних настройках, а восстановленные
# файлы лежат мёртвым грузом.
#
# Поэтому цикл выполняется здесь: остановка, перегенерация, запуск. И только
# после него имеет смысл что-либо проверять.
# Шаг цикла, выполняемый в заданном каталоге. У скриптов платформы всё завязано
# на текущий каталог: в config.env пути записаны точкой, и запуск из чужого
# места приводит к тому, что они ищут файлы не там.
_run_step_in() {
    local dir="$1"; shift
    ( cd -- "${dir}" 2>/dev/null || cd / ; _run_step "$@" )
}

_run_step() {
    local title="$1"; shift
    local rc t0 t1
    log "  ${title}..."
    t0=$(date +%s)
    "$@" >> "${RESTORE_LOG}" 2>&1
    rc=$?
    t1=$(date +%s)
    if [ "${rc}" -eq 0 ]; then
        log "    готово за $(( t1 - t0 )) с"
    else
        warn "${title}: код ${rc}, подробности в ${RESTORE_LOG}"
    fi
    return "${rc}"
}

apply_configs() {
    # run.sh лежит уровнем выше: скрипты платформы разложены как
    # scripts/run.sh и scripts/v3/prepare-config.sh.
    local run_sh prep
    run_sh="$(dirname -- "${SCRIPT_DIR}")/run.sh"
    prep="${SCRIPT_DIR}/prepare-config.sh"

    if [ ! -f "${run_sh}" ] || [ ! -f "${prep}" ]; then
        warn "не найдены ${run_sh} или ${prep} - выполните вручную:"
        warn "  ${run_sh} --stop"
        warn "  ${prep} --force-regenerate-configs"
        warn "  ${run_sh} --restart"
        return 1
    fi

    log "применяю восстановленные конфигурации"
    APPLIED_CONFIGS=1

    # Остановка и перегенерация могут не получиться, но запуск выполняется в
    # любом случае: оставить контур лежащим - худший из исходов.
    local run_dir prep_dir
    run_dir="$(dirname -- "${run_sh}")"
    prep_dir="$(dirname -- "${prep}")"

    _run_step_in "${run_dir}" "остановка платформы" \
        sudo timeout 1800 "${run_sh}" --stop || true

    # Остановку подтверждаем фактом, а не кодом возврата: перегенерация не может
    # заменить объекты конфигурации Swarm, пока их держат работающие службы, и
    # тогда восстановленные настройки молча не применятся.
    local still
    still=$(_services_raw | awk -F'|' '{ split($2, r, "/"); if (r[1] + 0 > 0) c++ } END { print c + 0 }')
    if [ "${still}" -gt 0 ]; then
        warn "после остановки ещё работают служб: ${still}. Перегенерация может не заменить конфигурации"
    fi

    _run_step_in "${prep_dir}" "перегенерация конфигураций" \
        sudo timeout 1800 "${prep}" --force-regenerate-configs \
        || warn "конфигурации не перегенерированы - платформа поднимется на прежних настройках"

    _run_step_in "${run_dir}" "запуск платформы" \
        sudo timeout 1800 "${run_sh}" --restart \
        || warn "платформа не запустилась. Запустите вручную: ${run_sh} --restart"
}

########################################
# Очистка рабочего каталога
########################################
# restore.sh распаковывает архив в BACKUP_DIR/backup и оставляет его там -
# столько же гигабайт, сколько весит сам архив. Платформе этот каталог не
# нужен: при следующем восстановлении он распаковывается заново, а до тех пор
# лишь занимает место.
#
# Команда намеренно повторяет ту, что стоит в самом restore.sh. Добавлено
# только ${...:?} - оно прерывает выполнение, если переменная окажется пустой,
# чтобы удаление ни при каких обстоятельствах не ушло в корень файловой системы.
cleanup_backup_dir() {
    local dir="${BACKUP_DIR%/}/backup" freed
    [ -d "${dir}" ] || return 0
    [ -n "$(sudo ls -A "${dir}" 2>/dev/null)" ] || return 0

    freed=$(sudo du -sh "${dir}" 2>/dev/null | cut -f1) || freed=""
    sudo rm -rf "${dir:?}"/*
    log "каталог ${dir} очищен${freed:+, освобождено ${freed}}"
}

########################################
# Остановка и подъём прикладных служб
########################################
# Остаётся ли служба работать.
_keep_running() {
    local name="$1" pat
    for pat in ${KEEP_RUNNING}; do
        case "${name}" in *"${pat}"*) return 0 ;; esac
    done
    return 1
}

# Дождаться, пока у погашенных служб не останется ни одного контейнера.
# Масштабирование в ноль возвращает управление сразу, а задачи умирают не
# мгновенно - и пока жив хоть один, он продолжает писать в базу.
_wait_stopped() {
    local deadline left name alive
    deadline=$(( $(date +%s) + 300 ))
    while :; do
        alive=0
        while IFS='=' read -r name _; do
            [ -n "${name}" ] || continue
            [ -n "$(sudo docker ps --filter "name=^${name}\\." --format '{{.ID}}' 2>/dev/null)" ] \
                && alive=$((alive + 1))
        done < "${SERVICES_STATE_FILE}"

        [ "${alive}" -eq 0 ] && return 0
        left=$(( deadline - $(date +%s) ))
        if [ "${left}" -le 0 ]; then
            warn "через 300 с ещё живы контейнеры: ${alive}. Восстановление продолжится, но они могут писать в базы"
            return 1
        fi
        log "  ещё останавливаются: ${alive}"
        sleep 10
    done
}

stop_services() {
    local name reps want stopped=0 kept=0
    log "останавливаю прикладные службы"
    : > "${SERVICES_STATE_FILE}" || { warn "не создать ${SERVICES_STATE_FILE}, службы не трогаю"; return 1; }

    while IFS='|' read -r name reps; do
        [ -n "${name}" ] || continue
        reps=$(_reps_clean "${reps}")
        want="${reps##*/}"
        # Уже выключенные не трогаем: иначе подняли бы то, что выключено намеренно.
        [ "${want}" = "0" ] && continue
        if _keep_running "${name}"; then
            kept=$((kept + 1))
            continue
        fi
        # Число реплик записывается до остановки: иначе восстанавливать будет нечем.
        printf '%s=%s\n' "${name}" "${want}" >> "${SERVICES_STATE_FILE}"
        if sudo timeout 120 docker service scale --detach "${name}=0" >/dev/null 2>&1; then
            stopped=$((stopped + 1))
        else
            warn "не удалось остановить ${name}"
        fi
    done < <(_services_raw)

    log "  остановлено: ${stopped}, оставлено работать: ${kept}"
    [ "${stopped}" -gt 0 ] || return 0
    _wait_stopped
    return 0
}

start_services() {
    [ -s "${SERVICES_STATE_FILE}" ] || return 0
    local name want started=0
    log "поднимаю службы обратно"
    while IFS='=' read -r name want; do
        [ -n "${name}" ] || continue
        if sudo timeout 120 docker service scale --detach "${name}=${want}" >/dev/null 2>&1; then
            started=$((started + 1))
        else
            warn "не удалось поднять ${name} (нужно ${want} реплик) - поднимите вручную"
        fi
    done < "${SERVICES_STATE_FILE}"
    log "  возвращено служб: ${started}"
    rm -f "${SERVICES_STATE_FILE}"
}

########################################
# Проверка 1. Службы Swarm
########################################
# Почему служба не набрала реплики. Swarm хранит это в состоянии последней
# задачи: без причины отказ "0/1" ничего не объясняет и тонет среди прочих.
_service_reason() {
    sudo timeout 20 docker service ps "$1" --no-trunc \
        --format '{{.CurrentState}} {{.Error}}' 2>/dev/null \
        | head -1 | sed 's/[[:space:]]\{2,\}/ /g' | cut -c1-160
}

_is_ignored() {
    local short="${1#${PROJECT}_}" item
    local IFS=','
    for item in ${IGNORE_SERVICES}; do
        item="${item## }"; item="${item%% }"
        [ -n "${item}" ] || continue
        [ "${item}" = "${short}" ] && return 0
        [ "${item}" = "$1" ] && return 0
    done
    return 1
}

check_services() {
    log "службы Swarm"
    local name reps run want total=0
    while IFS='|' read -r name reps; do
        [ -n "${name}" ] || continue
        total=$((total + 1))
        reps=$(_reps_clean "${reps}")
        run="${reps%%/*}"
        want="${reps##*/}"
        if _is_ignored "${name}"; then
            check_warn "${name} ${reps} - не проверяется по --ignore"
        elif [ "${run}" = "${want}" ] && [ "${run}" != "0" ]; then
            check_ok "${name} ${reps}"
        elif [ "${want}" = "0" ]; then
            check_warn "${name} ${reps} - выключена: Swarm не запрашивает ни одной реплики"
        else
            # Разница между "выключена" и "не запускается" принципиальна: в
            # первом случае так задумано, во втором служба должна работать и не
            # может. Swarm их и различает - 0/0 против 0/N.
            check_fail "${name}: не запущена (${run} из ${want}). $(_service_reason "${name}")"
        fi
    done < <(_services_raw)

    if [ "${total}" -eq 0 ]; then
        check_fail "не найдено ни одной службы с префиксом ${PROJECT}_"
    fi
}

########################################
# Проверка 2. Состояние healthcheck
########################################
# Healthcheck есть не у всех образов. Его отсутствие - не отказ: это решение
# поставщика образа, а не признак поломки. Отказом считается только явный
# unhealthy.
check_health() {
    log "healthcheck контейнеров"
    local ids id name status checked=0
    ids=$(sudo docker ps -q 2>/dev/null)
    if [ -z "${ids}" ]; then
        check_fail "не запущено ни одного контейнера"
        return
    fi

    for id in ${ids}; do
        name=$(sudo docker inspect --format '{{.Name}}' "${id}" 2>/dev/null | sed 's|^/||')
        case "${name}" in
            ${PROJECT}_*) ;;
            *) continue ;;
        esac
        status=$(sudo docker inspect \
            --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}нет{{end}}' \
            "${id}" 2>/dev/null)
        case "${status}" in
            healthy)   check_ok   "${name} - healthy"; checked=$((checked + 1)) ;;
            unhealthy) check_fail "${name} - unhealthy"; checked=$((checked + 1)) ;;
            starting)  check_warn "${name} - ещё проверяется (starting)"; checked=$((checked + 1)) ;;
            нет)       : ;;
            *)         check_warn "${name} - состояние '${status}'" ;;
        esac
    done

    [ "${checked}" -gt 0 ] || log "  ни у одного контейнера платформы нет healthcheck"
}

########################################
# Проверка 3. Postgres
########################################
# Пользователь не угадывается, а читается из окружения самого контейнера -
# так проверка не зависит от того, что записано в env-files на этой машине.
check_postgres() {
    log "Postgres"
    local found=0 cid cname
    while read -r cid cname; do
        [ -n "${cid}" ] || continue
        found=1
        _check_one_postgres "${cid}" "${cname}"
    done < <(_containers_like "${PROJECT}_postgres")

    [ "${found}" = "1" ] || check_fail "контейнеры ${PROJECT}_postgres* не найдены"
}

# Запрос к Postgres выбранным способом. Пароль передаётся через стандартный
# ввод, а не аргументом docker: иначе он попал бы в argv и был бы виден в ps.
_pgq() {
    local cid="$1" db="$2" q="$3"
    if [ -n "${PG_PASS}" ]; then
        printf '%s' "${PG_PASS}" | sudo timeout 30 docker exec -i "${cid}" \
            sh -c 'PGPASSWORD=$(cat) exec psql -w -U "$1" -d "$2" -tAc "$3"' \
            sh "${PG_USER}" "${db}" "${q}" 2>&1
    elif [ "${PG_ASUSER}" = "1" ]; then
        sudo timeout 30 docker exec -u postgres "${cid}" \
            psql -w -U "${PG_USER}" -d "${db}" -tAc "${q}" 2>&1
    else
        sudo timeout 30 docker exec "${cid}" \
            psql -w -U "${PG_USER}" -d "${db}" -tAc "${q}" 2>&1
    fi
}

# Подбор рабочего способа подключения. Перебираются варианты по убыванию
# определённости: учётные данные из окружения и env-files, затем вход
# суперпользователем, затем от системного пользователя postgres внутри
# контейнера - при локальном подключении по сокету пароль обычно не требуется.
_pg_connect() {
    local cid="$1" u p
    u=$(_find_env_value "${cid}" POSTGRES_USER PGUSER POSTGRESQL_USERNAME DB_USER) || u=""
    p=$(_find_env_value "${cid}" POSTGRES_PASSWORD PGPASSWORD POSTGRESQL_PASSWORD DB_PASSWORD) || p=""

    PG_USER="${u:-postgres}"; PG_PASS="${p}"; PG_ASUSER=0
    _pgq "${cid}" postgres 'select 1' | grep -q '^1$' && return 0

    PG_PASS=""
    _pgq "${cid}" postgres 'select 1' | grep -q '^1$' && return 0

    PG_USER="postgres"
    _pgq "${cid}" postgres 'select 1' | grep -q '^1$' && return 0

    PG_ASUSER=1
    _pgq "${cid}" postgres 'select 1' | grep -q '^1$' && return 0

    # Последняя попытка: имя базы из POSTGRES_DB нередко совпадает с именем
    # владельца, а подключение по сокету от него пароля не требует.
    PG_ASUSER=0
    u=$(_container_value "${cid}" POSTGRES_DB) || u=""
    [ -n "${u}" ] || return 1
    PG_USER="${u}"
    _pgq "${cid}" postgres 'select 1' | grep -q '^1$' && return 0

    return 1
}

_check_one_postgres() {
    local cid="$1" cname="$2" dbs db n size out

    if ! _pg_connect "${cid}"; then
        # Показываем, что именно ответил psql: "не отвечает" без причины
        # заставляет лезть в контейнер руками.
        out=$(_pgq "${cid}" postgres 'select 1' | head -2 | tr '\n' ' ')
        check_fail "${cname}: подключиться не удалось. Ответ: ${out:-пусто}"
        return
    fi
    check_ok "${cname}: отвечает (пользователь ${PG_USER})"

    dbs=$(_pgq "${cid}" postgres \
        "select datname from pg_database where datistemplate = false and datname <> 'postgres'" \
        | tr -d '\r')
    if [ -z "${dbs}" ]; then
        check_fail "${cname}: нет ни одной базы платформы"
        return
    fi

    for db in ${dbs}; do
        # Postgres при инициализации заводит базу с именем пользователя, если
        # не указано иное. Она всегда пуста, платформа её не использует, и
        # отсутствие таблиц в ней - норма, а не признак поломки.
        [ "${db}" = "${PG_USER}" ] && continue

        n=$(_pgq "${cid}" "${db}" \
            "select count(*) from information_schema.tables where table_schema not in ('pg_catalog','information_schema')" \
            | tr -d '\r ')
        case "${n}" in ''|*[!0-9]*) n=0 ;; esac

        # Размер вместо подсчёта строк: пересчитывать строки во всех таблицах
        # долго и незачем, а размер сразу показывает, лежат ли за схемой данные.
        size=$(_pgq "${cid}" postgres "select pg_database_size('${db}')" | tr -d '\r ')
        case "${size}" in ''|*[!0-9]*) size=0 ;; esac

        if [ "${n}" -eq 0 ]; then
            check_fail "${cname}/${db}: таблиц нет - восстановление не состоялось"
        else
            check_ok "${cname}/${db}: таблиц ${n}, размер $(_human "${size}")"
        fi
        STATE_NOW="${STATE_NOW}pg:${cname}/${db}=${n}"$'\n'
        STATE_NOW="${STATE_NOW}pgsize:${cname}/${db}=${size}"$'\n'
    done
}

########################################
# Проверка 4. ClickHouse
########################################
# Проверка наполнения здесь особенно важна: именно на ClickHouse мы уже теряли
# два десятка таблиц при внешне успешном восстановлении.
check_clickhouse() {
    log "ClickHouse"
    local found=0 cid cname
    while read -r cid cname; do
        [ -n "${cid}" ] || continue
        found=1
        _check_one_clickhouse "${cid}" "${cname}"
    done < <(_containers_like "${PROJECT}_clickhouse")

    [ "${found}" = "1" ] || check_warn "контейнеры ${PROJECT}_clickhouse* не найдены на этом хосте"
}

# Запрос к ClickHouse. Пароль, если он задан, уходит через стандартный ввод -
# в argv команды docker на хосте он не появляется.
_chq() {
    local cid="$1" q="$2"
    if [ -n "${CH_PASS}" ]; then
        printf '%s' "${CH_PASS}" | sudo timeout 30 docker exec -i "${cid}" \
            sh -c 'export CLICKHOUSE_PASSWORD=$(cat); exec clickhouse-client --user "$1" --query "$2"' \
            sh "${CH_USER}" "${q}" 2>&1
    else
        sudo timeout 30 docker exec "${cid}" clickhouse-client --query "${q}" 2>&1
    fi
}

_ch_connect() {
    local cid="$1" u p
    CH_USER="default"; CH_PASS=""
    _chq "${cid}" 'SELECT 1' | grep -q '^1$' && return 0

    u=$(_find_env_value "${cid}" CLICKHOUSE_USER CH_USER) || u=""
    p=$(_find_env_value "${cid}" CLICKHOUSE_PASSWORD CH_PASSWORD) || p=""
    CH_USER="${u:-default}"; CH_PASS="${p}"
    [ -n "${CH_PASS}" ] || return 1
    _chq "${cid}" 'SELECT 1' | grep -q '^1$' && return 0
    return 1
}

_check_one_clickhouse() {
    local cid="$1" cname="$2" n rows out

    if ! _ch_connect "${cid}"; then
        out=$(_chq "${cid}" 'SELECT 1' | head -2 | tr '\n' ' ')
        check_fail "${cname}: подключиться не удалось. Ответ: ${out:-пусто}"
        return
    fi
    check_ok "${cname}: отвечает"

    n=$(_chq "${cid}" "SELECT count() FROM system.tables WHERE database = '${CH_DB}'" | tr -d '\r ')
    case "${n}" in ''|*[!0-9]*) n=0 ;; esac
    if [ "${n}" -eq 0 ]; then
        check_fail "${cname}: в базе ${CH_DB} нет таблиц - данные не восстановлены"
    else
        check_ok "${cname}: таблиц ${n}"
    fi
    STATE_NOW="${STATE_NOW}ch:${cname}=${n}"$'\n'

    # Строки берутся из system.parts, а не count() по таблицам: это одна быстрая
    # выборка из метаданных вместо обхода данных. Таблицы могут существовать
    # пустыми - схема восстановилась, а данные нет.
    rows=$(_chq "${cid}" \
        "SELECT sum(rows) FROM system.parts WHERE database = '${CH_DB}' AND active" | tr -d '\r ')
    case "${rows}" in ''|*[!0-9]*) rows=0 ;; esac
    if [ "${rows}" -eq 0 ]; then
        check_fail "${cname}: таблицы есть, но строк нет - данные не восстановлены"
    else
        check_ok "${cname}: строк ${rows}"
    fi
    STATE_NOW="${STATE_NOW}chrows:${cname}=${rows}"$'\n'
}

########################################
# Проверка 5. Доступность по HTTP
########################################
# Код ответа, либо 000, если ответа не было.
#
# Запасной вариант через || здесь не годится: при обрыве соединения curl и
# печатает "000" по -w, и возвращает ненулевой код. Получалось "000000" - не
# равное ни одному ожидаемому значению, из-за чего недоступная платформа
# проходила проверку как исправная. Поэтому результат проверяется на вид, а не
# на код возврата curl.
_http_code() {
    local c
    c=$(curl -sS -k -o /dev/null -m "${HTTP_TIMEOUT}" -w '%{http_code}' "$1" 2>/dev/null)
    case "${c}" in
        [0-9][0-9][0-9]) printf '%s' "${c}" ;;
        *)               printf '000' ;;
    esac
}

check_http() {
    log "доступность по HTTP"

    if ! command -v curl >/dev/null 2>&1; then
        check_warn "curl не установлен, HTTP-проверки пропущены"
        return
    fi

    # Порядок источников: явный ключ, затем адрес, который платформа сообщает
    # своим службам, и лишь затем 127.0.0.1 вслепую.
    local bases=()
    if [ -n "${HTTP_URL}" ]; then
        bases=("${HTTP_URL%/}")
    elif [ -n "${PLATFORM_URL_ENV}" ]; then
        bases=("${PLATFORM_URL_ENV%/}")
        log "  адрес платформы из её настроек: ${PLATFORM_URL_ENV}"
    else
        bases=("https://127.0.0.1" "http://127.0.0.1")
        log "  адрес платформы не найден, пробую 127.0.0.1"
    fi

    local base="" code="" b err
    for b in "${bases[@]}"; do
        code=$(_http_code "${b}/")
        [ "${code}" != "000" ] && { base="${b}"; break; }
    done

    if [ -z "${base}" ]; then
        # Причину печатает сам curl - без неё непонятно, отказ ли это в
        # соединении, неверное имя или истёкшее время ожидания.
        err=$(curl -sS -k -o /dev/null -m "${HTTP_TIMEOUT}" "${bases[0]}/" 2>&1 | head -1)
        check_fail "${bases[0]}/ - нет ответа: ${err:-причина не сообщена}"
        check_warn "Keycloak не проверялся: платформа не отвечает по HTTP"
        return
    fi

    # Годится широкий диапазон: платформа отвечает и 200, и перенаправлением на
    # вход. Значение имеет лишь то, что ответ пришёл и это не отказ шлюза.
    case "${code}" in
        5*) check_fail "${base}/ - код ${code}, обратный прокси жив, а служба за ним нет" ;;
        *)  check_ok   "${base}/ - код ${code}" ;;
    esac

    # Keycloak. Ответ означает, что жив и он сам, и его база: конфигурацию
    # realm он читает из Postgres. Путь берём тот, который платформа раздаёт
    # своим службам; остальные варианты - на случай, если его нет.
    local realm="${KEYCLOAK_REALM:-Visiology}"
    local u body found=0 last=""
    local urls=()
    [ -n "${REALM_PATH}" ] && urls+=("${REALM_PATH%/}/.well-known/openid-configuration")
    urls+=("${base}${KEYCLOAK_PREFIX}/realms/${realm}/.well-known/openid-configuration" \
           "${base}/realms/${realm}/.well-known/openid-configuration")

    for u in "${urls[@]}"; do
        body=$(curl -sS -k -m "${HTTP_TIMEOUT}" "${u}" 2>/dev/null) || body=""
        last=$(_http_code "${u}")
        if printf '%s' "${body}" | grep -q '"issuer"'; then
            check_ok "Keycloak отдаёт конфигурацию realm ${realm}"
            found=1
            break
        fi
    done
    [ "${found}" = "1" ] \
        || check_fail "Keycloak не отдал конфигурацию realm ${realm} (последний код ${last}) - проверьте его и его базу"
}

########################################
# Проверка 6. Вход пользователя
########################################
# Проверка Keycloak выше подтверждает, что служба жива и её база читается. Это
# не то же самое, что "учётная запись работает": realm может отдаваться, а вход
# не проходить - например, когда восстановилась база платформы, но не база
# Keycloak. Здесь берётся настоящий токен и проверяется, что платформа его
# принимает.
#
# Выполняется, только если задано имя пользователя. Без него молча
# пропускается: остальным проверкам секреты не нужны, и навязывать их хранение
# ради одной было бы неправильно.
check_login() {
    [ -n "${LOGIN_USER}" ] || return 0
    log "вход пользователя"

    if ! command -v curl >/dev/null 2>&1; then
        check_warn "curl не установлен, проверка входа пропущена"
        return
    fi

    local base="${HTTP_URL:-${PLATFORM_URL_ENV:-https://127.0.0.1}}"
    base="${base%/}"
    local realm="${KEYCLOAK_REALM:-Visiology}"
    local kc
    if [ -n "${REALM_PATH}" ]; then
        kc="${REALM_PATH%/}/protocol/openid-connect"
    else
        kc="${base}${KEYCLOAK_PREFIX}/realms/${realm}/protocol/openid-connect"
    fi

    # Пароль уходит в curl через файл, а не аргументом: аргументы процесса
    # видны в ps. По той же причине токен передаётся файлом настроек curl, а не
    # ключом -H.
    local pfile
    pfile=$(mktemp) || { check_warn "не создать временный файл, проверка входа пропущена"; return; }
    chmod 600 "${pfile}"
    printf '%s' "${LOGIN_PASSWORD}" > "${pfile}"

    local body
    body=$(curl -sS -k -m "${HTTP_TIMEOUT}" -X POST "${kc}/token" \
        --data-urlencode "client_id=${LOGIN_CLIENT}" \
        --data-urlencode "grant_type=password" \
        --data-urlencode "scope=${LOGIN_SCOPE}" \
        --data-urlencode "username=${LOGIN_USER}" \
        --data-urlencode "password@${pfile}" 2>/dev/null)
    rm -f "${pfile}"

    # Пробелы вокруг двоеточия допускаются: форматирование ответа - дело
    # отдающей стороны, и завязываться на его отсутствие нельзя.
    local token
    token=$(printf '%s' "${body}" \
        | sed -n 's/.*"access_token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)

    if [ -z "${token}" ]; then
        local hint=""
        case "${body}" in
            *unauthorized_client*) hint=" - у клиента ${LOGIN_CLIENT} выключен прямой вход (Direct Access Grants)" ;;
            *invalid_grant*)       hint=" - неверный логин или пароль, либо учётная запись отключена" ;;
            *invalid_scope*)       hint=" - клиенту не выданы запрошенные права" ;;
            "")                    hint=" - Keycloak не ответил" ;;
        esac
        check_fail "вход ${LOGIN_USER}: токен не получен${hint}"
        [ -n "${body}" ] && echo "               ответ: $(printf '%s' "${body}" | head -c 200)"
        return
    fi
    check_ok "вход ${LOGIN_USER}: токен получен"

    # Токен выдан - ещё не значит, что он принимается. Отклоняемый токен виден
    # только на запросе с ним.
    local cfg code
    cfg=$(mktemp) || { check_warn "не создать временный файл, приём токена не проверен"; return; }
    chmod 600 "${cfg}"
    printf 'header = "Authorization: Bearer %s"\n' "${token}" > "${cfg}"
    code=$(curl -sS -k -m "${HTTP_TIMEOUT}" -o /dev/null -w '%{http_code}' \
        -K "${cfg}" "${kc}/userinfo" 2>/dev/null) || code="000"
    rm -f "${cfg}"

    if [ "${code}" = "200" ]; then
        check_ok "токен принимается платформой"
    else
        check_fail "токен выдан, но платформой не принимается: userinfo вернул ${code}"
    fi
}

########################################
# Сравнение с прошлым прогоном
########################################
# Счётчики таблиц сами по себе ничего не доказывают, но их изменение между
# восстановлениями видно сразу и стоит внимания: если вчера в ClickHouse было
# 340 таблиц, а сегодня 318 - потерялись данные, хотя все проверки зелёные.
compare_state() {
    [ -n "${STATE_NOW}" ] || return 0

    if [ -f "${STATE_FILE}" ]; then
        log "сравнение с прошлым прогоном ($(date -r "${STATE_FILE}" '+%F %T' 2>/dev/null))"
        local line key now was
        while IFS= read -r line; do
            [ -n "${line}" ] || continue
            key="${line%%=*}"
            now="${line##*=}"
            was=$(grep -F "${key}=" "${STATE_FILE}" 2>/dev/null | head -1 | sed 's/.*=//')
            if [ -z "${was}" ]; then
                log "  ${key}: ${now} (раньше не измерялось)"
            elif [ "${was}" = "${now}" ]; then
                log "  ${key}: ${now} - без изменений"
            elif [ "${now}" -lt "${was}" ] 2>/dev/null; then
                warn "  ${key}: было ${was}, стало ${now} - СТАЛО МЕНЬШЕ"
            else
                log "  ${key}: было ${was}, стало ${now}"
            fi
        done <<< "${STATE_NOW}"
    else
        log "прошлых измерений нет, сохраняю текущие как отправную точку"
    fi

    # Отправная точка обновляется только по итогам удачного прогона. Иначе
    # провал записал бы нули поверх исправных чисел, и следующее сравнение
    # показало бы рост с нуля как норму - потеря данных перестала бы быть видна.
    if [ "${CHECKS_FAIL}" -gt 0 ]; then
        warn "есть отказавшие проверки, прошлые измерения сохранены без изменений"
        return 0
    fi
    printf '%s' "${STATE_NOW}" > "${STATE_FILE}" 2>/dev/null \
        || warn "не удалось сохранить ${STATE_FILE}"
}

########################################
# Ход выполнения
########################################
T_START=$(date +%s)
T_START_HUMAN=$(date '+%F %T')
STATE_NOW=""
RESTORE_LOG=""
RESTORE_RC=0
RESTORE_BAD_HTTP=""
RESTORE_MARKERS=""
APPLIED_CONFIGS=0

# Единственный обработчик выхода: он и службы вернёт, и отчёт отправит - при
# любом исходе, включая прерывание с клавиатуры и аварию скрипта. Код возврата
# снимается первой же командой: любая другая затёрла бы его своим.
_finish() {
    local rc=$?
    trap '' INT TERM EXIT
    if [ -s "${SERVICES_STATE_FILE}" ]; then
        warn "прогон завершился, не вернув службы - поднимаю"
        start_services
    fi
    send_report "${rc}"
    exit "${rc}"
}
trap _finish EXIT
trap 'echo; warn "прервано с клавиатуры"; exit 130' INT TERM

# Проверочное письмо: убедиться, что настройки почты рабочие, не запуская ничего.
if [ "${TEST_MAIL}" = "1" ]; then
    if [ -z "${MAIL_TO}" ]; then
        die "MAIL_TO не задан. Проверьте ${MAIL_ENV}"
    fi
    log "отправляю проверочное письмо на ${MAIL_TO} через ${SMTP_HOST}:${SMTP_PORT}"
    _t=$(mktemp /var/tmp/visiology-restore-mail-XXXXXX.txt)
    {
        echo "Проверочное письмо от visiology-restore-test.sh"
        echo
        echo "Сервер:   $(hostname)"
        echo "Время:    $(date '+%F %T')"
        echo "Настройки взяты из ${MAIL_ENV}"
        echo "Релей:    ${SMTP_HOST}:${SMTP_PORT}"
    } > "${_t}"
    _mail_send "[visiology-restore-test] проверка почты с $(hostname)" "${_t}"
    rm -f "${_t}"
    log "готово. Если письмо не пришло - смотрите предупреждения выше"
    trap - EXIT INT TERM
    exit 0
fi

log "=== начало ==="
log "сервер: $(hostname), проект: ${PROJECT}, версия: ${VERSION:-неизвестна}"

if [ "${DO_RESTORE}" = "1" ]; then
    if [ -z "${ARCHIVE}" ]; then
        ARCHIVE=$(find_latest_archive)
        [ -n "${ARCHIVE}" ] || die "архив не найден.
     Искал по маске *-backup-v*.tar.gz в ${SCRIPT_DIR}, ${BACKUP_DIR}
     и в подкаталогах первого уровня. Укажите путь через --archive."
        log "найден самый свежий архив: ${ARCHIVE}"
    else
        ARCHIVE=$(readlink -f -- "${ARCHIVE}" 2>/dev/null || printf '%s' "${ARCHIVE}")
        log "архив задан явно: ${ARCHIVE}"
    fi

    preflight
    confirm

    # Возврат служб при любом исходе обеспечивает обработчик выхода: он видит
    # запись о погашенных службах и поднимает их, даже если прогон оборвался.
    [ "${STOP_SERVICES}" = "1" ] && stop_services

    run_restore

    # Реплики возвращаются до штатного цикла: что именно делает run.sh, мы не
    # знаем, и отдавать ему платформу с погашенными службами неправильно.
    [ "${STOP_SERVICES}" = "1" ] && start_services

    if [ "${APPLY_CONFIGS}" = "1" ]; then
        apply_configs
    else
        log "цикл применения конфигураций пропущен (--no-apply-configs)"
        log "  платформа осталась на прежних настройках"
    fi

    wait_services || true
else
    log "восстановление пропущено (--tests-only)"
fi

if [ "${DO_TESTS}" = "1" ]; then
    echo
    log "=== проверки ==="
    check_services
    check_health
    check_postgres
    check_clickhouse
    check_http
    check_login
    echo
    compare_state
else
    log "проверки пропущены (--restore-only)"
fi

# Уборка после всего: если восстановление сорвалось, содержимое каталога может
# понадобиться для разбора, поэтому чистим только успешный прогон.
if [ "${DO_RESTORE}" = "1" ] && [ "${KEEP_BACKUP_DIR}" != "1" ]; then
    if [ "${RESTORE_RC}" -eq 0 ] && [ -z "${RESTORE_BAD_HTTP}" ]; then
        cleanup_backup_dir
    else
        log "каталог ${BACKUP_DIR%/}/backup оставлен для разбора: восстановление завершилось с ошибкой"
    fi
fi

########################################
# Итог
########################################
T_END=$(date +%s)
echo
log "=== итог за ~$(( (T_END - T_START) / 60 )) мин ==="

if [ "${DO_RESTORE}" = "1" ]; then
    log "восстановление: код ${RESTORE_RC}, журнал ${RESTORE_LOG}"
    [ -n "${RESTORE_BAD_HTTP}" ] && log "  backup-service отвечал кодами: ${RESTORE_BAD_HTTP}"
    [ -n "${RESTORE_MARKERS}" ]  && log "  в выводе были признаки ошибок, см. журнал"
    [ "${APPLIED_CONFIGS}" = "1" ] && log "  конфигурации применены, платформа перезапущена"
fi

if [ "${DO_TESTS}" = "1" ]; then
    log "проверок пройдено: ${CHECKS_OK}, замечаний: ${CHECKS_WARN}, отказов: ${CHECKS_FAIL}"
    if [ "${CHECKS_FAIL}" -gt 0 ]; then
        log "отказавшие проверки:"
        printf '%s\n' "${FAILED_LIST[@]}" | sed 's/^/    - /'
    fi
fi

# Восстановление, отчитавшееся ошибкой, - это отказ, даже если проверки прошли:
# платформа могла подняться на прежних данных, а не на восстановленных.
RC=0
[ "${CHECKS_FAIL}" -gt 0 ] && RC=1
if [ "${DO_RESTORE}" = "1" ]; then
    { [ "${RESTORE_RC}" -ne 0 ] || [ -n "${RESTORE_BAD_HTTP}" ]; } && RC=1
fi

if [ "${RC}" -eq 0 ]; then
    log "РЕЗУЛЬТАТ: всё в порядке"
else
    log "РЕЗУЛЬТАТ: есть проблемы, см. выше"
fi
exit "${RC}"
