#!/bin/bash -e
#
# visiology-backup.sh
#
# Свой оркестратор полного бэкапа Visiology с консистентным ClickHouse.
# Собирает всё в одну папку backup/ и пакует ОДИН раз (без перепаковки).
#
# Не-CH части (postgres, smartforms, minio, keycloak, секреты, custom) делаются
# ТЕМИ ЖЕ командами, что штатный backup.sh. ClickHouse снимается своей логикой:
# LVM-снапшот корня (rw) -> временный CH на снапшоте -> параллельная выгрузка
# в штатный формат Native. Консистентный срез CH без падений.
#
# Кладётся В ТУ ЖЕ ПАПКУ, что штатный backup.sh (нужны config.env/defaults.env
# и относительные пути extended-services/env-files/custom-configs).
#
# ЭТАПЫ:
#   1. backup-service без clickhouse (postgres, smartforms)
#   2. custom scripts / extended / env / configs
#   3. keycloak (export + подмена секретов)
#   4. minio, секреты
#   5. ClickHouse через LVM-снапшот -> Native-выгрузка
#   6. tar один раз -> финальный архив
#
# ------------------------------------------------------------------------------
# ВАЖНО ПРО KEYCLOAK (причина, по которой прошлые архивы не поднимались):
# секреты из /run/secrets ЧИТАЮТСЯ ТОЛЬКО ЧЕРЕЗ `docker exec -i` (без -t).
# С флагом -t docker выделяет псевдотерминал, tty-дисциплина превращает \n в \r\n,
# и в переменную попадает хвостовой \r. Такой шаблон sed не находит в realm-json ->
# подмена на болванку молча не срабатывает -> в архиве остаются секреты ИСХОДНОГО
# стенда -> restore.sh не находит болванок, не подставляет секреты целевого стенда ->
# invalid_client_credentials. Подробности и порядок лечения: ИСПРАВЛЕНИЯ.md
# ------------------------------------------------------------------------------

# Версия платформы (определяется после source config.env - см. ниже).
COMMAND_LINE="$0 $*"
error_output=/dev/null

# Поведение при рассинхроне секретов Keycloak (см. --ignore-keycloak-secret-mismatch)
IGNORE_KC_MISMATCH=0

# Парсинг аргументов: -d/--debug (трассировка), -h/--help
while [ "$1" != "" ]; do
    case "$1" in
        "-?" | "-h" | "--help")
            echo "Usage: $0 [-d|--debug] [--ignore-keycloak-secret-mismatch] [-h|--help]"
            echo "  -d, --debug   режим отладки (трассировка команд, показ ошибок)"
            echo "  -h, --help    эта справка"
            echo
            echo "  --ignore-keycloak-secret-mismatch"
            echo "                не прерывать бэкап, если секрет клиента в Keycloak"
            echo "                не совпадает с docker secret. Архив в этом случае"
            echo "                помечается файлом KEYCLOAK-SECRETS-NOT-NORMALIZED.txt"
            echo "                и потребует ручной синхронизации после restore."
            echo
            echo "Полный бэкап Visiology (postgres, smartforms, minio, keycloak,"
            echo "секреты, custom) + консистентный ClickHouse через LVM-снапшот."
            exit 0
            ;;
        "-d" | "--debug")
            set -x
            error_output=/dev/fd/1
            ;;
        "--ignore-keycloak-secret-mismatch")
            IGNORE_KC_MISMATCH=1
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            echo "См. справку: $0 -h"
            exit 127
            ;;
    esac
    shift
done

# Ошибка в любом звене конвейера должна валить шаг, а не проглатываться.
set -o pipefail

SCRIPT_DIR=$( dirname -- "$( readlink -f -- "$0")")
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

CH_IMAGE="cr.yandex/crpe1mi33uplrq7coc9d/visiology/release/original/clickhouse-server:24.8.11.51285-alpine"
CH_DB="visiology"
CH_HOST_LABEL="clickhouse-1"
CH_TEMP_NAME="ch_temp_backup"
CH_TEMP_PORT="9001"
CH_VOLUME="visiology3_clickhouse_data"
CH_CPUS="4"
CH_MEMORY="16g"
CH_CPU_SHARES="512"
DUMP_PARALLEL="4"

