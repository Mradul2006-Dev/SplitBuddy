# SplitBuddy database normalization

SplitBuddy records group expenses, each person's share, and repayments between members. For example, if Asha pays ₹900 for dinner for Asha, Bina and Chetan, the expense is recorded once and each person has a ₹300 share. A repayment from Bina to Asha is a separate record.

The design assumes that amounts are in INR and stores them as integer paise. A group can have several expenses, a user can join several groups, and a repayment can cover shares from multiple expenses.

## Unnormalized data

A single group record could contain lists of members, expenses, and repayments. Each expense could contain another list of shares. Editing a member's name in a long list of expenses would then require updating the same detail repeatedly.

## 1NF

Use a row per expense share with atomic columns. The combined key is `(group_id, expense_no, user_id)`. `expense_no` is unique within a group.

| Group | Expense | Member | Paid by | Total (paise) | Share (paise) |
| --- | --- | --- | --- | ---: | ---: |
| 10 | 1 | Asha | Asha | 90000 | 30000 |
| 10 | 1 | Bina | Asha | 90000 | 30000 |
| 10 | 1 | Chetan | Asha | 90000 | 30000 |

The total and payer still repeat across the three rows. In a flattened table these dependencies would exist:

- `group_id → group_name, created_by, created_at`
- `user_id → display_name, email`
- `(group_id, user_id) → joined_at`
- `(group_id, expense_no) → paid_by, description, amount_paise, split_method, incurred_at`
- `(group_id, expense_no, user_id) → share_paise`

## 2NF

Move each fact that depends on part of the combined key to the table for that key.

| Table at this step | Key | What moves out of the flat share row |
| --- | --- | --- |
| `expense_groups` | `group_id` | Group name and creation details |
| `users` | `user_id` | Member name and email |
| `group_members` | `group_id, user_id` | Membership date |
| `expenses` | `group_id, expense_no` | Payer, description, expense total and date |
| `expense_splits` | `group_id, expense_no, user_id` | Share amount, which depends on the full key |

If the expense row still carries the payer's display name, it has a transitive dependency. The expense key determines `paid_by`, and `paid_by` identifies the display name.

## 3NF

Store the payer's user ID in `expenses`. The payer's name and email are obtained through `users`, so a name change updates just one row. Likewise, a settlement stores the IDs of its sender and receiver. The group name, member names, and current balances can be read using those relationships.

| Table | Primary key | Other columns and dependencies |
| --- | --- | --- |
| `users` | `user_id` | Determines `display_name` and `email`. The unique email also identifies the user. |
| `expense_groups` | `group_id` | Determines `group_name`, `created_by` and `created_at`. |
| `group_members` | `group_id, user_id` | The pair determines `joined_at`. |
| `expenses` | `group_id, expense_no` | The pair determines `paid_by`, `description`, `amount_paise`, `split_method` and `incurred_at`. |
| `expense_splits` | `group_id, expense_no, user_id` | All three columns determine `share_paise`. |
| `settlements` | `settlement_id` | Determines `group_id`, `from_user_id`, `to_user_id`, `amount_paise` and `paid_at`. |

Each listed dependency has a candidate key as its determinant in the table where it is stored, so the proposed tables also satisfy BCNF under these rules.

The foreign keys require the payer, the people with shares, and both sides of a repayment to belong to the expense group. On an expense write, the API should insert the expense and its shares in one transaction and check that the shares add up to the recorded total. For the example above, once Bina repays ₹300, the calculated balances are Asha +₹300, Bina ₹0 and Chetan −₹300.
