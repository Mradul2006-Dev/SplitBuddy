# SplitBuddy expense query timings

PostgreSQL 18.6 ran each write three times with `EXPLAIN (ANALYZE, BUFFERS)` on 17 Nov 2026. The synthetic fixture contains 50 groups, 500 members, 5,000 expenses and 20,000 split rows. Each run used a separate transaction with a rollback. Expense and split row counts matched before and after all six runs.

| Query | Type | What it does | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) | Scan type |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| [W3](plans/W3.txt) | WRITE | Record an expense split equally | 0.418 | 0.453 | 0.408 | 0.426 | Index Only Scan, Bitmap Heap Scan, Bitmap Index Scan |
| [W4](plans/W4.txt) | WRITE | Record an expense with custom shares | 0.446 | 0.410 | 0.374 | 0.410 | Index Only Scan, Bitmap Heap Scan, Bitmap Index Scan |

Both statements create the expense and its shares together. W3 assigns spare paise by ascending user ID. W4 keeps each amount paired with its supplied member ID. An empty result signals invalid input. The regression check covers the ₹100 three-way split, custom amounts, membership and rejected inputs.

## Run locally

Run the schema and test on a fresh PostgreSQL database from the repository root.

```bash
createdb splitbuddy_expenses
psql -X -v ON_ERROR_STOP=1 -d splitbuddy_expenses \
  -f dbms/03_schema.sql -f dbms/checks/expense_splits.sql
psql -X -v ON_ERROR_STOP=1 -d splitbuddy_expenses \
  -f dbms/checks/expense_benchmark_seed.sql
for run in 1 2 3; do
  psql -X -v ON_ERROR_STOP=1 -d splitbuddy_expenses \
    -f dbms/queries/expense_splits.sql -f - <<'SQL'
BEGIN;
EXPLAIN (ANALYZE, BUFFERS)
EXECUTE splitbuddy_record_equal_expense(10, 91, 'Dinner', 10000, ARRAY[93, 91, 92]::bigint[]);
ROLLBACK;
BEGIN;
EXPLAIN (ANALYZE, BUFFERS)
EXECUTE splitbuddy_record_custom_expense(10, 92, 'Cab', 5500, ARRAY[93, 91]::bigint[], ARRAY[3000, 2500]::bigint[]);
ROLLBACK;
SQL
done
```

The query statements are in [expense_splits.sql](queries/expense_splits.sql) for the combined CP3 file. The timing rows and raw plans are ready for the combined CP4 report.
