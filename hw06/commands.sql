-- 3.Зафиксируйте состояние обслуживания после нагрузки: для пользовательских таблиц сохраните n_dead_tup, last_autovacuum, last_vacuum из pg_stat_user_tables;
SELECT relname, n_live_tup, n_dead_tup, trunc(100*n_dead_tup/(n_live_tup+1))::float "ratio%", last_vacuum, last_autovacuum
  FROM pg_stat_user_tables WHERE relname LIKE 'pgbench%'
 ORDER BY relname;
--4.Создайте таблицу с текстовым полем и заполните её 1 000 000 строк (допускается генерация через generate_series);
CREATE TABLE test_tab (id serial PRIMARY KEY, txt text);

INSERT INTO test_tab (txt)
SELECT 'txt_' || g
 FROM generate_series(1, 1000000) AS g;
-- 5.Зафиксируйте размер таблицы (например, pg_total_relation_size) и значение n_dead_tup;
SELECT 'step5', pg_size_pretty(pg_total_relation_size('test_tab')) AS total_size, n_dead_tup
 FROM pg_stat_user_tables
WHERE relname = 'test_tab';
-- 6.Выполните 5 полных обновлений строк (добавление символа к текстовому полю), затем зафиксируйте n_dead_tup, last_autovacuum и размер таблицы;
UPDATE test_tab SET txt = txt || 'A'; -- 5 раз

SELECT 'step6', pg_size_pretty(pg_total_relation_size('test_tab')) AS total_size, n_dead_tup, last_autovacuum
 FROM pg_stat_user_tables
WHERE relname = 'test_tab';
-- 7.Дождитесь срабатывания autovacuum (периодически проверяя last_autovacuum) и зафиксируйте изменения n_dead_tup/размера;
SELECT 'step7', pg_size_pretty(pg_total_relation_size('test_tab')) AS total_size, n_dead_tup, last_autovacuum
 FROM pg_stat_user_tables
WHERE relname = 'test_tab';
-- 8.Отключите autovacuum только для этой таблицы, выполните 10 полных обновлений строк и снова зафиксируйте n_dead_tup и размер;
ALTER TABLE test_tab SET (autovacuum_enabled = false);

UPDATE test_tab SET txt = txt || 'B';  -- 10 раз

SELECT 'step8', pg_size_pretty(pg_total_relation_size('test_tab')) AS total_size, n_dead_tup, last_autovacuum
 FROM pg_stat_user_tables
WHERE relname = 'test_tab';
-- 10.Включите autovacuum обратно для таблицы;
ALTER TABLE test_tab SET (autovacuum_enabled = true);

SELECT 'step10', pg_size_pretty(pg_total_relation_size('test_tab')) AS total_size, n_dead_tup, last_autovacuum
 FROM pg_stat_user_tables
WHERE relname = 'test_tab';
-- дополнительно проведем эксперимент по уменьшению размеров таблицы через операцию VACUUM FULL 
VACUUM FULL test_tab;

SELECT 'step10.2', pg_size_pretty(pg_total_relation_size('test_tab')) AS total_size, n_dead_tup, last_autovacuum
 FROM pg_stat_user_tables
WHERE relname = 'test_tab';
