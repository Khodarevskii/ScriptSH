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

# Keycloak за обратным прокси лежит не по стандартному /auth и не по /realms.
KEYCLOAK_PREFIX="/v3/keycloak"
# Клиент и набор прав для проверки входа - как в рабочем примере получения
# токена. Прямой вход по логину и паролю у этого клиента разрешён, браузер не
# нужен.
LOGIN_CLIENT="visiology_designer"
LOGIN_SCOPE="openid data_management_service formula_engine workspace_service dashboard_service forms_service groups"

LOGIN_USER=""
LOGIN_PASSWORD=""
PASSWORD_FILE=""

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
                      по умолчанию https://127.0.0.1
      --wait СЕК      сколько ждать подъёма служб после восстановления
                      по умолчанию 900
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
    pushd "${SCRIPT_DIR}" >/dev/null || die "не удалось перейти в ${SCRIPT_DIR}"
    # shellcheck disable=SC1091
    source config.env
    # shellcheck disable=SC1091
    [ -f defaults.env ] && source defaults.env
    popd >/dev/null || true
else
    log "config.env рядом не найден, беру значения по умолчанию"
fi

# Имя стека спрашиваем у самого docker: он знает его точно, а совпадение с
# config.env не гарантировано, если стек переименовывали.
if [ -z "${PROJECT}" ]; then
    PROJECT=$(sudo docker service ls --format '{{.Name}}' 2>/dev/null \
              | grep -m1 '_' | cut -d_ -f1)
    [ -n "${PROJECT}" ] && log "имя стека определено по docker: ${PROJECT}"
fi

: "${PROJECT:=visiology3}"
: "${CH_DB:=visiology}"
# Пустая версия отключает сверку версий: сверять не с чем.
VERSION="${VI_VERSION:-}"
RESTORE_SH="${SCRIPT_DIR}/restore.sh"

# Без BACKUP_DIR ищем архив там, где лежим. Место под распаковку проверяется
# по тому же каталогу.
[ -n "${BACKUP_DIR}" ] || BACKUP_DIR="${SCRIPT_DIR}"

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

# Сколько служб не набрали нужное число реплик.
_services_pending() {
    local name reps run want pending=0
    while IFS='|' read -r name reps; do
        [ -n "${name}" ] || continue
        reps=$(_reps_clean "${reps}")
        run="${reps%%/*}"
        want="${reps##*/}"
        [ "${run}" = "${want}" ] || pending=$((pending + 1))
    done < <(_services_raw)
    printf '%s' "${pending}"
}

wait_services() {
    local deadline pending left
    deadline=$(( $(date +%s) + WAIT_SERVICES ))

    log "жду подъёма служб (до ${WAIT_SERVICES} с)"
    while :; do
        pending=$(_services_pending)
        [ -n "${pending}" ] || pending=0
        if [ "${pending}" -eq 0 ]; then
            log "  все службы набрали реплики"
            return 0
        fi
        left=$(( deadline - $(date +%s) ))
        if [ "${left}" -le 0 ]; then
            warn "по истечении ${WAIT_SERVICES} с не поднялись службы: ${pending}"
            return 1
        fi
        log "  ещё поднимаются: ${pending}, осталось ждать ${left} с"
        sleep 30
    done
}

