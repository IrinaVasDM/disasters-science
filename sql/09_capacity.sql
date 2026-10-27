-- =====================================================================
-- Поправка на научный потенциал страны.
--
-- Базовая модель (gap_analysis) сравнивает страну только со странами с похожей
-- нагрузкой бедствиями. Но у стран с маленькой наукой мало статей обо всём,
-- не только о бедствиях. Здесь в регрессию добавлен второй предиктор:
--   ln(1 + статьи) = a + b1 * ln(1 + нагрузка) + b2 * ln(1 + потенциал)
-- Потенциал — среднегодовое число научных статей страны (Всемирный банк,
-- IP.JRN.ARTC.SC, источник NSF) или, для проверки, ВВП по ППС.
-- Дефицит с поправкой = меньше половины статей, ожидаемых при такой нагрузке
-- И такой науке, то есть недостаток внимания именно к бедствиям.
--
-- Данные: python3 scripts/04_fetch_worldbank.py → data/reference/worldbank_capacity.csv
-- Запуск: psql -d disasters_science -f sql/09_capacity.sql
-- =====================================================================

DROP TABLE IF EXISTS country_capacity CASCADE;
CREATE TABLE country_capacity (
    iso3      char(3) NOT NULL REFERENCES countries,
    indicator text    NOT NULL,
    year      int     NOT NULL,
    value     double precision NOT NULL,
    PRIMARY KEY (iso3, indicator, year)
);
COMMENT ON TABLE country_capacity IS 'Показатели Всемирного банка (WDI, CC BY 4.0): IP.JRN.ARTC.SC — научные статьи, NY.GDP.MKTP.PP.KD — ВВП по ППС, SP.POP.TOTL — население';

CREATE TEMP TABLE _wb (iso3 char(3), indicator text, year int, value double precision);
\copy _wb FROM 'data/reference/worldbank_capacity.csv' WITH (FORMAT csv, HEADER true)
INSERT INTO country_capacity
SELECT w.* FROM _wb w JOIN countries c USING (iso3);

-- Страна × (нагрузка, статьи, потенциал) — исходные данные для обеих моделей
CREATE OR REPLACE FUNCTION capacity_panel(
    p_year_from int  DEFAULT 2000,
    p_year_to   int  DEFAULT 2024,
    p_burden    text DEFAULT 'events',    -- events | deaths | affected | damage
    p_capacity  text DEFAULT 'articles',  -- articles | gdp
    p_research  text DEFAULT 'all',       -- all | help
    p_pub_lag   int  DEFAULT 1
)
RETURNS TABLE (iso3 char(3), burden numeric, papers bigint, capacity double precision,
               y double precision, x1 double precision, x2 double precision)
LANGUAGE sql STABLE AS $$
WITH d AS (
    SELECT v.iso3,
           CASE p_burden WHEN 'deaths'   THEN sum(v.deaths)
                         WHEN 'affected' THEN sum(v.affected)
                         WHEN 'damage'   THEN sum(v.damage_adj_k_usd) / 1000.0
                         ELSE sum(v.events) END::numeric AS burden
    FROM v_disasters_country_year v
    WHERE v.year BETWEEN p_year_from AND p_year_to
      AND hazard_matches('natural', ARRAY[v.hazard_code])
    GROUP BY v.iso3
),
p AS (
    SELECT v.iso3,
           count(*) FILTER (WHERE p_research = 'all' OR v.is_help) AS papers
    FROM v_publication_country v
    WHERE v.year BETWEEN p_year_from AND p_year_to + p_pub_lag
      AND hazard_matches('natural', v.hazard_codes)
    GROUP BY v.iso3
),
s AS (
    -- среднее за годы периода, по которым есть данные
    SELECT k.iso3, avg(k.value) AS capacity
    FROM country_capacity k
    WHERE k.indicator = CASE p_capacity WHEN 'gdp' THEN 'NY.GDP.MKTP.PP.KD' ELSE 'IP.JRN.ARTC.SC' END
      AND k.year BETWEEN p_year_from AND p_year_to
    GROUP BY k.iso3
)
SELECT d.iso3, d.burden, COALESCE(p.papers, 0), s.capacity,
       ln(1 + COALESCE(p.papers, 0)), ln(1 + d.burden), ln(1 + s.capacity)
