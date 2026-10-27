-- =====================================================================
-- Все числа аналитического отчёта одним скриптом (разделы указаны в заголовках).
-- Требует sql/07_robustness.sql (функция gap_analysis_variant).
-- Запуск: psql -d disasters_science -f sql/08_report_numbers.sql > results/report_numbers.txt
-- =====================================================================
\pset footer off

\echo '=== 2.2–2.3. Корпус публикаций'
SELECT count(*)                                                          AS records,
       round(100.0 * count(*) FILTER (WHERE EXISTS (SELECT 1 FROM publication_mesh m WHERE m.pmid = p.pmid)) / count(*), 1) AS pct_with_mesh,
       count(*) FILTER (WHERE is_included)                               AS included,
       count(*) FILTER (WHERE is_included AND is_help)                   AS help,
       round(100.0 * count(*) FILTER (WHERE is_included AND is_help) / count(*) FILTER (WHERE is_included), 1) AS help_pct,
       count(*) FILTER (WHERE is_included AND is_rct)                    AS rct,
       round(100.0 * count(*) FILTER (WHERE is_included AND is_rct) / count(*) FILTER (WHERE is_included), 1) AS rct_pct,
       count(*) FILTER (WHERE is_included AND is_review)                 AS reviews,
       count(*) FILTER (WHERE is_included AND EXISTS (SELECT 1 FROM publication_countries pc WHERE pc.pmid = p.pmid)) AS included_with_country
FROM publications p;

SELECT round(avg(n), 2) AS countries_per_paper
FROM (SELECT pc.pmid, count(*) n FROM publication_countries pc JOIN publications p USING (pmid)
      WHERE p.is_included GROUP BY pc.pmid) x;

SELECT basis, count(*) AS links, round(100.0 * count(*) / sum(count(*)) OVER (), 1) AS pct
FROM publication_countries pc JOIN publications p USING (pmid)
WHERE p.is_included GROUP BY basis ORDER BY basis;

SELECT (SELECT count(*) FROM affiliation_countries) AS affiliations_resolved,
       (SELECT count(DISTINCT affiliation) FROM publication_affiliations WHERE affiliation <> '') AS affiliations_total,
       round(100.0 * (SELECT count(DISTINCT pmid) FROM publication_author_countries)
             / (SELECT count(*) FROM publications), 1) AS pct_records_with_author_country;

\echo '=== 2.1. Бедствия 2000–2024'
SELECT sum(events) AS natural_events, sum(deaths) AS deaths, sum(affected) AS affected, count(DISTINCT iso3) AS countries
FROM v_disasters_country_year
WHERE year BETWEEN 2000 AND 2024 AND hazard_matches('natural', ARRAY[hazard_code]);
SELECT sum(events) AS technological_events
FROM v_disasters_country_year WHERE year BETWEEN 2000 AND 2024 AND hazard_code = 'technological';

CREATE TEMP TABLE g AS SELECT * FROM gap_analysis();

\echo '=== 3.1. Модель, корреляции, неравномерность'
SELECT round(regr_intercept(ln(1 + papers), ln(1 + events))::numeric, 2) AS alpha,
       round(regr_slope(ln(1 + papers), ln(1 + events))::numeric, 2)     AS beta,
       round(regr_r2(ln(1 + papers), ln(1 + events))::numeric, 3)        AS r2,
       count(*) AS n
FROM g;
WITH r AS (SELECT rank() OVER (ORDER BY events) re, rank() OVER (ORDER BY deaths) rd,
                  rank() OVER (ORDER BY affected) ra, rank() OVER (ORDER BY damage_musd) rm,
                  rank() OVER (ORDER BY papers) rp FROM g)
SELECT round(corr(re, rp)::numeric, 2) AS rho_events, round(corr(rd, rp)::numeric, 2) AS rho_deaths,
       round(corr(rm, rp)::numeric, 2) AS rho_damage, round(corr(ra, rp)::numeric, 2) AS rho_affected
