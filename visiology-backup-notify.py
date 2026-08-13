#!/usr/bin/env python3
"""
visiology-backup-notify.py - отчёт о прогоне visiology-backup.sh по SMTP.

Вызывается самим бэкапом на выходе, в том числе при аварии и при отказе из-за
уже идущего прогона. Самостоятельно ничего не проверяет: все данные о прогоне
приходят аргументами.

Настройки почты читаются из файла окружения (KEY=VALUE, строки с # - комментарий):

    SMTP_HOST=mail.example.ru
    SMTP_PORT=25
    SMTP_USE_TLS=false
    SMTP_SKIP_VERIFY=false
    SMTP_USER=
    SMTP_PASSWORD=
    MAIL_FROM=visiology-backup@example.ru
    MAIL_TO=admin1@example.ru,admin2@example.ru

По умолчанию берётся /etc/visiology-backup.env, при его отсутствии -
visiology-backup.env рядом со скриптом. Файл содержит пароль, поэтому права на
него должны быть 600.

Если файла нет или MAIL_TO пуст, отправка пропускается. Код возврата всегда 0:
неудачная отправка письма не должна превращать успешный бэкап в неуспешный.
Используется только стандартная библиотека - внешние пакеты на контуре ставить
не требуется.
"""

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
from pathlib import Path

LOG_TAIL_LINES = 40
SMTP_TIMEOUT = 20

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("visiology-backup-notify")


def default_env_files() -> list:
    return ["/etc/visiology-backup.env",
            str(Path(__file__).resolve().parent / "visiology-backup.env")]


def read_env_file(path: str) -> dict:
    """Разбор KEY=VALUE. Кавычки вокруг значения снимаются, отсутствие файла - не ошибка."""
    values = {}
    try:
        with open(path, "r", encoding="utf-8") as fh:
            for line in fh:
                line = line.strip()
                if not line or line.startswith("#") or "=" not in line:
                    continue
                key, _, value = line.partition("=")
                value = value.strip()
                if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                    value = value[1:-1]
                values[key.strip()] = value
    except OSError as e:
        log.warning(f"Не удалось прочитать {path}: {e}")
    return values


def load_config(explicit: str) -> tuple:
    """Первый существующий файл настроек. Возвращает (значения, использованный путь)."""
    candidates = [explicit] if explicit else default_env_files()
    for path in candidates:
        if path and os.path.isfile(path):
            return read_env_file(path), path
    return {}, ""


def getenv_str(cfg: dict, key: str, default: str = "") -> str:
    value = cfg.get(key, os.getenv(key))
    if value is None or not str(value).strip():
        return default
    return str(value).strip()


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


def send_email(cfg: dict, subject: str, body: str) -> bool:
    mail_to = [addr.strip() for addr in getenv_str(cfg, "MAIL_TO").split(",") if addr.strip()]
    if not mail_to:
        log.warning("MAIL_TO пуст - отправка пропущена.")
        return False

    smtp_host = getenv_str(cfg, "SMTP_HOST", "localhost")
    smtp_port = int(getenv_str(cfg, "SMTP_PORT", "25"))
    smtp_use_tls = getenv_str(cfg, "SMTP_USE_TLS", "false").lower() in ("1", "true", "yes")
    smtp_skip_verify = getenv_str(cfg, "SMTP_SKIP_VERIFY", "false").lower() in ("1", "true", "yes")
    smtp_user = getenv_str(cfg, "SMTP_USER")
    smtp_password = getenv_str(cfg, "SMTP_PASSWORD")
    mail_from = getenv_str(cfg, "MAIL_FROM", smtp_user or f"visiology-backup@{HOSTNAME}")

    msg = MIMEMultipart()
    msg["From"] = mail_from
    msg["To"] = ", ".join(mail_to)
    msg["Subject"] = subject
    msg.attach(MIMEText(body, "plain", "utf-8"))

    context = ssl.create_default_context()
    if smtp_skip_verify:
        context.check_hostname = False
        context.verify_mode = ssl.CERT_NONE

    try:
        server = smtplib.SMTP(smtp_host, smtp_port, timeout=SMTP_TIMEOUT)
        if smtp_use_tls:
            server.starttls(context=context)
        if smtp_user and smtp_password:
            server.login(smtp_user, smtp_password)
        server.sendmail(mail_from, mail_to, msg.as_string())
        server.quit()
        log.info(f"Отчёт отправлен: {mail_to}")
        return True
    except Exception as e:
        log.error(f"Не удалось отправить отчёт: {e}")
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
    if args.status == "running":
        return f"{head}: ПРОПУЩЕН - предыдущий прогон ещё идёт"
    if args.status == "fail":
        return f"{head}: ОШИБКА (код {args.rc})"
    size = f", {args.archive_size}" if args.archive_size else ""
    tail = f", замечаний: {notes_count}" if notes_count else ""
    return f"{head}: успешно за ~{args.elapsed_min} мин{size}{tail}"


def build_body(args, notes: list, log_tail: list) -> str:
    if args.status == "ok":
        result = "успешно"
        intro = "Резервное копирование Visiology завершено."
    elif args.status == "fail":
        result = f"ОШИБКА (код возврата {args.rc})"
        intro = "ВНИМАНИЕ! Резервное копирование Visiology завершилось с ошибкой."
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
    if args.status != "running":
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
    parser.add_argument("--status", required=True, choices=("ok", "fail", "running"))
    parser.add_argument("--rc", type=int, default=0, help="код возврата бэкапа")
    parser.add_argument("--started", default="", help="время старта прогона")
    parser.add_argument("--elapsed-min", default="0", help="длительность в минутах")
    parser.add_argument("--archive", default="", help="путь к собранному архиву")
    parser.add_argument("--archive-size", default="", help="размер архива")
    parser.add_argument("--mode", default="", help="особый режим прогона, например ch-only")
    parser.add_argument("--notes-file", default="", help="файл с замечаниями (по строке)")
    parser.add_argument("--log-file", default="", help="журнал прогона")
    parser.add_argument("--env", default="", help="файл настроек SMTP")
    args = parser.parse_args()

    cfg, cfg_path = load_config(args.env)
    if not cfg:
        log.warning("Файл настроек SMTP не найден (%s) - отчёт не отправлен.",
                    args.env or ", ".join(default_env_files()))
        return 0
    log.info(f"Настройки почты: {cfg_path}")

    notes = [line for line in read_lines(args.notes_file) if line.strip()]
    # Хвост журнала прикладывается только к аварийному письму: при успехе он
    # ничего не добавляет, а объём письма увеличивает.
    log_tail = read_lines(args.log_file, LOG_TAIL_LINES) if args.status == "fail" else []

    send_email(cfg, build_subject(args, len(notes)), build_body(args, notes, log_tail))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as e:
        log.exception(f"Сбой при отправке отчёта: {e}")
        sys.exit(0)
