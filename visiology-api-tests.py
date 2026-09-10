#!/usr/bin/env python3
"""Сквозные проверки Visiology через API, без браузера.

Вход выполняется прямым запросом токена у Keycloak (grant_type=password),
поэтому ни браузер, ни графическая среда на сервере не нужны - достаточно
сетевого доступа к платформе.

Только стандартная библиотека: requests намеренно не используется. В закрытом
контуре установка пакетов через pip - отдельная задача, а python3 на серверах
уже есть, им же отправляются письма из visiology-backup.sh.

Пароль читается из окружения или из файла и никогда не передаётся аргументом
командной строки: аргументы видны в выводе ps любому пользователю системы.

Коды возврата: 0 - все проверки пройдены, 1 - есть отказы, 2 - ошибка запуска.
"""

import argparse
import base64
import json
import os
import ssl
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

# ---------------------------------------------------------------------------
# Значения по умолчанию. Взяты из рабочего примера получения токена.
# ---------------------------------------------------------------------------
DEFAULT_REALM = "Visiology"
DEFAULT_CLIENT_ID = "visiology_designer"
DEFAULT_SCOPE = (
    "openid data_management_service formula_engine workspace_service "
    "dashboard_service forms_service groups"
)
# Путь к Keycloak за обратным прокси. Не стандартный /auth и не /realms.
KEYCLOAK_PREFIX = "/v3/keycloak"

HTTP_TIMEOUT = 20

# ---------------------------------------------------------------------------
# Таблица проверок прикладного API.
#
# Сюда добавляются адреса, которые должны отвечать после восстановления:
# список дашбордов, конкретный дашборд, запрос данных виджета. Логику менять
# не нужно - только строки этой таблицы.
#
# Поля:
#   name     - что проверяем, попадёт в отчёт
#   method   - GET или POST
#   path     - путь относительно базового адреса
#   body     - тело запроса для POST, словарь (будет отправлен как JSON)
#   expect   - ожидаемые коды ответа
#   contains - подстрока, которая должна быть в ответе (необязательно)
#   min_items - если ответ - список или {"items": [...]}, минимальное число
#               элементов. Ноль дашбордов после восстановления - это отказ,
#               даже когда сам запрос отработал успешно.
#
# Адреса берутся из HAR рабочего стенда либо из вывода режима --probe.
# ---------------------------------------------------------------------------
CHECKS = [
    # Пример - раскомментировать и поправить под фактические адреса:
    # {
    #     "name": "список дашбордов",
    #     "method": "GET",
    #     "path": "/v3/dashboard-service/api/dashboards",
    #     "expect": (200,),
    #     "min_items": 1,
    # },
    # {
    #     "name": "данные виджета",
    #     "method": "POST",
    #     "path": "/v3/formula-engine/api/query",
    #     "body": {"...": "..."},
    #     "expect": (200,),
    # },
]

# ---------------------------------------------------------------------------
# Кандидаты для режима разведки.
#
# Имена служб взяты из набора scope в запросе токена: платформа сама называет
# их при выдаче прав. Swagger проверяется первым - если он открыт, то отдаёт
# полный перечень методов службы, и таблицу CHECKS можно заполнить по нему, не
# снимая HAR.
# ---------------------------------------------------------------------------
PROBE_SERVICES = [
    "dashboard-service",
    "data-management-service",
    "formula-engine",
    "workspace-service",
    "forms-service",
    "smart-forms",
    "keycloak",
]
PROBE_SUFFIXES = [
    "/swagger/v1/swagger.json",
    "/swagger/index.html",
    "/health",
    "/api",
    "",
]


# ---------------------------------------------------------------------------
# Вывод
# ---------------------------------------------------------------------------
class Report:
    """Счётчики и единый вид строк - как в visiology-restore-test.sh."""

    def __init__(self):
        self.ok = 0
        self.fail = 0
        self.warn = 0
        self.failed = []

    def add_ok(self, text):
        self.ok += 1
        print(f"    [ ОК ]     {text}")

    def add_warn(self, text):
        self.warn += 1
        print(f"    [ ! ]      {text}")

    def add_fail(self, text):
        self.fail += 1
        self.failed.append(text)
        print(f"    [ОТКАЗ]    {text}")