FROM r;
WITH v AS (SELECT events::numeric e, papers::numeric p,
                  row_number() OVER (ORDER BY events) ie, row_number() OVER (ORDER BY papers) ip,
                  count(*) OVER () n FROM g)
SELECT round(2 * sum(ie * e) / (max(n) * sum(e)) - (max(n) + 1.0) / max(n), 2) AS gini_events,
       round(2 * sum(ip * p) / (max(n) * sum(p)) - (max(n) + 1.0) / max(n), 2) AS gini_papers
FROM v;
WITH t AS (SELECT papers, events, row_number() OVER (ORDER BY papers DESC) rn FROM g),
     e AS (SELECT events, row_number() OVER (ORDER BY events DESC) rn FROM g)
SELECT (SELECT sum(papers) FROM g) AS links,
       round(100.0 * (SELECT sum(papers) FROM t WHERE rn <= 5) / (SELECT sum(papers) FROM g), 1) AS top5_pct_papers,
       (SELECT string_agg(country, ', ' ORDER BY papers DESC) FROM (SELECT country, papers FROM g ORDER BY papers DESC LIMIT 5) x) AS top5,
       round(100.0 * (SELECT sum(events) FROM e WHERE rn <= 5) / (SELECT sum(events) FROM g), 1) AS top5_pct_events_by_events,
       round(100.0 * (SELECT sum(events) FROM t WHERE rn <= 5) / (SELECT sum(events) FROM g), 1) AS top5_by_papers_pct_events;
SELECT count(*) FILTER (WHERE papers = 0) AS zero_papers,
       round(100.0 * count(*) FILTER (WHERE papers = 0) / count(*)) AS zero_pct,
       count(*) FILTER (WHERE papers = 0 AND events >= 20) AS zero_papers_20plus
FROM g;
SELECT search_year, count(*) FROM publications WHERE is_included AND search_year IN (2000, 2025) GROUP BY 1 ORDER BY 1;
SELECT min(e), max(e) FROM (SELECT year, sum(events) e FROM v_disasters_country_year
       WHERE year BETWEEN 2000 AND 2024 AND hazard_matches('natural', ARRAY[hazard_code]) GROUP BY year) x;
SELECT (v.year / 5) * 5 AS period, round(100.0 * avg((v.iso3 IN ('USA', 'JPN', 'CHN', 'AUS', 'TUR'))::int)) AS top5_pct
FROM v_publication_country v WHERE hazard_matches('natural', v.hazard_codes) GROUP BY 1 ORDER BY 1;

\echo '=== Таблица 1. Регионы'
SELECT region, count(*) countries, sum(events) events, sum(papers) papers,
       round(100.0 * sum(papers) / sum(events), 1) per100,
       count(*) FILTER (WHERE category LIKE 'Деф%') deficit,
       round(100.0 * sum(events) / (SELECT sum(events) FROM g)) pct_events,
       round(100.0 * sum(papers) / (SELECT sum(papers) FROM g)) pct_papers
FROM g GROUP BY ROLLUP (region) ORDER BY per100;

\echo '=== 3.2. Категории'
SELECT category, count(*) FROM g GROUP BY 1 ORDER BY 1;

-- варианты для устойчивости (как в 07_robustness.sql)
CREATE TEMP TABLE rv AS
SELECT 1 AS ord, * FROM gap_analysis_variant(p_burden => 'deaths')
UNION ALL SELECT 2, * FROM gap_analysis_variant(p_burden => 'affected')
UNION ALL SELECT 3, * FROM gap_analysis_variant(p_burden => 'damage')
UNION ALL SELECT 4, * FROM gap_analysis_variant(p_strict => true)
UNION ALL SELECT 5, * FROM gap_analysis_variant(p_bases => ARRAY['mesh', 'title'])
UNION ALL SELECT 6, * FROM gap_analysis_variant(p_bases => ARRAY['mesh'])
UNION ALL SELECT 7, * FROM gap_analysis_variant(p_pub_lag => 0)
UNION ALL SELECT 8, * FROM gap_analysis_variant(p_pub_lag => 2)
UNION ALL SELECT 9, * FROM gap_analysis_variant(2000, 2012)
UNION ALL SELECT 10, * FROM gap_analysis_variant(2013, 2024)
UNION ALL SELECT 11, * FROM gap_analysis_variant(p_model => 'poisson');

