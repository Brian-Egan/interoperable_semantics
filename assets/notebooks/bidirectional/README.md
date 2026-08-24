# Bidirectional Demo

A semantic model shared between Snowflake and Databricks, where a change made on either
platform reaches the other. Neither side is subordinate.

## Files, and the order you touch them

| File | Platform | When |
|---|---|---|
| `00_snowflake_setup.sql` | Snowflake | Before every run. Idempotent. |
| `00_databricks_setup.ipynb` | Databricks | Before every run, after the Snowflake setup. |
| `01_snowflake_semantic_view.ipynb` | Snowflake | Demo steps 1, 4 and 5 |
| `02_databricks_metric_view.ipynb` | Databricks | Demo steps 2, 3 and 7 |
| `03_snowflake_automation.ipynb` | Snowflake | Demo step 6 |

You visit `01` twice and `02` three times. Each has numbered step headings, and every
handoff point says which notebook and which step to go to next, so you cannot lose your
place mid-demo.

```
setup:  00_snowflake_setup.sql  ->  00_databricks_setup.ipynb

demo:   01 step 1-3   Snowflake    data is Iceberg, semantic view has 2 metrics
        02 step 1     Databricks   same data, no metric view
        01 step 4     Snowflake    export to Ossie on S3 (one native function)
        02 step 2     Databricks   build metric view, add TOTAL_QUANTITY, export back
        01 step 5     Snowflake    import, and TOTAL_QUANTITY appears
        03            Snowflake    stored procedure + 1 minute task, add AVG_ORDER_AMOUNT
        02 step 3     Databricks   AVG_ORDER_AMOUNT arrived on its own
```

Full narration, expected numbers at each step, and troubleshooting are in
[`docs/DEMO_RUNBOOK_BIDIRECTIONAL.md`](../../../docs/DEMO_RUNBOOK_BIDIRECTIONAL.md).

## Before a live run

```
python3 tests/test_convergence.py   # the round trip is fingerprint-stable
python3 tests/test_no_loop.py       # two schedules settle instead of ping-ponging
```

Both run offline in about a second. If either fails, the every-minute tasks in step 6 will
fight each other, so treat them as a gate.

## What lives where

The two native Snowflake functions carry the whole story on that side:

- export: `SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW`
- import: `SYSTEM$CREATE_SEMANTIC_VIEW_FROM_OSSIE_YAML`

Databricks has no native Ossie support yet, so notebook `02` carries the Apache converter
plus a shim for the spec-version gap, written out inline because explaining it is part of
the demo.

The consistency logic that stops the two schedules from looping is generated into the
notebooks from [`assets/ossie_sync/`](../../ossie_sync/) by
[`assets/build_notebooks.py`](../../build_notebooks.py). Edit the module, re-run the build.
It is deliberately underplayed in the narration.

## S3 layout

```
s3://<bucket>/
  iceberg/                      Snowflake-managed Iceberg tables, read by both platforms
  ossie/
    sales_model.yaml            the shared semantic model, either side may write it
    _state/snowflake.json       written only by Snowflake
    _state/databricks.json      written only by Databricks
```
