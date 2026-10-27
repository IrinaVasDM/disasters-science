-- =====================================================================
-- Проверки устойчивости: меняются ли выводы при других допущениях.
-- Сравнение с базовым вариантом (природные бедствия 2000–2024, нагрузка = число
-- бедствий, лаг публикаций +1 год, страна по MeSH, названию и аннотации):
--   * доля стран с той же категорией;
--   * ранговая корреляция Спирмена коэффициентов разрыва;
--   * пересечение множеств стран с дефицитом (индекс Жаккара).
-- Запуск: psql -d disasters_science -f sql/07_robustness.sql
-- =====================================================================

-- Тот же расчёт, что gap_analysis(), с дополнительными допущениями:
--   p_bases  — по каким признакам страна статьи считается установленной;
--   p_strict — TRUE: только статьи с названным природным типом (без «бедствия вообще»);
--   p_model  — 'loglinear' (как в gap_analysis) или 'poisson' (пуассоновская регрессия)
CREATE OR REPLACE FUNCTION gap_analysis_variant(
    p_year_from int     DEFAULT 2000,
    p_year_to   int     DEFAULT 2024,
    p_burden    text    DEFAULT 'events',
    p_pub_lag   int     DEFAULT 1,
    p_bases     text[]  DEFAULT ARRAY['mesh', 'title', 'abstract'],
    p_strict    boolean DEFAULT false,
    p_model     text    DEFAULT 'loglinear'
)
RETURNS TABLE (iso3 char(3), burden numeric, papers bigint, expected numeric, gap_ratio numeric, category text)
LANGUAGE plpgsql VOLATILE AS $$
#variable_conflict use_column
DECLARE
    a double precision; b double precision;
    sw double precision; sx double precision; sz double precision; sxx double precision; sxz double precision;
    i int;
BEGIN
    IF to_regclass('pg_temp._gv') IS NULL THEN
        CREATE TEMP TABLE _gv (iso3 char(3), burden numeric, papers bigint, x double precision,
                               mu double precision) ON COMMIT DROP;
    END IF;
    TRUNCATE _gv;
    INSERT INTO _gv
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
        SELECT v.iso3, count(*) AS papers
        FROM v_publication_country v
        WHERE v.year BETWEEN p_year_from AND p_year_to + p_pub_lag
          AND v.basis = ANY (p_bases)
          AND CASE WHEN p_strict
                   THEN v.hazard_codes && ARRAY['earthquake', 'flood', 'storm', 'wildfire', 'drought',
                                                'extreme_temp', 'volcanic', 'mass_movement']
                   ELSE hazard_matches('natural', v.hazard_codes) END
        GROUP BY v.iso3
    )
    SELECT d.iso3, d.burden, COALESCE(p.papers, 0), ln(1 + d.burden), NULL
    FROM d LEFT JOIN p USING (iso3);

    IF p_model = 'poisson' THEN
        -- IRLS: log(mu) = a + b * ln(1 + нагрузка)
        UPDATE _gv SET mu = papers + 0.5;
        FOR i IN 1..50 LOOP
            SELECT sum(mu), sum(mu * x), sum(mu * (ln(mu) + (papers - mu) / mu)),
                   sum(mu * x * x), sum(mu * x * (ln(mu) + (papers - mu) / mu))
            INTO sw, sx, sz, sxx, sxz FROM _gv;
            b := (sxz - sx * sz / sw) / (sxx - sx * sx / sw);
            a := (sz - b * sx) / sw;
            UPDATE _gv SET mu = exp(a + b * x);
        END LOOP;
        UPDATE _gv SET mu = mu;           -- mu уже ожидаемое число статей
    ELSE
        SELECT regr_intercept(ln(1 + _gv.papers), _gv.x), regr_slope(ln(1 + _gv.papers), _gv.x)
        INTO a, b FROM _gv;
        UPDATE _gv SET mu = greatest(exp(a + b * x) - 1, 0);
    END IF;

    RETURN QUERY
    SELECT g.iso3, g.burden, g.papers, round(g.mu::numeric, 2),
           round(((g.papers + 1) / (g.mu + 1))::numeric, 3),
           CASE WHEN g.mu < 1 AND g.papers <= 1                THEN 'Мало данных'
                WHEN (g.papers + 1) / (g.mu + 1) <= 0.5         THEN 'Дефицит исследований'
                WHEN (g.papers + 1) / (g.mu + 1) >= 2           THEN 'Изучено больше ожидаемого'
                ELSE 'В пределах ожидаемого' END
    FROM _gv g;
