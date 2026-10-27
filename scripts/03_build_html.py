"""Собирает интерактивную таблицу из базы PostgreSQL.

Выполняет sql/05_export_json.sql через psql и вставляет результат в scripts/template.html.
Параметры подключения — как у psql (аргументы или переменные PGHOST, PGPORT, PGUSER, PGDATABASE);
пароль psql спросит сам.

Запуск из папки проекта:
    python3 scripts/03_build_html.py -U postgres -d disasters_science
    python3 scripts/03_build_html.py --artifact -U postgres -d disasters_science   # без обёртки <html>, для публикации
"""
import os
import shutil
import subprocess
import sys

OUT = 'аналитика_бедствия_наука.html'
OUT_ARTIFACT = 'data/processed/artifact.html'
TEMPLATE = 'scripts/template.html'
EXPORT_SQL = 'sql/05_export_json.sql'
# Контуры стран (Natural Earth через datamaps@0.5.9, коды ISO3) для карты
WORLD = 'data/reference/world.topo.json'

# Та же базовая обёртка, что добавляет просмотрщик артефактов
SKELETON_HEAD = '''<!doctype html>
<html lang="ru">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<style>:root{color-scheme:light;padding-top:env(safe-area-inset-top,0px);padding-bottom:env(safe-area-inset-bottom,0px)}
body{margin:0;font:14px system-ui,sans-serif}img{max-width:100%}[hidden]{display:none!important}</style>
'''


def find_psql():
    if os.environ.get('PSQL'):
        return os.environ['PSQL']
    for p in ('/Library/PostgreSQL/18/bin/psql', shutil.which('psql')):
        if p and os.path.exists(p):
            return p
    sys.exit('Не найден psql. Укажите путь: PSQL=/путь/к/psql python3 scripts/03_build_html.py ...')


def main(args):
    artifact = '--artifact' in args
    psql_args = [a for a in args if a != '--artifact']
    cmd = [find_psql(), *psql_args, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-f', EXPORT_SQL]
    res = subprocess.run(cmd, stdout=subprocess.PIPE, text=True, encoding='utf-8')
    if res.returncode != 0:
        sys.exit('psql завершился с ошибкой')
    data = res.stdout.strip().replace('</', '<\\/')
    world = open(WORLD, encoding='utf-8').read().strip().replace('</', '<\\/')

    template = open(TEMPLATE, encoding='utf-8').read()
    page = template.replace('__DATA__', data).replace('__WORLD__', world)
    head, body = page.split('<!--BODY-->', 1)
    if artifact:
        out, html = OUT_ARTIFACT, head + body
    else:
        out, html = OUT, SKELETON_HEAD + head + '</head>\n<body>\n' + body + '\n</body>\n</html>\n'
    with open(out, 'w', encoding='utf-8') as f:
        f.write(html)
    print(f'{out}: {len(html.encode()) / 1e6:.1f} МБ')


if __name__ == '__main__':
    main(sys.argv[1:])