def log(text):
    print(f"{time.strftime('%F %T')} [api-tests] {text}")


def die(text):
    print(f"{time.strftime('%F %T')} [api-tests] ОШИБКА: {text}", file=sys.stderr)
    sys.exit(2)


# ---------------------------------------------------------------------------
# HTTP
# ---------------------------------------------------------------------------
class Client:
    def __init__(self, base_url, realm, insecure=True):
        self.base = base_url.rstrip("/")
        self.realm = realm
        if insecure:
            self.ctx = ssl._create_unverified_context()
        else:
            self.ctx = ssl.create_default_context()
        self.token = None

    def request(self, method, path, data=None, form=False, auth=True):
        """Возвращает (код, тело). Ошибка HTTP - это результат, а не исключение:
        проверке важно увидеть 401 или 500 и сообщить о них, а не упасть."""
        url = path if path.startswith("http") else self.base + path
        body = None
        headers = {}

        if data is not None:
            if form:
                body = urllib.parse.urlencode(data).encode()
                headers["Content-Type"] = "application/x-www-form-urlencoded"
            else:
                body = json.dumps(data).encode()
                headers["Content-Type"] = "application/json"

        if auth and self.token:
            headers["Authorization"] = f"Bearer {self.token}"

        req = urllib.request.Request(url, data=body, headers=headers, method=method)
        try:
            with urllib.request.urlopen(req, timeout=HTTP_TIMEOUT, context=self.ctx) as resp:
                return resp.status, resp.read().decode("utf-8", "replace")
        except urllib.error.HTTPError as e:
            return e.code, e.read().decode("utf-8", "replace")
        except urllib.error.URLError as e:
            return 0, f"соединение не установлено: {e.reason}"
        except Exception as e:  # таймаут, обрыв, некорректный ответ
            return 0, f"{type(e).__name__}: {e}"


# ---------------------------------------------------------------------------
# Разбор токена
# ---------------------------------------------------------------------------
def decode_jwt_payload(token):
    """Полезная нагрузка JWT без проверки подписи.

    Подпись здесь и не нужна: токен выдан нам напрямую по защищённому каналу,
    а проверять его будет сама платформа. Нам важно лишь содержимое - realm,
    имя пользователя, срок действия."""
    try:
        payload = token.split(".")[1]
        payload += "=" * (-len(payload) % 4)  # base64url без выравнивания
        return json.loads(base64.urlsafe_b64decode(payload))
    except Exception:
        return {}


def count_items(text):
    """Число элементов в ответе, если это список. Иначе None.

    Платформы отдают коллекции по-разному: голым списком или объектом с полем
    items/data/results. Разбираем распространённые варианты."""
    try:
        data = json.loads(text)
    except Exception:
        return None
    if isinstance(data, list):
        return len(data)
    if isinstance(data, dict):
        for key in ("items", "data", "results", "value"):
            if isinstance(data.get(key), list):
                return len(data[key])
    return None


# ---------------------------------------------------------------------------
# Проверки
# ---------------------------------------------------------------------------
def check_discovery(cli, rep, realm):
    """Keycloak жив и отдаёт конфигурацию realm.

    Проверка ценна тем, что затрагивает и базу: конфигурацию realm Keycloak
    читает из Postgres, поэтому её ответ подтверждает работу обоих."""
    path = f"{KEYCLOAK_PREFIX}/realms/{realm}/.well-known/openid-configuration"
    code, body = cli.request("GET", path, auth=False)
    if code == 0:
        # Кода ответа нет вовсе - до платформы не достучались. Причина лежит в
        # теле, и без неё сообщение "код 0" ничего не объясняет.
        rep.add_fail(f"платформа недоступна по адресу {cli.base}: {body}")
        return False
    if code != 200:
        rep.add_fail(f"конфигурация realm {realm}: код {code}")
        return False
    if '"issuer"' not in body:
        rep.add_fail(f"конфигурация realm {realm}: ответ без поля issuer")
        return False
    rep.add_ok(f"Keycloak отдаёт конфигурацию realm {realm}")
    return True


