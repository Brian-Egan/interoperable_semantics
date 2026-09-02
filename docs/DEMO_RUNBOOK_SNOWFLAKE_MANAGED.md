# Demo Runbook: Snowflake Managed / Unidirectional

The Snowflake Semantic View is the single source of truth. Downstream platforms mirror it
and are effectively read-only.

> **Status: built, but not yet rehearsed.** Notebooks are in
> [assets/notebooks/unidirectional/](../assets/notebooks/unidirectional/)
> (`10_snowflake_managed_export.ipynb`, `11_databricks_managed_mirror.ipynb`) and share the
> same `ossie_sync` module as the bidirectional pair. This runbook is deliberately thinner
> than its sibling, and sections marked **TODO** are yours to develop.

Runtime once rehearsed: 8 to 10 minutes, shorter than the bidirectional demo because there
is only one direction of travel.

---

## How this differs from the bidirectional demo

Same module, same fingerprint, same S3 layout. The only behavioural difference is which
actions each side is permitted to take:

| | Snowflake | Databricks |
|---|---|---|
| Bidirectional | `IMPORT`, `EXPORT` | `IMPORT`, `EXPORT` |
| Snowflake managed | `EXPORT` only | `IMPORT` only |

That restriction is an argument rather than a fork: the Snowflake procedure sets
`ALLOWED = SNOWFLAKE_MANAGED_SOURCE` and the Databricks notebook sets
`ALLOWED = SNOWFLAKE_MANAGED_MIRROR`. A
Databricks-side edit therefore cannot produce `EXPORT`; it produces
`REVERT_LOCAL_DRIFT` and is overwritten on the next run.

This changes the demo script. In the bidirectional flow, adding a measure in Databricks is
the payoff. Here that same action is a governance failure that gets reverted, so the
measure must be added in Snowflake instead. Do not run the two demos from the same
script.

---

## What the audience should take away

One authored definition, many consumers. A metric is defined once by the team that owns
the business logic, published in an open interchange format, and every downstream engine
picks it up without anyone re-implementing it. Where a consumer drifts, it gets corrected
rather than negotiated.

The right audience for this is a governance or platform team: whoever is nervous about the
same metric being defined four times in four tools, with four slightly different answers.

---

## Before the audience arrives

Same preflight as the bidirectional runbook, with two changes:

| Check | How | Expected |
|---|---|---|
| Offline gate passes | `python3 tests/test_convergence.py` and `tests/test_no_loop.py` | all checks pass |
| Iceberg data present | `manual/01_demo_and_export.ipynb`, region aggregate | EAST 750/5/12, WEST 700/5/11 |
| Semantic View exists | `SHOW SEMANTIC VIEWS` | `SALES_SV` with its original two metrics |
| Export task suspended | `SHOW TASKS` | `EXPORT_OSSIE_TASK` suspended |
| Mirror job paused | Databricks Workflows | Paused |
| No bidirectional task running | `SHOW TASKS` | `SYNC_OSSIE_TASK` is suspended |
| Databricks compute warm | Notebook 11 config cell | Completes |

The fifth row matters. If the bidirectional task is left resumed, both architectures are
running at once and the Databricks drift you are about to demonstrate will get exported
instead of reverted.

---

## a. Snowflake: the authored definition

**Notebook:** `unidirectional/10_snowflake_managed_export.ipynb`

As in the bidirectional demo: Iceberg tables, the raw data, the region aggregate, the
`CREATE SEMANTIC VIEW` statement, and a `SEMANTIC_VIEW()` query.

Frame it differently, though. This is the definition of record rather than one of two
peers. Everything downstream derives from it.

**TODO:** decide whether to open with governance framing (who owns the metric, who is
allowed to change it) or keep it technical. Depends on the audience.

---

## b. Databricks: mirror the definition

**Notebook:** `unidirectional/11_databricks_managed_mirror.ipynb`

1. Aggregate query against the Iceberg tables. Same numbers, same files.
2. Show the Metric View does not exist.
3. `run_once()`. Expected `ADOPT`, then the Metric View appears with
   `ORDER_COUNT` and `TOTAL_ORDER_AMOUNT`.
4. `run_once()` again. `NO_CHANGE - converged`.
5. Resume the mirror job.

Identical to the bidirectional demo up to this point. Everything after it diverges.

