const fs = require('fs');
const d = require('docx');
const {
  Document, Packer, Paragraph, TextRun, HeadingLevel, AlignmentType,
  Table, TableRow, TableCell, WidthType, ShadingType, BorderStyle,
  LevelFormat, convertInchesToTwip,
} = d;

// A4, поля 2 см -> полезная ширина 11906 - 2*1134 = 9638 DXA
const W = 9638;
const MONO = 'Consolas';
const BODY = 'Calibri';

const INK = '1A232B';
const MUTED = '58656F';
const ACCENT = '16565E';
const CRIT = '9E2B25';

const p = (text, opts = {}) => new Paragraph({
  spacing: { after: opts.after ?? 140, line: 276 },
  alignment: opts.align,
  indent: opts.indent,
  border: opts.border,
  shading: opts.shading,
  children: Array.isArray(text) ? text : [new TextRun({ text, font: BODY, size: 22, color: opts.color ?? INK, bold: opts.bold, italics: opts.italics })],
});

const run = (text, opts = {}) => new TextRun({
  text, font: opts.mono ? MONO : BODY, size: opts.mono ? 19 : 22,
  color: opts.color ?? INK, bold: opts.bold, italics: opts.italics,
});

const h1 = (text) => new Paragraph({
  heading: HeadingLevel.HEADING_1,
  spacing: { before: 360, after: 160 },
  children: [new TextRun({ text, font: BODY, size: 30, bold: true, color: INK })],
});

const h2 = (text) => new Paragraph({
  heading: HeadingLevel.HEADING_2,
  spacing: { before: 280, after: 120 },
  children: [new TextRun({ text, font: BODY, size: 24, bold: true, color: ACCENT })],
});

// Блок кода: моноширинный текст на подложке, по строке на абзац
const code = (lines) => lines.map((l, i) => new Paragraph({
  spacing: { after: i === lines.length - 1 ? 160 : 0, line: 240 },
  shading: { type: ShadingType.CLEAR, fill: 'F0F2F3' },
  indent: { left: 170, right: 170 },
  children: [new TextRun({ text: l, font: MONO, size: 18, color: INK })],
}));

const bullet = (text, level = 0) => new Paragraph({
  numbering: { reference: 'dots', level },
  spacing: { after: 90, line: 276 },
  children: Array.isArray(text) ? text : [run(text)],
});

const num = (text) => new Paragraph({
  numbering: { reference: 'steps', level: 0 },
  spacing: { after: 90, line: 276 },
  children: Array.isArray(text) ? text : [run(text)],
});

const cell = (children, width, opts = {}) => new TableCell({
  width: { size: width, type: WidthType.DXA },
  shading: opts.fill ? { type: ShadingType.CLEAR, fill: opts.fill } : undefined,
  margins: { top: 80, bottom: 80, left: 120, right: 120 },
  children,
});

const th = (text, width) => cell([new Paragraph({
  spacing: { after: 0 },
  children: [new TextRun({ text, font: BODY, size: 19, bold: true, color: 'FFFFFF' })],
})], width, { fill: ACCENT });

const td = (text, width, opts = {}) => cell([new Paragraph({
  spacing: { after: 0 },
  children: Array.isArray(text) ? text : [new TextRun({ text, font: BODY, size: 20, color: opts.color ?? INK, bold: opts.bold })],
})], width, opts);

// ---------------------------------------------------------------- документ

const COLS3 = [2500, 4100, 3038];
const COLS_ASK = [700, 4300, 4638];

const children = [];

// Шапка
children.push(new Paragraph({
  spacing: { after: 60 },
  children: [new TextRun({ text: 'ОБРАЩЕНИЕ В ТЕХНИЧЕСКУЮ ПОДДЕРЖКУ VISIOLOGY', font: BODY, size: 18, bold: true, color: MUTED, characterSpacing: 20 })],
}));
children.push(new Paragraph({
  spacing: { after: 200 },
  border: { bottom: { style: BorderStyle.SINGLE, size: 12, color: INK, space: 6 } },
  children: [new TextRun({ text: 'Восстановление из резервной копии на работающей платформе повреждает данные', font: BODY, size: 34, bold: true, color: INK })],
}));

