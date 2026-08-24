# Demo Runbook: Fully Bidirectional

A semantic change made on either platform appears on the other, with no loop.

Notebooks: [assets/notebooks/bidirectional/](../assets/notebooks/bidirectional/). Their
[README](../assets/notebooks/bidirectional/README.md) has the file-by-file map.

Runtime: 15 to 18 minutes. Two browser windows, Snowsight and Databricks, side by side.

---

## What the audience should take away

Two things are shared, and only two. The **data**, once, as Iceberg on S3, with no copy.
And the **meaning**, as an open Apache Ossie file on the same bucket. Everything else is
each platform doing what it is good at.

The part to land hardest: on the Snowflake side this is **two function calls**, one each
way, with no connector and no pipeline. Read the function names out loud. An audience that
has built semantic-layer sync by hand will recognise how much is missing from the picture.

Then the payoff: a metric defined by the Snowflake team appears in Databricks, and a
measure defined by the Databricks team appears in Snowflake, within a minute, with nobody
re-implementing anything.

---

## Before the audience arrives

| Check | How | Expected |
|---|---|---|
| Offline gate | `python3 tests/test_convergence.py` and `tests/test_no_loop.py` | all pass |
| Snowflake reset | run `00_snowflake_setup.sql` | EAST 750/5/12, WEST 700/5/11, `SALES_SV` with 2 metrics |
| Databricks reset | run `00_databricks_setup.ipynb` | same numbers, `sales_metric_view` **not** listed |
| Converter installed | notebook 02, the `%pip` cell and `restartPython` | completes |
| Task suspended | `SHOW TASKS IN SCHEMA DEMOS.EXT_SEMANTIC_INTEROP` | `SYNC_OSSIE_TASK` absent or suspended |
| Job paused | Databricks Workflows | paused |

Run the `%pip` install before anyone is watching. On serverless it takes 45 to 75 seconds,
which is dead air in the middle of a demo.

Both setup scripts are idempotent, so re-run them freely.

---

## a. Snowflake: the data and the semantic view

**Notebook:** `01_snowflake_semantic_view.ipynb`, steps 1 to 3

1. Open on the diagram in the title cell. Two shared things, one bucket.
2. `SHOW ICEBERG TABLES`. These are Iceberg on a bucket we own, not Snowflake-internal
   tables. Say it explicitly; it is the foundation of the second half.
3. `SELECT * FROM CUSTOMERS`, then the region aggregate. **EAST 750/5, WEST 700/5.** Ask
   the room to remember two numbers.
4. The `SEMANTIC_VIEW()` query returns the same numbers, now from a governed definition with
   `TOTAL_ORDER_AMOUNT` and `ORDER_COUNT`. Nobody wrote the join.

---

## b. Databricks: same data, no semantic model

**Notebook:** `02_databricks_metric_view.ipynb`, step 1

1. `SELECT * FROM customers` and the region aggregate. Same numbers, different engine, no
   copy. This is where Iceberg earns its place in the story, so let it land.
2. `SHOW VIEWS` shows no `sales_metric_view`. The data is shared; the meaning is not. Anyone
   querying here has to rebuild the join and the metrics by hand and hope they match.

---

## c. Snowflake: export to Ossie

**Notebook:** `01_snowflake_semantic_view.ipynb`, step 4

1. Explain the interchange: an open Ossie file at `ossie/sales_model.yaml`, on the same
   bucket as the Iceberg data.
2. Run `SELECT SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW(...)` on its own first. **One
   function, no arguments beyond the view name, and the whole model comes out in an open
   format.** This is the single most persuasive cell in the demo.
3. The `COPY INTO` cell writes it to S3. Doing the first export by hand makes it obvious
   there is nothing hidden.
4. The `DIRECTORY()` query confirms the file is there.
5. Read the closing markdown: Databricks will now read this file and build a matching
   Metric View.

---

## d. Databricks: build the Metric View, then add a measure

**Notebook:** `02_databricks_metric_view.ipynb`, step 2

1. **2a, the shim.** Be straightforward: the Ossie spec is young and moving, Snowflake
   emits `0.1.1`, the Apache converter targets `0.2.0.dev0`, and they disagree on three
   mechanical points. The shim fixes the envelope and never the semantics. It goes away as
   the spec settles. The honest framing is that an open standard plus native support on the
   Snowflake side is what makes this a 40-line adapter instead of a project.
2. **2b** defines both directions in one cell. Say that the export half will be used later
   and move on; do not read it line by line.
3. **2c** is the actual moment: `import_ossie_to_metric_view()`, three lines, and the
   Metric View exists with both measures.
4. **2d** queries it. **EAST 750/5, WEST 700/5**, the numbers from step (a). The join, the
   dimension and both measures were authored in Snowflake.
5. **2e, the turn.** The Databricks team wants `TOTAL_QUANTITY`. Show the UI path in the
   markdown, then run the SQL cell. Query it: **EAST 12, WEST 11.**
6. **2f** publishes it back with `export_metric_view_to_ossie()`.
7. **2g** introduces `sync_once()` and the schedule. Keep this brief. If asked how the two
   schedules avoid overwriting each other, the answer is one sentence: each side compares
   what the model means, not when the file was written, so once they agree they stop. Do
   not go further unless pushed.