SNAP_MNT="/mnt/vis_snap"
CH_COPY_DIR="/mnt/disk2/vis_ch_copy"   # копия данных CH (на ней работает временный CH)

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
REALM_FILE="${MAIN_BACKUP_DIR}/visiology-realm.json"
KC_MAP_FILE="${MAIN_BACKUP_DIR}/keycloak-clients.map"
KC_WARN_FILE="${MAIN_BACKUP_DIR}/KEYCLOAK-SECRETS-NOT-NORMALIZED.txt"

LOG_TAG="[visiology-backup]"
log() { echo "$(date '+%F %T') ${LOG_TAG} $*"; }
warn() { echo "$(date '+%F %T') ${LOG_TAG} ВНИМАНИЕ: $*" >&2; }
die() { echo "$(date '+%F %T') ${LOG_TAG} ОШИБКА: $*" >&2; exit 1; }

CH_STARTED=0
SNAP_MOUNTED=0
SNAP_CREATED=0
CH_COPY_CREATED=0

########################################
# Общие помощники
########################################

# Поиск контейнера по подстроке имени. Через docker ps --filter, а не
# `docker ps | grep`: grep ловит совпадения и в колонке IMAGE, а при нескольких
# совпавших строках awk вернёт несколько ID через пробел и docker exec сломается.
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

# Чтение ЗНАЧЕНИЯ секрета для подстановки в sed.
# ТОЛЬКО -i, без -t (см. блок ВАЖНО ПРО KEYCLOAK в шапке).
# tr -d '\r\n' - страховка на случай, если сам файл секрета создан с переводом строки.
read_secret_value() {
    local cid="$1" name="$2" val
    val=$(docker exec -i "${cid}" cat "/run/secrets/${name}" 2>/dev/null | tr -d '\r\n') || true
    [ -n "${val}" ] || die "секрет ${name} пуст или недоступен в контейнере ${cid}"
    printf '%s' "${val}"
}

# Копирование секрета В ФАЙЛ архива - байт-в-байт, БЕЗ нормализации.
# Здесь \r\n убирать НЕЛЬЗЯ: restore.sh отдаёт этот файл в `docker secret create`,
# и секрет должен восстановиться ровно тем же набором байт, иначе Fernet-ключи
# (DATA_MANAGEMENT_SECRET_KEY, ONEC_CONNECTOR_FERNET) перестанут расшифровывать данные.
# Отличие от штатного скрипта: '>' вместо '>>' (append при повторном прогоне
# склеивал два ключа в один файл) и проверка, что файл не пустой.
copy_secret_file() {
    local cid="$1" name="$2" out="$3"
    docker exec -i "${cid}" cat "/run/secrets/${name}" > "${out}" \
        || die "не удалось прочитать секрет ${name} из контейнера ${cid}"
    [ -s "${out}" ] || die "секрет ${name} сохранён пустым: ${out}"
}

# Экранирование для sed: BRE-шаблон и строка замены (разделитель '/').
_esc_bre()  { printf '%s' "$1" | sed 's@[][\\.*^$/]@\\&@g'; }
_esc_repl() { printf '%s' "$1" | sed 's@[\\&/]@\\&@g'; }

