#!/bin/bash
#
# visiology-keycloak-sync.sh
#
# Сверяет и (по умолчанию) синхронизирует секреты клиентов Keycloak со значениями
# docker secrets текущего стенда. Запускать ПОСЛЕ restore.sh --with-keycloak true.
#
# Автоматизирует ручную процедуру kcadm из инструкции по восстановлению и
# распространяет её на все четыре клиента, а не только visiology_m2m.
# Идемпотентен: если секреты уже совпадают, ничего не меняет.
#
# Соответствие "docker secret -> clientId" берётся из карты, которую кладёт в
# архив visiology-backup.sh: <BACKUP_DIR>/backup/keycloak-clients.map
# Если карты нет, синхронизируется только KEYCLOAK_M2M_SECRET -> visiology_m2m.
#
# Usage: sudo ./visiology-keycloak-sync.sh [--check] [--map FILE] [--realm NAME]
#   --check       только сверить и показать расхождения, ничего не менять
#   --map FILE    путь к keycloak-clients.map
#   --realm NAME  realm (по умолчанию KEYCLOAK_REALM из defaults.env)
#
# Значения секретов НЕ печатаются. Внутри контейнера kcadm получает пароль
# админа и новый секрет аргументами командной строки - так же, как в штатной
# ручной процедуре Visiology; они видны в `ps` внутри контейнера keycloak.

set -euo pipefail

MODE="apply"
MAP_FILE=""
REALM_OVERRIDE=""

while [ "${1:-}" != "" ]; do
    case "$1" in
        "-?"|"-h"|"--help")
            sed -n '2,25p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        "--check")  MODE="check" ;;
        "--map")    shift; MAP_FILE="${1:-}" ;;
        "--realm")  shift; REALM_OVERRIDE="${1:-}" ;;
        *) echo "Неизвестный аргумент: $1" >&2; exit 127 ;;
    esac
    shift
done

SCRIPT_DIR=$( dirname -- "$( readlink -f -- "$0")")
cd "${SCRIPT_DIR}"

if [ -f config.env ];   then source config.env;   fi
if [ -f defaults.env ]; then source defaults.env; fi

PROJECT="${PROJECT:-visiology3}"
REALM="${REALM_OVERRIDE:-${KEYCLOAK_REALM:-Visiology}}"
KC_SERVER="${KC_SERVER:-http://localhost:8080/v3/keycloak}"
: "${BACKUP_DIR:=/var/lib/visiology/backup}"
[ -n "${MAP_FILE}" ] || MAP_FILE="${BACKUP_DIR%/}/backup/keycloak-clients.map"

log() { echo "[keycloak-sync] $*"; }
die() { echo "[keycloak-sync] ОШИБКА: $*" >&2; exit 1; }

cid=$(docker ps --filter "name=${PROJECT}_keycloak" --format '{{.ID}}' | head -1)
[ -n "${cid}" ] || die "контейнер ${PROJECT}_keycloak не найден"

pairs=()
if [ -f "${MAP_FILE}" ]; then
    log "карта клиентов: ${MAP_FILE}"
    while IFS= read -r line; do
        line="${line%%$'\r'}"
        [ -n "${line}" ] || continue
        case "${line}" in \#*) continue ;; esac
        pairs+=("${line}")
    done < "${MAP_FILE}"
else
    log "карта ${MAP_FILE} не найдена - синхронизирую только visiology_m2m"
    log "  (полную карту кладёт в архив visiology-backup.sh; остальные clientId укажите в --map)"
    pairs=("KEYCLOAK_M2M_SECRET=visiology_m2m")
fi
[ ${#pairs[@]} -gt 0 ] || die "список клиентов пуст"

log "realm: ${REALM}, режим: ${MODE}, клиентов: ${#pairs[@]}"

set +e
docker exec -i "${cid}" bash -s -- "${MODE}" "${REALM}" "${KC_SERVER}" "${pairs[@]}" <<'INNER'
set -u
mode="$1"; realm="$2"; server="$3"; shift 3
KCADM=/opt/keycloak/bin/kcadm.sh

"${KCADM}" config credentials --server "${server}" --realm master \
    --user "$(cat /run/secrets/KEYCLOAK_ADMIN)" \
    --password "$(cat /run/secrets/KEYCLOAK_ADMIN_PASSWORD)" >/dev/null 2>&1 \
    || { echo "  ! не удалось авторизоваться в keycloak (${server})"; exit 3; }

if ! "${KCADM}" get "realms/${realm}" --fields realm >/dev/null 2>&1; then
    echo "  ! realm '${realm}' в keycloak отсутствует - restore импорта realm не выполнил"
    exit 4
fi

rc=0
for pair in "$@"; do
    name="${pair%%=*}"
    client="${pair#*=}"

    if [ -z "${client}" ] || [ "${client}" = "${name}" ]; then
        echo "  ? ${name}: clientId неизвестен, пропуск"; rc=1; continue
    fi
    val=$(cat "/run/secrets/${name}" 2>/dev/null | tr -d '\r\n')
    if [ -z "${val}" ]; then
        echo "  ! ${name}: docker secret недоступен или пуст"; rc=1; continue
    fi
    id=$("${KCADM}" get clients -r "${realm}" -q "clientId=${client}" --fields id --format csv --noquotes 2>/dev/null | tr -d '\r"' | head -1)
    if [ -z "${id}" ]; then
        echo "  ! ${client}: клиент не найден в realm ${realm}"; rc=1; continue
    fi
    cur=$("${KCADM}" get "clients/${id}" -r "${realm}" --fields secret --format csv --noquotes 2>/dev/null | tr -d '\r"' | head -1)

    if [ "${cur}" = "${val}" ]; then
        echo "  = ${client}: совпадает"
        continue
    fi
    if [ "${mode}" = "check" ]; then
        echo "  ! ${client}: РАСХОЖДЕНИЕ (секрет в keycloak != docker secret ${name})"
        rc=2; continue
    fi
    if "${KCADM}" update "clients/${id}" -r "${realm}" -s "secret=${val}" >/dev/null 2>&1; then
        echo "  + ${client}: секрет синхронизирован"
    else
        echo "  ! ${client}: не удалось обновить секрет"; rc=1
    fi
done
exit "${rc}"
INNER
rc=$?
set -e

case "${rc}" in
    0) log "готово: все секреты совпадают с docker secrets" ;;
    2) log "найдены расхождения (режим --check). Запустите без --check, чтобы исправить"; exit 2 ;;
    3) die "авторизация kcadm не прошла" ;;
    4) die "realm отсутствует - перезапустите restore.sh с --with-keycloak true" ;;
    *) log "завершено с замечаниями (код ${rc}) - см. строки выше"; exit "${rc}" ;;
esac

log "После синхронизации перезапустите платформу, если дашборды всё ещё отдают DAX-ошибку:"
log "  /var/lib/visiology/scripts/run.sh --restart"