END $$;
COMMENT ON FUNCTION gap_analysis_variant IS 'gap_analysis() для природных бедствий с иными допущениями — для проверок устойчивости';

-- Сводка: насколько каждый вариант согласуется с базовым
CREATE TEMP TABLE robustness_base AS SELECT * FROM gap_analysis_variant();

CREATE TEMP TABLE robustness_variants AS
SELECT 1 AS ord, 'Нагрузка: погибшие' AS variant, * FROM gap_analysis_variant(p_burden => 'deaths')
UNION ALL SELECT 2, 'Нагрузка: пострадавшие', * FROM gap_analysis_variant(p_burden => 'affected')
UNION ALL SELECT 3, 'Нагрузка: ущерб', * FROM gap_analysis_variant(p_burden => 'damage')
UNION ALL SELECT 4, 'Без статей, где тип бедствия не назван', * FROM gap_analysis_variant(p_strict => true)
UNION ALL SELECT 5, 'Страна только по MeSH и названию', * FROM gap_analysis_variant(p_bases => ARRAY['mesh', 'title'])
UNION ALL SELECT 6, 'Страна только по MeSH', * FROM gap_analysis_variant(p_bases => ARRAY['mesh'])
UNION ALL SELECT 7, 'Лаг публикаций 0 лет', * FROM gap_analysis_variant(p_pub_lag => 0)
UNION ALL SELECT 8, 'Лаг публикаций 2 года', * FROM gap_analysis_variant(p_pub_lag => 2)
UNION ALL SELECT 9, 'Период 2000–2012', * FROM gap_analysis_variant(2000, 2012)
UNION ALL SELECT 10, 'Период 2013–2024', * FROM gap_analysis_variant(2013, 2024)
UNION ALL SELECT 11, 'Пуассоновская регрессия', * FROM gap_analysis_variant(p_model => 'poisson');

WITH j AS (
    SELECT v.ord, v.variant, b.iso3,
           b.category AS cat_b, v.category AS cat_v,
           rank() OVER (PARTITION BY v.ord ORDER BY b.gap_ratio) AS rb,
           rank() OVER (PARTITION BY v.ord ORDER BY v.gap_ratio) AS rv
    FROM robustness_variants v
    JOIN robustness_base b USING (iso3)
)
SELECT variant                                                         AS "Вариант",
       count(*)                                                        AS "Стран",
       round(100.0 * avg((cat_b = cat_v)::int), 1)                     AS "Та же категория, %",
       round(corr(rb, rv)::numeric, 2)                                 AS "Спирмен ρ",
       round(count(*) FILTER (WHERE cat_b LIKE 'Деф%' AND cat_v LIKE 'Деф%')::numeric
             / NULLIF(count(*) FILTER (WHERE cat_b LIKE 'Деф%' OR cat_v LIKE 'Деф%'), 0), 2)
                                                                       AS "Жаккар (дефицит)",
       count(*) FILTER (WHERE cat_v LIKE 'Деф%')                       AS "Стран с дефицитом"
FROM j
GROUP BY ord, variant
ORDER BY ord;

-- Устойчивое ядро: страны с дефицитом в базовом варианте и во всех вариантах нагрузки и определения страны
SELECT c.name_ru AS "Страна", b.burden::int AS "Бедствий", b.papers AS "Статей",
       count(*) FILTER (WHERE v.category LIKE 'Деф%') AS "Дефицит в вариантах (из 11)"
FROM robustness_base b
JOIN robustness_variants v USING (iso3)
JOIN countries c USING (iso3)
WHERE b.category LIKE 'Деф%'
GROUP BY c.name_ru, b.burden, b.papers
HAVING count(*) FILTER (WHERE v.category LIKE 'Деф%') >= 9
ORDER BY b.burden DESC;