FROM d
LEFT JOIN p USING (iso3)
LEFT JOIN s USING (iso3)
$$;

-- Коэффициенты регрессии по странам, где известен потенциал.
-- p_adjust = false — базовая модель на той же выборке (для честного сравнения).
CREATE OR REPLACE FUNCTION capacity_fit(
    p_year_from int     DEFAULT 2000,
    p_year_to   int     DEFAULT 2024,
    p_burden    text    DEFAULT 'events',
    p_capacity  text    DEFAULT 'articles',
    p_research  text    DEFAULT 'all',
    p_pub_lag   int     DEFAULT 1,
    p_adjust    boolean DEFAULT true
)
RETURNS TABLE (n bigint, a double precision, b1 double precision, b2 double precision,
               se_b1 double precision, se_b2 double precision, r2 double precision)
LANGUAGE sql STABLE AS $$
WITH m AS (
    SELECT * FROM capacity_panel(p_year_from, p_year_to, p_burden, p_capacity, p_research, p_pub_lag)
    WHERE capacity IS NOT NULL
),
s AS (
    SELECT count(*) AS n, avg(y) AS my, avg(x1) AS m1, avg(x2) AS m2, var_pop(y) AS syy,
           var_pop(x1) AS s11, var_pop(x2) AS s22, covar_pop(x1, x2) AS s12,
           covar_pop(x1, y) AS s1y, covar_pop(x2, y) AS s2y
    FROM m
),
b AS (
    -- МНК для двух предикторов через ковариации; без поправки b2 = 0
    SELECT s.*,
           CASE WHEN p_adjust THEN (s22 * s1y - s12 * s2y) / (s11 * s22 - s12 * s12)
                ELSE s1y / s11 END AS b1,
           CASE WHEN p_adjust THEN (s11 * s2y - s12 * s1y) / (s11 * s22 - s12 * s12)
                ELSE 0 END AS b2
    FROM s
),
e AS (
    SELECT b.*, b.my - b.b1 * b.m1 - b.b2 * b.m2 AS a,
           (SELECT sum((m.y - (b.my + b.b1 * (m.x1 - b.m1) + b.b2 * (m.x2 - b.m2)))^2) FROM m)
               / (b.n - CASE WHEN p_adjust THEN 3 ELSE 2 END) AS sigma2
    FROM b
)
SELECT n, a, b1, b2,
       CASE WHEN p_adjust THEN sqrt(sigma2 * s22 / (n * (s11 * s22 - s12 * s12)))
            ELSE sqrt(sigma2 / (n * s11)) END,
       CASE WHEN p_adjust THEN sqrt(sigma2 * s11 / (n * (s11 * s22 - s12 * s12))) END,
       (b1 * s1y + b2 * s2y) / syy
FROM e
$$;

-- Разрыв с поправкой на потенциал. Страны без данных о потенциале — отдельная категория.
CREATE OR REPLACE FUNCTION gap_analysis_adj(
    p_year_from int     DEFAULT 2000,
    p_year_to   int     DEFAULT 2024,
    p_burden    text    DEFAULT 'events',
    p_capacity  text    DEFAULT 'articles',
    p_research  text    DEFAULT 'all',
    p_pub_lag   int     DEFAULT 1,
    p_adjust    boolean DEFAULT true
)
RETURNS TABLE (iso3 char(3), country text, region text, burden numeric, papers bigint,
               capacity numeric, expected numeric, gap_ratio numeric, category text)
LANGUAGE sql STABLE AS $$
WITH f AS (
    SELECT * FROM capacity_fit(p_year_from, p_year_to, p_burden, p_capacity, p_research, p_pub_lag, p_adjust)
),
r AS (
    SELECT m.*, CASE WHEN m.capacity IS NOT NULL
                     THEN greatest(exp(f.a + f.b1 * m.x1 + f.b2 * m.x2) - 1, 0) END AS mu
    FROM capacity_panel(p_year_from, p_year_to, p_burden, p_capacity, p_research, p_pub_lag) m
    CROSS JOIN f
)
SELECT r.iso3, c.name_ru, c.region_ru, r.burden, r.papers,
       round(r.capacity::numeric, 0), round(r.mu::numeric, 1),
       round(((r.papers + 1) / (r.mu + 1))::numeric, 2),
       CASE WHEN r.mu IS NULL                          THEN 'Нет данных о потенциале'
            WHEN r.mu < 1 AND r.papers <= 1            THEN 'Мало данных'
            WHEN (r.papers + 1) / (r.mu + 1) <= 0.5    THEN 'Дефицит исследований'
            WHEN (r.papers + 1) / (r.mu + 1) >= 2      THEN 'Изучено больше ожидаемого'
            ELSE 'В пределах ожидаемого' END
