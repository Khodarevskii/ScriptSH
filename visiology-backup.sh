#!/bin/bash -e
#
# visiology-backup.sh - полный бэкап платформы Visiology (Docker Swarm).
#
# Postgres, Smart Forms, MinIO, Keycloak, docker secrets и пользовательские
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
COMMAND_LINE="$0 $*"
error_output=/dev/null

# Оставить в realm-json секреты этого стенда, не подменяя их на заглушки
KC_KEEP_SECRETS=0
# Разрешить неполный дамп ClickHouse и выгрузку одной конкретной ноды
ALLOW_PARTIAL_CH=0
CH_ONLY_NODE=""
CH_ONLY=0

# Парсинг аргументов: -d/--debug (трассировка), -h/--help
while [ "$1" != "" ]; do
    case "$1" in
        "-?" | "-h" | "--help")
            echo "Usage: $0 [-d|--debug] [--ch-node ИМЯ] [--allow-partial-clickhouse]"
            echo "          [--keep-keycloak-secrets] [--ch-only] [-h|--help]"
            echo "  -d, --debug   режим отладки (трассировка команд, показ ошибок)"
            echo "  -h, --help    эта справка"
            echo
            echo "  --ch-node ИМЯ выгрузить только ноду ClickHouse с этим именем"
            echo "                хоста (как в CLICKHOUSE_HOSTS, напр. clickhouse-1)."
            echo "                Нужно, когда ноды CH разнесены по разным хостам:"
            echo "                скрипт снимает LVM-снапшот ЛОКАЛЬНОГО корня и"
            echo "                чужие ноды снять не может."
            echo "  --ch-only     только ClickHouse: без postgres/keycloak/minio/"
            echo "                секретов, без очистки backup/ и без упаковки."
            echo "                Режим для дополнительных хостов CH: на каждом"
            echo "                \"$0 --ch-only --ch-node ИМЯ\", затем каталоги"
            echo "                backup/clickhouse/ИМЯ переносятся к основному"
            echo "                хосту и пакуются вместе с ним."
            echo "  --allow-partial-clickhouse"
            echo "                не прерывать бэкап, если часть нод CH недоступна"
            echo "                или часть таблиц не выгрузилась (словари,"
            echo "                Distributed - у временного CH нет доступа к их"
            echo "                источникам и к конфигу кластера)."
            echo "                Архив помечается файлом CLICKHOUSE-PARTIAL.txt"
            echo "                со списком того, что не попало."
            echo
            echo "  --keep-keycloak-secrets"
            echo "                не подменять секреты клиентов в realm-json на"
            echo "                заглушки. В архив попадут секреты этого стенда,"
            echo "                и после восстановления их потребуется"
            echo "                синхронизировать вручную."
            echo
            echo "Полный бэкап Visiology (postgres, smartforms, minio, keycloak,"
            echo "секреты, custom) + консистентный ClickHouse через LVM-снапшот."
            echo
            echo "Коды возврата: 0 - успех, 1 - ошибка, 3 - предыдущий прогон"
            echo "ещё идёт, 20/127 - неверные аргументы."
            exit 0
            ;;
        "-d" | "--debug")
            set -x
            error_output=/dev/fd/1
            ;;
        "--keep-keycloak-secrets")
            KC_KEEP_SECRETS=1
            ;;
        "--allow-partial-clickhouse")
            ALLOW_PARTIAL_CH=1
            ;;
        "--ch-only")
            CH_ONLY=1
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

# Защита от параллельных запусков: прогон длится часами, и наложение расписания
# привело бы к попытке создать снапшот с уже занятым именем.
LOCK_DIR=/var/lock
[ -w "${LOCK_DIR}" ] || LOCK_DIR=/tmp
LOCK_FILE="${LOCK_DIR}/visiology-backup.lock"
exec 9>"${LOCK_FILE}"
if ! flock -n 9; then
    echo "$(date '+%F %T') [visiology-backup] предыдущий бэкап ещё выполняется (${LOCK_FILE}), выходим" >&2
    exit 3