const metaRow = (k, v) => new TableRow({ children: [
  td([new TextRun({ text: k, font: BODY, size: 19, color: MUTED })], 2500),
  td([new TextRun({ text: v, font: MONO, size: 18, color: INK })], 7138),
]});
children.push(new Table({
  width: { size: W, type: WidthType.DXA },
  columnWidths: [2500, 7138],
  borders: {
    top: { style: BorderStyle.NONE }, bottom: { style: BorderStyle.NONE },
    left: { style: BorderStyle.NONE }, right: { style: BorderStyle.NONE },
    insideHorizontal: { style: BorderStyle.SINGLE, size: 4, color: 'DDE1E6' },
    insideVertical: { style: BorderStyle.NONE },
  },
  rows: [
    metaRow('Версия платформы', '3.16.1 (воспроизводится и на 3.13)'),
    metaRow('Развёртывание', 'Docker Swarm, один узел, PROJECT=visiology3'),
    metaRow('Компоненты', 'visiology3_backup-service, backup.sh, restore.sh'),
  ],
}));
children.push(p('', { after: 200 }));

// ГЛАВНОЕ
children.push(new Paragraph({
  spacing: { before: 120, after: 120, line: 276 },
  shading: { type: ShadingType.CLEAR, fill: 'EDF3F3' },
  indent: { left: 170, right: 170 },
  border: { left: { style: BorderStyle.SINGLE, size: 18, color: ACCENT, space: 8 } },
  children: [
    new TextRun({ text: 'Суть обращения. ', font: BODY, size: 22, bold: true, color: INK }),
    new TextRun({ text: 'Все наблюдаемые сбои восстановления вызваны одной причиной — платформа продолжает работать во время восстановления. Сервисы пишут в те же базы, в которые идёт восстановление, и данные повреждаются. При предварительно остановленных сервисах то же восстановление того же архива проходит без единой ошибки.', font: BODY, size: 22, color: INK }),
  ],
}));
children.push(new Paragraph({
  spacing: { after: 260, line: 276 },
  shading: { type: ShadingType.CLEAR, fill: 'EDF3F3' },
  indent: { left: 170, right: 170 },
  border: { left: { style: BorderStyle.SINGLE, size: 18, color: ACCENT, space: 8 } },
  children: [
    new TextRun({ text: 'При этом документация не требует останавливать сервисы, а restore.sh их не останавливает. Просим либо зафиксировать это требование в документации, либо реализовать остановку в самом restore.sh.', font: BODY, size: 22, bold: true, color: INK }),
  ],
}));

// 1
children.push(h1('1. Что происходит при восстановлении на работающей платформе'));
children.push(p('Восстановление выполняется штатным restore.sh. Пока backup-service накатывает дампы, работающие сервисы платформы продолжают читать и писать те же таблицы. Наблюдаются три независимых проявления.'));

children.push(new Table({
  width: { size: W, type: WidthType.DXA },
  columnWidths: COLS3,
  rows: [
    new TableRow({ tableHeader: true, children: [
      th('Компонент', COLS3[0]), th('Ошибка при работающих сервисах', COLS3[1]), th('При остановленных сервисах', COLS3[2]),
    ]}),
    new TableRow({ children: [
      td('PostgreSQL, схемы Hangfire', COLS3[0]),
      td([new TextRun({ text: 'COPY failed for table "jobparameter": violates foreign key constraint. Key (jobid)=(675565) is not present in table "job"', font: MONO, size: 17, color: CRIT })], COLS3[1]),
      td('Ошибок нет', COLS3[2], { color: '2C6440' }),
    ]}),
    new TableRow({ children: [
      td('ClickHouse', COLS3[0]),
      td([new TextRun({ text: 'UNKNOWN_TABLE — data-management-service обращается к таблицам, пока идёт DROP DATABASE и CREATE DATABASE', font: MONO, size: 17, color: CRIT })], COLS3[1]),
      td('Ошибок нет', COLS3[2], { color: '2C6440' }),
    ]}),
    new TableRow({ children: [
      td('Smart Forms', COLS3[0]),
      td([new TextRun({ text: 'Нарушение уникальности: сервис пишет в те же таблицы, куда идёт восстановление', font: MONO, size: 17, color: CRIT })], COLS3[1]),
      td('Ошибок нет', COLS3[2], { color: '2C6440' }),
    ]}),
  ],
}));
children.push(p('', { after: 160 }));

