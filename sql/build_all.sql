-- Сборка базы целиком из CSV. Запускать из корня проекта:
--   psql -U postgres -d disasters_science -f sql/build_all.sql
\set ON_ERROR_STOP on
\set QUIET on
SET client_min_messages = warning;
\echo '1/5 Таблицы и справочники'
\ir 01_schema.sql
\echo '2/5 Загрузка EM-DAT и PubMed'
\ir 02_load.sql
\echo '3/5 Разметка статей (1–3 минуты)'
\ir 03_classify.sql
\echo '4/5 Аналитика'
\ir 04_analytics.sql
\echo '5/5 Поправка на научный потенциал и сравнение моделей'
\ir 09_capacity.sql
\echo 'Готово. Попробуйте: SELECT * FROM gap_analysis() LIMIT 20;'
