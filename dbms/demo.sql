\set ON_ERROR_STOP on
BEGIN;
\ir 04_queries.sql

INSERT INTO splitbuddy.users (user_id, display_name, email) VALUES
    (1, 'Asha', 'asha@example.test'),
    (2, 'Bina', 'bina@example.test'),
    (3, 'Chetan', 'chetan@example.test'),
    (4, 'Dev', 'dev@example.test');
SELECT setval(pg_get_serial_sequence('splitbuddy.users', 'user_id'), 4);

EXECUTE splitbuddy_create_group(1, 'Weekend trip') \gset
EXECUTE splitbuddy_add_member(:group_id, 1, 2);
EXECUTE splitbuddy_add_member(:group_id, 1, 3);
EXECUTE splitbuddy_record_equal_expense(
    :group_id, 1, 'Dinner', 90000, ARRAY[1, 2, 3]::bigint[]
);
EXECUTE splitbuddy_record_settlement(:group_id, 2, 1, 30000);
COMMIT;
