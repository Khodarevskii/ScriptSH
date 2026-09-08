#!/bin/bash -e
#
# visiology-remote-setup.sh - разовая настройка доступа по ключу с боевого
# сервера на сервер-хранилище архивов.
#
# Запускается на КАЖДОМ боевом сервере по одному разу. У каждого сервера свой
# ключ: так его можно отозвать отдельно, не трогая остальные.
#
# Что делает:
#   1. создаёт ключ ed25519 без пароля, если его ещё нет;
#   2. запоминает ключ хоста хранилища и показывает отпечаток для сверки;
#   3. кладёт открытый ключ в authorized_keys на хранилище - для этого один раз
#      спросит пароль пользователя хранилища;
#   4. проверяет вход по ключу, создание папки сервера, передачу файла,
#      совпадение контрольных сумм и удаление;
#   5. печатает готовые строки для /etc/visiology-backup.env и для cron.
#
# Повторный запуск ничего не ломает: существующий ключ переиспользуется,
# запись в authorized_keys не дублируется.
#
# Usage: sudo ./visiology-remote-setup.sh --host АДРЕС [опции]
#   --host АДРЕС     имя или IP сервера-хранилища (обязательно)
#   --user ИМЯ       пользователь на хранилище (по умолчанию backup)
#   --port ПОРТ      порт SSH (по умолчанию 22)
#   --root ПУТЬ      корневой каталог для архивов (по умолчанию /srv/visiology-backups)
#   --key ПУТЬ       путь к ключу (по умолчанию /root/.ssh/id_visiology_backup)
#   --restrict-from  ограничить ключ этим адресом-источником. По умолчанию
#                    подставляется исходящий адрес этого сервера, "no" отключает
#   --check          только проверить уже настроенный доступ, ничего не менять
#
# Коды возврата: 0 - успех, 1 - ошибка, 20 - неверные аргументы.

REMOTE_HOST=""
REMOTE_USER="backup"
REMOTE_PORT="22"
REMOTE_ROOT="/srv/visiology-backups"
REMOTE_KEY="/root/.ssh/id_visiology_backup"
RESTRICT_FROM=""
CHECK_ONLY=0

while [ "$1" != "" ]; do
    case "$1" in
        "-?"|"-h"|"--help")
            sed -n '2,32p' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        "--host")           shift; REMOTE_HOST="$1" ;;
        "--user")           shift; REMOTE_USER="$1" ;;
        "--port")           shift; REMOTE_PORT="$1" ;;
        "--root")           shift; REMOTE_ROOT="$1" ;;
        "--key")            shift; REMOTE_KEY="$1" ;;
        "--restrict-from")  shift; RESTRICT_FROM="$1" ;;
        "--check")          CHECK_ONLY=1 ;;
        *) echo "Неизвестный аргумент: $1. См. справку: $0 -h" >&2; exit 20 ;;
    esac
    shift
done

LOG_TAG="[remote-setup]"
log()  { echo "$(date '+%F %T') ${LOG_TAG} $*"; }
warn() { echo "$(date '+%F %T') ${LOG_TAG} ВНИМАНИЕ: $*" >&2; }
die()  { echo "$(date '+%F %T') ${LOG_TAG} ОШИБКА: $*" >&2; exit 1; }

[ -n "${REMOTE_HOST}" ] || die "не задан --host. См. справку: $0 -h"
[ "$(id -u)" = "0" ] || die "запускать от root: sudo $0 --host ${REMOTE_HOST}"

SRV_NAME=$(hostname)
TARGET="${REMOTE_USER}@${REMOTE_HOST}"
SSH_BASE=(-o BatchMode=yes -o ConnectTimeout=10 -p "${REMOTE_PORT}" -i "${REMOTE_KEY}")

log "боевой сервер: ${SRV_NAME}"
log "хранилище:     ${TARGET}:${REMOTE_ROOT}/${SRV_NAME} (порт ${REMOTE_PORT})"

########################################
# 1. Ключ
########################################
if [ "${CHECK_ONLY}" = "0" ]; then
    if [ -f "${REMOTE_KEY}" ]; then
        log "ключ уже есть: ${REMOTE_KEY}"
    else
        log "создаю ключ ${REMOTE_KEY}"
        # Без пароля: под cron ввести его некому. ed25519 - короткий и быстрый.
        install -d -m 700 "$(dirname "${REMOTE_KEY}")"
        ssh-keygen -t ed25519 -N '' -q \
            -f "${REMOTE_KEY}" -C "visiology-backup@${SRV_NAME}" \
            || die "не удалось создать ключ"
    fi
    chmod 600 "${REMOTE_KEY}"
    chmod 644 "${REMOTE_KEY}.pub"