children.push(h2('Документация предписывает обратное'));
children.push(p('Раздел «Резервное копирование и перенос данных на другой сервер» (обновлён 26 января) в части восстановления содержит прямое указание:'));
children.push(new Paragraph({
  spacing: { before: 60, after: 160, line: 276 },
  indent: { left: 340, right: 340 },
  border: { left: { style: BorderStyle.SINGLE, size: 12, color: CRIT, space: 10 } },
  children: [new TextRun({ text: '«Убедитесь, что платформа на целевом стенде запущена и работает правильно»', font: BODY, size: 22, italics: true, color: INK })],
}));
children.push(p('То есть инструкция требует, чтобы платформа во время восстановления работала. Требования останавливать сервисы в ней нет ни в одном месте: остановка платформы упоминается единственный раз — для кластера ClickHouse, где перед восстановлением предписано удалить том данных на каждом узле.'));
children.push(p('Администратор, действующий строго по документации, гарантированно получает описанные выше ошибки.', { bold: true }));

children.push(h2('Проверено на архиве, собранном штатными средствами'));
children.push(p('Существенно: ошибки воспроизводятся на резервной копии, снятой штатным backup.sh, без применения каких-либо сторонних инструментов. Причина не в способе создания архива.'));

children.push(h2('Перечень сервисов, остановка которых устраняет проблему'));
children.push(p('Восстановление проходит без ошибок, если перед ним свести к нулю следующие сервисы, оставив работающими postgres, clickhouse, minio, keycloak и сам backup-service:'));
children.push(...code([
  'for s in data-management-service dashboard-service workspace-service \\',
  '         smart-forms formula-engine python-script-service dashboard-viewer; do',
  '  docker service scale visiology3_${s}=0',
  'done',
]));
children.push(p('После восстановления сервисы возвращаются тем же перебором со значением 1.'));

// 2
children.push(h1('2. Почему администратор не видит отказа'));
children.push(p('Восстановление на работающей платформе не просто повреждает данные — оно завершается сообщением об успехе. Этому способствуют два дефекта в штатных средствах.'));

children.push(h2('2.1. Скрипты не проверяют код ответа backup-service'));
children.push(p('В restore.sh и в backup.sh вызов выполняется так:'));
children.push(...code([
  'docker exec "${container_id}" curl -sLv --request POST --url http://127.0.0.1:8000 \\',
  '  --header \'Content-Type: application/json\' \\',
  '  --data \'{"command":"restore","databases":\'"${databases_str}"\'}\'',
]));
children.push(p([
  run('У curl не задан ключ '), run('-f', { mono: true }),
  run('. Без него код возврата равен нулю при любом ответе сервера, включая HTTP 500. Скрипт продолжает работу и завершается сообщением '),
  run('Restore completed successfully!', { mono: true }),
  run(' — при полностью или частично невосстановленной базе.'),
]));
children.push(p('Тот же дефект в backup.sh означает, что и неудачное создание резервной копии проходит незамеченным: в архив попадает каталог без дампов баз.'));

children.push(h2('2.2. Сервис отдаёт 500 одинаково на сбой и на завершение с пропусками'));
children.push(p('Фактический ответ backup-service при восстановлении:'));
children.push(...code([
  '< HTTP/1.0 500 Internal Server Error',
  '< Server: SimpleHTTP/0.6 Python/3.13.2',
  '',
  '(1, [\'pg_restore: error: COPY failed for table "jobparameter": ERROR:',
  '      insert or update on table "jobparameter" violates foreign key',
  '      constraint "jobparameter_jobid_fkey"\',',
  '     \'DETAIL:  Key (jobid)=(675565) is not present in table "job".\',',
  '     \'pg_restore: warning: errors ignored on restore: 2\'])',
]));
children.push(p([
  run('Последняя строка — '), run('errors ignored on restore: 2', { mono: true }),
  run(' — означает, что pg_restore завершился, пропустив две строки. Восстановление состоялось. Тем не менее сервис возвращает 500, не разделяя случаи «восстановление не выполнено» и «выполнено, пропущено N строк». Вызывающая сторона отличить их не может.'),
]));

