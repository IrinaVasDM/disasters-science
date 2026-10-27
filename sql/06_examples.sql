-- =====================================================================
-- Примеры аналитических запросов. Каждый запрос можно запускать отдельно
-- (в pgAdmin: выделить запрос и нажать F5).
-- =====================================================================

-- 1. Где больше всего природных бедствий при дефиците исследований
SELECT country, region, events, deaths, papers, expected, gap_ratio
FROM gap_analysis(2000, 2024, 'natural', 'events', 'all')
WHERE category = 'Дефицит исследований'
ORDER BY events DESC
LIMIT 15;

-- 2. То же, но нагрузка — пострадавшие, а считаем только работы о помощи
SELECT country, affected, papers, papers_help, expected, gap_ratio, category
FROM gap_analysis(2000, 2024, 'natural', 'affected', 'help')
ORDER BY affected DESC
LIMIT 15;

-- 3. Пробелы по типам внутри стран: 20+ бедствий одного типа и ни одной статьи о нём
WITH d AS (
    SELECT iso3, hazard_code, sum(events) AS events, sum(deaths) AS deaths
    FROM v_disasters_country_year
    WHERE year BETWEEN 2000 AND 2024
    GROUP BY iso3, hazard_code
),
p AS (
    SELECT v.iso3, h AS hazard_code, count(*) AS papers
    FROM v_publication_country v, unnest(v.hazard_codes) AS h
    WHERE v.year BETWEEN 2000 AND 2025
    GROUP BY v.iso3, h
)
SELECT c.name_ru AS country, hz.name_ru AS hazard, d.events, d.deaths, COALESCE(p.papers, 0) AS papers
FROM d
JOIN countries c USING (iso3)
JOIN hazards hz USING (hazard_code)
LEFT JOIN p USING (iso3, hazard_code)
WHERE d.events >= 20 AND COALESCE(p.papers, 0) = 0
ORDER BY d.events DESC;

-- 4. «Парашютная наука»: доля статей о стране, где есть хотя бы один местный автор, по регионам
SELECT c.region_ru AS region,
       count(*)                                                  AS papers,
       round(100.0 * avg(v.has_local_author::int), 1)            AS pct_local_author
FROM v_publication_country v
JOIN countries c USING (iso3)
GROUP BY c.region_ru
ORDER BY pct_local_author;

-- 5. Кто изучает Гаити: страны авторов статей о Гаити
SELECT c.name_ru AS author_country, count(DISTINCT ac.pmid) AS papers
FROM publication_countries pc
JOIN publications p USING (pmid)
JOIN publication_author_countries ac USING (pmid)
JOIN countries c ON c.iso3 = ac.iso3
WHERE pc.iso3 = 'HTI' AND p.is_included
GROUP BY c.name_ru
ORDER BY papers DESC
LIMIT 10;

-- 6. Динамика: природные бедствия и статьи по годам (по всему миру)
SELECT y AS year,
       (SELECT sum(events) FROM v_disasters_country_year v
         WHERE v.year = y AND hazard_matches('natural', ARRAY[v.hazard_code]))      AS natural_events,
       (SELECT count(*) FROM publications p
         WHERE p.search_year = y AND p.is_included)                                  AS papers,
       (SELECT count(*) FROM publications p
         WHERE p.search_year = y AND p.is_included AND p.is_help)                    AS papers_help
FROM generate_series(2000, 2025) AS y
ORDER BY y;

-- 7. Концентрация: какая доля статей приходится на 5 самых изучаемых стран
WITH t AS (
    SELECT iso3, count(*) AS papers FROM v_publication_country GROUP BY iso3
)
SELECT round(100.0 * sum(papers) FILTER (WHERE rn <= 5) / sum(papers), 1) AS pct_top5,
       string_agg(name_ru, ', ' ORDER BY rn) FILTER (WHERE rn <= 5)       AS top5
FROM (SELECT t.*, c.name_ru, row_number() OVER (ORDER BY papers DESC) AS rn
      FROM t JOIN countries c USING (iso3)) x;

-- 8. Статьи о помощи после наводнений в Бангладеш
SELECT p.search_year, p.title, p.journal, 'https://pubmed.ncbi.nlm.nih.gov/' || p.pmid AS url
FROM v_publication_country v
JOIN publications p USING (pmid)
WHERE v.iso3 = 'BGD' AND 'flood' = ANY (v.hazard_codes) AND v.is_help
ORDER BY p.search_year DESC;

-- 9. Контроль качества: как определялась страна статьи
SELECT basis, count(*) AS links, round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM publication_countries
GROUP BY basis;

-- 10. Полнотекстовый поиск по аннотациям (например, психологическая первая помощь)
SELECT p.search_year, p.title
FROM publications p
WHERE p.is_included
  AND to_tsvector('english', concat_ws(' ', p.title, p.abstract)) @@ phraseto_tsquery('english', 'psychological first aid')
ORDER BY p.search_year DESC
LIMIT 20;
