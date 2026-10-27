-- =====================================================================
-- Шаг 4: аналитика «бедствия против науки».
-- =====================================================================

-- Бедствия: страна × год × укрупнённый тип (с 2000 г., как рекомендует CRED)
CREATE OR REPLACE VIEW v_disasters_country_year AS
SELECT e.iso3,
       e.start_year                              AS year,
       e.hazard_code,
       count(*)                                  AS events,
       COALESCE(sum(e.total_deaths), 0)          AS deaths,
       COALESCE(sum(e.total_affected), 0)        AS affected,
       COALESCE(sum(e.total_damage_adj_k_usd), 0) AS damage_adj_k_usd
FROM emdat_events e
WHERE e.hazard_code IS NOT NULL
  AND NOT e.historic
GROUP BY e.iso3, e.start_year, e.hazard_code;
COMMENT ON VIEW v_disasters_country_year IS 'Число бедствий, погибшие, пострадавшие и ущерб по стране, году и типу (2000+)';

-- Статьи: одна строка — статья × страна, о которой она написана
CREATE OR REPLACE VIEW v_publication_country AS
SELECT pc.pmid,
       pc.iso3,
       pc.basis,
       p.search_year AS year,
       p.is_help,
       p.is_rct,
       p.is_review,
       EXISTS (SELECT 1 FROM publication_author_countries ac
               WHERE ac.pmid = pc.pmid AND ac.iso3 = pc.iso3) AS has_local_author,
       ARRAY(SELECT t.tag
             FROM publication_tags t
             JOIN hazards h ON h.hazard_code = t.tag
             WHERE t.pmid = pc.pmid
             ORDER BY h.sort_order)                           AS hazard_codes
FROM publication_countries pc
JOIN publications p USING (pmid)
WHERE p.is_included;
COMMENT ON VIEW v_publication_country IS 'Учитываемые статьи по странам: год, тип бедствия, о помощи ли, РКИ, есть ли автор из этой страны';

-- Подходит ли набор типов под фильтр:
--   'all' — любые; 'natural' — природные (или «бедствие» без уточнения); иначе — конкретный код
CREATE OR REPLACE FUNCTION hazard_matches(p_filter text, p_codes text[])
RETURNS boolean
LANGUAGE sql IMMUTABLE AS $$
    SELECT CASE
        WHEN p_filter = 'all' THEN cardinality(p_codes) > 0
        WHEN p_filter = 'natural' THEN
             p_codes && ARRAY['earthquake', 'flood', 'storm', 'wildfire', 'drought',
                              'extreme_temp', 'volcanic', 'mass_movement']
             OR p_codes = ARRAY['generic']
        ELSE p_filter = ANY (p_codes)
    END
$$;