// 3
children.push(h1('3. Вопросы к разработке по таблицам Hangfire'));
children.push(p('Нарушения ссылочной целостности возникают на таблицах планировщика Hangfire: job, jobparameter, state. Очередь фоновых заданий меняется непрерывно, поэтому именно она страдает первой. Просим уточнить:'));
children.push(bullet('Снимается ли дамп PostgreSQL в единой транзакции? Если да, нарушений ссылочной целостности внутри дампа быть не должно, и причину следует искать на стороне восстановления.'));
children.push(bullet('Восстанавливаются ли данные в схему с уже созданными ограничениями внешнего ключа? Тогда порядок загрузки таблиц становится значимым и требуется --disable-triggers либо отложенная проверка ограничений.'));
children.push(bullet('Используется ли параллельное восстановление pg_restore -j? При включённых ограничениях оно нарушает порядок загрузки.'));
children.push(p('Содержимое очереди фоновых заданий переносу не подлежит: платформа создаёт её заново. Просим исключить эти таблицы из резервной копии либо восстанавливать их с отключённой проверкой ограничений.'));

// 4
children.push(h1('4. Просьбы'));
children.push(new Table({
  width: { size: W, type: WidthType.DXA },
  columnWidths: COLS_ASK,
  rows: [
    new TableRow({ tableHeader: true, children: [
      th('№', COLS_ASK[0]), th('Наблюдение', COLS_ASK[1]), th('Просьба', COLS_ASK[2]),
    ]}),
    new TableRow({ children: [
      td('1', COLS_ASK[0], { bold: true }),
      td('Восстановление на работающей платформе повреждает данные', COLS_ASK[1], { bold: true }),
      td('Зафиксировать в документации требование останавливать сервисы, с конкретным перечнем, либо выполнять остановку в самом restore.sh — как это уже сделано для data-management-service при восстановлении секрета DATA_MANAGEMENT_SECRET_KEY', COLS_ASK[2], { bold: true }),
    ]}),
    new TableRow({ children: [
      td('2', COLS_ASK[0]),
      td('Скрипты не проверяют код ответа backup-service', COLS_ASK[1]),
      td('Добавить проверку и прерывание выполнения при ошибке', COLS_ASK[2]),
    ]}),
    new TableRow({ children: [
      td('3', COLS_ASK[0]),
      td('Сервис не различает фатальный сбой и завершение с пропусками', COLS_ASK[1]),
      td('Разделить эти состояния в коде ответа', COLS_ASK[2]),
    ]}),
    new TableRow({ children: [
      td('4', COLS_ASK[0]),
      td('Нарушение ссылочной целостности в таблицах Hangfire', COLS_ASK[1]),
      td('Исключить очередь заданий из копии либо восстанавливать без проверки ограничений', COLS_ASK[2]),
    ]}),
  ],
}));
children.push(p('', { after: 160 }));

// 5
children.push(h1('5. Как воспроизвести'));
children.push(num('Снять резервную копию штатным backup.sh на работающей платформе.'));
children.push(num('Восстановить её штатным restore.sh --archive-name <архив>, не останавливая сервисы.'));
children.push(num('В подробном выводе curl наблюдать HTTP/1.0 500 Internal Server Error и текст ошибок pg_restore.'));
children.push(num('Убедиться, что скрипт при этом завершается сообщением Restore completed successfully! с нулевым кодом возврата.'));
children.push(num('Повторить восстановление того же архива, предварительно сведя к нулю сервисы из перечня в разделе 1. Ошибок не будет.'));

// Приложение
children.push(h1('Приложение. Дефекты, найденные попутно'));
children.push(p('Эти дефекты к остановке сервисов отношения не имеют, но обнаружены при том же разборе и также приводят к потере данных.'));

