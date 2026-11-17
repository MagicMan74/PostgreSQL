# Виды индексов. Работа с индексами и оптимизация запросов // ДЗ 10
Задание:
1. Создать индекс к какой-либо из таблиц вашей БД
2. Прислать текстом результат команды explain, в которой используется данный индекс
3. Реализовать индекс для полнотекстового поиска
4. Реализовать индекс на часть таблицы или индекс на поле с функцией
5. Создать индекс на несколько полей
6. Написать комментарии к каждому из индексов
7. Описать что и как делали, с какими проблемами столкнулись


Для работы используем базу созданную на прошлом уроке.

## 1. Обычный B-tree индекс

Для начала проанализируем выборки из прошлого урока и посмотрим какое из полей чаще используется при построении отчетов.
Хорошим кандидатом для индексаци является поле PAY.ACC_ID по которому просиходит склейка для отчета "5.плетежы по счету".

Смотрим план до и после создания индекса.

```sql
-- план до создания индекса
EXPLAIN ANALYZE SELECT * FROM PAY WHERE ACC_ID = 1;
                                          QUERY PLAN
-----------------------------------------------------------------------------------------------
 Seq Scan on pay  (cost=0.00..1.07 rows=1 width=496) (actual time=0.059..0.060 rows=3 loops=1)
   Filter: (acc_id = 1)
   Rows Removed by Filter: 3
 Planning Time: 0.159 ms
 Execution Time: 0.097 ms

-- (1) B-tree индекс на PAY.ACC_ID
CREATE INDEX idx_pay_acc_id ON PAY (ACC_ID);

-- план после создания индекса
EXPLAIN ANALYZE SELECT * FROM PAY WHERE ACC_ID = 1;

                                          QUERY PLAN
-----------------------------------------------------------------------------------------------
 Seq Scan on pay  (cost=0.00..1.07 rows=1 width=496) (actual time=0.006..0.006 rows=3 loops=1)
   Filter: (acc_id = 1)
   Rows Removed by Filter: 3
 Planning Time: 0.167 ms
 Execution Time: 0.014 ms
```

на тестовых данных планировщик всё равно выбирает Seq Scan, потому что таблица маленькая и полное сканирование дешевле. 
проверим использование индекса принудительно выключив Seq Scan

```sql
-- принудительно выключаем Seq Scan
SET enable_seqscan = off;
EXPLAIN ANALYZE SELECT * FROM PAY WHERE ACC_ID = 1;

                                                      QUERY PLAN
----------------------------------------------------------------------------------------------------------------------
 Index Scan using idx_pay_acc_id on pay  (cost=0.13..8.15 rows=1 width=496) (actual time=0.137..0.138 rows=3 loops=1)
   Index Cond: (acc_id = 1)
 Planning Time: 0.293 ms
 Execution Time: 0.152 ms

RESET enable_seqscan;
```

Видим что планировщик переключился с __Seq Scan__ на __Index Scan using idx_pay_acc_id__, когда мы задействовали индексированное поле ACC_ID. 
На маленькой таблице выигрыш по времени отсутствует, но при масштабировании должен быть приличный прирост в скорости.

## 2. Индекс для полнотекстового поиска (Full-Text Search GIN) 

Поле PAY.PURPOSE - назначение платежа, подходит для полнотекстового поиска.
Применим индекс для оптимизации запроса где следует найти все платежи со словом "налог".
Обычный LIKE '%налог%' такой индекс не использует, поэтому нужен GIN-индекс с приобразование текста в 
текстовый вектор с помощь функции по to_tsvector. принудительно поставим использование русского языка.
Слова находятся по корню, поэтому 'налог' найдёт и 'налог', и 'налоговый'.

```sql
-- (2) GIN-индекс по PAY.PURPOSE для полнотекстового поиска
CREATE INDEX idx_pay_purpose
    ON PAY
    USING GIN (to_tsvector('russian', PURPOSE));

EXPLAIN ANALYZE
SELECT PAY_ID, PURPOSE
FROM PAY
WHERE to_tsvector('russian', PURPOSE) @@ plainto_tsquery('russian', 'налог');

                                                       QUERY PLAN
------------------------------------------------------------------------------------------------------------------------
 Bitmap Heap Scan on pay  (cost=8.52..12.79 rows=1 width=422) (actual time=0.011..0.011 rows=1 loops=1)
   Recheck Cond: (to_tsvector('russian'::regconfig, (purpose)::text) @@ '''налог'''::tsquery)
   Heap Blocks: exact=1
   ->  Bitmap Index Scan on idx_pay_purpose  (cost=0.00..8.52 rows=1 width=0) (actual time=0.006..0.006 rows=1 loops=1)
         Index Cond: (to_tsvector('russian'::regconfig, (purpose)::text) @@ '''налог'''::tsquery)
 Planning Time: 0.069 ms
 Execution Time: 0.023 ms
```

