-- SplitBuddy's parameterized query catalog.
-- Run this file to prepare the statements in psql, or use the app's SQL loader.

-- READ R1 — List the local demo accounts.
PREPARE splitbuddy_list_people AS
SELECT user_id, display_name
FROM splitbuddy.users
ORDER BY display_name, user_id;

-- READ R2 — List groups for a member.
-- Parameters: viewer ID.
PREPARE splitbuddy_list_groups (bigint) AS
SELECT g.group_id, g.group_name, g.created_by
FROM splitbuddy.group_members membership
JOIN splitbuddy.expense_groups g USING (group_id)
WHERE membership.user_id = $1
ORDER BY lower(g.group_name), g.group_id;

-- READ R3 — List the members of a group.
-- Parameters: group ID, viewer ID.
PREPARE splitbuddy_group_members (bigint, bigint) AS
SELECT u.user_id, u.display_name
FROM splitbuddy.group_members viewer
JOIN splitbuddy.group_members member USING (group_id)
JOIN splitbuddy.users u ON u.user_id = member.user_id
WHERE viewer.group_id = $1 AND viewer.user_id = $2
ORDER BY u.display_name, u.user_id;

-- READ R4 — Calculate the current balance for every group member.
-- Parameters: group ID, viewer ID.
PREPARE splitbuddy_group_balances (bigint, bigint) AS
WITH allowed_group AS (
    SELECT group_id
    FROM splitbuddy.group_members
    WHERE group_id = $1 AND user_id = $2
), movements AS (
    SELECT e.paid_by AS user_id, e.amount_paise AS delta
    FROM splitbuddy.expenses e JOIN allowed_group USING (group_id)
    UNION ALL
    SELECT s.user_id, -s.share_paise
    FROM splitbuddy.expense_splits s JOIN allowed_group USING (group_id)
    UNION ALL
    SELECT s.from_user_id, s.amount_paise
    FROM splitbuddy.settlements s JOIN allowed_group USING (group_id)
    UNION ALL
    SELECT s.to_user_id, -s.amount_paise
    FROM splitbuddy.settlements s JOIN allowed_group USING (group_id)
), totals AS (
    SELECT user_id, sum(delta) AS balance_paise
    FROM movements
    GROUP BY user_id
)
SELECT u.user_id, u.display_name, coalesce(t.balance_paise, 0) AS balance_paise
FROM allowed_group
JOIN splitbuddy.group_members m USING (group_id)
JOIN splitbuddy.users u ON u.user_id = m.user_id
LEFT JOIN totals t ON t.user_id = u.user_id
ORDER BY u.display_name, u.user_id;

-- READ R5 — List up to 50 expenses and repayments in chronological pages.
-- Parameters: group ID, viewer ID, cursor timestamp, cursor kind, cursor event ID.
-- Pass NULL for all cursor values for the first page.
PREPARE splitbuddy_group_history (bigint, bigint, timestamptz, text, bigint) AS
WITH allowed_group AS (
    SELECT group_id
    FROM splitbuddy.group_members
    WHERE group_id = $1 AND user_id = $2
), events AS (
    SELECT 'expense'::text AS kind, e.expense_no AS event_id, e.incurred_at AS occurred_at,
           e.description AS label, payer.display_name AS actor, NULL::text AS recipient,
           e.amount_paise
    FROM allowed_group
    JOIN splitbuddy.expenses e USING (group_id)
    JOIN splitbuddy.users payer ON payer.user_id = e.paid_by
    UNION ALL
    SELECT 'settlement', s.settlement_id, s.paid_at, 'Repayment',
           sender.display_name, receiver.display_name, s.amount_paise
    FROM allowed_group
    JOIN splitbuddy.settlements s USING (group_id)
    JOIN splitbuddy.users sender ON sender.user_id = s.from_user_id
    JOIN splitbuddy.users receiver ON receiver.user_id = s.to_user_id
)
SELECT kind, event_id, occurred_at, occurred_at::text AS cursor_time,
       label, actor, recipient, amount_paise
FROM events
WHERE $3 IS NULL OR (occurred_at, kind, event_id) < ($3, $4, $5)
ORDER BY occurred_at DESC, kind DESC, event_id DESC
LIMIT 50;

-- READ R6 — Show the members and amounts for an expense.
-- Parameters: group ID, viewer ID, expense number.
PREPARE splitbuddy_expense_shares (bigint, bigint, bigint) AS
SELECT u.user_id, u.display_name, s.share_paise
FROM splitbuddy.group_members viewer
JOIN splitbuddy.expense_splits s USING (group_id)
JOIN splitbuddy.users u ON u.user_id = s.user_id
WHERE viewer.group_id = $1 AND viewer.user_id = $2 AND s.expense_no = $3
ORDER BY u.display_name, u.user_id;