# Подмена секрета в realm-json с проверкой ДО и ПОСЛЕ.
# Именно отсутствие этих проверок делало поломку невидимой: sed возвращает 0,
# даже когда не нашёл ни одного совпадения.
replace_in_realm() {
    local old="$1" new="$2" label="$3"

    [ -n "${old}" ] || die "${label}: пустое исходное значение секрета"
    [ -n "${new}" ] || die "${label}: пустая болванка"

    if ! grep -qF -- "${old}" "${REALM_FILE}"; then
        if [ "${IGNORE_KC_MISMATCH}" = "1" ]; then
            warn "${label}: значение из /run/secrets не найдено в visiology-realm.json - подмена пропущена"
            echo "${label}: секрет клиента в Keycloak не совпадает с docker secret, болванка не подставлена" >> "${KC_WARN_FILE}"
            return 0
        fi
        die "${label}: значение из /run/secrets НЕ НАЙДЕНО в visiology-realm.json.
     Это ровно та ситуация, из-за которой архив потом не поднимается: restore.sh
     не найдёт болванку и оставит в realm секреты чужого стенда.
     Возможные причины:
       1) секрет клиента в Keycloak разошёлся с docker secret на ЭТОМ стенде -
          синхронизируйте: ./visiology-keycloak-sync.sh
       2) kc.sh export отдал устаревший/неполный realm - проверьте вывод с -d
     Обойти проверку осознанно: $0 --ignore-keycloak-secret-mismatch"
    fi

    sed -i "s/$(_esc_bre "${old}")/$(_esc_repl "${new}")/g" "${REALM_FILE}"

    grep -qF -- "${new}" "${REALM_FILE}" || die "${label}: болванка не появилась в realm-json"
    if grep -qF -- "${old}" "${REALM_FILE}"; then
        die "${label}: исходный секрет остался в realm-json после подмены"
    fi
    log "  ${label}: подменён на болванку"
}

# Карта "имя docker secret -> clientId" по фактическим значениям секретов.
# Кладётся в архив и позволяет после restore точечно синхронизировать секреты
# (visiology-keycloak-sync.sh), не угадывая clientId руками.
# Секреты передаются в python ТОЛЬКО через stdin - в argv/ps они не светятся.
write_keycloak_client_map() {
    command -v python3 >/dev/null 2>&1 || { warn "python3 не найден, keycloak-clients.map не создан"; return 0; }
    local py; py=$(mktemp)
    cat > "${py}" <<'PYEOF'
import json, sys
realm_path, out_path = sys.argv[1], sys.argv[2]
pairs = {}
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    name, _, value = line.partition("=")
    pairs[value] = name
with open(realm_path, encoding="utf-8") as fh:
    realm = json.load(fh)
found = []
for client in realm.get("clients", []):
    name = pairs.get(client.get("secret"))
    if name:
        found.append("%s=%s" % (name, client.get("clientId", "")))
with open(out_path, "w", encoding="utf-8") as fh:
    fh.write("\n".join(sorted(set(found))) + ("\n" if found else ""))
print(len(found))
PYEOF
    local cnt
    cnt=$(printf '%s\n' \
        "KEYCLOAK_M2M_SECRET=${m2m_secret}" \
        "KEYCLOAK_GRAFANA_CLIENT_SECRET=${grafana_client_secret}" \
        "KEYCLOAK_PUBLIC_DASHBOARD_ACCESS_SECRET=${public_dashboard_access_secret}" \
        "KEYCLOAK_VISIOLOGY_ADMIN_REALM_SECRET=${visiology_admin_realm_secret}" \
        | python3 "${py}" "${REALM_FILE}" "${KC_MAP_FILE}") || cnt=""
    rm -f "${py}"
    if [ -n "${cnt}" ]; then
        log "  карта клиентов keycloak: сопоставлено ${cnt} из 4"
        [ "${cnt}" = "4" ] || warn "не все секреты сопоставлены с клиентами Keycloak (см. ${KC_MAP_FILE})"
    else
        warn "не удалось построить keycloak-clients.map (realm-json не распарсился?)"
    fi
}

_umount_lazy() {
    local mp="$1"
    mountpoint -q "${mp}" 2>/dev/null || return 0
    local i
    for i in 1 2 3; do
        if sudo umount "${mp}" >/dev/null 2>&1; then return 0; fi
        sleep 2
    done
    sudo fuser -km "${mp}" >/dev/null 2>&1 || true
    sleep 1
    sudo umount -l "${mp}" >/dev/null 2>&1 || true
}

_remove_snapshot() {
    sudo lvs "${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1 || return 0
    local i
    for i in $(seq 1 20); do
        if sudo lvremove -y "${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1; then return 0; fi
        sudo lvchange -an "${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1 || true
        sleep 3
    done
    return 1
}

