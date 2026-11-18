\set ON_ERROR_STOP on
BEGIN;
SET LOCAL search_path TO splitbuddy;
\ir ../04_queries.sql

INSERT INTO users (user_id, display_name, email) VALUES
    (1, 'Asha', 'asha@example.test'),
    (2, 'Bina', 'bina@example.test'),
    (3, 'Chetan', 'chetan@example.test'),
    (4, 'Dev', 'dev@example.test');

EXECUTE splitbuddy_create_group(1, 'Fixture') \gset
EXECUTE splitbuddy_add_member(:group_id, 1, 2);
EXECUTE splitbuddy_add_member(:group_id, 1, 3);
EXECUTE splitbuddy_add_member(:group_id, 2, 4);
EXECUTE splitbuddy_add_member(:group_id, 1, 2);

EXECUTE splitbuddy_record_equal_expense(
    :group_id, 1, 'Dinner', 90000, ARRAY[1, 2, 3]::bigint[]
);
EXECUTE splitbuddy_record_settlement(:group_id, 2, 1, 30000);
EXECUTE splitbuddy_record_settlement(:group_id, 2, 2, 30000);
EXECUTE splitbuddy_record_settlement(:group_id, 4, 1, 30000);

SELECT expense_no FROM expenses WHERE group_id = :group_id AND description = 'Dinner' \gset

CREATE TEMP TABLE actual_members AS EXECUTE splitbuddy_group_members(:group_id, 1);
CREATE TEMP TABLE actual_balances AS EXECUTE splitbuddy_group_balances(:group_id, 1);
CREATE TEMP TABLE hidden_balances AS EXECUTE splitbuddy_group_balances(:group_id, 4);
CREATE TEMP TABLE actual_history AS EXECUTE splitbuddy_group_history(:group_id, 2, NULL, NULL, NULL);
CREATE TEMP TABLE hidden_history AS EXECUTE splitbuddy_group_history(:group_id, 4, NULL, NULL, NULL);
CREATE TEMP TABLE actual_shares AS EXECUTE splitbuddy_expense_shares(:group_id, 3, :expense_no);
CREATE TEMP TABLE hidden_shares AS EXECUTE splitbuddy_expense_shares(:group_id, 4, :expense_no);
CREATE TEMP TABLE outsider_groups AS EXECUTE splitbuddy_list_groups(4);

DO $$
BEGIN
    IF (SELECT array_agg(user_id ORDER BY user_id) FROM actual_members)
        IS DISTINCT FROM ARRAY[1, 2, 3]::bigint[] THEN
        RAISE EXCEPTION 'Group creation or membership composition is incorrect';
    END IF;

    IF (SELECT array_agg(balance_paise ORDER BY user_id) FROM actual_balances)
        IS DISTINCT FROM ARRAY[30000, 0, -30000]::numeric[] THEN
        RAISE EXCEPTION 'Balances must include expenses, splits and both sides of repayments';
    END IF;

    IF (SELECT count(*) FROM settlements) <> 1
        OR (SELECT array_agg(kind ORDER BY kind) FROM actual_history)
           IS DISTINCT FROM ARRAY['expense', 'settlement']::text[] THEN
        RAISE EXCEPTION 'History or settlement validation is incorrect';
    END IF;

    IF (SELECT array_agg(share_paise ORDER BY user_id) FROM actual_shares)
        IS DISTINCT FROM ARRAY[30000, 30000, 30000]::bigint[] THEN
        RAISE EXCEPTION 'Expense detail must show every share';
    END IF;

    IF EXISTS (TABLE hidden_balances) OR EXISTS (TABLE hidden_history)
        OR EXISTS (TABLE hidden_shares) OR EXISTS (TABLE outsider_groups) THEN
        RAISE EXCEPTION 'A nonmember can see group data';
    END IF;
END;
$$;
ROLLBACK;
\echo PASS group creation, group access, history, balances and repayments
