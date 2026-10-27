-- =====================================================================
-- Шаг 3: разметка статей.
--   * метки по правилам classification_rules (типы бедствий, help, контексты);
--   * о какой стране статья (MeSH -> название -> аннотация);
--   * страны авторов (по аффилиациям).
-- Можно перезапускать после правки classification_rules или country_patterns.
--
-- Регулярные выражения перебираются в цикле по шаблонам: так каждый шаблон
-- компилируется один раз (кеш регулярных выражений в PostgreSQL — всего 32 шт.).
-- =====================================================================

TRUNCATE publication_tags, publication_countries, affiliation_countries, publication_author_countries;

-- ---------------------------------------------------------------------
-- 1. Метки
-- ---------------------------------------------------------------------
INSERT INTO publication_tags
SELECT DISTINCT m.pmid, r.target
FROM publication_mesh m
JOIN classification_rules r ON r.source = 'mesh' AND m.descriptor_name = r.pattern;

DO $$
DECLARE r record;
BEGIN
    FOR r IN SELECT * FROM classification_rules WHERE source IN ('title', 'text') LOOP
        INSERT INTO publication_tags
        SELECT p.pmid, r.target
        FROM publications p
        WHERE CASE r.source
                  WHEN 'title' THEN p.title
                  ELSE concat_ws(' ', p.title, p.abstract, p.keywords)
              END ~* r.pattern
        ON CONFLICT DO NOTHING;
    END LOOP;
END $$;

UPDATE publications p
SET is_help = EXISTS (SELECT 1 FROM publication_tags t WHERE t.pmid = p.pmid AND t.tag = 'help'),
    is_included =
        -- назван конкретный тип бедствия
        EXISTS (SELECT 1 FROM publication_tags t
                WHERE t.pmid = p.pmid
                  AND t.tag IN (SELECT hazard_code FROM hazards WHERE hazard_code <> 'generic'))
        -- или «бедствие» вообще, но не в контексте пандемии, терактов, войн
        OR (EXISTS (SELECT 1 FROM publication_tags t WHERE t.pmid = p.pmid AND t.tag = 'generic')
            AND NOT EXISTS (SELECT 1 FROM publication_tags t
                            WHERE t.pmid = p.pmid AND t.tag IN ('ctx_covid', 'ctx_terror', 'ctx_war')));

-- ---------------------------------------------------------------------
-- 2. О какой стране статья
-- ---------------------------------------------------------------------
CREATE TEMP TABLE hits (pmid bigint, iso3 char(3), field text, n int);

DO $$
DECLARE cp record;
BEGIN
    FOR cp IN SELECT * FROM country_patterns LOOP
        IF cp.scope IN ('any', 'mesh') THEN
            INSERT INTO hits
            SELECT DISTINCT m.pmid, cp.iso3, 'mesh', 1
            FROM publication_mesh m
            WHERE m.descriptor_name ~ cp.pattern;
        END IF;
        IF cp.scope IN ('any', 'text') THEN
            INSERT INTO hits
            SELECT p.pmid, cp.iso3, 'title', 1
            FROM publications p
            WHERE p.title ~ cp.pattern;
        END IF;
        -- в аннотации прилагательные (Chinese, Spanish) не считаем: часто это язык опросника
        IF cp.scope IN ('any', 'text') AND cp.kind <> 'demonym' THEN
            INSERT INTO hits
            SELECT p.pmid, cp.iso3, 'abstract', regexp_count(x.txt, cp.pattern)
            FROM publications p
            CROSS JOIN LATERAL (SELECT concat_ws(' ', p.abstract, p.keywords) AS txt) x
            WHERE x.txt ~ cp.pattern;
        END IF;
    END LOOP;
END $$;

-- Если у статьи есть географические рубрики MeSH — берём их (и страны из названия);
-- если нет — страны из названия; если и там нет — из аннотации, но только страну,
-- которая там единственная или упомянута хотя бы дважды (в обзорах страны перечисляют мимоходом).
INSERT INTO publication_countries (pmid, iso3, basis)
SELECT DISTINCT ON (pmid, iso3) pmid, iso3, field
FROM (
    SELECT pmid, iso3, field,
           sum(n) AS n,
           bool_or(field = 'mesh')  OVER (PARTITION BY pmid) AS has_mesh,
           bool_or(field = 'title') OVER (PARTITION BY pmid) AS has_title,
           count(*) FILTER (WHERE field = 'abstract') OVER (PARTITION BY pmid) AS abstract_countries
    FROM hits
    GROUP BY pmid, iso3, field
) x
WHERE field IN ('mesh', 'title')
   OR (field = 'abstract' AND NOT has_mesh AND NOT has_title AND (abstract_countries = 1 OR n >= 2))
ORDER BY pmid, iso3, CASE field WHEN 'mesh' THEN 1 WHEN 'title' THEN 2 ELSE 3 END;

-- ---------------------------------------------------------------------
-- 3. Страны авторов: в каждой строке аффилиации берём последнее упоминание страны
--    («..., Boston, MA, USA»). Гонконг, Макао, Тайвань, Пуэрто-Рико и т. п.
--    важнее «China» / «USA» в той же строке.
-- ---------------------------------------------------------------------
CREATE TEMP TABLE aff AS
SELECT affiliation,
       regexp_replace(regexp_replace(affiliation, '\S+@\S+', '', 'g'), 'Electronic address:?', '', 'gi') AS clean
FROM (SELECT DISTINCT affiliation FROM publication_affiliations WHERE affiliation <> '') a;

CREATE TEMP TABLE aff_hits (affiliation text, iso3 char(3), pos int);

DO $$
DECLARE cp record;
BEGIN
    FOR cp IN SELECT * FROM country_patterns WHERE scope IN ('any', 'text', 'affil') LOOP
        INSERT INTO aff_hits
        SELECT a.affiliation, cp.iso3, regexp_instr(a.clean, cp.pattern)
        FROM aff a
        WHERE a.clean ~ cp.pattern;
    END LOOP;
END $$;

INSERT INTO affiliation_countries
SELECT DISTINCT ON (affiliation) affiliation, iso3
FROM aff_hits
ORDER BY affiliation,
         iso3 IN ('HKG', 'MAC', 'TWN', 'PRI', 'GUM', 'VIR', 'ASM', 'MNP') DESC,
         pos DESC;

INSERT INTO publication_author_countries
SELECT DISTINCT pa.pmid, ac.iso3
FROM publication_affiliations pa
JOIN affiliation_countries ac USING (affiliation);

DROP TABLE hits, aff, aff_hits;

ANALYZE publications, publication_tags, publication_countries, publication_author_countries;