def get_token(cli, rep, realm, client_id, scope, user, password):
    """Прямой запрос токена. Заодно проверяет, что у клиента включён
    Direct Access Grants: без него Keycloak ответит unauthorized_client."""
    path = f"{KEYCLOAK_PREFIX}/realms/{realm}/protocol/openid-connect/token"
    code, body = cli.request(
        "POST",
        path,
        data={
            "client_id": client_id,
            "grant_type": "password",
            "scope": scope,
            "username": user,
            "password": password,
        },
        form=True,
        auth=False,
    )

    if code != 200:
        hint = ""
        if "unauthorized_client" in body:
            hint = " - у клиента выключен Direct Access Grants"
        elif "invalid_grant" in body:
            hint = " - неверный логин или пароль"
        elif "invalid_scope" in body:
            hint = " - клиенту не выданы запрошенные scope"
        rep.add_fail(f"получение токена: код {code}{hint}")
        if body:
            print(f"               ответ: {body[:300]}")
        return None

    try:
        token = json.loads(body)["access_token"]
    except Exception:
        rep.add_fail("получение токена: в ответе нет access_token")
        return None

    rep.add_ok(f"токен получен для клиента {client_id}")

    claims = decode_jwt_payload(token)
    who = claims.get("preferred_username") or claims.get("sub") or "?"
    left = int(claims.get("exp", 0) - time.time()) if claims.get("exp") else 0
    if claims:
        rep.add_ok(f"токен принадлежит {who}, действует ещё {left} с")
    else:
        rep.add_warn("токен получен, но разобрать его содержимое не удалось")

    return token


def check_userinfo(cli, rep):
    """Токен действительно принимается платформой.

    Стандартная точка OIDC - она есть всегда, поэтому проверка не зависит от
    того, как устроено прикладное API. Отличает 'токен выдан' от 'токен
    работает': выданный, но отклоняемый токен даёт 401 именно здесь."""
    realm = cli.realm
    path = f"{KEYCLOAK_PREFIX}/realms/{realm}/protocol/openid-connect/userinfo"
    code, body = cli.request("GET", path)
    if code == 200:
        rep.add_ok("токен принимается: userinfo отвечает")
        return True
    rep.add_fail(f"токен не принимается: userinfo вернул {code}")
    if body:
        print(f"               ответ: {body[:200]}")
    return False


def run_checks(cli, rep):
    """Обход таблицы CHECKS."""
    if not CHECKS:
        rep.add_warn(
            "таблица CHECKS пуста - прикладное API не проверяется. "
            "Заполните её адресами, см. режим --probe"
        )
        return

    for c in CHECKS:
        name = c.get("name", c.get("path", "?"))
        method = c.get("method", "GET")
        expect = c.get("expect", (200,))
        code, body = cli.request(method, c["path"], data=c.get("body"))

        if code not in expect:
            rep.add_fail(f"{name}: код {code}, ожидался {'/'.join(map(str, expect))}")
            if body:
                print(f"               ответ: {body[:200]}")
            continue

        need = c.get("contains")
        if need and need not in body:
            rep.add_fail(f"{name}: в ответе нет '{need}'")
            continue

        min_items = c.get("min_items")
        if min_items is not None:
            n = count_items(body)
            if n is None:
                rep.add_warn(f"{name}: код {code}, но ответ не список - число элементов не проверено")
                continue
            if n < min_items:
                rep.add_fail(f"{name}: элементов {n}, ожидалось не меньше {min_items}")
                continue
            rep.add_ok(f"{name}: код {code}, элементов {n}")
            continue

        rep.add_ok(f"{name}: код {code}")


# ---------------------------------------------------------------------------
# Разведка
# ---------------------------------------------------------------------------
def probe(cli):
    """Перебор вероятных адресов служб.

    Нужен один раз, чтобы узнать фактическую раскладку API и заполнить CHECKS.
    Ничего не утверждает - только показывает, что чем отвечает."""
    log("разведка адресов служб")
    log(f"  база: {cli.base}, токен: {'есть' if cli.token else 'нет'}")
    print()

    found = []
    for svc in PROBE_SERVICES:
        for suffix in PROBE_SUFFIXES:
            path = f"/v3/{svc}{suffix}"
            code, body = cli.request("GET", path)
            if code in (0, 404):
                continue
            mark = " <-- перечень методов" if "swagger.json" in path and code == 200 else ""
            size = len(body)
            print(f"    {code:>3}  {path}  ({size} байт){mark}")
            found.append((code, path))

    print()
    if not found:
        log("ничего не ответило. Возможно, другой префикс вместо /v3/ -")
        log("посмотрите адреса запросов в HAR рабочего стенда")
    else:
        log(f"ответило адресов: {len(found)}")
        log("если среди них есть swagger.json - откройте его, там полный")
        log("перечень методов службы, из которого заполняется таблица CHECKS")


