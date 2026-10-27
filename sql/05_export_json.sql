-- =====================================================================
-- Шаг 5: выгрузка данных для интерактивной таблицы (один JSON).
-- Используется скриптом scripts/03_build_html.py; можно запустить и вручную:
--   psql -At -d disasters_science -f sql/05_export_json.sql > data.json
-- Массивы компактные (без имён полей) — так страница легче.
-- =====================================================================
WITH h AS (
    SELECT hazard_code, name_ru, disaster_group, sort_order - 1 AS hi
    FROM hazards
),
c AS (
    SELECT iso3, name_ru, region_ru, subregion_ru,
           (row_number() OVER (ORDER BY name_ru COLLATE "C") - 1)::int AS ci
    FROM countries
    WHERE iso3 IN (SELECT iso3 FROM v_disasters_country_year
                   UNION SELECT iso3 FROM v_publication_country
                   UNION SELECT iso3 FROM publication_author_countries)
),
pub AS (
    SELECT p.pmid, p.search_year, p.title, p.journal,
           p.is_help, p.is_rct, p.is_review,
           (SELECT COALESCE(sum(1 << h.hi), 0)
            FROM publication_tags t JOIN h ON h.hazard_code = t.tag
            WHERE t.pmid = p.pmid)                                        AS hmask,
           (SELECT json_agg(c.ci ORDER BY c.ci)
            FROM publication_countries pc JOIN c USING (iso3)
            WHERE pc.pmid = p.pmid)                                       AS cis,
           (SELECT json_agg(c.ci ORDER BY c.ci)
            FROM publication_countries pc
            JOIN publication_author_countries ac USING (pmid, iso3)
            JOIN c USING (iso3)
            WHERE pc.pmid = p.pmid)                                       AS local_cis,
           (SELECT json_agg(c.ci ORDER BY c.ci)
            FROM publication_author_countries ac JOIN c USING (iso3)
            WHERE ac.pmid = p.pmid)                                       AS author_cis
    FROM publications p
    WHERE p.is_included
      AND EXISTS (SELECT 1 FROM publication_countries pc WHERE pc.pmid = p.pmid)
)
SELECT json_build_object(
    'meta', json_build_object(
        'built',            to_char(now(), 'YYYY-MM-DD'),
        'emdat_version',    (SELECT value FROM dataset_info WHERE key = 'emdat_version'),
        'emdat_events',     (SELECT count(*) FROM emdat_events WHERE NOT historic AND hazard_code IS NOT NULL),
        'pubmed_fetched',   (SELECT value FROM dataset_info WHERE key = 'pubmed_fetched'),
        'pubs_total',       (SELECT count(*) FROM publications),
        'pubs_included',    (SELECT count(*) FROM publications WHERE is_included),
        'pubs_with_country',(SELECT count(*) FROM pub),
        'year_min',         2000,
        'year_max',         (SELECT max(start_year) FROM emdat_events),
        'pub_year_max',     (SELECT max(search_year) FROM publications),
        -- число строк в таблицах — для схемы проекта на странице
        'tables', json_build_object(
            'emdat_events',                 (SELECT count(*) FROM emdat_events),
            'publications',                 (SELECT count(*) FROM publications),
            'publication_mesh',             (SELECT count(*) FROM publication_mesh),
            'publication_affiliations',     (SELECT count(*) FROM publication_affiliations),
            'countries',                    (SELECT count(*) FROM countries),
            'country_patterns',             (SELECT count(*) FROM country_patterns),
            'classification_rules',         (SELECT count(*) FROM classification_rules),
            'hazards',                      (SELECT count(*) FROM hazards),
            'publication_tags',             (SELECT count(*) FROM publication_tags),
            'publication_countries',        (SELECT count(*) FROM publication_countries),
            'affiliation_countries',        (SELECT count(*) FROM affiliation_countries),
            'publication_author_countries', (SELECT count(*) FROM publication_author_countries),
            'country_capacity',             (SELECT count(*) FROM country_capacity)
        )
    ),
    'hazards',   (SELECT json_agg(json_build_array(hazard_code, name_ru, disaster_group) ORDER BY hi) FROM h),
    'countries', (SELECT json_agg(json_build_array(iso3, name_ru, region_ru, subregion_ru) ORDER BY ci) FROM c),
    -- [страна, год, тип, бедствий, погибших, пострадавших, ущерб млн $]
    'dis', (SELECT json_agg(json_build_array(c.ci, v.year, h.hi, v.events, v.deaths, v.affected,
                                             round(v.damage_adj_k_usd / 1000.0, 1)))
            FROM v_disasters_country_year v JOIN c USING (iso3) JOIN h USING (hazard_code)),
    -- [pmid, год, название, журнал, [страны], маска типов, флаги (1 помощь, 2 РКИ, 4 обзор),
    --  [страны с местным автором], [страны всех авторов]]
    'pubs', (SELECT json_agg(json_build_array(pmid, search_year, title, journal, cis, hmask,
                                              is_help::int + 2 * is_rct::int + 4 * is_review::int,
                                              COALESCE(local_cis, '[]'::json),
                                              COALESCE(author_cis, '[]'::json))
                             ORDER BY search_year DESC, pmid DESC)
             FROM pub),
    -- [страна, год, научных статей] — Всемирный банк, для модели с поправкой на потенциал (sql/09_capacity.sql)
    'cap', (SELECT json_agg(json_build_array(c.ci, k.year, round(k.value::numeric, 1)) ORDER BY c.ci, k.year)
            FROM country_capacity k JOIN c USING (iso3)
            WHERE k.indicator = 'IP.JRN.ARTC.SC'),
    -- [страна, год, тип, описание, погибших, пострадавших] — для раскрывающейся карточки страны
    'ev', (SELECT json_agg(json_build_array(c.ci, e.start_year, h.hi,
                                            left(concat_ws(' — ', COALESCE(st.name_ru, e.disaster_subtype),
                                                           e.event_name, left(e.location, 90)), 160),
                                            COALESCE(e.total_deaths, 0), COALESCE(e.total_affected, 0)))
           FROM emdat_events e
           JOIN c USING (iso3)
           JOIN h USING (hazard_code)
           LEFT JOIN emdat_subtypes_ru st USING (disaster_subtype)
           WHERE NOT e.historic)
);