\echo '=== Таблица 2. Дефицит, 15 стран с наибольшим числом бедствий'
SELECT g.country, g.events, g.deaths, round(g.affected / 1e6, 1) AS affected_mln, g.papers, g.papers_help,
       g.expected, g.gap_ratio, count(*) FILTER (WHERE rv.category LIKE 'Деф%') AS robust_of_11
FROM g JOIN rv USING (iso3)
WHERE g.category LIKE 'Деф%'
GROUP BY 1, 2, 3, 4, 5, 6, 7, 8 ORDER BY g.events DESC LIMIT 15;

\echo '=== Таблица 3. Больше ожидаемого (20+ бедствий)'
SELECT g.country, g.events, g.papers, g.expected, round(g.gap_ratio, 1) AS g, round(100 * g.local_share) AS local_pct
FROM g WHERE g.events >= 20 AND g.category LIKE 'Изуч%' ORDER BY g.gap_ratio DESC LIMIT 10;

\echo '=== Устойчивое ядро'
SELECT count(*) FILTER (WHERE k_def >= 9 AND category LIKE 'Деф%') AS robust_deficit,
       count(*) FILTER (WHERE k_sur >= 9 AND category LIKE 'Изуч%') AS robust_surplus
FROM (SELECT g.iso3, g.category,
             count(*) FILTER (WHERE rv.category LIKE 'Деф%') k_def,
             count(*) FILTER (WHERE rv.category LIKE 'Изуч%') k_sur
      FROM g JOIN rv USING (iso3) GROUP BY 1, 2) x;
SELECT string_agg(country, ', ' ORDER BY events DESC) AS robust_deficit_20plus
FROM (SELECT g.country, g.events FROM g JOIN rv USING (iso3)
      WHERE g.category LIKE 'Деф%' AND g.events >= 50
      GROUP BY 1, 2 HAVING count(*) FILTER (WHERE rv.category LIKE 'Деф%') >= 9) x;

\echo '=== 3.2. Крупные страны в пределах ожидаемого'
SELECT country, events, papers, gap_ratio, category FROM g WHERE iso3 IN ('PHL', 'VNM', 'MEX', 'RUS') ORDER BY events DESC;

\echo '=== 3.2. Отдельные события'
SELECT 'JPN 2011' AS what, round(100.0 * avg((concat_ws(' ', p.title, p.abstract) ~* '(great east japan|tohoku|2011|fukushima)')::int)) AS pct, count(*) n
FROM v_publication_country v JOIN publications p USING (pmid) WHERE v.iso3 = 'JPN' AND hazard_matches('natural', v.hazard_codes)
UNION ALL
SELECT 'TUR 2023', round(100.0 * avg((concat_ws(' ', p.title, p.abstract) ~* '(2023|kahramanmara|hatay|february 6)')::int)), count(*)
FROM v_publication_country v JOIN publications p USING (pmid) WHERE v.iso3 = 'TUR' AND hazard_matches('natural', v.hazard_codes);
SELECT count(*) FILTER (WHERE concat_ws(' ', p.title, p.abstract) ~* '(2023|kahramanmara|hatay|february 6)') AS tur_2023_papers
FROM v_publication_country v JOIN publications p USING (pmid) WHERE v.iso3 = 'TUR' AND hazard_matches('natural', v.hazard_codes);
SELECT count(*) papers,
       count(*) FILTER (WHERE concat_ws(' ', p.title, p.abstract) ~* 'maria') AS maria,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM publication_author_countries a WHERE a.pmid = v.pmid AND a.iso3 = 'USA')) AS us_author