FROM r
JOIN countries c USING (iso3)
ORDER BY (r.papers + 1) / (r.mu + 1) NULLS LAST, r.burden DESC
$$;
COMMENT ON FUNCTION gap_analysis_adj IS 'Разрыв «бедствия — исследования» с поправкой на научный потенциал страны (природные бедствия). Пример: SELECT * FROM gap_analysis_adj(p_capacity => ''gdp'');';

CREATE OR REPLACE VIEW v_gap_adjusted AS
SELECT * FROM gap_analysis_adj();
COMMENT ON VIEW v_gap_adjusted IS 'gap_analysis_adj() по умолчанию: природные бедствия 2000–2024, нагрузка = число бедствий, потенциал = научные статьи';


-- =====================================================================
-- Сравнение: как меняется список стран с дефицитом
-- =====================================================================
\pset footer off
\echo
\echo '1. Модели: базовая (все страны и та же выборка) и с поправкой на потенциал'
SELECT 'Базовая, все страны' AS "Модель", count(*) AS "Стран",
       round(regr_r2(y, x1)::numeric, 2) AS "R²",
       round(regr_slope(y, x1)::numeric, 2) AS "b нагрузка", NULL::numeric AS "SE",
       NULL::numeric AS "b потенциал", NULL::numeric AS "SE "
FROM capacity_panel()
UNION ALL
SELECT 'Базовая, страны с данными о науке', n, round(r2::numeric, 2), round(b1::numeric, 2),
       round(se_b1::numeric, 2), NULL, NULL
FROM capacity_fit(p_adjust => false)
UNION ALL
SELECT 'Поправка: научные статьи', n, round(r2::numeric, 2), round(b1::numeric, 2),
       round(se_b1::numeric, 2), round(b2::numeric, 2), round(se_b2::numeric, 2)
FROM capacity_fit()
UNION ALL
SELECT 'Поправка: ВВП по ППС', n, round(r2::numeric, 2), round(b1::numeric, 2),
       round(se_b1::numeric, 2), round(b2::numeric, 2), round(se_b2::numeric, 2)
FROM capacity_fit(p_capacity => 'gdp');

CREATE TEMP TABLE cmp AS
SELECT b.iso3, b.country, b.region, b.events, b.papers,
       b.expected AS exp_base, b.gap_ratio AS gap_base, b.category AS cat_base,
       a.capacity, a.expected AS exp_adj, a.gap_ratio AS gap_adj, a.category AS cat_adj,
       g.category AS cat_gdp
FROM gap_analysis() b
JOIN gap_analysis_adj() a USING (iso3)
JOIN gap_analysis_adj(p_capacity => 'gdp') g USING (iso3);

\echo
\echo '2. Переходы между категориями: строки — базовая модель, столбцы — с поправкой на статьи'
SELECT cat_base AS "Базовая / с поправкой",
       count(*) FILTER (WHERE cat_adj LIKE 'Деф%') AS "Дефицит",
       count(*) FILTER (WHERE cat_adj LIKE 'В пред%') AS "В пределах",
       count(*) FILTER (WHERE cat_adj LIKE 'Изуч%') AS "Больше ожид.",
       count(*) FILTER (WHERE cat_adj LIKE 'Мало%') AS "Мало данных",
       count(*) FILTER (WHERE cat_adj LIKE 'Нет%') AS "Нет данных о науке",
       count(*) AS "Всего"
FROM cmp
GROUP BY cat_base
ORDER BY min(CASE cat_base WHEN 'Дефицит исследований' THEN 1 WHEN 'В пределах ожидаемого' THEN 2
                           WHEN 'Изучено больше ожидаемого' THEN 3 ELSE 4 END);