fi

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
KC_SERVER="http://localhost:8080/v3/keycloak"
REALM_FILE="${MAIN_BACKUP_DIR}/visiology-realm.json"
KC_IDP_DIR="${MAIN_BACKUP_DIR}/keycloak-idp"
KC_MAP_FILE="${MAIN_BACKUP_DIR}/keycloak-clients.map"
KC_WARN_FILE="${MAIN_BACKUP_DIR}/KEYCLOAK-SECRETS-README.txt"

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


# Значение секрета для подстановки в realm-json.
# Только -i, без -t: с псевдотерминалом docker добавляет к выводу \r.
# tr -d дополнительно нормализует файл секрета, созданный с переводом строки.
read_secret_value() {
    local cid="$1" name="$2" val
    val=$(docker exec -i "${cid}" cat "/run/secrets/${name}" 2>/dev/null | tr -d '\r\n') || true
    [ -n "${val}" ] || die "секрет ${name} пуст или недоступен в контейнере ${cid}"
    printf '%s' "${val}"
}


# Файл секрета для архива - побайтово, без нормализации: restore.sh передаёт его
# в docker secret create, и значение должно восстановиться без изменений.
copy_secret_file() {
    local cid="$1" name="$2" out="$3"
    docker exec -i "${cid}" cat "/run/secrets/${name}" > "${out}" \
        || die "не удалось прочитать секрет ${name} из контейнера ${cid}"
    [ -s "${out}" ] || die "секрет ${name} сохранён пустым: ${out}"
}

# Экранирование для sed: BRE-шаблон и строка замены (разделитель '/').
_esc_bre()  { printf '%s' "$1" | sed 's@[][\\.*^$/]@\\&@g'; }
_esc_repl() { printf '%s' "$1" | sed 's@[\\&/]@\\&@g'; }

# Подмена секрета в realm-json на значение-заглушку с проверкой до и после.
# sed возвращает 0 и тогда, когда не нашёл ни одного совпадения, поэтому
# результат проверяется явно. Расхождения не прерывают бэкап: они записываются
# в KC_WARN_FILE и устраняются вручную после восстановления.
replace_in_realm() {
    local old="$1" new="$2" label="$3"

    if [ -z "${old}" ] || [ -z "${new}" ]; then
        warn "${label}: пустое значение, подмена пропущена"
        echo "${label}: значение не получено, в realm-json осталось как есть" >> "${KC_WARN_FILE}"
        return 0
    fi

    if ! grep -qF -- "${old}" "${REALM_FILE}"; then
        warn "${label}: значение из /run/secrets не найдено в visiology-realm.json"
        echo "${label}: секрет клиента в Keycloak не совпадает с docker secret этого стенда" >> "${KC_WARN_FILE}"
        return 0
    fi

    sed -i "s/$(_esc_bre "${old}")/$(_esc_repl "${new}")/g" "${REALM_FILE}"

    if ! grep -qF -- "${new}" "${REALM_FILE}" || grep -qF -- "${old}" "${REALM_FILE}"; then
        warn "${label}: подмена применилась не полностью"
        echo "${label}: подмена на болванку не завершилась, проверьте realm-json" >> "${KC_WARN_FILE}"
        return 0
    fi
    log "  ${label}: подменён на болванку"
}

# Вызов kcadm внутри контейнера Keycloak. Учётные данные читаются из
# /run/secrets самим контейнером и в argv не попадают.
#   $1 - идентификатор контейнера, далее - аргументы kcadm
_kcadm() {
    local cid="$1"; shift
    docker exec -i "${cid}" bash -c '
        KCADM=/opt/keycloak/bin/kcadm.sh
        "${KCADM}" config credentials --server "$1" --realm master \
            --user "$(cat /run/secrets/KEYCLOAK_ADMIN)" \
            --password "$(cat /run/secrets/KEYCLOAK_ADMIN_PASSWORD)" >/dev/null 2>&1 || exit 1
        shift
        "${KCADM}" "$@"
    ' _ "${KC_SERVER}" "$@"
}

