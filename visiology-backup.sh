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

# Версия платформы (определяется после source config.env - см. ниже).
COMMAND_LINE="$0 $*"
error_output=/dev/null

# Парсинг аргументов: -d/--debug (трассировка), -h/--help
while [ "$1" != "" ]; do
    case "$1" in
        "-?" | "-h" | "--help")
            echo "Usage: $0 [-d|--debug] [-h|--help]"
            echo "  -d, --debug   режим отладки (трассировка команд, показ ошибок)"
            echo "  -h, --help    эта справка"
            echo
            echo "Полный бэкап Visiology (postgres, smartforms, minio, keycloak,"
            echo "секреты, custom) + консистентный ClickHouse через LVM-снапшот."
            exit 0
            ;;
        "-d" | "--debug")
            set -x
            error_output=/dev/fd/1
            ;;
        *)
            echo "Неизвестный аргумент: $1"
            echo "См. справку: $0 -h"
            exit 127
            ;;
    esac
    shift
done

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

LOG_TAG="[visiology-backup]"
log() { echo "$(date '+%F %T') ${LOG_TAG} $*"; }
die() { echo "$(date '+%F %T') ${LOG_TAG} ОШИБКА: $*" >&2; exit 1; }

CH_STARTED=0
SNAP_MOUNTED=0
SNAP_CREATED=0
CH_COPY_CREATED=0

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
    free_mb=$(sudo pvs --noheadings -o pv_free --units m "${SNAP_PV}" 2>/dev/null | tr -d ' m<' | cut -d. -f1)
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

    local err_dir
    err_dir=$(mktemp -d)
    export CH_TEMP_NAME CH_DB sql_dir data_dir err_dir
    _dump_one() {
        local table="$1"
        [ -n "${table}" ] || return 0
        if ! sudo docker exec "${CH_TEMP_NAME}" clickhouse-client -d "${CH_DB}" \
                -q "SHOW CREATE TABLE \"${table}\"" --format TabSeparatedRaw \
                > "${sql_dir}/${table}.sql" 2>"${err_dir}/${table}.err"; then
            rm -f "${sql_dir}/${table}.sql"; return 1
        fi
        if ! sudo docker exec "${CH_TEMP_NAME}" clickhouse-client -d "${CH_DB}" \
                -q "SELECT * FROM \"${table}\" FORMAT Native" \
                > "${data_dir}/${table}" 2>>"${err_dir}/${table}.err"; then
            rm -f "${data_dir}/${table}"; return 1
        fi
        rm -f "${err_dir}/${table}.err"; return 0
    }
    export -f _dump_one

    xargs -P "${DUMP_PARALLEL}" -I {} bash -c '_dump_one "$@"' _ {} < "${tables_file}" || true

    local done_cnt
    done_cnt=$(find "${sql_dir}" -name '*.sql' | wc -l)
    log "  выгружено таблиц: ${done_cnt} из ${total}"
    [ "${done_cnt}" -gt 0 ] || die "не выгружено ни одной таблицы"

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
container_id=$(docker ps | grep "${PROJECT}_backup-service" | awk '{ print $1 }')
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
keycloak_container_id=$(docker ps | grep "${PROJECT}_keycloak" | awk '{ print $1 }')
docker exec -it "${keycloak_container_id}" /opt/keycloak/bin/kc.sh export --file /opt/keycloak/visiology-realm.json --realm "${KEYCLOAK_REALM}" > ${error_output} || true
docker cp "${keycloak_container_id}":/opt/keycloak/visiology-realm.json "${MAIN_BACKUP_DIR}/visiology-realm.json"
m2m_secret=$(docker exec -it "${keycloak_container_id}" cat /run/secrets/KEYCLOAK_M2M_SECRET)
grafana_client_secret=$(docker exec -it "${keycloak_container_id}" cat /run/secrets/KEYCLOAK_GRAFANA_CLIENT_SECRET)
public_dashboard_access_secret=$(docker exec -it "${keycloak_container_id}" cat /run/secrets/KEYCLOAK_PUBLIC_DASHBOARD_ACCESS_SECRET)
visiology_admin_realm_secret=$(docker exec -it "${keycloak_container_id}" cat /run/secrets/KEYCLOAK_VISIOLOGY_ADMIN_REALM_SECRET)
m2m_secret_new="68c96230-43e8-4308-b0ae-65835d8de35e"
grafana_client_secret_new="749e9d46-1360-4c65-a0a0-82ba3e369b09"
public_dashboard_access_secret_new="49d410ba-4e0d-4b1a-a064-834f41fb1cfd"
visiology_admin_realm_secret_new="23e5da38-76e9-47d2-e12c-f0da9f039cc6"
sed -i "s/${m2m_secret}/${m2m_secret_new}/g" "${MAIN_BACKUP_DIR}/visiology-realm.json"
sed -i "s/${grafana_client_secret}/${grafana_client_secret_new}/g" "${MAIN_BACKUP_DIR}/visiology-realm.json"
sed -i "s/${public_dashboard_access_secret}/${public_dashboard_access_secret_new}/g" "${MAIN_BACKUP_DIR}/visiology-realm.json"
sed -i "s/${visiology_admin_realm_secret}/${visiology_admin_realm_secret_new}/g" "${MAIN_BACKUP_DIR}/visiology-realm.json"

