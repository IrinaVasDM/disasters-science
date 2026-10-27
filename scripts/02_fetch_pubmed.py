"""Выгружает из PubMed статьи о психическом здоровье и психологической помощи при бедствиях.

Шаг 1 (fetch): поиск по годам через NCBI E-utilities, сырые XML кешируются
в data/raw/pubmed/ — повторный запуск ничего не скачивает заново.
Шаг 2 (parse): из XML собираются CSV для PostgreSQL в data/processed/.

Только стандартная библиотека Python. Ключ NCBI не обязателен (лимит 3 запроса/с);
если он есть, задайте переменную окружения NCBI_API_KEY — будет быстрее.

Запуск из папки проекта:
    python3 scripts/02_fetch_pubmed.py
"""
import csv
import glob
import gzip
import json
import os
import re
import ssl
import sys
import time
import urllib.parse
import urllib.request
import xml.etree.ElementTree as ET

YEARS = range(2000, 2026)
RAW_DIR = 'data/raw/pubmed'
OUT_DIR = 'data/processed'
EUTILS = 'https://eutils.ncbi.nlm.nih.gov/entrez/eutils/'
API_KEY = os.environ.get('NCBI_API_KEY', '')
PAUSE = 0.12 if API_KEY else 0.4
BATCH = 200
# Python с python.org на macOS не видит системные сертификаты — берём их из /etc/ssl
SSL_CTX = ssl.create_default_context(
    cafile=os.environ.get('SSL_CERT_FILE') or ('/etc/ssl/cert.pem' if os.path.exists('/etc/ssl/cert.pem') else None))

# Бедствия: рубрики MeSH + слова в названии/аннотации
DISASTER = ' OR '.join([
    '"Disasters"[MeSH]', '"Earthquakes"[MeSH]', '"Floods"[MeSH]', '"Cyclonic Storms"[MeSH]',
    '"Tsunamis"[MeSH]', '"Wildfires"[MeSH]', '"Droughts"[MeSH]', '"Volcanic Eruptions"[MeSH]',
    '"Landslides"[MeSH]', '"Tornadoes"[MeSH]', '"Avalanches"[MeSH]', '"Extreme Heat"[MeSH]',
    '"Radioactive Hazard Release"[MeSH]',
    'disaster*[tiab]', 'earthquake*[tiab]', 'flood*[tiab]', 'hurricane*[tiab]', 'cyclone*[tiab]',
    'typhoon*[tiab]', 'tsunami*[tiab]', 'wildfire*[tiab]', 'bushfire*[tiab]', '"forest fire"[tiab]',
    '"forest fires"[tiab]', 'landslide*[tiab]', 'mudslide*[tiab]', 'drought*[tiab]',
    '"heat wave"[tiab]', '"heat waves"[tiab]', 'heatwave*[tiab]', 'tornado*[tiab]', 'volcanic[tiab]',
    '"tropical storm"[tiab]', 'superstorm[tiab]', '"nuclear accident"[tiab]', 'Chernobyl[tiab]',
])
# Психическое здоровье и психологическая помощь
PSYCH = ' OR '.join([
    '"Mental Health"[MeSH]', '"Mental Disorders"[MeSH]', '"Stress, Psychological"[MeSH]',
    '"Psychological Trauma"[MeSH]', '"Resilience, Psychological"[MeSH]', '"Depression"[MeSH]',
    '"Suicide"[MeSH]', '"Grief"[MeSH]', '"Psychological First Aid"[MeSH]', '"Crisis Intervention"[MeSH]',
    '"Psychosocial Support Systems"[MeSH]', '"Mental Health Services"[MeSH]', '"Psychotherapy"[MeSH]',
    '"Counseling"[MeSH]',
    '"mental health"[tiab]', 'psycholog*[tiab]', 'psychosocial[tiab]', 'PTSD[tiab]',
    'posttraumatic[tiab]', '"post-traumatic"[tiab]', 'psychiatr*[tiab]', 'depressive[tiab]',
    'anxiety[tiab]', 'suicid*[tiab]',
])
# Не исследования: исправления, отзывы, комментарии, письма, редакционные статьи, новости.
# "Implosive Therapy" — терапия «наводнением» (flooding), не про бедствия.
EXCLUDE = ' OR '.join([
    'Erratum[pt]', '"Published Erratum"[pt]', '"Retracted Publication"[pt]',
    '"Retraction of Publication"[pt]', 'Comment[pt]', 'Letter[pt]', 'Editorial[pt]', 'News[pt]',
    '"Newspaper Article"[pt]', '"Implosive Therapy"[MeSH]',
])
QUERY = f'(({DISASTER}) AND ({PSYCH})) NOT ({EXCLUDE})'


def eutils(tool, params, post=False):
    params = dict(params, tool='disaster_science_gap')
    if API_KEY:
        params['api_key'] = API_KEY
    data = urllib.parse.urlencode(params).encode()
    for attempt in range(5):
        try:
            if post:
                req = urllib.request.Request(EUTILS + tool, data=data)
            else:
                req = urllib.request.Request(EUTILS + tool + '?' + data.decode())
            with urllib.request.urlopen(req, timeout=120, context=SSL_CTX) as r:
                body = r.read()
            time.sleep(PAUSE)
            return body
        except Exception as e:  # сеть или 429 — ждём и повторяем
            wait = 2 ** attempt
            print(f'  {tool}: {e}; повтор через {wait} с', file=sys.stderr)
            time.sleep(wait)
    raise RuntimeError(f'{tool} не ответил после 5 попыток')


