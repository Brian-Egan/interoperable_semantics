# Demo Runbook: Fully Bidirectional

A semantic change made on either platform appears on the other, with no loop.

> Notebooks: [assets/notebooks/bidirectional/](../assets/notebooks/bidirectional/)
> (`20_snowflake_bidirectional_sync.ipynb`, `21_databricks_bidirectional_sync.ipynb`).
> Before running it live for the first time, clear the offline gate:
>
> ```
> python3 tests/test_convergence.py    # fingerprint survives the round trip
> python3 tests/test_no_loop.py        # two agents settle instead of ping-ponging
> ```

Runtime: 12 to 15 minutes. Two browser windows, Snowsight and Databricks, side by side.

---

## What the audience should take away

Both platforms read the same Parquet files through Iceberg, and both read the same
semantic definition through one Ossie file on S3. Neither platform is the master. A
metric authored in Snowflake is queryable in Databricks, and a measure authored in
Databricks is queryable in Snowflake.

Spend a minute on why it does not oscillate. Each side compares a fingerprint of the
model's meaning rather than a file timestamp, so once the two agree, neither writes
anything. Timestamps cannot do this: any write makes the writer the most recent change,
so a timestamp-driven pair trades the model back and forth forever.

---

## Before the audience arrives

Run through this once. It takes about 3 minutes and it is where anything broken shows up.

| Check | How | Expected |
|---|---|---|
| Offline gate passes | `python3 tests/test_convergence.py` and `tests/test_no_loop.py` | all checks pass |
| Iceberg data present | `manual/01_demo_and_export.ipynb`, the region aggregate cell | EAST 750/5/12, WEST 700/5/11 |
| Semantic View exists | `SHOW SEMANTIC VIEWS IN DEMOS.EXT_SEMANTIC_INTEROP` | `SALES_SV` listed |
| Both tasks suspended | `SHOW TASKS IN SCHEMA DEMOS.EXT_SEMANTIC_INTEROP` | `state = suspended` |
| Databricks job paused | Workflows, the sync job | Paused |
| Databricks compute warm | Attach notebook 21, run the config cell | Cell completes |
| Clean starting state | Notebook 21, `reset_demo()` | Metric View dropped, state cleared |

Leave `SALES_SV` with its original two metrics. `reset_demo()` drops the Metric View and
clears `_state/databricks.json` so step (b) shows the view being created rather than
replaced.

Warm the Databricks compute. On serverless the `%pip` install of the Ossie converter
takes 45 to 75 seconds, and that is dead air if it happens while people are watching.

---

## a. Snowflake: the data and the Semantic View

**Notebook:** `manual/01_demo_and_export.ipynb`

1. `SHOW ICEBERG TABLES`. The tables are Iceberg, not internal Snowflake tables.
2. `SELECT * FROM CUSTOMERS` and `ORDERS`. 4 customers, 10 orders, small enough to
   verify by eye.
3. The region aggregate: EAST 750/5/12, WEST 700/5/11.
4. The `CREATE SEMANTIC VIEW SALES_SV` cell. Read the `METRICS` clause aloud:
   `TOTAL_ORDER_AMOUNT` and `ORDER_COUNT`. These two names are what the audience should
   watch for on the Databricks side.
5. `SELECT * FROM SEMANTIC_VIEW(...)`. The semantic layer returns the same numbers.

Point out that the Parquet files behind these tables sit on S3, and that Databricks is
about to read those same files.

---

## b. Databricks: same data, then turn the sync on

**Notebook:** `bidirectional/21_databricks_bidirectional_sync.ipynb`

1. Run the aggregate query against `demos.ext_semantic_interop.orders` and `customers`.
   Same numbers, different engine, no copy. This is the Iceberg half of the story and it
   is worth a beat.

2. Show that the Metric View does not exist:

   ```sql
   SHOW VIEWS IN demos.ext_semantic_interop
   ```

3. Run the `run_once()` cell. Expected output:

   ```
   Local  : (none)
   Remote : sha256:...
   Base   : (none)
   Verdict: ADOPT - no local model, taking the shared Ossie definition
   Created demos.ext_semantic_interop.sales_metric_view
   Measures: ORDER_COUNT, TOTAL_ORDER_AMOUNT
   ```

   The `display()` cell underneath returns EAST and WEST through `MEASURE()`. The Metric
   View was defined by Snowflake, converted through Ossie, and is now queryable in
   Databricks.

4. Run `run_once()` a second time. It prints `NO_CHANGE - converged`. Nothing was written.
   This is the loop termination, demonstrated in one cell rather than described.

5. Resume the background job in Workflows. From here on the demo has a 1-minute
   heartbeat carrying anything either side changes, and you can still trigger manually
   whenever you do not want to wait.

---

## c. Databricks: add a measure

**Notebook:** `bidirectional/21_databricks_bidirectional_sync.ipynb`

1. Add `TOTAL_QUANTITY` to the Metric View:

   ```sql
   ALTER VIEW demos.ext_semantic_interop.sales_metric_view ...
   ```

   Use the notebook's add-measure cell, which appends
   `{'name': 'TOTAL_QUANTITY', 'expr': 'SUM(order_qty)'}` and re-applies the view.

2. Query it: EAST 12, WEST 11.

3. Run `run_once()`. Expected:

   ```
   Verdict: EXPORT - local model changed, publishing to the shared Ossie file
   Wrote s3://<bucket>/ossie/sales_model.yaml
   ```

   Do not wait for the schedule. Trigger it so the room sees cause and effect.

Say plainly what just happened: a measure authored in Databricks has been written back
in the interchange format, and Snowflake has had no involvement yet.

