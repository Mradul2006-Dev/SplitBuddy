# SplitBuddy query timings

PostgreSQL 18.6 (Homebrew) measured every app query three times with EXPLAIN (ANALYZE, BUFFERS). The reproducible synthetic fixture has 50 groups, 500 memberships, 5,000 expenses, 20,000 expense shares and 50 repayments. Every write was rolled back. Group 10 has ten members and 101 history entries for the group and history queries.

| Query | Type | What it does | Run 1 (ms) | Run 2 (ms) | Run 3 (ms) | Average (ms) | Scan type |
| --- | --- | --- | ---: | ---: | ---: | ---: | --- |
| [R1](plans/R1.txt) | READ | List demo accounts | 0.160 | 0.141 | 0.151 | 0.151 | Seq Scan |
| [R2](plans/R2.txt) | READ | List groups for one person | 0.086 | 0.056 | 0.057 | 0.066 | Seq Scan |
| [R3](plans/R3.txt) | READ | List group members | 0.092 | 0.089 | 0.090 | 0.090 | Bitmap Heap Scan, Bitmap Index Scan, Index Only Scan, Seq Scan |
| [R4](plans/R4.txt) | READ | Calculate balances | 0.445 | 0.502 | 0.434 | 0.460 | Bitmap Heap Scan, Bitmap Index Scan, Index Only Scan, Index Scan, Seq Scan |
| [R5](plans/R5.txt) | READ | Page through the group history | 0.291 | 0.262 | 0.247 | 0.267 | Bitmap Heap Scan, Bitmap Index Scan, Index Only Scan, Index Scan, Seq Scan |
| [R6](plans/R6.txt) | READ | Show the shares for an expense | 0.051 | 0.053 | 0.057 | 0.054 | Index Only Scan, Index Scan |
| [W1](plans/W1.txt) | WRITE | Create a group and its first membership | 0.292 | 0.282 | 0.268 | 0.281 | Index Only Scan |
| [W2](plans/W2.txt) | WRITE | Add a group member | 0.190 | 0.187 | 0.189 | 0.189 | Index Only Scan, Seq Scan |
| [W3](plans/W3.txt) | WRITE | Record a ₹100 expense split in three | 0.405 | 0.382 | 0.501 | 0.429 | Bitmap Heap Scan, Bitmap Index Scan, Index Only Scan |
| [W4](plans/W4.txt) | WRITE | Record the two custom shares for a cab | 0.464 | 0.452 | 0.392 | 0.436 | Bitmap Heap Scan, Bitmap Index Scan, Index Only Scan |
| [W5](plans/W5.txt) | WRITE | Record a repayment between group members | 0.182 | 0.173 | 0.166 | 0.174 | Index Only Scan |

R2 and R3 join through membership. R4 aggregates signed movements once and keeps members whose balances are zero. R5 orders by timestamp, event type and ID so later pages have a stable cursor. The W3 and W4 statements save expenses and shares together, and the tests cover rounding, custom totals and membership.

To repeat the measurements, apply 03_schema.sql and checks/expense_benchmark_seed.sql to a fresh database, then run the benchmark command in the repository README.
