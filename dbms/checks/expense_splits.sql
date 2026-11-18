\set ON_ERROR_STOP on
BEGIN;
SET LOCAL search_path TO splitbuddy;
\ir ../04_queries.sql

INSERT INTO users (user_id, display_name, email) VALUES
    (1, 'Asha', 'asha@example.test'),
    (2, 'Bina', 'bina@example.test'),
    (3, 'Chetan', 'chetan@example.test'),
    (4, 'Dev', 'dev@example.test');
INSERT INTO expense_groups (group_id, group_name, created_by) VALUES (10, 'Trip', 1);
INSERT INTO group_members (group_id, user_id) VALUES (10, 1), (10, 2), (10, 3);

EXECUTE splitbuddy_record_equal_expense(10, 1, 'Dinner', 10000, ARRAY[3, 1, 2]::bigint[]);
EXECUTE splitbuddy_record_custom_expense(
    10, 2, 'Cab', 5500, ARRAY[3, 1]::bigint[], ARRAY[3000, 2500]::bigint[]
);

EXECUTE splitbuddy_record_equal_expense(10, 1, 'Duplicate member', 10000, ARRAY[1, 1]::bigint[]);
EXECUTE splitbuddy_record_equal_expense(10, 1, 'Outside member', 10000, ARRAY[1, 4]::bigint[]);
EXECUTE splitbuddy_record_equal_expense(10, 1, 'Empty split', 10000, ARRAY[]::bigint[]);
EXECUTE splitbuddy_record_equal_expense(10, 4, 'Outside payer', 10000, ARRAY[1, 2]::bigint[]);
EXECUTE splitbuddy_record_equal_expense(10, 1, ' ', 10000, ARRAY[1]::bigint[]);
EXECUTE splitbuddy_record_custom_expense(
    10, 1, 'Wrong total', 5500, ARRAY[1, 2]::bigint[], ARRAY[3000, 2400]::bigint[]
);
EXECUTE splitbuddy_record_custom_expense(
    10, 1, 'Missing amount', 5500, ARRAY[1, 2]::bigint[], ARRAY[5500]::bigint[]
);
EXECUTE splitbuddy_record_custom_expense(
    10, 1, 'Negative amount', 5500, ARRAY[1, 2]::bigint[], ARRAY[-10, 5510]::bigint[]
);
EXECUTE splitbuddy_record_custom_expense(
    10, 1, 'Null amount', 5500, ARRAY[1, 2]::bigint[], ARRAY[5500, NULL]::bigint[]
);
EXECUTE splitbuddy_record_custom_expense(
    10, 1, 'Duplicate member', 5500, ARRAY[1, 1]::bigint[], ARRAY[2500, 3000]::bigint[]
);

DO $$
BEGIN
    IF (SELECT count(*) FROM expenses WHERE group_id = 10) <> 2 THEN
        RAISE EXCEPTION 'Invalid input created an expense';
    END IF;

    IF (
        SELECT array_agg(s.share_paise ORDER BY s.user_id)
        FROM expense_splits s
        JOIN expenses e USING (group_id, expense_no)
        WHERE e.group_id = 10 AND e.description = 'Dinner' AND e.split_method = 'EQUAL'
    ) IS DISTINCT FROM ARRAY[3334, 3333, 3333]::bigint[] THEN
        RAISE EXCEPTION 'Equal split must distribute the remainder by user ID';
    END IF;

    IF (
        SELECT array_agg(s.share_paise ORDER BY s.user_id)
        FROM expense_splits s
        JOIN expenses e USING (group_id, expense_no)
        WHERE e.group_id = 10 AND e.description = 'Cab' AND e.split_method = 'CUSTOM'
    ) IS DISTINCT FROM ARRAY[2500, 3000]::bigint[] THEN
        RAISE EXCEPTION 'Custom amounts must stay paired with the supplied member IDs';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM expenses e
        LEFT JOIN expense_splits s USING (group_id, expense_no)
        WHERE e.group_id = 10
        GROUP BY e.group_id, e.expense_no, e.amount_paise
        HAVING sum(s.share_paise) IS DISTINCT FROM e.amount_paise::numeric
    ) THEN
        RAISE EXCEPTION 'Shares must sum to the expense amount';
    END IF;
END;
$$;
ROLLBACK;
\echo PASS equal splits, custom splits, membership and invalid input