\echo
\echo '3. Остались в дефиците и после поправки (недостаток внимания именно к бедствиям)'
SELECT country AS "Страна", region AS "Регион", events AS "Бедствий", papers AS "Статей",
       exp_base AS "Ожид. базовая", exp_adj AS "Ожид. с поправкой",
       gap_adj AS "Разрыв с поправкой", capacity AS "Научных статей в год",
       CASE WHEN cat_gdp LIKE 'Деф%' THEN 'да' ELSE 'нет' END AS "Дефицит и с поправкой на ВВП"
FROM cmp WHERE cat_base LIKE 'Деф%' AND cat_adj LIKE 'Деф%'
ORDER BY events DESC;

\echo
\echo '4. Вышли из дефицита: мало статей объясняется слабой наукой в целом'
SELECT country AS "Страна", region AS "Регион", events AS "Бедствий", papers AS "Статей",
       exp_base AS "Ожид. базовая", exp_adj AS "Ожид. с поправкой",
       capacity AS "Научных статей в год", cat_adj AS "Категория с поправкой"
FROM cmp WHERE cat_base LIKE 'Деф%' AND cat_adj NOT LIKE 'Деф%'
ORDER BY cat_adj, events DESC;

\echo
\echo '5. Новые в дефиците: сильная наука, но бедствия изучаются мало'
SELECT country AS "Страна", region AS "Регион", events AS "Бедствий", papers AS "Статей",
       exp_base AS "Ожид. базовая", exp_adj AS "Ожид. с поправкой",
       gap_adj AS "Разрыв с поправкой", capacity AS "Научных статей в год", cat_base AS "Было",
       CASE WHEN cat_gdp LIKE 'Деф%' THEN 'да' ELSE 'нет' END AS "Дефицит и с поправкой на ВВП"
FROM cmp WHERE cat_adj LIKE 'Деф%' AND cat_base NOT LIKE 'Деф%'
ORDER BY events DESC;

\echo
\echo '6. Изучено больше ожидаемого: базовая модель и с поправкой'
SELECT country AS "Страна", events AS "Бедствий", papers AS "Статей",
       gap_base AS "Разрыв базовый", gap_adj AS "Разрыв с поправкой", cat_adj AS "Категория с поправкой"
FROM cmp WHERE cat_base LIKE 'Изуч%' OR cat_adj LIKE 'Изуч%'
ORDER BY gap_adj DESC NULLS LAST;

\echo
\echo '7. Дефицит по регионам'
SELECT region AS "Регион",
       count(*) FILTER (WHERE cat_base LIKE 'Деф%') AS "Базовая",
       count(*) FILTER (WHERE cat_adj LIKE 'Деф%')  AS "Поправка: статьи",
       count(*) FILTER (WHERE cat_gdp LIKE 'Деф%')  AS "Поправка: ВВП",
       count(*) AS "Стран"
FROM cmp GROUP BY region ORDER BY 2 DESC;

\echo
\echo '8. Устойчивость дефицита с поправкой: 4 меры нагрузки × 2 меры потенциала'
CREATE TEMP TABLE adj_variants AS
SELECT bu, ca, g.iso3, g.category
FROM unnest(ARRAY['events', 'deaths', 'affected', 'damage']) bu
CROSS JOIN unnest(ARRAY['articles', 'gdp']) ca
CROSS JOIN LATERAL gap_analysis_adj(p_burden => bu, p_capacity => ca) g;

SELECT c.country AS "Страна", c.events AS "Бедствий", c.papers AS "Статей",
       count(*) FILTER (WHERE v.category LIKE 'Деф%') AS "Дефицит в вариантах (из 8)",
       CASE WHEN c.cat_base LIKE 'Деф%' THEN 'да' ELSE 'нет' END AS "Дефицит в базовой"
FROM cmp c JOIN adj_variants v USING (iso3)
GROUP BY c.country, c.events, c.papers, c.cat_base
HAVING count(*) FILTER (WHERE v.category LIKE 'Деф%') >= 6
ORDER BY 4 DESC, c.events DESC;