fi
[ -f "${REMOTE_KEY}" ] || die "ключ ${REMOTE_KEY} не найден, запустите без --check"

########################################
# 2. Ключ хоста хранилища
########################################
# Без этого шага соединение в пакетном режиме оборвётся на запросе
# подтверждения: отвечать под cron некому.
KNOWN_HOSTS="/root/.ssh/known_hosts"
install -d -m 700 /root/.ssh
touch "${KNOWN_HOSTS}"; chmod 600 "${KNOWN_HOSTS}"

host_key_id="${REMOTE_HOST}"
[ "${REMOTE_PORT}" = "22" ] || host_key_id="[${REMOTE_HOST}]:${REMOTE_PORT}"

if ssh-keygen -F "${host_key_id}" -f "${KNOWN_HOSTS}" >/dev/null 2>&1; then
    log "ключ хоста уже записан в ${KNOWN_HOSTS}"
elif [ "${CHECK_ONLY}" = "1" ]; then
    warn "ключа хоста нет в ${KNOWN_HOSTS} - соединение по расписанию не пройдёт"
else
    log "запрашиваю ключ хоста"
    scan=$(timeout 30 ssh-keyscan -p "${REMOTE_PORT}" -t ed25519,rsa "${REMOTE_HOST}" 2>/dev/null) \
        || die "не удалось получить ключ хоста ${REMOTE_HOST}:${REMOTE_PORT}. Сервер доступен?"
    [ -n "${scan}" ] || die "ключ хоста пуст: сервер ${REMOTE_HOST}:${REMOTE_PORT} не отвечает по SSH"

    # Отпечаток печатается, чтобы его можно было сверить с тем, что показывает
    # сам сервер хранилища: это защита от подмены при первом подключении.
    log "отпечатки полученного ключа - сверьте с хранилищем:"
    printf '%s\n' "${scan}" | ssh-keygen -lf - 2>/dev/null | while IFS= read -r l; do log "    ${l}"; done
    printf '%s\n' "${scan}" >> "${KNOWN_HOSTS}"
    log "ключ хоста записан"
fi

########################################
# 3. Установка открытого ключа на хранилище
########################################
key_works() {
    timeout 30 ssh "${SSH_BASE[@]}" "${TARGET}" 'echo ok' 2>/dev/null | grep -qx ok
}

if key_works; then
    log "вход по ключу уже работает"
elif [ "${CHECK_ONLY}" = "1" ]; then
    die "вход по ключу не работает. Запустите без --check, чтобы настроить"
else
    # Адрес-источник для ограничения ключа. Определяется по маршруту до
    # хранилища: именно с этого адреса пойдут соединения.
    if [ -z "${RESTRICT_FROM}" ]; then
        RESTRICT_FROM=$(ip route get "$(getent hosts "${REMOTE_HOST}" | awk '{print $1; exit}')" 2>/dev/null \
                        | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1) || RESTRICT_FROM=""
    fi

    # restrict запрещает проброс портов, агента, X11 и выделение терминала,
    # оставляя выполнение команд и передачу файлов - всё, что нужно бэкапу.
    # from ограничивает ключ адресом этого сервера: украденный ключ с чужой
    # машины не сработает.
    opts="restrict"
    if [ -n "${RESTRICT_FROM}" ] && [ "${RESTRICT_FROM}" != "no" ]; then
        opts="restrict,from=\"${RESTRICT_FROM}\""
        log "ключ будет принят только с адреса ${RESTRICT_FROM}"
    else
        warn "ключ не ограничен по адресу источника"
    fi

    pub=$(cat "${REMOTE_KEY}.pub")
    # Для поиска дубля берётся сама base64-часть ключа: она уникальна и не
    # содержит кавычек, поэтому безопасно подставляется в удалённую команду.
    blob=$(awk '{print $2}' "${REMOTE_KEY}.pub")
    [ -n "${blob}" ] || die "не удалось прочитать ${REMOTE_KEY}.pub"

    log "устанавливаю ключ на ${TARGET} - потребуется пароль пользователя ${REMOTE_USER}"
    log "  (пароль вводится один раз и нигде не сохраняется)"

    # Пароль спрашивает сам ssh в интерактивном режиме. BatchMode здесь не
    # ставится намеренно, ключи отключены - иначе ssh не дойдёт до пароля.
    # Сама строка authorized_keys передаётся через stdin, а не аргументом.
    printf '%s %s\n' "${opts}" "${pub}" | timeout 300 ssh \
        -o ConnectTimeout=10 -o PubkeyAuthentication=no -o NumberOfPasswordPrompts=3 \
        -p "${REMOTE_PORT}" "${TARGET}" \
        "umask 077; mkdir -p ~/.ssh; line=\$(cat); if grep -qF '${blob}' ~/.ssh/authorized_keys 2>/dev/null; then echo 'ключ уже был установлен'; else printf '%s\n' \"\${line}\" >> ~/.ssh/authorized_keys; echo 'ключ добавлен'; fi; chmod 700 ~/.ssh; chmod 600 ~/.ssh/authorized_keys" \
        || die "не удалось установить ключ на ${TARGET}"

    key_works || die "ключ установлен, но вход по нему не проходит. Проверьте на хранилище: права ~/.ssh (700) и ~/.ssh/authorized_keys (600), и что sshd разрешает вход по ключу"
    log "вход по ключу настроен"