########################################
# Проверка 1. Службы Swarm
########################################
check_services() {
    log "службы Swarm"
    local name reps run want total=0
    while IFS='|' read -r name reps; do
        [ -n "${name}" ] || continue
        total=$((total + 1))
        reps=$(_reps_clean "${reps}")
        run="${reps%%/*}"
        want="${reps##*/}"
        if [ "${run}" = "${want}" ] && [ "${run}" != "0" ]; then
            check_ok "${name} ${reps}"
        elif [ "${want}" = "0" ]; then
            check_warn "${name} ${reps} - служба выключена намеренно"
        else
            check_fail "${name} ${reps} - реплики не набраны"
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

_check_one_postgres() {
    local cid="$1" cname="$2" user dbs db n size

    # Пользователь читается из окружения контейнера, а не угадывается. Заодно
    # это признак того, что перед нами действительно Postgres: у чужого образа
    # переменной не будет, и придираться к нему незачем.
    user=$(_dexec "${cid}" printenv POSTGRES_USER | tr -d '\r\n')
    if [ -z "${user}" ]; then
        check_warn "${cname}: не похоже на Postgres (нет POSTGRES_USER), пропущен"
        return
    fi

    # Ключ -w запрещает psql спрашивать пароль. Без него при парольном доступе
    # он ждал бы ввода, которого в неинтерактивном запуске не будет никогда, и
    # прогон висел бы до бесконечности.
    if ! _dexec "${cid}" psql -w -U "${user}" -tAc 'select 1' >/dev/null; then
        check_fail "${cname}: не отвечает на запрос (пользователь ${user})"
        return
    fi
    check_ok "${cname}: отвечает"

    dbs=$(_dexec "${cid}" psql -w -U "${user}" -tAc \
        "select datname from pg_database where datistemplate = false and datname <> 'postgres'" \
        | tr -d '\r')
    if [ -z "${dbs}" ]; then
        check_fail "${cname}: нет ни одной базы платформы"
        return
    fi

    for db in ${dbs}; do
        n=$(_dexec "${cid}" psql -w -U "${user}" -d "${db}" -tAc \
            "select count(*) from information_schema.tables
             where table_schema not in ('pg_catalog','information_schema')" \
            | tr -d '\r ')
        [ -n "${n}" ] || n=0

        # Размер вместо подсчёта строк: пересчитывать строки во всех таблицах
        # долго и незачем, а размер сразу показывает, лежат ли за схемой данные.
        size=$(_dexec "${cid}" psql -w -U "${user}" -tAc \
            "select pg_database_size('${db}')" | tr -d '\r ')
        [ -n "${size}" ] || size=0

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

_check_one_clickhouse() {
    local cid="$1" cname="$2" n rows

    if ! _dexec "${cid}" clickhouse-client --query 'SELECT 1' >/dev/null; then
        check_fail "${cname}: не отвечает на запрос"
        return
    fi
    check_ok "${cname}: отвечает"

    n=$(_dexec "${cid}" clickhouse-client --query \
        "SELECT count() FROM system.tables WHERE database = '${CH_DB}'" | tr -d '\r ')
    [ -n "${n}" ] || n=0
    if [ "${n}" -eq 0 ]; then
        check_fail "${cname}: в базе ${CH_DB} нет таблиц - данные не восстановлены"
    else
        check_ok "${cname}: таблиц ${n}"
    fi
    STATE_NOW="${STATE_NOW}ch:${cname}=${n}"$'\n'

    # Строки берутся из system.parts, а не count() по таблицам: это одна быстрая
    # выборка из метаданных вместо обхода данных. Таблицы могут существовать
    # пустыми - схема восстановилась, а данные нет.
    rows=$(_dexec "${cid}" clickhouse-client --query \
        "SELECT sum(rows) FROM system.parts WHERE database = '${CH_DB}' AND active" \
        | tr -d '\r ')
    [ -n "${rows}" ] || rows=0
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

    local base="${HTTP_URL}"
    [ -n "${base}" ] || base="https://127.0.0.1"
    base="${base%/}"

    # Корень. Здесь годится широкий диапазон: платформа отвечает как 200, так и
    # перенаправлением на вход в Keycloak. Значение имеет только то, что ответ
    # вообще пришёл и это не отказ шлюза.
    local code
    code=$(_http_code "${base}/")
    case "${code}" in
        000) check_fail "${base}/ - соединение не установлено" ;;
        5*)  check_fail "${base}/ - код ${code}, обратный прокси жив, а служба за ним нет" ;;
        *)   check_ok   "${base}/ - код ${code}" ;;
    esac

    # Keycloak. Ответ на этот адрес означает, что жив и сам Keycloak, и его база:
    # конфигурацию realm он читает из Postgres. Первый путь - фактический для
    # нашей сборки, он же используется в рабочем примере получения токена.
    # Остальные оставлены на случай другой раскладки обратного прокси.
    local realm="${KEYCLOAK_REALM:-Visiology}"
    local u body found=0
    for u in "${base}${KEYCLOAK_PREFIX}/realms/${realm}/.well-known/openid-configuration" \
             "${base}/auth/realms/${realm}/.well-known/openid-configuration" \
             "${base}/realms/${realm}/.well-known/openid-configuration"; do
        body=$(curl -sS -k -m "${HTTP_TIMEOUT}" "${u}" 2>/dev/null) || body=""
        if printf '%s' "${body}" | grep -q '"issuer"'; then
            check_ok "Keycloak отвечает и отдаёт конфигурацию realm ${realm}"
            found=1
            break
        fi
    done
    [ "${found}" = "1" ] || check_fail "Keycloak не отдал конфигурацию realm ${realm} - проверьте его и его базу"
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

    local base="${HTTP_URL}"
    [ -n "${base}" ] || base="https://127.0.0.1"
    base="${base%/}"
    local realm="${KEYCLOAK_REALM:-Visiology}"
    local kc="${base}${KEYCLOAK_PREFIX}/realms/${realm}/protocol/openid-connect"

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
STATE_NOW=""
RESTORE_LOG=""
RESTORE_RC=0
RESTORE_BAD_HTTP=""
RESTORE_MARKERS=""

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
    run_restore
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