children.push(h2('П.1. Штатный backup.sh молча теряет данные части таблиц ClickHouse'));
children.push(p('В /Backuper.py внутри контейнера backup-service:'));
children.push(...code([
  'if exit_code != 0:',
  "    logger.warning(f'The table: {table} disappeared suddenly')",
  '    continue          # файл данных для этой таблицы не создаётся',
]));
children.push(p('Файл sql/<таблица>.sql создаётся перенаправлением вывода до запуска команды, поэтому появляется всегда, независимо от результата. При неуспешном SHOW CREATE TABLE оператор continue пропускает выгрузку данных.'));
children.push(p([
  run('На реальном архиве, снятом штатными средствами: '),
  run('7232', { bold: true }), run(' файла в sql/ и '), run('7210', { bold: true }),
  run(' в data/. Разница в 22 объекта — таблицы, исчезнувшие между SHOW TABLES и SHOW CREATE TABLE. Ни backup.sh, ни restore.sh о расхождении не сообщают: при восстановлении пустые файлы данных пропускаются штатным кодом без предупреждения.'),
]));
children.push(p('Просим сверять количество выгруженных схем и файлов данных и сообщать о расхождении в результате операции.'));

children.push(h2('П.2. Документация расходится с кодом по умолчанию для --with-sf'));
children.push(p('В документации для restore.sh указано, что значение по умолчанию параметра --with-sf равно false. В коде restore.sh версии 3.16.1 задано WITH_SF=true, и встроенная справка скрипта (-h) также сообщает Default: true.'));
children.push(p('Расхождение существенно: администратор, полагающийся на документацию, считает, что Смарт Формы не восстанавливаются, тогда как они восстанавливаются. Просим привести документацию в соответствие с кодом.'));

children.push(h2('П.3. Секреты Keycloak читаются через псевдотерминал'));
children.push(p('В backup.sh и restore.sh, ветка --with-keycloak true, шаблон встречается восемь раз:'));
children.push(...code([
  'm2m_secret=$(docker exec -it "${keycloak_container_id}" cat /run/secrets/KEYCLOAK_M2M_SECRET)',
]));
children.push(p('Ключ -t выделяет псевдотерминал, дисциплина которого заменяет \\n на \\r\\n. Подстановка команд срезает завершающий \\n, и в переменной остаётся символ \\r.'));
children.push(p('В backup.sh значение идёт в левую часть sed — подстановка не находит совпадения. sed при этом возвращает нулевой код, ошибки нет, и в архив попадают действующие секреты исходного стенда вместо заглушек.'));
children.push(p('В restore.sh то же значение идёт в правую часть sed, то есть \\r вставляется внутрь строки JSON-файла realm. Такой файл kc.sh import не принимает. Ошибка импорта заглушена через || true, а realm к этому моменту уже удалён предыдущей строкой:'));
children.push(...code([
  'kcadm.sh delete -x realms/${keycloak_realm} &> ${error_output} || true',
  'kc.sh import --file /opt/keycloak/visiology-realm.json > ${error_output} || true',
]));
children.push(p('Realm теряется целиком. Просим использовать docker exec -i без -t и отбрасывать управляющие символы, а результат импорта realm проверять до удаления существующего.'));

const doc = new Document({
  creator: 'Отдел BI',
  title: 'Обращение в техническую поддержку Visiology',
  description: 'Восстановление на работающей платформе повреждает данные',
  numbering: {
    config: [
      { reference: 'dots', levels: [{ level: 0, format: LevelFormat.BULLET, text: '•', alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 460, hanging: 240 } } } }] },
      { reference: 'steps', levels: [{ level: 0, format: LevelFormat.DECIMAL, text: '%1.', alignment: AlignmentType.LEFT,
        style: { paragraph: { indent: { left: 460, hanging: 240 } } } }] },
    ],
  },
  sections: [{
    properties: { page: { margin: { top: 1134, right: 1134, bottom: 1134, left: 1134 } } },
    children,
  }],
});

Packer.toBuffer(doc).then((b) => {
  fs.writeFileSync(process.argv[2], b);
  console.log('готово:', process.argv[2], b.length, 'байт');
});