cleanup() {
    local rc=$?
    log "очистка CH-ресурсов..."
    if [ "${CH_STARTED}" = "1" ] || sudo docker ps -a --format '{{.Names}}' | grep -q "^${CH_TEMP_NAME}$"; then
        sudo docker stop "${CH_TEMP_NAME}" >/dev/null 2>&1 || true
        sudo docker rm   "${CH_TEMP_NAME}" >/dev/null 2>&1 || true
    fi
    if [ "${SNAP_MOUNTED}" = "1" ] || mountpoint -q "${SNAP_MNT}" 2>/dev/null; then
        _umount_lazy "${SNAP_MNT}"
    fi
    if [ "${SNAP_CREATED}" = "1" ] || sudo lvs "${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1; then
        _remove_snapshot || log "  ! снапшот не удалён: sudo lvremove -y ${VG_NAME}/${SNAP_NAME}"
    fi
    sudo rmdir "${SNAP_MNT}" >/dev/null 2>&1 || true
    sudo rm -rf /tmp/vis_ch_conf >/dev/null 2>&1 || true
    if [ "${CH_COPY_CREATED}" = "1" ] || [ -d "${CH_COPY_DIR}" ]; then
        sudo rm -rf "${CH_COPY_DIR}" >/dev/null 2>&1 || true
    fi
    [ "${rc}" -ne 0 ] && log "завершено с ошибкой (код ${rc})."
    exit "${rc}"
}
trap 'trap "" INT TERM; cleanup' EXIT
trap 'exit 130' INT TERM

