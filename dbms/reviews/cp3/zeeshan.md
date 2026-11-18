# SplitBuddy CP3 check — ₹100 equal split

This check ran on 18 November 2026 in a browser with a fresh PostgreSQL 18.6 database loaded from the [demo fixture](../../demo.sql).

## Steps to repeat

1. Start the [local app](../../../README.md#run-the-app). Choose Asha and open **Weekend trip**.
2. Open **Add expense**. Enter `Equal split check` and `100.00`, keep **Equal**, select Asha, Bina and Chetan, then save.
3. In **History**, open **View shares** on the new entry. Reload the page, reopen the group and check the entry and its shares again.

## Observed result

| Member | Share before and after reload | Group balance after save |
| --- | ---: | ---: |
| Asha | ₹33.34 | ₹366.66 |
| Bina | ₹33.33 | −₹33.33 |
| Chetan | ₹33.33 | −₹333.33 |

A direct read of the expense and share rows also returned `3334`, `3333` and `3333` paise. The shares added up to exactly ₹100.00 and the group balances summed to zero. The existing [expense split](../../checks/expense_splits.sql) and [application](../../checks/application.sql) SQL checks passed on the fresh database.

## Code to explain

In the [query catalog](../../04_queries.sql), `W3` saves the expense and its shares in one statement. It splits 10,000 paise into three lots of 3,333 and assigns the one remaining paise to the first participant ordered by user ID. `R6` reads the stored shares and `R4` recomputes balances. The [W3 plan](../../plans/W3.txt) and [R6 plan](../../plans/R6.txt) show the corresponding queries from the separate three-run benchmark.