---

## e. Snowflake: the Databricks measure arrives

**Notebook:** `01_snowflake_semantic_view.ipynb`, step 5

1. Read the file and `CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_OSSIE_YAML`. **One function
   again**, and it replaces `SALES_SV` in place so everything pointing at it stays valid.
2. `SHOW SEMANTIC METRICS` lists three metrics now.
3. The `SEMANTIC_VIEW()` query: **EAST 12/750/5, WEST 11/700/5.** A measure authored in
   Databricks, queried through a Snowflake Semantic View.

This is the halfway payoff. Pause here.

---

## f. Snowflake: automate it

**Notebook:** `03_snowflake_automation.ipynb`

1. Create the stored procedure. The framing: the two native functions are unchanged, and
   the procedure only decides which one to run.
2. Create the task, then resume it. Leave the suspend cell alone until the end.
3. Add `AVG_ORDER_AMOUNT` to `SALES_SV`, and touch nothing else.
4. **Now you have about two minutes**, one for the Snowflake task to publish and one for
   the Databricks job to pick it up. Two ways to spend it:
   - **Talk.** The best question to put to the room: how many places is your most
     important metric defined today, what happens when one of them changes, and who finds
     out. This is the moment they are most receptive to it.
   - **Or skip the wait.** `EXECUTE TASK` runs it immediately, and works whether or not the
     schedule is on. Nobody can tell.
5. The `TASK_HISTORY` query shows one `EXPORT` where the metric changed and `NO_CHANGE`
   either side of it. That column of `NO_CHANGE` is worth pointing at: the task runs every
   minute and writes nothing until something actually changes.

---

## g. Databricks: it arrived on its own

**Notebook:** `02_databricks_metric_view.ipynb`, step 3

1. `sync_once()` if you did not wait, or nothing at all if you did.
2. Query all four measures: **EAST 150/12/750/5, WEST 140/11/700/5.**
3. `avg_order_amount` was defined in Snowflake and nobody here wrote a definition.
4. The closing markdown covers event-driven alternatives. The one worth mentioning aloud is
   that Snowflake can drive this off S3 event notifications rather than a schedule, so the
   minute is a demo artifact and not a limit.

**Demo complete.**

---

## Afterwards, every time

1. Suspend `SYNC_OSSIE_TASK` using the cell in notebook 03, step 3.
2. Pause the Databricks job in Workflows.
3. To run again, start from `00_snowflake_setup.sql`.

Leaving the task and job running costs credits and leaves a confusing starting state.

---

## Verdict reference

The automated steps report one of these. Only `NO_CHANGE`, `IMPORT` and `EXPORT` should
appear in a healthy demo.

| Verdict | Meaning |
|---|---|
| `NO_CHANGE` | Both sides agree. Nothing written. |
| `ADOPT` | No recorded state. Takes the shared file as the starting point. |
| `IMPORT` | The shared file changed. Local model replaced. |
| `EXPORT` | The local model changed. Shared file written. |
| `CONFLICT` | Both changed within the same window. Snowflake wins. |

---

## Known limitations, if asked

Conflict resolution is crude. When both sides change in the same window, Snowflake wins and
the Databricks edit is discarded with a log line. Fine for a demo, not for production,
where this needs a merge or an approval gate. Say it before someone else does. The
production treatment is in [PRODUCTION_ARCHITECTURE.md](PRODUCTION_ARCHITECTURE.md).

Not everything propagates. Tables, relationships, dimensions and metrics do. Comments,
descriptions and Snowflake-only `FACTS` do not, because Databricks cannot round-trip them.
Editing only a comment syncs nothing, deliberately: including those fields would mean the
two sides never agree and the sync would write on every tick forever.

Databricks needs the converter and Snowflake does not. Snowflake reads and writes Ossie
natively. That asymmetry is fair to point out and is the strongest argument in the demo.

The 1-minute schedule is a demo setting. Production would react to the file landing.

Databricks file arrival triggers will not work for this file as written, because
overwriting a file with the same name does not fire them. Versioned filenames fix it. This
is covered in the notebook, and it is better to volunteer it than to promise a trigger that
silently never fires.

---

## If something goes wrong

| Symptom | Likely cause | Fix |
|---|---|---|
| Databricks setup errors on missing Iceberg paths | Snowflake setup not run | run `00_snowflake_setup.sql` first |
| `import_ossie_to_metric_view()` fails on a missing file | export step skipped | run notebook 01 step 4 |
| Metric View has no measures | converter dropped them | re-run `tests/test_convergence.py`, check the converter commit is the pinned one |
| Sync reports `CONFLICT` unexpectedly | stale state from a previous run | re-run both setup scripts |
| Every run reports `IMPORT` or `EXPORT`, never `NO_CHANGE` | fingerprint not converging | fall back to slides, then run the offline tests |
| Databricks cell hangs on `%pip` | cold serverless compute | warm it beforehand, or use a cluster library |
| Snowflake sees a stale file | directory metadata not refreshed | `ALTER STAGE OSSIE_S3_STAGE REFRESH` |
| `EXECUTE TASK` fails on privileges | session role reset | `USE ROLE ACCOUNTADMIN` |

Have a screenshot of the final Databricks four-measure result. If the live sync fails, show
the outcome and keep moving.