---

## d. Snowflake: the Databricks change lands

**Notebook:** `bidirectional/20_snowflake_bidirectional_sync.ipynb`

1. Trigger the sync manually rather than waiting for the task:

   ```sql
   EXECUTE TASK DEMOS.EXT_SEMANTIC_INTEROP.SYNC_OSSIE_TASK;
   ```

   `EXECUTE TASK` runs a suspended task, and it calls the same procedure the schedule
   calls. `CALL SYNC_OSSIE(...)` is equivalent if you prefer to show the procedure
   directly.

2. Read the verdict:

   ```
   IMPORT - shared Ossie file changed, replacing SALES_SV
   ```

3. Confirm the measure arrived:

   ```sql
   SHOW SEMANTIC METRICS IN DEMOS.EXT_SEMANTIC_INTEROP.SALES_SV;
   ```

   Three metrics now: `TOTAL_ORDER_AMOUNT`, `ORDER_COUNT`, `TOTAL_QUANTITY`.

4. Query through the semantic layer:

   ```sql
   SELECT * FROM SEMANTIC_VIEW(
     DEMOS.EXT_SEMANTIC_INTEROP.SALES_SV
     DIMENSIONS region
     METRICS total_quantity, total_order_amount, order_count
   ) ORDER BY region;
   ```

   EAST 12/750/5, WEST 11/700/5. A measure defined in Databricks is now a metric in a
   Snowflake Semantic View.

5. Run the task once more. `NO_CHANGE - converged`. Both sides agree, so nothing is written.

6. If you want to show the background schedule doing the same work unattended, resume
   the task and display its history:

   ```sql
   ALTER TASK DEMOS.EXT_SEMANTIC_INTEROP.SYNC_OSSIE_TASK RESUME;

   SELECT scheduled_time, state, return_value
     FROM TABLE(INFORMATION_SCHEMA.TASK_HISTORY(
       TASK_NAME => 'SYNC_OSSIE_TASK'))
    ORDER BY scheduled_time DESC LIMIT 10;
   ```

   A column of `NO_CHANGE - converged` is the point: the sync runs every minute and writes
   nothing until something genuinely changes.

---

## Optional: the reverse direction, live

Worth doing if the room is engaged, because it closes the loop in the other direction
with both schedules running.

1. In Snowflake, add a metric to `SALES_SV`:
   `orders.avg_order_amount AS AVG(orders.order_amount)`.
2. Leave both schedules resumed and wait. Within roughly 90 seconds Snowflake exports
   and Databricks imports.
3. In Databricks, `MEASURE(avg_order_amount)` returns EAST 150, WEST 140.

No manual trigger, nobody touching anything. This is the version that tends to land.

---

## Reset

Run before repeating the demo:

1. Suspend the Snowflake task and pause the Databricks job.
2. Notebook 21, `reset_demo()`. Drops the Metric View, clears `_state/databricks.json`.
3. Notebook 20, the reset cell. Restores `SALES_SV` to its original two metrics and
   clears `_state/snowflake.json`.
4. Re-export the baseline so the shared file matches the restored view.

Resetting both state files matters. A stale `base_fingerprint` makes the next run report
`CONFLICT` instead of `ADOPT`, which is confusing to debug mid-demo.

---

## Verdict reference

| Verdict | Meaning |
|---|---|
| `NO_CHANGE` | Local and shared fingerprints match. Nothing written. |
| `ADOPT` | No recorded base. Takes the shared file as the starting point. |
| `IMPORT` | Shared file changed, local did not. Local model replaced. |
| `EXPORT` | Local changed, shared file did not. Shared file written. |
| `CONFLICT` | Both changed since the base. Snowflake wins; see the caveat below. |

---

## Known limitations, if asked

Conflict resolution is crude. When both sides change within the same window, Snowflake
wins and the Databricks edit is discarded with a log line. Fine for a demo, not fine for
production, where this needs either a real merge or an approval gate. Say this before
someone else does. The production treatment is in
[PRODUCTION_ARCHITECTURE.md](PRODUCTION_ARCHITECTURE.md).

Not everything propagates. The fingerprint covers tables, relationships, dimensions, and
metrics. Comments, descriptions, and Snowflake-only `FACTS` are excluded, so editing only
a comment syncs nothing. This is deliberate: Databricks cannot round-trip those
constructs, and including them in the fingerprint would mean the two sides never agree,
so the sync would write on every tick forever.

The 1-minute schedule is a demo setting. Production would run on change notification
instead of polling.

Databricks needs the Apache converter and Snowflake does not, because Snowflake reads and
writes Ossie natively. That asymmetry is a fair thing to point out.

---

## If something goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| `run_once()` reports `CONFLICT` unexpectedly | Stale state file from an earlier run | Run the full reset |
| Every run reports `EXPORT` or `IMPORT`, never `NO_CHANGE` | Fingerprint not converging | Fall back to slides; run `tests/test_convergence.py` afterwards |
| Databricks cell hangs on `%pip` | Cold serverless compute | Warm it before the demo, or install the converter as a cluster library |
| `EXECUTE TASK` errors on privileges | Session role reset | `USE ROLE ACCOUNTADMIN` |
| Snowflake sees a stale file | Directory table metadata not refreshed | `ALTER STAGE OSSIE_S3_STAGE REFRESH` |
| Metric View missing after `ADOPT` | Shared Ossie file absent on S3 | Re-run the Snowflake export |

Have a screenshot of the final Snowflake `SEMANTIC_VIEW()` result showing all three
metrics. If the live sync fails, show the outcome and move on.