# ---------------------------------------------------------------------------
# Точка входа
# ---------------------------------------------------------------------------
def main():
    p = argparse.ArgumentParser(
        description="Сквозные проверки Visiology через API, без браузера.",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Логин и пароль передаются только через окружение или файл:

  export VIS_USER=tester
  export VIS_PASSWORD='...'
  ./visiology-api-tests.py --base-url https://bi.example.ru

либо

  ./visiology-api-tests.py --base-url ... --user tester --password-file /root/.vis-test.pass

Аргументом командной строки пароль не принимается намеренно: аргументы
процесса видны в выводе ps любому пользователю системы.
""",
    )
    p.add_argument("--base-url", default=os.environ.get("VIS_BASE_URL", ""),
                   help="адрес платформы, например https://bi.example.ru")
    p.add_argument("--realm", default=os.environ.get("VIS_REALM", DEFAULT_REALM))
    p.add_argument("--client-id", default=os.environ.get("VIS_CLIENT_ID", DEFAULT_CLIENT_ID))
    p.add_argument("--scope", default=os.environ.get("VIS_SCOPE", DEFAULT_SCOPE))
    p.add_argument("--user", default=os.environ.get("VIS_USER", ""))
    p.add_argument("--password-file", default=os.environ.get("VIS_PASSWORD_FILE", ""))
    p.add_argument("--verify", action="store_true",
                   help="проверять сертификат (по умолчанию не проверяется: "
                        "во внутреннем контуре он самоподписанный)")
    p.add_argument("--probe", action="store_true",
                   help="разведка: показать, какие адреса служб отвечают")
    args = p.parse_args()

    if not args.base_url:
        die("не задан адрес платформы: --base-url или VIS_BASE_URL")

    password = os.environ.get("VIS_PASSWORD", "")
    if args.password_file:
        try:
            with open(args.password_file, "r", encoding="utf-8") as fh:
                password = fh.readline().strip()
        except OSError as e:
            die(f"не прочитать {args.password_file}: {e}")

    if not args.user or not password:
        die("не заданы учётные данные. Нужны VIS_USER и VIS_PASSWORD "
            "(или --user и --password-file)")

    cli = Client(args.base_url, args.realm, insecure=not args.verify)
    rep = Report()

    log("=== начало ===")
    log(f"платформа: {args.base_url}")
    log(f"realm: {args.realm}, client_id: {args.client_id}")
    if not args.verify:
        log("сертификат не проверяется (внутренний самоподписанный)")
    print()

    log("вход")
    if not check_discovery(cli, rep, args.realm):
        # Без Keycloak дальше идти некуда: токена не будет, а все прикладные
        # проверки упрутся в 401 и завалят отчёт шумом.
        summary(rep)
        return 1

    token = get_token(cli, rep, args.realm, args.client_id, args.scope,
                      args.user, password)
    if not token:
        summary(rep)
        return 1
    cli.token = token

    check_userinfo(cli, rep)

    if args.probe:
        print()
        probe(cli)
        print()
        summary(rep)
        return 1 if rep.fail else 0

    print()
    log("прикладное API")
    run_checks(cli, rep)

    print()
    return summary(rep)


def summary(rep):
    log("=== итог ===")
    log(f"пройдено: {rep.ok}, замечаний: {rep.warn}, отказов: {rep.fail}")
    if rep.failed:
        log("отказавшие проверки:")
        for f in rep.failed:
            print(f"    - {f}")
    if rep.fail:
        log("РЕЗУЛЬТАТ: есть проблемы")
        return 1
    log("РЕЗУЛЬТАТ: всё в порядке")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except KeyboardInterrupt:
        print()
        die("прервано с клавиатуры")
