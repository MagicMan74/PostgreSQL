-- Секционирование таблицы 
-- подключаемся к ранее установленной тестой базе 
-- sudo -u postgres psql -h localhost -p 5433 -d demo
--  список таблиц
\dt

-- количество данных в таблице кондидате
select count(1) from bookings;

-- структура таблицы
\d+ bookings

-- Переключаемся в схему bookings демо-базы
SET search_path TO bookings;

-- Создаём новую секционированную таблицу с той же структурой что и оригинал,
-- но с составным первичным ключом (book_ref, book_date).
CREATE TABLE bookings_partitioned (
    book_ref     char(6)      NOT NULL,
    book_date    timestamptz  NOT NULL,
    total_amount numeric(10,2) NOT NULL,
    PRIMARY KEY (book_ref, book_date)
) PARTITION BY RANGE (book_date);

-- проверим диапазон данных в первичной таблице
select min(book_date), max(book_date) from bookings;

-- создадим 3 партиции за 3 месяца 2025 года 
CREATE TABLE bookings_2025_09 PARTITION OF bookings_part
    FOR VALUES FROM ('2025-09-01') TO ('2025-10-01');
CREATE TABLE bookings_2025_10 PARTITION OF bookings_part
    FOR VALUES FROM ('2025-10-01') TO ('2025-11-01');
CREATE TABLE bookings_2025_11 PARTITION OF bookings_part
    FOR VALUES FROM ('2025-11-01') TO ('2025-12-01');
-- плюс DEFAULT-секция для записей вне явно заданных диапазонов
CREATE TABLE bookings_default PARTITION OF bookings_part DEFAULT;

-- Освобождаем зависимость от внешнего ключа
ALTER TABLE tickets DROP CONSTRAINT IF EXISTS tickets_book_ref_fkey;

-- Копируем данные из старой таблицы в секционированную
INSERT INTO bookings_part (book_ref, book_date, total_amount)
SELECT book_ref, book_date, total_amount
FROM bookings;

-- Переименовываем старую таблицу (сохраняем как резервную) и вводим новую
ALTER TABLE bookings RENAME TO bookings_old;
ALTER TABLE bookings_part RENAME TO bookings;

-- Индекс по ключу секционирования 
CREATE INDEX idx_bookings_book_date ON bookings (book_date);
-- Дополнительный индекс по старому первичному ключу book_ref
CREATE INDEX idx_bookings_book_ref ON bookings (book_ref);

--Проверка распределения данных по секциям
SELECT tableoid::regclass AS partition, count(*)
FROM bookings
GROUP BY tableoid
ORDER BY partition;

-- план старой таблицы
EXPLAIN ANALYZE
SELECT count(*)
FROM bookings_old
WHERE book_date >= '2025-09-01'
  AND book_date <  '2025-10-01';

-- план новой секционированной таблицы
EXPLAIN ANALYZE
SELECT count(*)
FROM bookings
WHERE book_date >= '2025-09-01'
  AND book_date <  '2025-10-01';

-- Проверим операции вставки, обновления и удаления 
-- добовляем строку - строка остается в ожидаемой секции
INSERT INTO bookings (book_ref, book_date, total_amount)
VALUES ('TST001', '2025-10-15 12:00:00+05', 100.00);

SELECT tableoid::regclass AS partition, book_ref, book_date, total_amount
FROM bookings WHERE book_ref = 'TST001';
-- Ожидаем: bookings_2025_10

-- меняем сумму - строка остается в текущей секции
UPDATE bookings SET total_amount = 101.00
WHERE book_ref = 'TST001';

SELECT tableoid::regclass AS partition, total_amount
FROM bookings WHERE book_ref = 'TST001';
-- Ожидаем: bookings_2025_10, total_amount = 101.00

-- меняющий ключ секционирования — строка переедет в другую секцию
UPDATE bookings SET book_date = '2025-11-05 09:00:00+05'
WHERE book_ref = 'TST001';

SELECT tableoid::regclass AS partition, book_date
FROM bookings WHERE book_ref = 'TST001';
-- Ожидаем: bookings_2025_11 — PostgreSQL сам перенёс строку

-- удаление строк
DELETE FROM bookings
WHERE book_ref = 'TST001';

SELECT count(*) FROM bookings WHERE book_ref = 'TST001';