---

## c. Snowflake: add a metric

**Notebook:** `unidirectional/10_snowflake_managed_export.ipynb`

Add `TOTAL_QUANTITY` to `SALES_SV`:

```sql
orders.total_quantity AS SUM(orders.order_qty)
```

Then trigger the export:

```sql
EXECUTE TASK DEMOS.SNOWFLAKE_MANAGED_SEMANTIC_INTEROP.EXPORT_OSSIE_TASK;
```

Expected: `EXPORT - local model changed, publishing to Ossie`.

**TODO:** confirm whether the metric is better added by editing the `CREATE OR REPLACE
SEMANTIC VIEW` cell (clearer to read, but re-runs the whole definition) or by an
incremental statement. Prefer whichever reads better on screen.

---

## d. Databricks: the new metric arrives

**Notebook:** `unidirectional/11_databricks_managed_mirror.ipynb`

1. `run_once()`. Expected `IMPORT`.
2. `MEASURE(total_quantity)` returns EAST 12, WEST 11.

A metric authored by the Snowflake team is now queryable in Databricks, and nobody wrote
it twice.

---

## e. Drift correction

This is the section that distinguishes this demo, and it has no counterpart in the
bidirectional one.

1. In Databricks, run the drift cell in step 8 of notebook 11, which adds a `LOCAL_DRIFT`
   measure directly to the Metric View.

2. Query it and show it works. Locally, it is real.

3. Run `run_once()`. Expected:

   ```
   Verdict: REVERT_LOCAL_DRIFT - local edit is not authoritative, restoring from Ossie
   ```

4. Query again. The local edit is gone.

The framing to use: the Metric View is a projection rather than a place to author. Local
edits are not rejected at write time, they are reconciled away on the next run. Be honest
that this is a deliberate architectural choice with a real cost, and that whether it is
correct depends entirely on who owns the metric.

**TODO:** the more interesting version of this step shows Snowflake winning while the
Databricks user believes they succeeded. Worth developing, but it needs care to avoid
looking like a bug.

---

## Reset

1. Suspend the export task, pause the mirror job.
2. Notebook 11, `reset_demo()`. Drop the Metric View, clear `_state/databricks.json`.
3. Notebook 10, reset cell. Restore `SALES_SV` to two metrics, clear
   `_state/snowflake.json`.
4. Re-export the baseline.

---

## Verdict reference

| Verdict | Meaning |
|---|---|
| `NO_CHANGE` | Fingerprints match. Nothing written. |
| `ADOPT` | No recorded base. Takes the Ossie file as the starting point. |
| `IMPORT` | Ossie file changed. Local model replaced. |
| `EXPORT` | Snowflake side only. Publishes the Semantic View. |
| `REVERT_LOCAL_DRIFT` | Databricks side only. Local edit discarded, model restored. |

`CONFLICT` cannot occur here. With only one writer to the Ossie file there is nothing to
conflict over, which is the main thing this architecture buys.

---

## Known limitations, if asked

Consumers cannot contribute. A Databricks analyst who spots a missing metric has to file a
request against the Snowflake definition. That is the trade: consistency for autonomy. If
the audience pushes back, that is the cue to show the bidirectional demo.

Revert is silent to the person who made the edit. They will find their change gone with no
notification. Production needs an alert on `REVERT_LOCAL_DRIFT`; see
[PRODUCTION_ARCHITECTURE.md](PRODUCTION_ARCHITECTURE.md).

Not everything propagates. Same fingerprint scope as the bidirectional demo: tables,
relationships, dimensions, metrics. Comments, descriptions, and `FACTS` are excluded.

One consumer is shown and many are implied. The architecture fans out to any number of
downstream platforms reading the same Ossie file, but this demo only has Databricks.

---

## TODO for the next iteration

- Rehearse end to end; the notebooks are built but this flow has not been run live.
- Add a second downstream consumer to make the fan-out concrete rather than asserted.
  A second Metric View in a different Databricks catalog is the cheapest option.
- Decide how to present revert: silent as now, or with a notification.
- Consider showing a rejected change end to end, from analyst request through Snowflake
  edit to propagation, which is the honest full lifecycle.
- Time the demo. It should come in well under the bidirectional one; if it does not,
  something is being over-explained.