FROM v_publication_country v JOIN publications p USING (pmid)
WHERE v.iso3 = 'PRI' AND hazard_matches('natural', v.hazard_codes) AND v.year BETWEEN 2000 AND 2025;

\echo '=== 3.3. Типы бедствий (рис. 2)'
WITH d AS (SELECT hazard_code, sum(events) ev, sum(deaths) de, sum(affected) af
           FROM v_disasters_country_year WHERE year BETWEEN 2000 AND 2024 GROUP BY 1),
     p AS (SELECT h AS hazard_code, count(DISTINCT pmid) pap, count(DISTINCT pmid) FILTER (WHERE is_help) help
           FROM v_publication_country v, unnest(hazard_codes) h WHERE year BETWEEN 2000 AND 2025 GROUP BY 1)
SELECT hz.hazard_code, d.ev, d.de, d.af, p.pap, round(100.0 * p.pap / NULLIF(d.ev, 0), 1) per100,
       round(1000.0 * p.pap / NULLIF(d.de, 0), 2) per1000deaths, round(100.0 * p.help / NULLIF(p.pap, 0), 1) help_pct
FROM hazards hz LEFT JOIN d USING (hazard_code) LEFT JOIN p USING (hazard_code) ORDER BY hz.sort_order;
SELECT round(100.0 * sum(deaths) FILTER (WHERE hazard_code = 'extreme_temp') / sum(deaths)) AS temp_pct_of_natural_deaths,
       round(100.0 * sum(events) FILTER (WHERE hazard_code = 'flood') / sum(events)) AS flood_pct_of_natural_events
FROM v_disasters_country_year WHERE year BETWEEN 2000 AND 2024 AND hazard_matches('natural', ARRAY[hazard_code]);

\echo '=== 3.3. Пробелы внутри стран (20+ событий типа, 0 работ о нём)'
WITH d AS (SELECT iso3, hazard_code, sum(events) ev FROM v_disasters_country_year WHERE year BETWEEN 2000 AND 2024 GROUP BY 1, 2),
     p AS (SELECT v.iso3, h hazard_code, count(*) pap FROM v_publication_country v, unnest(v.hazard_codes) h
           WHERE year BETWEEN 2000 AND 2025 GROUP BY 1, 2)
SELECT d.hazard_code, count(*) FILTER (WHERE d.ev >= 20) n20, count(*) FILTER (WHERE d.ev >= 20 AND COALESCE(p.pap, 0) = 0) n20_zero
FROM d LEFT JOIN p USING (iso3, hazard_code) GROUP BY 1 ORDER BY 1;
WITH d AS (SELECT iso3, hazard_code, sum(events) ev FROM v_disasters_country_year WHERE year BETWEEN 2000 AND 2024 GROUP BY 1, 2),
     p AS (SELECT v.iso3, h hazard_code, count(*) pap FROM v_publication_country v, unnest(v.hazard_codes) h
           WHERE year BETWEEN 2000 AND 2025 GROUP BY 1, 2)
SELECT c.name_ru, d.hazard_code, d.ev, COALESCE(p.pap, 0) AS papers
FROM d JOIN countries c USING (iso3) LEFT JOIN p USING (iso3, hazard_code)
WHERE (d.iso3, d.hazard_code) IN (('AGO', 'flood'), ('MDG', 'storm'), ('AFG', 'flood'), ('IDN', 'flood'), ('CHN', 'mass_movement'),
                                  ('HTI', 'earthquake'), ('HTI', 'flood'))
   OR (d.hazard_code = 'technological' AND d.ev >= 150)
ORDER BY d.hazard_code, d.ev DESC;