Видим что планировщик использовал __Bitmap Heap Scan on idx_pay_purpose__, индекс задействован, когда идет поиск по назачению платежа.

## 3. Частичный индекс (partial index) 

Для создания данного индекса используем таблицу платещей PAY, оставив только исполненные платежи STATUS = 'executed'.

```sql
-- (3) Частичный индекс на PAY.PAY_DATE только по исполненным платежам
CREATE INDEX idx_pay_executed_date
    ON PAY (PAY_DATE)
    WHERE STATUS = 'executed';

EXPLAIN ANALYZE
SELECT PAY_ID, PAY_DATE, AMOUNT
FROM PAY
WHERE STATUS = 'executed' AND PAY_DATE >= '2026-11-01';

                                                         QUERY PLAN
----------------------------------------------------------------------------------------------------------------------------
 Index Scan using idx_pay_executed_date on pay  (cost=0.13..8.15 rows=1 width=26) (actual time=0.089..0.091 rows=5 loops=1)
   Index Cond: (pay_date >= '2026-11-01'::date)
 Planning Time: 0.845 ms
 Execution Time: 0.102 ms
```

Видим что планировщик использовал __Index Scan using idx_pay_executed_date__, частичный индекс задействован, когда соблюдается условие индекса STATUS = 'executed'.

## 4. Функциональный индекс (index on expression)

Создадим функциональный индекс для поиска клиентов в таблице UL_CLI по ФИО без учёта регистра LOWER(FULL_NAME). 
используем оператор text_pattern_ops который заставляет индекс сортировать строки строго посимвольно, побайтово, игнорируя языковые правила.

```sql
-- (4) Функциональный индекс по LOWER(FULL_NAME) на UL_CLI.FULL_NAME
CREATE INDEX idx_ul_cli_name_lower
    ON UL_CLI (LOWER(FULL_NAME) text_pattern_ops);

EXPLAIN ANALYZE
SELECT CLIENT_ID, FULL_NAME
FROM UL_CLI
WHERE LOWER(FULL_NAME) LIKE 'ооо%';

                                                           QUERY PLAN
--------------------------------------------------------------------------------------------------------------------------------
 Index Scan using idx_ul_cli_name_lower on ul_cli  (cost=0.13..8.16 rows=1 width=262) (actual time=0.079..0.095 rows=2 loops=1)
   Index Cond: ((lower((full_name)::text) ~>=~ 'ооо'::text) AND (lower((full_name)::text) ~<~ 'ооп'::text))
   Filter: (lower((full_name)::text) ~~ 'ооо%'::text)
 Planning Time: 0.323 ms
 Execution Time: 0.106 ms
```

Видим что планировщик использовал __Index Scan using idx_ul_cli_name_lower__, планировщик обнаружил выражение LOWER(FULL_NAME) и воспользовался функциональным индексом.

## 5. Многоколоночный индекс (composite index)

Создадим Многоколоночный индекс для поиск, в котором задейстованы два поля CLIENT_ID, AGR_TYPE таблицы договоров AGR 

```sql
-- (5) Многоколоночный индекс на AGR(CLIENT_ID, AGR_TYPE):
CREATE INDEX idx_agr_client_type
    ON AGR (CLIENT_ID, AGR_TYPE);

EXPLAIN ANALYZE
SELECT AGR_ID, AGR_NO, OPEN_DATE
FROM AGR
WHERE CLIENT_ID = 1 AND AGR_TYPE = 'РКО';

                                                        QUERY PLAN
--------------------------------------------------------------------------------------------------------------------------
 Index Scan using idx_agr_client_type on agr  (cost=0.13..8.15 rows=1 width=86) (actual time=0.014..0.014 rows=1 loops=1)
   Index Cond: ((client_id = 1) AND ((agr_type)::text = 'РКО'::text))
 Planning Time: 0.898 ms
 Execution Time: 0.025 ms
```

Видим что планировщик использовал __Index Scan using idx_agr_client_type__. оба условия попали в Index Cond, а значит индекс используется по двум колонкам сразу.

