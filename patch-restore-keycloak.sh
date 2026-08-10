#!/bin/bash
#
# patch-restore-keycloak.sh
#
# Разовая идемпотентная правка ШТАТНОГО restore.sh (и, по желанию, backup.sh):
# чтение секретов Keycloak переводится с `docker exec -it` на `docker exec -i`
# с обрезкой \r.
#
# ЗАЧЕМ. С флагом -t docker выделяет псевдотерминал, tty-дисциплина заменяет \n
# на \r\n, и в переменную попадает хвостовой \r. В restore.sh это значение идёт
# в ПРАВУЮ часть sed:
#     sed -i "s/${m2m_secret_old}/${m2m_secret}/g" visiology-realm.json
# то есть \r вставляется ВНУТРЬ JSON-строки. Такой файл kc.sh import не примет
# (Jackson валится на unquoted control char), а restore.sh глушит ошибку импорта
# через `|| true` - при том, что realm к этому моменту уже удалён строкой
#     kcadm.sh delete -x realms/<realm>
# Итог: realm потерян целиком. Пока подмена в backup не работала, эта ветка не
# срабатывала; после починки backup-скрипта её надо закрыть ОБЯЗАТЕЛЬНО.
#
# Скрипт делает резервную копию, правит по шаблону, проверяет bash -n.
# Повторный запуск ничего не меняет.
#
# Usage: sudo ./patch-restore-keycloak.sh [файл ...]
#        по умолчанию: /var/lib/visiology/scripts/v3/restore.sh
#                      /var/lib/visiology/scripts/v3/backup.sh

set -euo pipefail

targets=("$@")
if [ ${#targets[@]} -eq 0 ]; then
    targets=(/var/lib/visiology/scripts/v3/restore.sh /var/lib/visiology/scripts/v3/backup.sh)
fi

patched_any=0
for f in "${targets[@]}"; do
    if [ ! -f "${f}" ]; then
        echo "пропуск: ${f} не найден"
        continue
    fi

    before=$(grep -c 'docker exec -it "${keycloak_container_id}" cat /run/secrets/' "${f}" || true)
    if [ "${before}" -eq 0 ]; then
        if grep -q 'cat /run/secrets/.*tr -d' "${f}"; then
            echo "уже исправлен: ${f}"
        else
            echo "нечего править: ${f} (шаблон чтения секретов не найден)"
        fi
        continue
    fi

    bak="${f}.bak-$(date '+%Y%m%d-%H%M%S')"
    cp -a "${f}" "${bak}"

    sed -E -i \
        's@docker exec -it ("\$\{keycloak_container_id\}") cat (/run/secrets/[A-Za-z0-9_]+)\)@docker exec -i \1 cat \2 | tr -d "\\r\\n")@g' \
        "${f}"

    after=$(grep -c 'docker exec -it "${keycloak_container_id}" cat /run/secrets/' "${f}" || true)
    fixed=$(grep -c 'cat /run/secrets/.*| tr -d "\\r\\n")' "${f}" || true)

    if [ "${after}" -ne 0 ] || [ "${fixed}" -ne "${before}" ]; then
        cp -a "${bak}" "${f}"
        echo "ОШИБКА: правка ${f} не применилась полностью, файл возвращён из ${bak}" >&2
        exit 1
    fi
    if ! bash -n "${f}"; then
        cp -a "${bak}" "${f}"
        echo "ОШИБКА: после правки ${f} не проходит bash -n, файл возвращён из ${bak}" >&2
        exit 1
    fi

    echo "исправлено строк: ${fixed} в ${f} (копия: ${bak})"
    patched_any=1
done

if [ "${patched_any}" = "1" ]; then
    echo
    echo "Проверить глазами:"
    echo "  grep -n 'cat /run/secrets/KEYCLOAK' ${targets[0]}"
fi