\echo '=== 3.3. Работы о помощи'
SELECT c.region_ru, sum(g.papers) papers, round(100.0 * sum(g.papers_help) / sum(g.papers), 1) help_pct
FROM g JOIN countries c USING (iso3) GROUP BY 1 ORDER BY 3;
SELECT country, papers, papers_help FROM g WHERE iso3 = 'VNM';
SELECT c.region_ru, count(*) FILTER (WHERE v.is_rct) AS rct
FROM v_publication_country v JOIN countries c USING (iso3) WHERE hazard_matches('natural', v.hazard_codes) GROUP BY 1 ORDER BY 2 DESC;
SELECT (search_year / 5) * 5 AS period, round(100.0 * avg(is_help::int), 1) help_pct
FROM publications WHERE is_included GROUP BY 1 ORDER BY 1;

\echo '=== 3.4. Местные авторы'
SELECT round(100.0 * avg(has_local_author::int), 1) AS pct_local_all
FROM v_publication_country WHERE hazard_matches('natural', hazard_codes) AND year BETWEEN 2000 AND 2025;
SELECT c.region_ru, round(100.0 * avg(v.has_local_author::int), 1) pct
FROM v_publication_country v JOIN countries c USING (iso3)
WHERE hazard_matches('natural', v.hazard_codes) AND v.year BETWEEN 2000 AND 2025 GROUP BY 1 ORDER BY 2 DESC;
SELECT count(*) FILTER (WHERE v.has_local_author) local, count(*) n, round(100.0 * avg(v.has_local_author::int), 1) pct
FROM v_publication_country v
WHERE hazard_matches('natural', v.hazard_codes) AND v.year BETWEEN 2000 AND 2025
  AND v.iso3 IN (SELECT iso3 FROM g WHERE category LIKE 'Деф%');
WITH low AS (SELECT iso3, country, papers, round(100 * local_share) loc FROM g WHERE papers >= 20 ORDER BY local_share LIMIT 10),
     pp AS (SELECT iso3, pmid FROM v_publication_country WHERE hazard_matches('natural', hazard_codes) AND year BETWEEN 2000 AND 2025),
     fa AS (SELECT pp.iso3, ac.iso3 auth, count(DISTINCT pp.pmid) n FROM pp JOIN publication_author_countries ac USING (pmid)
            WHERE ac.iso3 <> pp.iso3 GROUP BY 1, 2),
     top AS (SELECT DISTINCT ON (iso3) iso3, auth, n FROM fa ORDER BY iso3, n DESC)
SELECT low.country, low.papers, low.loc, c.name_ru AS top_foreign, top.n
FROM low JOIN top USING (iso3) JOIN countries c ON c.iso3 = top.auth ORDER BY low.loc;
SELECT country, round(100 * local_share) pct FROM g WHERE papers >= 20 ORDER BY local_share DESC LIMIT 6;
SELECT round(100.0 * count(*) FILTER (WHERE NOT EXISTS (SELECT 1 FROM publication_author_countries a WHERE a.pmid = v.pmid))
             / count(*), 1) AS pct_links_without_author_country
FROM v_publication_country v WHERE hazard_matches('natural', v.hazard_codes);

\echo '=== 4. СНГ, Армения, Сирия'
SELECT country, events, papers, gap_ratio FROM g WHERE iso3 IN ('TJK', 'KGZ', 'KAZ', 'RUS', 'ARM') ORDER BY events DESC;
SELECT v.iso3, count(*) n,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM publication_author_countries a WHERE a.pmid = v.pmid AND a.iso3 = 'USA')) us_author,
       count(*) FILTER (WHERE EXISTS (SELECT 1 FROM publication_author_countries a WHERE a.pmid = v.pmid AND a.iso3 = 'TUR')) tur_author,
       count(*) FILTER (WHERE concat_ws(' ', p.title, p.abstract) ~* '(2023|kahramanmara|february 6)') about_2023
FROM v_publication_country v JOIN publications p USING (pmid)
WHERE v.iso3 IN ('ARM', 'SYR') AND hazard_matches('natural', v.hazard_codes) GROUP BY 1;