def fetch():
    os.makedirs(RAW_DIR, exist_ok=True)
    total = 0
    for year in YEARS:
        ids_path = f'{RAW_DIR}/{year}_ids.json'
        if os.path.exists(ids_path):
            ids = json.load(open(ids_path))
        else:
            res = json.loads(eutils('esearch.fcgi', {
                'db': 'pubmed', 'term': f'({QUERY}) AND {year}[dp]',
                'retmax': 10000, 'retmode': 'json'}))['esearchresult']
            ids = res['idlist']
            if int(res['count']) > len(ids):
                raise RuntimeError(f'{year}: найдено {res["count"]}, получено {len(ids)} — разбейте год на части')
            json.dump(ids, open(ids_path, 'w'))
        total += len(ids)
        for i in range(0, len(ids), BATCH):
            path = f'{RAW_DIR}/{year}_{i // BATCH:03d}.xml.gz'
            if os.path.exists(path):
                continue
            xml = eutils('efetch.fcgi', {'db': 'pubmed', 'id': ','.join(ids[i:i + BATCH]),
                                         'retmode': 'xml'}, post=True)
            with gzip.open(path, 'wb') as f:
                f.write(xml)
        print(f'{year}: {len(ids)} статей', flush=True)
    print(f'Всего PMID: {total}')


def text(el):
    return re.sub(r'\s+', ' ', ''.join(el.itertext())).strip() if el is not None else ''


def pub_year(art):
    for path in ('.//Journal/JournalIssue/PubDate/Year', './/ArticleDate/Year'):
        y = art.findtext(path)
        if y:
            return int(y)
    m = re.search(r'(19|20)\d\d', art.findtext('.//Journal/JournalIssue/PubDate/MedlineDate') or '')
    return int(m.group()) if m else None


def parse():
    os.makedirs(OUT_DIR, exist_ok=True)
    seen = set()
    f_pub = open(f'{OUT_DIR}/publications.csv', 'w', newline='', encoding='utf-8')
    f_mesh = open(f'{OUT_DIR}/publication_mesh.csv', 'w', newline='', encoding='utf-8')
    f_aff = open(f'{OUT_DIR}/publication_affiliations.csv', 'w', newline='', encoding='utf-8')
    w_pub, w_mesh, w_aff = csv.writer(f_pub), csv.writer(f_mesh), csv.writer(f_aff)
    w_pub.writerow(['pmid', 'pub_year', 'title', 'abstract', 'keywords', 'journal', 'doi',
                    'language', 'publication_types', 'search_year'])
    w_mesh.writerow(['pmid', 'descriptor_ui', 'descriptor_name', 'is_major'])
    w_aff.writerow(['pmid', 'author_order', 'affiliation'])
    for path in sorted(glob.glob(f'{RAW_DIR}/*.xml.gz')):
        search_year = int(os.path.basename(path)[:4])
        root = ET.parse(gzip.open(path)).getroot()
        for pa in root.iter('PubmedArticle'):
            mc = pa.find('MedlineCitation')
            pmid = mc.findtext('PMID')
            if pmid in seen:
                continue
            seen.add(pmid)
            art = mc.find('Article')
            abstract = ' '.join(
                (f'{a.get("Label")}: ' if a.get('Label') else '') + text(a)
                for a in art.findall('Abstract/AbstractText'))
            doi = pa.findtext("PubmedData/ArticleIdList/ArticleId[@IdType='doi']") or \
                art.findtext("ELocationID[@EIdType='doi']") or ''
            w_pub.writerow([
                pmid, pub_year(art) or search_year, text(art.find('ArticleTitle')), abstract,
                ' | '.join(text(k) for k in mc.findall('KeywordList/Keyword')),
                art.findtext('Journal/Title') or '', doi.strip(),
                art.findtext('Language') or '',
                ' | '.join(text(t) for t in art.findall('PublicationTypeList/PublicationType')),
                search_year,
            ])
            for mh in mc.findall('MeshHeadingList/MeshHeading'):
                d = mh.find('DescriptorName')
                w_mesh.writerow([pmid, d.get('UI'), text(d), d.get('MajorTopicYN') == 'Y'])
            for n, au in enumerate(art.findall('AuthorList/Author'), 1):
                for aff in au.findall('AffiliationInfo/Affiliation'):
                    w_aff.writerow([pmid, n, text(aff)])
    for f in (f_pub, f_mesh, f_aff):
        f.close()
    # Происхождение данных: дата выгрузки (по самому позднему сырому файлу) и точный запрос
    fetched = max(os.path.getmtime(p) for p in glob.glob(f'{RAW_DIR}/*.xml.gz'))
    with open(f'{OUT_DIR}/dataset_info.csv', 'w', newline='', encoding='utf-8') as f:
        w = csv.writer(f)
        w.writerow(['key', 'value'])
        w.writerow(['pubmed_fetched', time.strftime('%Y-%m-%d', time.localtime(fetched))])
        w.writerow(['pubmed_query', QUERY])
        w.writerow(['pubmed_years', f'{YEARS.start}-{YEARS.stop - 1}'])
    print(f'Разобрано статей: {len(seen)}')


if __name__ == '__main__':
    if '--parse-only' not in sys.argv:
        fetch()
    parse()
