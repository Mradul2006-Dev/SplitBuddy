-- Load into a fresh SplitBuddy database after dbms/03_schema.sql.
BEGIN;
SET LOCAL search_path TO splitbuddy;

INSERT INTO users (user_id, display_name, email)
SELECT user_id, 'Test user ' || user_id, 'user' || user_id || '@example.test'
FROM generate_series(1, 500) AS ids(user_id);

INSERT INTO expense_groups (group_id, group_name, created_by)
SELECT group_id, 'Test group ' || group_id, (group_id - 1) * 10 + 1
FROM generate_series(1, 50) AS ids(group_id);

INSERT INTO group_members (group_id, user_id)
SELECT g.group_id, g.created_by + offsets.member_offset
FROM expense_groups AS g
CROSS JOIN generate_series(0, 9) AS offsets(member_offset);

INSERT INTO expenses (group_id, expense_no, paid_by, description, amount_paise, split_method)
SELECT g.group_id, (g.group_id - 1) * 100 + rows.expense_index,
       g.created_by, 'Test expense', 40000, 'EQUAL'
FROM expense_groups AS g
CROSS JOIN generate_series(1, 100) AS rows(expense_index);

INSERT INTO expense_splits (group_id, expense_no, user_id, share_paise)
SELECT e.group_id, e.expense_no, e.paid_by + offsets.member_offset, 10000
FROM expenses AS e
CROSS JOIN generate_series(0, 3) AS offsets(member_offset);

SELECT setval(pg_get_serial_sequence('users', 'user_id'), max(user_id)) FROM users;
SELECT setval(pg_get_serial_sequence('expense_groups', 'group_id'), max(group_id)) FROM expense_groups;
SELECT setval(pg_get_serial_sequence('expenses', 'expense_no'), max(expense_no)) FROM expenses;

COMMIT;
ANALYZE;
