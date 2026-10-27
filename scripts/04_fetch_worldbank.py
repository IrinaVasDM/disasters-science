"""Скачивает из World Development Indicators (Всемирный банк) показатели научного потенциала стран.

  IP.JRN.ARTC.SC     — научные и технические статьи (источник NSF, Science & Engineering Indicators)
  NY.GDP.MKTP.PP.KD  — ВВП по ППС, постоянные международные доллары
  SP.POP.TOTL        — население

Результат: data/reference/worldbank_capacity.csv (iso3, indicator, year, value) — только страны,
без агрегатов вроде «Мир» или «Страны Африки». Лицензия данных: CC BY 4.0.

Только стандартная библиотека Python. Запуск из папки проекта:
    python3 scripts/04_fetch_worldbank.py
"""
import csv
import json
import os
import ssl
import urllib.request

INDICATORS = ['IP.JRN.ARTC.SC', 'NY.GDP.MKTP.PP.KD', 'SP.POP.TOTL']
YEARS = '2000:2024'
OUT = 'data/reference/worldbank_capacity.csv'
API = 'https://api.worldbank.org/v2/'
# Python с python.org на macOS не видит системные сертификаты — берём их из /etc/ssl
SSL_CTX = ssl.create_default_context(
    cafile=os.environ.get('SSL_CERT_FILE') or ('/etc/ssl/cert.pem' if os.path.exists('/etc/ssl/cert.pem') else None))


def get(path):
    with urllib.request.urlopen(API + path, context=SSL_CTX, timeout=60) as r:
        return json.load(r)


def main():
    # Агрегаты (регионы, группы по доходу) отмечены region.id = 'NA'
    meta = get('country?format=json&per_page=400')[1]
    countries = {c['id'] for c in meta if c['region']['id'] != 'NA'}

    rows = []
    for ind in INDICATORS:
        data = get(f'country/all/indicator/{ind}?format=json&per_page=20000&date={YEARS}')[1]
        n = 0
        for d in data:
            if d['countryiso3code'] in countries and d['value'] is not None:
                rows.append((d['countryiso3code'], ind, int(d['date']), d['value']))
                n += 1
        print(f'{ind}: {n} значений')

    rows.sort()
    with open(OUT, 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(['iso3', 'indicator', 'year', 'value'])
        w.writerows(rows)
    print(f'{OUT}: {len(rows)} строк, {len({r[0] for r in rows})} стран')


if __name__ == '__main__':
    main()