fi

########################################
# 4. Проверка полного пути доставки
########################################
RDIR="${REMOTE_ROOT%/}/${SRV_NAME}"
log "проверяю каталог ${RDIR}"
timeout 60 ssh "${SSH_BASE[@]}" "${TARGET}" "mkdir -p -- '${RDIR}' && test -w '${RDIR}' && echo ok" \
    | grep -qx ok || die "каталог ${RDIR} не создан или недоступен на запись пользователю ${REMOTE_USER}"

tmp_local=$(mktemp /tmp/vis-remote-check.XXXXXX)
head -c 1048576 /dev/urandom > "${tmp_local}"
sum_local=$(sha256sum "${tmp_local}" | cut -d' ' -f1)
probe="${RDIR}/.setup-probe-${SRV_NAME}"

log "передаю пробный файл (1 МБ) через scp"
timeout 120 scp -p -o BatchMode=yes -o ConnectTimeout=10 -P "${REMOTE_PORT}" -i "${REMOTE_KEY}" \
    "${tmp_local}" "${TARGET}:${probe}" >/dev/null \
    || { rm -f "${tmp_local}"; die "scp не смог передать файл в ${RDIR}"; }

sum_remote=$(timeout 120 ssh "${SSH_BASE[@]}" "${TARGET}" "sha256sum -- '${probe}' 2>/dev/null | cut -d' ' -f1")
timeout 60 ssh "${SSH_BASE[@]}" "${TARGET}" "rm -f -- '${probe}'" >/dev/null 2>&1 || true
rm -f "${tmp_local}"

[ "${sum_local}" = "${sum_remote}" ] \
    || die "контрольные суммы не совпали: локально ${sum_local}, на хранилище ${sum_remote:-нет ответа}"
log "передача и сверка контрольной суммы прошли успешно"

# Проверяем команды, которыми пользуется ротация.
timeout 60 ssh "${SSH_BASE[@]}" "${TARGET}" "command -v find sha256sum stat >/dev/null && echo ok" \
    | grep -qx ok || warn "на хранилище не хватает find, sha256sum или stat - ротация и сверка работать не будут"

########################################
# 5. Готовые настройки
########################################
log ""
log "ГОТОВО. Строки для /etc/visiology-backup.env (права 600):"
log ""
log "    REMOTE_HOST=${REMOTE_HOST}"
log "    REMOTE_USER=${REMOTE_USER}"
log "    REMOTE_PORT=${REMOTE_PORT}"
log "    REMOTE_KEY=${REMOTE_KEY}"
log "    REMOTE_ROOT=${REMOTE_ROOT}"
log "    REMOTE_METHOD=scp"
log ""
log "Строка расписания для этого сервера:"
log ""
log "    0 3 * * 4 timeout -k 60 8h /var/lib/visiology/scripts/v3/visiology-backup.sh --remote-store >> /var/log/visiology-backup.log 2>&1"
log ""
log "Проверить доступ позже, ничего не меняя: $0 --host ${REMOTE_HOST} --check"