# Identity providers и их мапперы сохраняются отдельно от экспорта realm.
# Экспорт может не содержать identityProviderMappers, а без них после
# восстановления перестаёт работать вход через внешний SSO: провайдер есть,
# но группы и атрибуты из токена никуда не переносятся.
# Данные складываются в keycloak-idp/ как есть, в формате Admin API.
dump_keycloak_idp() {
    local cid="$1" aliases a cnt
    aliases=$(_kcadm "${cid}" get identity-provider/instances -r "${KEYCLOAK_REALM}" \
        --fields alias --format csv --noquotes 2>/dev/null | tr -d '\r"') || aliases=""
    if [ -z "${aliases}" ]; then
        log "  identity providers не настроены"
        return 0
    fi
    mkdir -p "${KC_IDP_DIR}"
    _kcadm "${cid}" get identity-provider/instances -r "${KEYCLOAK_REALM}" \
        > "${KC_IDP_DIR}/instances.json" 2>/dev/null || true
    for a in ${aliases}; do
        _kcadm "${cid}" get "identity-provider/instances/${a}/mappers" -r "${KEYCLOAK_REALM}" \
            > "${KC_IDP_DIR}/${a}.mappers.json" 2>/dev/null || true
        cnt=$(grep -c '"identityProviderAlias"' "${KC_IDP_DIR}/${a}.mappers.json" 2>/dev/null) || cnt=0
        log "  identity provider ${a}: мапперов ${cnt}"
        [ "${cnt}" -gt 0 ] || warn "у провайдера ${a} нет мапперов - вход через SSO может не давать доступов"
    done
}

# Соответствие "имя docker secret -> clientId". Определяется по фактическим
# значениям секретов и кладётся в архив: после восстановления оно позволяет
# синхронизировать секреты, не подбирая clientId вручную.
# Значения передаются в python через stdin и не попадают в argv.
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

cleanup() {
    local rc=$?
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
        log "  удаляю снапшот. Архив к этому моменту уже собран; при зависании"
        log "  снапшот снимается вручную:"
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
    exit "${rc}"
}

trap 'trap "" INT TERM; cleanup' EXIT
trap 'exit 130' INT TERM

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

    local free_mb
    free_mb=$(sudo pvs --noheadings -o pv_free --units m "${SNAP_PV}" 2>/dev/null | tr -d ' m<' | cut -d. -f1) || free_mb=""
    [ -n "${free_mb}" ] && [ "${free_mb}" -gt 1024 ] || die "нет свободного места на ${SNAP_PV}"
    log "  снапшот (COW ${free_mb}M)"
    sudo lvcreate -s -n "${SNAP_NAME}" -L "${free_mb}M" "${VG_NAME}/${LV_NAME}" "${SNAP_PV}"
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
        sudo cp -a "${src}/." "${CH_COPY_DIR}/${chost}/"
        log "  ${chost}: копия готова ($(sudo du -sh "${CH_COPY_DIR}/${chost}" 2>/dev/null | cut -f1))"
    done

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

    for line in "${locals[@]}"; do
        IFS='|' read -r chost vol <<< "${line}"
        _dump_ch_node "${chost}" "${CH_COPY_DIR}/${chost}"
        # копию удаляем сразу - на многонодовой установке иначе нужен суммарный объём
        sudo rm -rf "${CH_COPY_DIR:?}/${chost}" >/dev/null 2>&1 || true
    done

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
t_start=$(date +%s)
log "=== СТАРТ полного бэкапа Visiology ==="

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

# Прошлый экспорт удаляется заранее: ошибка kc.sh export глушится, и без этого
# в архив мог бы попасть realm от предыдущего прогона.
docker exec -i "${keycloak_container_id}" rm -f /opt/keycloak/visiology-realm.json 2>/dev/null || true
docker exec "${keycloak_container_id}" /opt/keycloak/bin/kc.sh export \
    --file /opt/keycloak/visiology-realm.json --realm "${KEYCLOAK_REALM}" > "${error_output}" 2>&1 || true
docker exec -i "${keycloak_container_id}" test -s /opt/keycloak/visiology-realm.json \
    || die "kc.sh export не создал /opt/keycloak/visiology-realm.json (запустите с -d и посмотрите вывод)"
