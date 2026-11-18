-- Use the authenticated payer's ID and integer paise from the app.
-- Each command returns the new split rows. Invalid inputs return zero rows.

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
