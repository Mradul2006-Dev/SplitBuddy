#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C

if [[ $# -ne 1 ]]; then
  echo 'Usage: bash dbms/benchmark.sh <database-loaded-with-the-benchmark-fixture>' >&2
  exit 2
fi
database="$1"
dbms=$(cd -- "$(dirname -- "$0")" && pwd)
if ! mkdir "$dbms/.benchmark-lock"; then
  echo 'Another SplitBuddy benchmark is running in this checkout.' >&2
  exit 1
fi
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"; rmdir -- "$dbms/.benchmark-lock"' EXIT
mkdir "$scratch/plans"
counts='SELECT (SELECT count(*) FROM splitbuddy.expense_groups), (SELECT count(*) FROM splitbuddy.group_members), (SELECT count(*) FROM splitbuddy.expenses), (SELECT count(*) FROM splitbuddy.expense_splits), (SELECT count(*) FROM splitbuddy.settlements)'
fixture=$(psql -X -qAt -v ON_ERROR_STOP=1 -d "$database" -c "$counts")
if [[ "$fixture" != '50|500|5000|20000|50' ]]; then
  echo 'Load dbms/checks/expense_benchmark_seed.sql into a fresh database first.' >&2
  exit 1
fi

report="$scratch/05_query_timings.md"
version=$(psql -X -qAt -v ON_ERROR_STOP=1 -d "$database" -c 'SHOW server_version')
cat > "$report" <<DOC
# SplitBuddy query timings

PostgreSQL $version measured every app query three times with EXPLAIN (ANALYZE, BUFFERS). The reproducible synthetic fixture has 50 groups, 500 memberships, 5,000 expenses, 20,000 expense shares and 50 repayments. Every write was rolled back. Group 10 has ten members and 101 history entries for the group and history queries.

| Query | Type | What it does | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) | Scan type |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
DOC

measure() {
  local id="$1" type="$2" description="$3" call="$4"
  local run elapsed scans raw="$scratch/plans/$1.txt"
  {
    for run in 1 2 3; do
      printf '=== %s run %s ===\n' "$id" "$run"
      {
        [[ "$type" != WRITE ]] || printf 'BEGIN;\n'
        printf 'EXPLAIN (ANALYZE, BUFFERS) EXECUTE %s;\n' "$call"
        [[ "$type" != WRITE ]] || printf 'ROLLBACK;\n'
      } | psql -X -qAt -v ON_ERROR_STOP=1 -d "$database" -f "$dbms/04_queries.sql" -f -
    done
  } > "$raw"
  elapsed=$(awk '/^Execution Time:/ { t[++n]=$3; sum+=$3 } END {
    if (n != 3) exit 1
    printf "%.3f | %.3f | %.3f | %.3f", t[1], t[2], t[3], sum/n
  }' "$raw")
  scans=$(grep -oE 'Index Only Scan|Index Scan|Seq Scan|Bitmap Heap Scan|Bitmap Index Scan' "$raw" | sort -u | paste -sd, - | sed 's/,/, /g' || true)
  if [[ -z "$scans" ]]; then scans='Constant or CTE'; fi
  printf '| [%s](plans/%s.txt) | %s | %s | %s | %s |\n' "$id" "$id" "$type" "$description" "$elapsed" "$scans" >> "$report"
  printf '%s measured\n' "$id"
}

measure R1 READ 'List demo accounts' 'splitbuddy_list_people'
measure R2 READ 'List groups for one person' 'splitbuddy_list_groups(91)'
measure R3 READ 'List group members' 'splitbuddy_group_members(10, 91)'
measure R4 READ 'Calculate balances' 'splitbuddy_group_balances(10, 91)'
measure R5 READ 'Page through the group history' 'splitbuddy_group_history(10, 91, NULL, NULL, NULL)'
measure R6 READ 'Show the shares for an expense' 'splitbuddy_expense_shares(10, 91, 901)'
measure W1 WRITE 'Create a group and its first membership' "splitbuddy_create_group(91, 'Benchmark trip')"
measure W2 WRITE 'Add a group member' 'splitbuddy_add_member(10, 91, 101)'
measure W3 WRITE 'Record a ₹100 expense split in three' "splitbuddy_record_equal_expense(10, 91, 'Dinner', 10000, ARRAY[93, 91, 92]::bigint[])"
measure W4 WRITE 'Record the two custom shares for a cab' "splitbuddy_record_custom_expense(10, 92, 'Cab', 5500, ARRAY[93, 91]::bigint[], ARRAY[3000, 2500]::bigint[])"
measure W5 WRITE 'Record a repayment between group members' 'splitbuddy_record_settlement(10, 91, 92, 1000)'

if [[ "$(psql -X -qAt -v ON_ERROR_STOP=1 -d "$database" -c "$counts")" != "$fixture" ]]; then
  echo 'The benchmark fixture row counts changed.' >&2
  exit 1
fi
cat >> "$report" <<'DOC'

R2 and R3 join through membership. R4 aggregates signed movements once and keeps members whose balances are zero. R5 orders by timestamp, event type and ID so later pages have a stable cursor. The W3 and W4 statements save expenses and shares together, and the tests cover rounding, custom totals and membership.

To repeat the measurements, apply 03_schema.sql and checks/expense_benchmark_seed.sql to a fresh database, then run the benchmark command in the repository README.
DOC
mkdir -p "$dbms/plans"
cp "$scratch/plans/"*.txt "$dbms/plans/"
cp "$report" "$dbms/05_query_timings.md"
echo 'Wrote dbms/05_query_timings.md and 33 execution plans.'