log "minio..."
mkdir -p "${MN_FILES_HOST_PATH}"
minio_container_id=$(docker ps | grep "${PROJECT}_minio" | awk '{ print $1 }')
if docker exec "${minio_container_id}" test -d "${MN_FILES_CONTAINER_PATH}/dev"; then
    docker cp "${minio_container_id}":${MN_FILES_CONTAINER_PATH}/dev "${MN_FILES_HOST_PATH}"
fi
if docker exec "${minio_container_id}" test -d "${MN_FILES_CONTAINER_PATH}/permanent"; then
    docker cp "${minio_container_id}":${MN_FILES_CONTAINER_PATH}/permanent "${MN_FILES_HOST_PATH}"
fi

log "секреты..."
mkdir -p "${SECRETS_FILES_HOST_PATH}"

# dm-secret (DATA_MANAGEMENT_SECRET_KEY)
dms_container_id=$(docker ps | grep "${PROJECT}_data-management-service" | awk '{ print $1 }')
if [ -n "${dms_container_id}" ]; then
    docker exec -i "${dms_container_id}" sh -c 'cat /run/secrets/DATA_MANAGEMENT_SECRET_KEY; echo -n ""' >> "${SECRETS_FILES_HOST_PATH}/dm-secret.txt"
else
    log "  ! data-management-service не найден, dm-secret пропущен"
fi

# ai-secret (AI_API_KEY)
ai_agent_container_id=$(docker ps | grep "${PROJECT}_ai-agent" | awk '{ print $1 }')
if [ -n "${ai_agent_container_id}" ]; then
    docker exec -i "${ai_agent_container_id}" sh -c 'cat /run/secrets/AI_API_KEY; echo -n ""' >> "${SECRETS_FILES_HOST_PATH}/ai-secret.txt"
else
    log "  ! ai-agent не найден, ai-secret пропущен"
fi

# onec-secret (ONEC_CONNECTOR_FERNET)
onec_container_id=$(docker ps | grep "${PROJECT}_onec-connector.1" | awk '{ print $1 }')
if [ -n "${onec_container_id}" ]; then
    docker exec -i "${onec_container_id}" sh -c 'cat /run/secrets/ONEC_CONNECTOR_FERNET; echo -n ""' >> "${SECRETS_FILES_HOST_PATH}/onec-secret.txt"
else
    log "  ! onec-connector не найден, onec-secret пропущен"
fi

dump_clickhouse

archive_name="$(hostname)-backup-v${VERSION}-$(date '+%Y-%m-%d-%H-%M-%S').tar.gz"
backup_file_dir=$(dirname "$(readlink -f "${BACKUP_DIR}/${archive_name}")")
log "упаковка (${COMPRESSOR%% *})..."
sudo tar -cf - -C "${backup_file_dir}" backup | ${COMPRESSOR} > "${backup_file_dir}/${archive_name}"

t_end=$(date +%s)
elapsed=$(( (t_end - t_start) / 60 ))
log "=== ГОТОВО за ~${elapsed} мин ==="
log "Архив: ${backup_file_dir}/${archive_name} ($(sudo du -h "${backup_file_dir}/${archive_name}" 2>/dev/null | cut -f1))"
