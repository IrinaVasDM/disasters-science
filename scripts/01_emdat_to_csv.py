"""Конвертирует выгрузку EM-DAT (.xlsx) в CSV для загрузки в PostgreSQL.

Только стандартная библиотека Python: xlsx — это zip-архив с XML внутри,
поэтому openpyxl не нужен.

Запуск из папки проекта:
    python3 scripts/01_emdat_to_csv.py data/raw/emdat/260430_emdat_archive.xlsx data/processed/emdat_events.csv

Подойдёт и свежая выгрузка с public.emdat.be (после регистрации) — формат колонок тот же.
"""
import csv
import re
import sys
import zipfile
import xml.etree.ElementTree as ET
from datetime import date, timedelta

NS = '{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'

# Колонки EM-DAT -> имена колонок в таблице emdat_events
COLUMNS = {
    'DisNo.': 'dis_no',
    'Historic': 'historic',
    'Classification Key': 'classification_key',
    'Disaster Group': 'disaster_group',
    'Disaster Subgroup': 'disaster_subgroup',
    'Disaster Type': 'disaster_type',
    'Disaster Subtype': 'disaster_subtype',
    'External IDs': 'external_ids',
    'Event Name': 'event_name',
    'ISO': 'iso3',
    'Country': 'country',
    'Subregion': 'subregion',
    'Region': 'region',
    'Location': 'location',
    'Origin': 'origin',
    'Associated Types': 'associated_types',
    'OFDA/BHA Response': 'ofda_bha_response',
    'Appeal': 'appeal',
    'Declaration': 'declaration',
    "AID Contribution ('000 US$)": 'aid_contribution_k_usd',
    'Magnitude': 'magnitude',
    'Magnitude Scale': 'magnitude_scale',
    'Latitude': 'latitude',
    'Longitude': 'longitude',
    'River Basin': 'river_basin',
    'Start Year': 'start_year',
    'Start Month': 'start_month',
    'Start Day': 'start_day',
    'End Year': 'end_year',
    'End Month': 'end_month',
    'End Day': 'end_day',
    'Total Deaths': 'total_deaths',
    'No. Injured': 'no_injured',
    'No. Affected': 'no_affected',
    'No. Homeless': 'no_homeless',
    'Total Affected': 'total_affected',
    "Reconstruction Costs ('000 US$)": 'reconstruction_costs_k_usd',
    "Reconstruction Costs, Adjusted ('000 US$)": 'reconstruction_costs_adj_k_usd',
    "Insured Damage ('000 US$)": 'insured_damage_k_usd',
    "Insured Damage, Adjusted ('000 US$)": 'insured_damage_adj_k_usd',
    "Total Damage ('000 US$)": 'total_damage_k_usd',
    "Total Damage, Adjusted ('000 US$)": 'total_damage_adj_k_usd',
    'CPI': 'cpi',
    'Admin Units': 'admin_units',
    'GADM Admin Units': 'gadm_admin_units',
    'Entry Date': 'entry_date',
    'Last Update': 'last_update',
}
DATE_COLUMNS = {'entry_date', 'last_update'}


def col_index(ref):
    """'AB12' -> 27 (номер колонки с нуля)."""
    letters = re.match(r'[A-Z]+', ref).group()
    n = 0
    for ch in letters:
        n = n * 26 + ord(ch) - 64
    return n - 1


def read_shared_strings(z):
    strings = []
    for _, el in ET.iterparse(z.open('xl/sharedStrings.xml')):
        if el.tag == NS + 'si':
            strings.append(''.join(t.text or '' for t in el.iter(NS + 't')))
            el.clear()
    return strings


def iter_rows(z, strings):
    for _, el in ET.iterparse(z.open('xl/worksheets/sheet1.xml')):
        if el.tag != NS + 'row':
            continue
        row = {}
        for c in el.findall(NS + 'c'):
            v = c.find(NS + 'v')
            if c.get('t') == 's':
                val = strings[int(v.text)]
            elif c.get('t') == 'inlineStr':
                val = ''.join(t.text or '' for t in c.iter(NS + 't'))
            else:
                val = v.text if v is not None else ''
            row[col_index(c.get('r'))] = val
        el.clear()
        if row:
            yield [row.get(i, '') for i in range(max(row) + 1)]


def excel_date(value):
    """Даты в xlsx бывают числом дней от 1899-12-30 или уже строкой."""
    if re.fullmatch(r'\d+(\.\d+)?', value or ''):
        return (date(1899, 12, 30) + timedelta(days=int(float(value)))).isoformat()
    return value


def main(src, dst):
    z = zipfile.ZipFile(src)
    rows = iter_rows(z, read_shared_strings(z))
    header = next(rows)
    unknown = [h for h in header if h not in COLUMNS]
    if unknown:
        sys.exit(f'Неизвестные колонки в выгрузке: {unknown}')
    names = [COLUMNS[h] for h in header]
    n = 0
    with open(dst, 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(names)
        for r in rows:
            r = (r + [''] * len(names))[:len(names)]
            rec = dict(zip(names, r))
            for k in DATE_COLUMNS:
                rec[k] = excel_date(rec[k])
            w.writerow([rec[k] for k in names])
            n += 1
    print(f'{dst}: {n} событий')


if __name__ == '__main__':
    main(sys.argv[1], sys.argv[2])