-- ---------------------------------------------------------------------
-- Главная функция: разрыв между бедствиями и исследованиями по странам.
--
-- «Ожидаемое» число статей — по регрессии ln(1 + статьи) на ln(1 + нагрузка)
-- среди всех стран с бедствиями за период. gap_ratio = (статьи + 1) / (ожидаемое + 1):
-- 0,25 — статей в 4 раза меньше, чем у стран с похожей нагрузкой; 3 — в 3 раза больше.
-- «Мало данных» — ожидается меньше одной статьи и есть не больше одной: судить не о чем.
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION gap_analysis(
    p_year_from int  DEFAULT 2000,
    p_year_to   int  DEFAULT 2024,
    p_hazard    text DEFAULT 'natural',  -- natural | all | код из hazards
    p_burden    text DEFAULT 'events',   -- events | deaths | affected | damage
    p_research  text DEFAULT 'all',      -- all (все работы) | help (только о помощи)
    p_pub_lag   int  DEFAULT 1           -- статьи считаем до p_year_to + лаг
)
RETURNS TABLE (
    iso3            char(3),
    country         text,
    region          text,
    events          bigint,
    deaths          bigint,
    affected        bigint,
    damage_musd     numeric,
    papers          bigint,
    papers_help     bigint,
    papers_rct      bigint,
    local_share     numeric,
    papers_per_100_events numeric,
    expected        numeric,
    gap_ratio       numeric,
    category        text
)
LANGUAGE sql STABLE AS $$
WITH d AS (
    SELECT v.iso3,
           sum(v.events)::bigint            AS events,
           sum(v.deaths)::bigint            AS deaths,
           sum(v.affected)::bigint          AS affected,
           sum(v.damage_adj_k_usd) / 1000.0 AS damage_musd
    FROM v_disasters_country_year v
    WHERE v.year BETWEEN p_year_from AND p_year_to
      AND hazard_matches(p_hazard, ARRAY[v.hazard_code])
    GROUP BY v.iso3
),
p AS (
    SELECT v.iso3,
           count(*)                                    AS papers,
           count(*) FILTER (WHERE v.is_help)           AS papers_help,
           count(*) FILTER (WHERE v.is_rct)            AS papers_rct,
           count(*) FILTER (WHERE v.has_local_author)  AS papers_local
    FROM v_publication_country v
    WHERE v.year BETWEEN p_year_from AND p_year_to + p_pub_lag
      AND hazard_matches(p_hazard, v.hazard_codes)
    GROUP BY v.iso3
),
j AS (
    SELECT c.iso3, c.name_ru, c.region_ru,
           d.events, d.deaths, d.affected, d.damage_musd,
           COALESCE(p.papers, 0)       AS papers,
           COALESCE(p.papers_help, 0)  AS papers_help,
           COALESCE(p.papers_rct, 0)   AS papers_rct,
           COALESCE(p.papers_local, 0) AS papers_local,
           ln(1 + CASE p_burden
                      WHEN 'deaths'   THEN d.deaths
                      WHEN 'affected' THEN d.affected
                      WHEN 'damage'   THEN d.damage_musd
                      ELSE d.events
                  END) AS x,
           CASE p_research WHEN 'help' THEN COALESCE(p.papers_help, 0)
                           ELSE COALESCE(p.papers, 0) END AS research
    FROM d
    JOIN countries c USING (iso3)
    LEFT JOIN p USING (iso3)
),
fit AS (
    SELECT regr_intercept(ln(1 + research), x) AS a,
           regr_slope(ln(1 + research), x)     AS b
    FROM j
),
r AS (
    SELECT j.*, greatest(exp(f.a + f.b * j.x) - 1, 0) AS exp_papers
    FROM j CROSS JOIN fit f
)
SELECT r.iso3, r.name_ru, r.region_ru, r.events, r.deaths, r.affected,
       round(r.damage_musd, 1),
       r.papers, r.papers_help, r.papers_rct,
       round(r.papers_local::numeric / NULLIF(r.papers, 0), 2),
       round(100.0 * r.papers / r.events, 1),
       round(r.exp_papers::numeric, 1),
       round(((r.research + 1) / (r.exp_papers + 1))::numeric, 2),
       CASE WHEN r.exp_papers < 1 AND r.research <= 1                THEN 'Мало данных'
            WHEN (r.research + 1) / (r.exp_papers + 1) <= 0.5 THEN 'Дефицит исследований'
            WHEN (r.research + 1) / (r.exp_papers + 1) >= 2   THEN 'Изучено больше ожидаемого'
            ELSE 'В пределах ожидаемого'
       END
FROM r
ORDER BY (r.research + 1) / (r.exp_papers + 1), r.events DESC;
$$;
COMMENT ON FUNCTION gap_analysis IS 'Разрыв «бедствия — исследования» по странам. Пример: SELECT * FROM gap_analysis(2010, 2024, ''flood'', ''affected'', ''help'');';

-- Результат с параметрами по умолчанию — удобно открыть в pgAdmin
CREATE OR REPLACE VIEW v_gap_default AS
SELECT * FROM gap_analysis();
COMMENT ON VIEW v_gap_default IS 'gap_analysis() с параметрами по умолчанию: природные бедствия 2000–2024, нагрузка = число бедствий, все работы';
