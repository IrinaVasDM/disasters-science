-- =====================================================================
-- Шаг 2: загрузка данных из CSV.
-- Запускать через psql из корня проекта (пути в \copy — относительные).
-- =====================================================================

\copy emdat_raw FROM 'data/processed/emdat_events.csv' WITH (FORMAT csv, HEADER true)

-- Страны: все ISO-коды EM-DAT (включая исторические, например SUN — СССР)
CREATE TEMP TABLE countries_ru (iso3 char(3), name_ru text);
\copy countries_ru FROM 'data/reference/countries_ru.csv' WITH (FORMAT csv, HEADER true)

INSERT INTO countries (iso3, name_en, name_ru, subregion, subregion_ru, region, region_ru)
SELECT DISTINCT ON (r.iso3)
       r.iso3, r.country, COALESCE(ru.name_ru, r.country),
       r.subregion,
       CASE r.subregion
           WHEN 'Sub-Saharan Africa'               THEN 'Африка южнее Сахары'
           WHEN 'Northern Africa'                  THEN 'Северная Африка'
           WHEN 'Latin America and the Caribbean'  THEN 'Латинская Америка и Карибы'
           WHEN 'Northern America'                 THEN 'Северная Америка'
           WHEN 'Southern Asia'                    THEN 'Южная Азия'
           WHEN 'Western Asia'                     THEN 'Западная Азия'
           WHEN 'Eastern Asia'                     THEN 'Восточная Азия'
           WHEN 'South-eastern Asia'               THEN 'Юго-Восточная Азия'
           WHEN 'Central Asia'                     THEN 'Центральная Азия'
           WHEN 'Eastern Europe'                   THEN 'Восточная Европа'
           WHEN 'Western Europe'                   THEN 'Западная Европа'
           WHEN 'Northern Europe'                  THEN 'Северная Европа'
           WHEN 'Southern Europe'                  THEN 'Южная Европа'
           WHEN 'Australia and New Zealand'        THEN 'Австралия и Новая Зеландия'
           WHEN 'Melanesia'                        THEN 'Меланезия'
           WHEN 'Micronesia'                       THEN 'Микронезия'
           WHEN 'Polynesia'                        THEN 'Полинезия'
           ELSE r.subregion
       END,
       r.region,
       CASE r.region
           WHEN 'Africa'   THEN 'Африка'
           WHEN 'Americas' THEN 'Америка'
           WHEN 'Asia'     THEN 'Азия'
           WHEN 'Europe'   THEN 'Европа'
           WHEN 'Oceania'  THEN 'Океания'
           ELSE r.region
       END
FROM emdat_raw r
LEFT JOIN countries_ru ru ON ru.iso3 = r.iso3
ORDER BY r.iso3, r.start_year::int DESC;

\copy country_patterns (iso3, pattern, scope, kind) FROM 'data/reference/country_patterns.csv' WITH (FORMAT csv, HEADER true)

-- Все техногенные типы EM-DAT -> 'technological'
INSERT INTO emdat_type_hazard
SELECT DISTINCT disaster_group, disaster_type, 'technological'
FROM emdat_raw
WHERE disaster_group = 'Technological'
ON CONFLICT DO NOTHING;

DO $$
DECLARE missing text;
BEGIN
    SELECT string_agg(DISTINCT r.disaster_group || ' / ' || r.disaster_type, ', ') INTO missing
    FROM emdat_raw r
    LEFT JOIN emdat_type_hazard t USING (disaster_group, disaster_type)
    WHERE t.disaster_type IS NULL;
    IF missing IS NOT NULL THEN
        RAISE WARNING 'Новые типы EM-DAT без соответствия в emdat_type_hazard: %', missing;
    END IF;
END $$;

INSERT INTO emdat_events
SELECT r.dis_no,
       r.historic = 'Yes',
       r.classification_key, r.disaster_group, r.disaster_subgroup, r.disaster_type, r.disaster_subtype,
       t.hazard_code,
       NULLIF(r.external_ids, ''), NULLIF(r.event_name, ''), r.iso3,
       NULLIF(r.location, ''), NULLIF(r.origin, ''), NULLIF(r.associated_types, ''),
       r.appeal = 'Yes', r.declaration = 'Yes',
       NULLIF(r.magnitude, '')::numeric, NULLIF(r.magnitude_scale, ''),
       NULLIF(r.latitude, '')::numeric, NULLIF(r.longitude, '')::numeric, NULLIF(r.river_basin, ''),
       NULLIF(r.start_year, '')::int, NULLIF(r.start_month, '')::int, NULLIF(r.start_day, '')::int,
       NULLIF(r.end_year, '')::int, NULLIF(r.end_month, '')::int, NULLIF(r.end_day, '')::int,
       NULLIF(r.total_deaths, '')::int, NULLIF(r.no_injured, '')::int,
       NULLIF(r.no_affected, '')::bigint, NULLIF(r.no_homeless, '')::int,
       NULLIF(r.total_affected, '')::bigint,
       NULLIF(r.reconstruction_costs_adj_k_usd, '')::numeric,
       NULLIF(r.insured_damage_adj_k_usd, '')::numeric,
       NULLIF(r.total_damage_k_usd, '')::numeric,
       NULLIF(r.total_damage_adj_k_usd, '')::numeric,
       NULLIF(r.cpi, '')::numeric,
       NULLIF(r.admin_units, '')::jsonb, NULLIF(r.gadm_admin_units, '')::jsonb,
       NULLIF(r.entry_date, '')::date, NULLIF(r.last_update, '')::date
FROM emdat_raw r
JOIN emdat_type_hazard t USING (disaster_group, disaster_type);

DROP TABLE emdat_raw;

CREATE INDEX ON emdat_events (iso3, start_year);
CREATE INDEX ON emdat_events (hazard_code);

-- ---------------------------------------------------------------------
-- PubMed
-- ---------------------------------------------------------------------
CREATE TEMP TABLE pub_raw (
    pmid bigint, pub_year int, title text, abstract text, keywords text, journal text,
    doi text, language text, publication_types text, search_year int
);
\copy pub_raw FROM 'data/processed/publications.csv' WITH (FORMAT csv, HEADER true)

INSERT INTO publications (pmid, pub_year, title, abstract, keywords, journal, doi, language,
                          publication_types, search_year)
SELECT pmid, pub_year, title, NULLIF(abstract, ''), NULLIF(keywords, ''), journal, NULLIF(doi, ''),
       language, string_to_array(publication_types, ' | '), search_year
FROM pub_raw;

\copy dataset_info FROM 'data/processed/dataset_info.csv' WITH (FORMAT csv, HEADER true)
\copy publication_mesh FROM 'data/processed/publication_mesh.csv' WITH (FORMAT csv, HEADER true)
\copy publication_affiliations FROM 'data/processed/publication_affiliations.csv' WITH (FORMAT csv, HEADER true)

CREATE INDEX ON publication_mesh (descriptor_name);
CREATE INDEX ON publication_affiliations (pmid);