-- WRITE W1 — Create a group and enroll its creator atomically.
-- Parameters: creator ID, group name.
PREPARE splitbuddy_create_group (bigint, text) AS
WITH new_group AS (
    INSERT INTO splitbuddy.expense_groups (group_name, created_by)
    SELECT btrim($2), u.user_id
    FROM splitbuddy.users u
    WHERE u.user_id = $1 AND btrim($2) <> ''
    RETURNING group_id, group_name, created_by
), creator_member AS (
    INSERT INTO splitbuddy.group_members (group_id, user_id)
    SELECT group_id, created_by FROM new_group
    RETURNING group_id
)
SELECT group_id, group_name FROM new_group JOIN creator_member USING (group_id);

-- WRITE W2 — Add a person to a group as its creator.
-- Parameters: group ID, creator ID, new member ID.
PREPARE splitbuddy_add_member (bigint, bigint, bigint) AS
INSERT INTO splitbuddy.group_members (group_id, user_id)
SELECT g.group_id, u.user_id
FROM splitbuddy.expense_groups g
JOIN splitbuddy.users u ON u.user_id = $3
WHERE g.group_id = $1 AND g.created_by = $2
ON CONFLICT (group_id, user_id) DO NOTHING
RETURNING group_id, user_id;

-- WRITE W3 — Record an expense with an equal split.
-- Parameters: group ID, payer ID, description, total paise, participant IDs.
PREPARE splitbuddy_record_equal_expense (bigint, bigint, text, bigint, bigint[]) AS
WITH participants AS (
    SELECT member.user_id
    FROM unnest($5) AS requested(user_id)
    JOIN splitbuddy.group_members AS member
      ON member.group_id = $1 AND member.user_id = requested.user_id
), ranked_participants AS (
    SELECT user_id,
           row_number() OVER (ORDER BY user_id) AS share_position,
           count(*) OVER () AS participant_count
    FROM participants
), new_expense AS (
    INSERT INTO splitbuddy.expenses (group_id, paid_by, description, amount_paise, split_method)
    SELECT $1, $2, btrim($3), $4, 'EQUAL'
    WHERE $4 > 0 AND btrim($3) <> ''
      AND EXISTS (
          SELECT 1 FROM splitbuddy.group_members
          WHERE group_id = $1 AND user_id = $2
      )
      AND (
          SELECT count(*) > 0
             AND count(*) = cardinality($5)
             AND count(*) = count(DISTINCT user_id)
          FROM participants
      )
    RETURNING group_id, expense_no
)
INSERT INTO splitbuddy.expense_splits (group_id, expense_no, user_id, share_paise)
SELECT new_expense.group_id, new_expense.expense_no, participant.user_id,
       $4 / participant.participant_count
       + CASE WHEN participant.share_position <= $4 % participant.participant_count THEN 1 ELSE 0 END
FROM new_expense
CROSS JOIN ranked_participants AS participant
RETURNING group_id, expense_no, user_id, share_paise;

-- WRITE W4 — Record an expense with custom shares.
-- Parameters: group ID, payer ID, description, total paise, participant IDs, shares in matching order.
PREPARE splitbuddy_record_custom_expense (bigint, bigint, text, bigint, bigint[], bigint[]) AS
WITH participants AS (
    SELECT member.user_id, requested.share_paise
    FROM unnest($5, $6) AS requested(user_id, share_paise)
    JOIN splitbuddy.group_members AS member
      ON member.group_id = $1 AND member.user_id = requested.user_id
), new_expense AS (
    INSERT INTO splitbuddy.expenses (group_id, paid_by, description, amount_paise, split_method)
    SELECT $1, $2, btrim($3), $4, 'CUSTOM'
    WHERE $4 > 0 AND btrim($3) <> ''
      AND cardinality($5) = cardinality($6)
      AND EXISTS (
          SELECT 1 FROM splitbuddy.group_members
          WHERE group_id = $1 AND user_id = $2
      )
      AND (
          SELECT count(*) > 0
             AND count(*) = cardinality($5)
             AND count(*) = count(DISTINCT user_id)
             AND count(*) = count(share_paise)
             AND min(share_paise) >= 0
             AND sum(share_paise) = $4
          FROM participants
      )
    RETURNING group_id, expense_no
)
INSERT INTO splitbuddy.expense_splits (group_id, expense_no, user_id, share_paise)
SELECT new_expense.group_id, new_expense.expense_no, participant.user_id, participant.share_paise
FROM new_expense
CROSS JOIN participants AS participant
RETURNING group_id, expense_no, user_id, share_paise;

-- WRITE W5 — Record a repayment between two members of a group.
-- Parameters: group ID, sending member ID, receiving member ID, amount in paise.
PREPARE splitbuddy_record_settlement (bigint, bigint, bigint, bigint) AS
INSERT INTO splitbuddy.settlements (group_id, from_user_id, to_user_id, amount_paise)
SELECT sender.group_id, sender.user_id, receiver.user_id, $4
FROM splitbuddy.group_members sender
JOIN splitbuddy.group_members receiver USING (group_id)
WHERE sender.group_id = $1 AND sender.user_id = $2 AND receiver.user_id = $3
  AND sender.user_id <> receiver.user_id AND $4 > 0
RETURNING settlement_id, group_id, from_user_id, to_user_id, amount_paise;