docker cp "${keycloak_container_id}":/opt/keycloak/visiology-realm.json "${REALM_FILE}"
grep -q '"realm"' "${REALM_FILE}" || die "visiology-realm.json не похож на экспорт realm"

dump_keycloak_idp "${keycloak_container_id}"

# Секреты читаются через docker exec -i, без -t.
m2m_secret=$(read_secret_value "${keycloak_container_id}" KEYCLOAK_M2M_SECRET)
grafana_client_secret=$(read_secret_value "${keycloak_container_id}" KEYCLOAK_GRAFANA_CLIENT_SECRET)
public_dashboard_access_secret=$(read_secret_value "${keycloak_container_id}" KEYCLOAK_PUBLIC_DASHBOARD_ACCESS_SECRET)
visiology_admin_realm_secret=$(read_secret_value "${keycloak_container_id}" KEYCLOAK_VISIOLOGY_ADMIN_REALM_SECRET)

# Значения-заглушки. Должны совпадать байт в байт с константами *_old в штатном
# restore.sh, который выполняет обратную подстановку при восстановлении.
m2m_secret_new="68c96230-43e8-4308-b0ae-65835d8de35e"
grafana_client_secret_new="749e9d46-1360-4c65-a0a0-82ba3e369b09"
public_dashboard_access_secret_new="49d410ba-4e0d-4b1a-a064-834f41fb1cfd"
visiology_admin_realm_secret_new="23e5da38-76e9-47d2-e12c-f0da9f039cc6"

# Карта clientId строится ДО подмены - по реальным значениям секретов.
write_keycloak_client_map

if [ "${KC_KEEP_SECRETS}" = "1" ]; then
    log "  подмена секретов пропущена (--keep-keycloak-secrets)"
    echo "Секреты клиентов оставлены без изменений по ключу --keep-keycloak-secrets." >> "${KC_WARN_FILE}"
else
    replace_in_realm "${m2m_secret}"                     "${m2m_secret_new}"                     "KEYCLOAK_M2M_SECRET"
    replace_in_realm "${grafana_client_secret}"          "${grafana_client_secret_new}"          "KEYCLOAK_GRAFANA_CLIENT_SECRET"
    replace_in_realm "${public_dashboard_access_secret}" "${public_dashboard_access_secret_new}" "KEYCLOAK_PUBLIC_DASHBOARD_ACCESS_SECRET"
    replace_in_realm "${visiology_admin_realm_secret}"   "${visiology_admin_realm_secret_new}"   "KEYCLOAK_VISIOLOGY_ADMIN_REALM_SECRET"

    # В realm-json не должно остаться ни одного секрета исходного стенда:
    # иначе архив непереносим на другую установку.
    for _s in "${m2m_secret}" "${grafana_client_secret}" "${public_dashboard_access_secret}" "${visiology_admin_realm_secret}"; do
        if grep -qF -- "${_s}" "${REALM_FILE}"; then
            die "в visiology-realm.json остался секрет исходного стенда"
        fi
    done
    unset _s
fi
# Символ \r внутри строки JSON недопустим: импорт realm его не примет, а
# restore.sh глушит ошибку импорта уже после удаления realm.
if LC_ALL=C grep -q $'\r' "${REALM_FILE}"; then
    die "в visiology-realm.json есть символ \\r - kc.sh import такой файл не примет"
fi
log "  realm-json готов"

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
[ -s "${backup_file_dir}/${archive_name}" ] || die "архив не создан или пустой"

if [ -f "${KC_WARN_FILE}" ]; then
    warn "секреты Keycloak нормализованы не полностью, подробности в ${KC_WARN_FILE}"
    warn "  после восстановления секреты клиентов нужно синхронизировать вручную"
fi

t_end=$(date +%s)
elapsed=$(( (t_end - t_start) / 60 ))
log "=== ГОТОВО за ~${elapsed} мин ==="
log "Архив: ${backup_file_dir}/${archive_name} ($(sudo du -h "${backup_file_dir}/${archive_name}" 2>/dev/null | cut -f1))"
