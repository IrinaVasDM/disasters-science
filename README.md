# Disasters and Research Attention

**Where are disasters frequent but research on mental health and psychological help scarce — and the other way round?**

This project links the [EM-DAT](https://www.emdat.be) international disaster database with PubMed literature on disaster mental health and psychosocial support, country by country. Everything lives in PostgreSQL: loading, classification rules, and the gap analysis itself (`gap_analysis()`).

**Explore:** interactive map, charts and country profiles — **[live page](https://irinavasdm.github.io/disasters-science/)**.

**Data.** 9,387 natural disasters in 217 countries (EM-DAT archive, 2000–2024) and 14,301 PubMed records (2000–2025), of which 9,416 are included. The country studied is taken from MeSH geographic headings (80% of links), titles, or abstracts. Author countries come from affiliations.

**Method.** For each country, the expected number of papers is estimated from its disaster burden with a log-linear regression across all countries. The gap is actual vs. expected papers. Findings are checked in 11 robustness variants: alternative burden measures, country-assignment rules, publication lags, periods, and a Poisson model.

**Key findings**
- Disaster burden explains only 42% of cross-country variation in research volume. Five countries (USA, Japan, China, Türkiye, Australia) account for 58% of papers but 18% of disasters.
- 67 countries have less than half the expected research; for 47 of them this holds in nearly all robustness variants (Sub-Saharan Africa, Latin America, Central Asia, Eastern Europe).
- Earthquakes get 405 papers per 100 events, floods 17. Extreme temperatures cause 23% of disaster deaths but yield 0.5 papers per 1,000 deaths.
- Only 39% of papers on under-researched countries have a local author. For Haiti it is 15%.

**Reproduce:** `createdb disasters_science && psql -d disasters_science -f sql/build_all.sql` (details in the Russian section below). Raw EM-DAT and PubMed files are not included in the repository: `scripts/01_emdat_to_csv.py` converts the EM-DAT archive (download it from [UCLouvain Dataverse](https://doi.org/10.14428/DVN/I0LTPH)) and `scripts/02_fetch_pubmed.py` downloads PubMed records.

**Licences.** Code: [MIT](LICENSE). EM-DAT data © CRED/UCLouvain, CC BY-NC-ND 4.0 (Delforge et al., 2025, doi:[10.1016/j.ijdrr.2025.105509](https://doi.org/10.1016/j.ijdrr.2025.105509)). PubMed metadata: U.S. National Library of Medicine. Map geometry: Natural Earth.

---

# Бедствия и научное внимание

База PostgreSQL, которая соединяет статистику бедствий **EM-DAT** с научными публикациями **PubMed** о психическом здоровье и психологической помощи пострадавшим, и интерактивная страница поверх неё.

Для каждой страны считается, сколько статей «ожидается» при её числе бедствий (по всем странам мира), и сравнивается с тем, сколько их есть на самом деле.

**Открыть страницу «Бедствия и научное внимание»:** https://irinavasdm.github.io/disasters-science/ или локально `аналитика_бедствия_наука.html` — двойной щелчок, откроется в браузере (нужен интернет для шрифта и библиотеки карты).

**Аналитический отчёт** (структура научной статьи: методы, результаты, проверки устойчивости, литература) готовится к публикации; все его числа воспроизводятся скриптом `sql/08_report_numbers.sql`, вывод — в `results/report_numbers.txt`.

## Что видно уже сейчас

Природные бедствия 2000–2024, нагрузка = число бедствий, все работы (`SELECT * FROM gap_analysis();`):

- **Дефицит исследований** у 67 стран из 217, у 47 из них он устойчив в 9 и более вариантах проверки из 11 (`sql/07_robustness.sql`). Больше всего бедствий при дефиците — Афганистан (154 бедствия, 10 статей при ожидаемых 22), Колумбия (130 и 4), Гватемала (86 и 3), Аргентина, Румыния, Мозамбик, Боливия, ДР Конго, Мадагаскар. У Таджикистана, Анголы, Алжира, Бурунди, Йемена — ни одной статьи при 47–57 бедствиях.
- **Изучено больше ожидаемого**: Япония (в 30 раз), Турция (в 28), США (в 20), Австралия, Канада, Китай, Италия. На эти 5 стран (США, Япония, Китай, Турция, Австралия) приходится 58 % всех статей при 18 % бедствий.
- **Типы бедствий**: на 100 землетрясений — 405 работ, на 100 наводнений — 17; на аномальную жару и холод приходится 23 % погибших и 0,5 работы на 1000 погибших.
- **Пробелы внутри стран**: на Гаити 4 землетрясения дали 104 статьи, а 48 наводнений — 3. Во Вьетнаме из 28 статей о помощи — одна.
- **Техногенные катастрофы почти не изучаются**: в ДР Конго, Индонезии, Египте, Иране по 150–170 таких бедствий и ни одной статьи (запрос 3 в `sql/06_examples.sql`).
- **«Парашютная наука»**: у статей о Гаити местный автор есть лишь в 15 % случаев (авторы из США — в 73 статьях, из Гаити — в 17); по Африке в целом — 63,5 %.

## Что в папке

| Путь | Что это |
|---|---|
| `аналитика_бедствия_наука.html` | интерактивная страница: карта разрыва, нагрузка и наука по странам, «куда уходит внимание» (регионы и типы бедствий), типы бедствий, динамика, матрица «кто кого изучает», таблица стран с карточками, схема проекта. Все блоки подчиняются одним фильтрам |
| `data/reference/world.topo.json` | контуры стран для карты (Natural Earth, пакет datamaps@0.5.9, коды ISO3) |
| `sql/build_all.sql` | собирает базу целиком (запускает шаги 01–04) |
| `sql/01_schema.sql` | таблицы, справочники, правила классификации |
| `sql/02_load.sql` | загрузка CSV |
| `sql/03_classify.sql` | разметка статей: тип бедствия, «о помощи», страна исследования, страны авторов |
| `sql/04_analytics.sql` | представления и функция `gap_analysis()` |
| `sql/05_export_json.sql` | выгрузка данных для таблицы |
| `sql/06_examples.sql` | 10 примеров аналитических запросов |
| `sql/07_robustness.sql` | проверки устойчивости: 11 вариантов допущений, функция `gap_analysis_variant()`, пуассоновская регрессия |
| `sql/08_report_numbers.sql` | все числа аналитического отчёта одним скриптом (по разделам) |
| `results/` | вывод запросов на вашей базе: примеры, проверки устойчивости, числа отчёта |
| `data/validation/validation_sample.csv` | 90 случайных статей (по 30 на способ определения страны) для проверки двумя кодировщиками |
| `scripts/01_emdat_to_csv.py` | EM-DAT .xlsx → CSV |
| `scripts/02_fetch_pubmed.py` | выгрузка PubMed (с кешем) → CSV |
| `scripts/03_build_html.py` | база → интерактивная таблица |
| `data/raw/` | исходники: архив EM-DAT и сырые XML PubMed |
| `data/processed/` | CSV для загрузки в PostgreSQL |
| `data/reference/` | русские названия стран и шаблоны для их поиска в текстах |

Скриптам нужен только Python 3 без дополнительных пакетов.

## Как загрузить в PostgreSQL

Из папки проекта, в Терминале (каждая команда спросит пароль пользователя `postgres`):

```bash
cd ~/Downloads/клод/база_чс_наука
```

```bash
/Library/PostgreSQL/18/bin/createdb -U postgres disasters_science
```

```bash
/Library/PostgreSQL/18/bin/psql -U postgres -d disasters_science -f sql/build_all.sql
```

Сборка занимает около двух минут. Потом в pgAdmin появится база `disasters_science`; начните с представления `v_gap_default` или запросов из `sql/06_examples.sql`.

Чтобы пересобрать таблицу из своей базы (например, после правки правил):

```bash
python3 scripts/03_build_html.py -U postgres -d disasters_science
```

## Главная функция

```sql
SELECT * FROM gap_analysis(
    2010,        -- с года
    2024,        -- по год
    'flood',     -- natural | all | earthquake | flood | storm | wildfire | drought | extreme_temp | volcanic | mass_movement | technological
    'affected',  -- нагрузка: events | deaths | affected | damage
    'help'       -- all — все работы, help — только о помощи
);
```

Возвращает по каждой стране: бедствия, погибшие, пострадавшие, ущерб, статьи, работы о помощи, РКИ, долю статей с местным автором, ожидаемое число статей, разрыв и категорию (дефицит / в пределах ожидаемого / больше ожидаемого / мало данных).

## Таблицы

| Таблица | Строк | Что хранит |
|---|---:|---|
| `emdat_events` | 26 946 | события EM-DAT 1900–2024 (анализ — с 2000 г.), с типом, жертвами, ущербом и затронутыми районами (`jsonb`) |
| `publications` | 14 301 | статьи PubMed: название, аннотация, журнал, DOI, тип публикации, флаги «учитывается», «о помощи», РКИ, обзор |
| `publication_mesh` | 152 539 | рубрики MeSH |
| `publication_affiliations` | 62 773 | места работы авторов |
| `publication_countries` | 9 976 | о какой стране статья и как это определено (`mesh` / `title` / `abstract`) |
| `publication_author_countries` | 16 590 | страны авторов |
| `publication_tags` | 24 948 | метки по правилам: тип бедствия, help, COVID-19 / теракты / войны |
| `countries`, `country_patterns` | 231 / 419 | страны и шаблоны для их поиска |
| `hazards`, `emdat_type_hazard`, `emdat_subtypes_ru` | | укрупнённые типы бедствий и соответствие типам EM-DAT |
| `classification_rules` | 62 | правила разметки статей — их можно менять и перезапускать `03_classify.sql` |
| `dataset_info` | | версия EM-DAT, дата выгрузки и точный запрос PubMed |

## Как обновить данные

- **EM-DAT.** Сейчас используется открытый архив UCLouvain (версия 30.04.2026, события по 2024 г.). Свежую выгрузку можно скачать на [public.emdat.be](https://public.emdat.be) после бесплатной регистрации; формат тот же: `python3 scripts/01_emdat_to_csv.py путь/к/файлу.xlsx data/processed/emdat_events.csv`, затем снова `build_all.sql`.
- **PubMed.** `python3 scripts/02_fetch_pubmed.py` докачает только недостающее (сырые XML кешируются). Чтобы выгрузить заново, удалите `data/raw/pubmed/`.

## Методика и ограничения

- **Почему PubMed, а не OpenAlex.** OpenAlex теперь ограничивает бесплатные запросы (около 100 в день без ключа), а у PubMed есть географические рубрики MeSH: индексаторы указывают, где проводилось исследование. По ним определено 80 % связей «статья — страна»; остальные — по названию (9 %) и аннотации (11 %, только если страна там единственная или упомянута дважды).
- **Учитываются** статьи, где назван конкретный тип бедствия, или «бедствие» вообще, но не в контексте COVID-19, терактов и войн. Эпидемии из EM-DAT исключены.
- **Ожидаемое число статей** — регрессия ln(1 + статьи) на ln(1 + нагрузка) по всем странам с бедствиями за период. Статьи считаются с лагом +1 год.
- PubMed почти не видит национальные журналы, в том числе русскоязычные. Дефицит у стран с сильной местной наукой (Россия, Латинская Америка) может быть завышен.
- Статьи о давних бедствиях (например, о Чернобыле) относятся к стране, но не к году события.

## Источники и лицензии

- EM-DAT: Delforge D. et al. EM-DAT: The Emergency Events Database. *International Journal of Disaster Risk Reduction*, 2025. doi:[10.1016/j.ijdrr.2025.105509](https://doi.org/10.1016/j.ijdrr.2025.105509). Архив: doi:[10.14428/DVN/I0LTPH](https://doi.org/10.14428/DVN/I0LTPH). Лицензия CC BY-NC-ND 4.0: только некоммерческое использование со ссылкой на источник, без распространения изменённых данных.
- PubMed: National Library of Medicine, E-utilities. Аннотации принадлежат авторам и издателям и используются здесь для поиска.