dump_clickhouse() {
    log "ClickHouse: снапшот и выгрузка..."

    sudo docker rm -f "${CH_TEMP_NAME}" >/dev/null 2>&1 || true
    if sudo lvs "${VG_NAME}/${SNAP_NAME}" >/dev/null 2>&1; then
        _umount_lazy "${SNAP_MNT}"; _remove_snapshot || true
    fi

    local free_mb
    free_mb=$(sudo pvs --noheadings -o pv_free --units m "${SNAP_PV}" 2>/dev/null | tr -d ' m<' | cut -d. -f1) || free_mb=""
    [ -n "${free_mb}" ] && [ "${free_mb}" -gt 1024 ] || die "нет свободного места на ${SNAP_PV}"
    log "  снапшот (COW ${free_mb}M)"
    sudo lvcreate -s -n "${SNAP_NAME}" -L "${free_mb}M" "${VG_NAME}/${LV_NAME}" "${SNAP_PV}"
    SNAP_CREATED=1

    sudo mkdir -p "${SNAP_MNT}"
    sudo mount -o ro "/dev/${VG_NAME}/${SNAP_NAME}" "${SNAP_MNT}"
    SNAP_MOUNTED=1

    local ch_data_in_snap="${SNAP_MNT}/var/lib/docker/volumes/${CH_VOLUME}/_data"
    [ -d "${ch_data_in_snap}" ] || die "в снапшоте нет данных CH"

    # Копируем данные CH из снапшота, затем снапшот сразу удаляем.
    # Снапшот живёт только на время cp (минуты) - COW не успевает переполниться
    # от записи боевой системы в корень. Выгрузка идёт с копии.
    log "  копирую данные CH в ${CH_COPY_DIR}..."
    sudo rm -rf "${CH_COPY_DIR}"
    sudo mkdir -p "${CH_COPY_DIR}"
    CH_COPY_CREATED=1
    sudo cp -a "${ch_data_in_snap}/." "${CH_COPY_DIR}/"
    log "  копия готова: $(sudo du -sh "${CH_COPY_DIR}" 2>/dev/null | cut -f1)"

    # снапшот больше не нужен - удаляем сразу (COW освобождается)
    log "  удаляю снапшот"
    _umount_lazy "${SNAP_MNT}"
    SNAP_MOUNTED=0
    if _remove_snapshot; then SNAP_CREATED=0; fi

    # Глушащий конфиг: отключаем системные лог-таблицы (чтобы CH не тратил
    # ресурсы и не раздувал копию логами при работе).
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

    log "  временный CH (${CH_CPUS} ядер, ${CH_MEMORY})"
    sudo docker run -d \
        --name "${CH_TEMP_NAME}" \
        --user 101:101 \
        --cpus="${CH_CPUS}" --memory="${CH_MEMORY}" --cpu-shares="${CH_CPU_SHARES}" \
        -v "${CH_COPY_DIR}:/var/lib/clickhouse" \
        -v "${ch_conf_dir}/zz-backup-quiet.xml:/etc/clickhouse-server/config.d/zz-backup-quiet.xml:ro" \
        -p "${CH_TEMP_PORT}:9000" \
        --ulimit nofile=262144:262144 \
        -e CLICKHOUSE_SKIP_USER_SETUP=1 \
        "${CH_IMAGE}" >/dev/null
    CH_STARTED=1

    local ok=0 i
    for i in $(seq 1 90); do
        if sudo docker exec "${CH_TEMP_NAME}" clickhouse-client --query "SELECT 1" >/dev/null 2>&1; then
            ok=1; break
        fi
        if ! sudo docker ps --format '{{.Names}}' | grep -q "^${CH_TEMP_NAME}$"; then
            sudo docker logs "${CH_TEMP_NAME}" 2>&1 | tail -20 | while IFS= read -r l; do log "      ${l}"; done
            die "временный CH упал при старте"
        fi
        sleep 2
    done
    [ "${ok}" = "1" ] || { sudo docker logs "${CH_TEMP_NAME}" 2>&1 | tail -20; die "временный CH не поднялся"; }

    sudo docker exec "${CH_TEMP_NAME}" clickhouse-client --query "SYSTEM STOP MERGES" >/dev/null 2>&1 || true
    sudo docker exec "${CH_TEMP_NAME}" clickhouse-client --query "SYSTEM STOP MOVES"  >/dev/null 2>&1 || true
    sudo docker exec "${CH_TEMP_NAME}" clickhouse-client --query "EXISTS DATABASE ${CH_DB}" | grep -q 1 \
        || die "временный CH не видит базу ${CH_DB}"

    local ch_base="${MAIN_BACKUP_DIR}/clickhouse/${CH_HOST_LABEL}"
    local sql_dir="${ch_base}/sql"
    local data_dir="${ch_base}/data"
    sudo mkdir -p "${sql_dir}" "${data_dir}"
    sudo chown -R "$(id -u):$(id -g)" "${MAIN_BACKUP_DIR}/clickhouse"

    local tables_file
    tables_file=$(mktemp)
    sudo docker exec "${CH_TEMP_NAME}" clickhouse-client -d "${CH_DB}" -q "SHOW TABLES FORMAT TSVRaw" \
        | grep -v 'jemalloc' | grep -v '^cache_queries_' > "${tables_file}" || true
    local total
    total=$(wc -l < "${tables_file}")
    [ "${total}" -gt 0 ] || die "не получен список таблиц"
    log "  таблиц к выгрузке: ${total}"

    # Справочно: движки таблиц. View/MaterializedView/Dictionary выгружаются как
    # обычные таблицы (SELECT * ... FORMAT Native), и при restore INSERT в них
    # может не пройти. Если строки ниже не пустые - сверьтесь со штатным архивом.
    local odd
    odd=$(sudo docker exec "${CH_TEMP_NAME}" clickhouse-client -q \
        "SELECT engine || ': ' || toString(count()) FROM system.tables
         WHERE database='${CH_DB}' AND (engine LIKE '%View' OR engine='Dictionary')
         GROUP BY engine FORMAT TSVRaw" 2>/dev/null) || odd=""
    if [ -n "${odd}" ]; then
        warn "в базе есть представления/словари, они попадут в дамп как обычные таблицы:"
        printf '%s\n' "${odd}" | while IFS= read -r l; do warn "    ${l}"; done
    fi

    local err_dir
    err_dir=$(mktemp -d)
    export CH_TEMP_NAME CH_DB sql_dir data_dir err_dir
    _dump_one() {
        local table="$1"
        [ -n "${table}" ] || return 0
        if ! sudo docker exec "${CH_TEMP_NAME}" clickhouse-client -d "${CH_DB}" \
                -q "SHOW CREATE TABLE \"${table}\"" --format TabSeparatedRaw \
                > "${sql_dir}/${table}.sql" 2>"${err_dir}/${table}.err"; then
            rm -f "${sql_dir}/${table}.sql" "${data_dir}/${table}"; return 1
        fi
        if ! sudo docker exec "${CH_TEMP_NAME}" clickhouse-client -d "${CH_DB}" \
                -q "SELECT * FROM \"${table}\" FORMAT Native" \
                > "${data_dir}/${table}" 2>>"${err_dir}/${table}.err"; then
            # ВАЖНО: удаляем и .sql тоже, иначе таблица считалась выгруженной,
            # хотя данных для неё в архиве нет.
            rm -f "${data_dir}/${table}" "${sql_dir}/${table}.sql"; return 1
        fi
        rm -f "${err_dir}/${table}.err"; return 0
    }
    export -f _dump_one

    xargs -P "${DUMP_PARALLEL}" -I {} bash -c '_dump_one "$@"' _ {} < "${tables_file}" || true

    local done_cnt failed_cnt
    done_cnt=$(find "${sql_dir}" -name '*.sql' | wc -l)
    failed_cnt=$(find "${err_dir}" -name '*.err' | wc -l)
    log "  выгружено таблиц: ${done_cnt} из ${total}"

    # Раньше проверялось только "выгружена хотя бы одна таблица" - неполный дамп
    # уезжал в архив как успешный и вскрывался только на restore.
    if [ "${failed_cnt}" -gt 0 ] || [ "${done_cnt}" -ne "${total}" ]; then
        warn "не выгружено таблиц: $(( total - done_cnt )), ошибок: ${failed_cnt}"
        find "${err_dir}" -name '*.err' -printf '%f\n' 2>/dev/null | head -10 \
            | while IFS= read -r f; do warn "    ${f%.err}"; done
        rm -rf "${err_dir}" "${tables_file}"
        die "ClickHouse выгружен не полностью - архив собирать нельзя"
    fi

    rm -rf "${err_dir}" "${tables_file}"
}

########################################
# MAIN
########################################
t_start=$(date +%s)
log "=== СТАРТ полного бэкапа Visiology ==="

rm -rf "${MAIN_BACKUP_DIR:?}"/*
mkdir -p "${MAIN_BACKUP_DIR}"
echo "${COMMAND_LINE}" > "${MAIN_BACKUP_DIR}/${COMMAND_FILE}"

log "backup-service: postgres, smartforms (без clickhouse)..."
container_id=$(require_container "${PROJECT}_backup-service" "backup-service")
docker exec "${container_id}" curl -sLv --request POST --url http://127.0.0.1:8000 \
    --header 'Content-Type: application/json' \
    --data '{"command":"backup","databases":["postgres", "smartforms"],"is_cleanup":true}'

log "custom scripts..."
mkdir -p "${DV_CUSTOM_SCRIPTS_HOST_PATH}"
cp -ra "${DV_CUSTOM_SCRIPTS_CONTAINER_PATH}" "${DV_CUSTOM_SCRIPTS_HOST_PATH}"

log "extended services, env, configs..."
cp -ra "${EXTENDED_SERVICES_PATH}" "${MAIN_BACKUP_DIR}/${EXTENDED_SERVICES_PATH}"
cp -ra "${ENV_FILES_PATH}"         "${MAIN_BACKUP_DIR}/${ENV_FILES_PATH}"
cp -ra "${CUSTOM_CONFIGS_PATH}"    "${MAIN_BACKUP_DIR}/${CUSTOM_CONFIGS_PATH}"

log "keycloak..."
keycloak_container_id=$(require_container "${PROJECT}_keycloak" "keycloak")

# Удаляем прошлый экспорт внутри контейнера: иначе при неудачном kc.sh export
# (ошибка глушится через || true) в архив уехал бы СТАРЫЙ realm из прошлого прогона.
docker exec -i "${keycloak_container_id}" rm -f /opt/keycloak/visiology-realm.json 2>/dev/null || true
docker exec "${keycloak_container_id}" /opt/keycloak/bin/kc.sh export \
    --file /opt/keycloak/visiology-realm.json --realm "${KEYCLOAK_REALM}" > "${error_output}" 2>&1 || true
docker exec -i "${keycloak_container_id}" test -s /opt/keycloak/visiology-realm.json \
    || die "kc.sh export не создал /opt/keycloak/visiology-realm.json (запустите с -d и посмотрите вывод)"
docker cp "${keycloak_container_id}":/opt/keycloak/visiology-realm.json "${REALM_FILE}"
grep -q '"realm"' "${REALM_FILE}" || die "visiology-realm.json не похож на экспорт realm"

# Чтение секретов: docker exec -i, БЕЗ -t. Это и есть починка (см. шапку файла).
m2m_secret=$(read_secret_value "${keycloak_container_id}" KEYCLOAK_M2M_SECRET)
grafana_client_secret=$(read_secret_value "${keycloak_container_id}" KEYCLOAK_GRAFANA_CLIENT_SECRET)
public_dashboard_access_secret=$(read_secret_value "${keycloak_container_id}" KEYCLOAK_PUBLIC_DASHBOARD_ACCESS_SECRET)
visiology_admin_realm_secret=$(read_secret_value "${keycloak_container_id}" KEYCLOAK_VISIOLOGY_ADMIN_REALM_SECRET)

# Болванки. ОБЯЗАНЫ совпадать байт-в-байт с *_old в штатном restore.sh.
m2m_secret_new="68c96230-43e8-4308-b0ae-65835d8de35e"
grafana_client_secret_new="749e9d46-1360-4c65-a0a0-82ba3e369b09"
public_dashboard_access_secret_new="49d410ba-4e0d-4b1a-a064-834f41fb1cfd"
visiology_admin_realm_secret_new="23e5da38-76e9-47d2-e12c-f0da9f039cc6"

# Карта clientId строится ДО подмены - по реальным значениям секретов.
write_keycloak_client_map

replace_in_realm "${m2m_secret}"                    "${m2m_secret_new}"                    "KEYCLOAK_M2M_SECRET"
replace_in_realm "${grafana_client_secret}"         "${grafana_client_secret_new}"         "KEYCLOAK_GRAFANA_CLIENT_SECRET"
replace_in_realm "${public_dashboard_access_secret}" "${public_dashboard_access_secret_new}" "KEYCLOAK_PUBLIC_DASHBOARD_ACCESS_SECRET"
replace_in_realm "${visiology_admin_realm_secret}"  "${visiology_admin_realm_secret_new}"  "KEYCLOAK_VISIOLOGY_ADMIN_REALM_SECRET"

# Контроль: в realm-json не должно остаться ни одного секрета исходного стенда.
for _s in "${m2m_secret}" "${grafana_client_secret}" "${public_dashboard_access_secret}" "${visiology_admin_realm_secret}"; do
    if grep -qF -- "${_s}" "${REALM_FILE}"; then
        die "в visiology-realm.json остался секрет исходного стенда - архив непереносим"
    fi
done
unset _s
# Байт \r внутри JSON-строки Keycloak при импорте не примет (Jackson валит на
# unquoted control char), а restore.sh глушит ошибку импорта через || true -
# realm при этом уже удалён. Проверяем явно.
if LC_ALL=C grep -q $'\r' "${REALM_FILE}"; then
    die "в visiology-realm.json есть символ \\r - kc.sh import такой файл не примет"
fi
log "  realm-json нормализован, секреты стенда в архив не попали"

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

dump_clickhouse

archive_name="$(hostname)-backup-v${VERSION}-$(date '+%Y-%m-%d-%H-%M-%S').tar.gz"
backup_file_dir=$(dirname "$(readlink -f "${BACKUP_DIR}/${archive_name}")")
log "упаковка (${COMPRESSOR%% *})..."
sudo tar -cf - -C "${backup_file_dir}" backup | ${COMPRESSOR} > "${backup_file_dir}/${archive_name}"
[ -s "${backup_file_dir}/${archive_name}" ] || die "архив не создан или пустой"

if [ -f "${KC_WARN_FILE}" ]; then
    warn "секреты Keycloak НЕ нормализованы - после restore обязательно выполните:"
    warn "    ./visiology-keycloak-sync.sh"
fi

t_end=$(date +%s)
elapsed=$(( (t_end - t_start) / 60 ))
log "=== ГОТОВО за ~${elapsed} мин ==="
log "Архив: ${backup_file_dir}/${archive_name} ($(sudo du -h "${backup_file_dir}/${archive_name}" 2>/dev/null | cut -f1))"
