# Interoperable Semantics: Snowflake + Databricks via Apache Ossie

Bidirectional semantic model interoperability between Snowflake Semantic Views and Databricks Metric Views, using [Apache Ossie](https://github.com/apache/ossie) as the interchange format and S3 as the shared transport layer.

## What This Demonstrates

1. **Shared physical data** -- Snowflake-managed Iceberg tables on S3, readable by both platforms without data duplication
2. **Semantic model exchange** -- A Snowflake Semantic View exports to Ossie YAML, which Databricks converts into a Metric View (and vice versa)
3. **Loop-free continuous sync** -- Background tasks and jobs (suspended by default) on both platforms watch the same S3 bucket every minute. They compare a fingerprint of the model's meaning rather than a file timestamp, so a change on one platform reaches the other in one hop and then the sync goes silent instead of ping-ponging.

## Architecture

```
+---------------------------------------------------------------------+
|                    S3: <your-bucket>                                |
|                                                                     |
|   ossie/                              iceberg/                      |
|   +-- sales_model.yaml   (shared)     +-- customers/ (Parquet+meta)  |
|   +-- _state/snowflake.json           +-- orders/    (Parquet+meta)  |
|   +-- _state/databricks.json                                        |
+--------------+--------------------------------------+---------------+
               |                                      |
    +----------+----------+              +------------+--------+
    |   Snowflake         |              |   Databricks        |
    |                     |              |                     |
    | External Stage      |              | External Location   |
    | External Volume     |              | Storage Credential  |
    | Iceberg Tables      |              | Iceberg Table Read  |
    | Semantic View       |              | Metric View         |
    | SYNC_OSSIE task     |              | sync job            |
    | (manual or 1 min)   |              | (manual or 1 min)   |
    +---------------------+              +---------------------+
```

The manual flow uses `ossie_from_snowflake.yaml` and `ossie_from_databricks.yaml` instead of
the single shared `sales_model.yaml`.

## Prerequisites

- **AWS** -- An account with permissions to create S3 buckets and IAM roles
- **Snowflake** -- Account with ACCOUNTADMIN access (for storage integration and external volume)
- **Databricks** -- Workspace on AWS with Unity Catalog enabled and admin access

## Object Names

| Concept | Snowflake | Databricks |
|---------|-----------|------------|
| Database / Catalog | `DEMOS` | `demos` |
| Schema | `EXT_SEMANTIC_INTEROP` | `ext_semantic_interop` |
| Customers table | `CUSTOMERS` (Iceberg) | Read from S3 Iceberg metadata |
| Orders table | `ORDERS` (Iceberg) | Read from S3 Iceberg metadata |
| Semantic model | `SALES_SV` (Semantic View) | `sales_metric_view` (Metric View) |
| S3 bucket | `s3://<your-bucket>/` | Same |

## Demo Data

4 customers across 2 regions, 10 orders. Expected aggregated results:

| Region | Total Order Amount | Order Count | Total Quantity |
|--------|-------------------|-------------|----------------|
| EAST   | 750               | 5           | 12             |
| WEST   | 700               | 5           | 11             |

## Three Flows

The notebooks are grouped by how the sync is driven. Each group is self-contained; pick one
and stay in it.

### manual/ -- the walkthrough

The original demo, driven cell by cell. Best for explaining what Ossie is and what crosses
the boundary, because every step is visible and nothing happens on a timer.

- `00_snowflake_setup.ipynb`, `01_demo_and_export.ipynb` (Snowflake)
- `02_databricks_ossie_to_metric_view.ipynb`, `02b_databricks_ossie_sync.ipynb` (Databricks)
- `03_snowflake_import_from_ossie.ipynb` (Snowflake)

The `MONITOR_*` tasks in notebooks 01 and 03 loop if both are left running: each write makes
the writer look like the most recent change, so the model is traded back and forth forever.
That is what the other two flows fix.

### bidirectional/ -- a change on either platform reaches the other

A narrated demo across five files. Setup is idempotent and re-run before every demo:

- `00_snowflake_setup.sql` (Snowflake) and `00_databricks_setup.ipynb` (Databricks) reset
  the environment, create the Iceberg tables if missing, and create `SALES_SV` with two
  metrics
- `01_snowflake_semantic_view.ipynb` shows the data, exports to Ossie, imports back
- `02_databricks_metric_view.ipynb` builds the Metric View, adds a measure, exports
- `03_snowflake_automation.ipynb` bundles both directions into a procedure and a task

You revisit notebooks as the demo crosses platforms; each handoff says where to go next.
See [assets/notebooks/bidirectional/README.md](assets/notebooks/bidirectional/README.md)
for the visit order and
[docs/DEMO_RUNBOOK_BIDIRECTIONAL.md](docs/DEMO_RUNBOOK_BIDIRECTIONAL.md) for the narration.

### unidirectional/ -- Snowflake managed, consumers mirror

- `10_snowflake_managed_export.ipynb`
- `11_databricks_managed_mirror.ipynb`

Snowflake is the source of truth and never imports. A Metric View edited locally is drift and
gets reverted. Runbook: [`docs/DEMO_RUNBOOK_SNOWFLAKE_MANAGED.md`](docs/DEMO_RUNBOOK_SNOWFLAKE_MANAGED.md).

Still to do: this flow has not been restructured into the `00` setup plus narrated-notebook
shape that `bidirectional/` now uses, and it needs its own `00_snowflake_setup.sql` and
`00_databricks_setup.ipynb`. The `manual/` flow needs the same treatment.

## How the Sync Avoids a Loop

Both automated flows compare a **fingerprint of what the model means** rather than a file
timestamp. Each side also records the fingerprint it last agreed on, which gives a three-way
comparison and a single verdict per run:

| Verdict | Meaning |
|---|---|
| `NO_CHANGE` | local and shared model agree, nothing written |
| `ADOPT` | no recorded base, take the shared model |
| `IMPORT` | shared model changed, replace the local model |
| `EXPORT` | local model changed, publish it |
| `CONFLICT` | both changed since the last agreement |
| `REVERT_LOCAL_DRIFT` | local edit is not authoritative (managed flow only) |

After acting, the new fingerprint becomes the base, so the next run returns `NO_CHANGE`. That is
the loop termination. Timestamps cannot achieve this, because any write makes the writer the
most recent change.

The fingerprint covers tables, relationships, dimensions and metrics, with table qualifiers
stripped so the two dialects compare equal. Comments, descriptions, Snowflake-only `FACTS`,
spec version and dialect labels are excluded, because Databricks cannot round-trip them and
including them would mean the two sides never agree. The cost is real: **editing only a
comment propagates nothing.**

## Shared Code, Inlined for Visibility

The sync logic lives once in [`assets/ossie_sync/`](assets/ossie_sync/) and is stamped into
the notebooks as marked cells:

```
python3 assets/build_notebooks.py           # stamp all four sync notebooks
python3 assets/build_notebooks.py --check    # exit 1 if any notebook is stale
```

Edit the module, re-run the build. The notebooks still carry the code inline so it can be read
on screen during a demo, but there is only one editable copy. This is correctness rather than
tidiness: if the Snowflake and Databricks fingerprints differed by a single character, the
sync would never converge.

## Tests (run these before a live demo)

Both run offline, in a second, with no Snowflake or Databricks connection:

```
python3 tests/test_convergence.py   # fingerprint survives the round trip, twice
python3 tests/test_no_loop.py       # two agents settle instead of ping-ponging
```

`test_no_loop.py` also runs the timestamp scheme for contrast and shows it writing forever.
These are the gate: if either fails, do not enable the tasks.

## Setup (New Environment)

For a fresh setup on a new Snowflake/AWS/Databricks account, see
[`setup/SETUP.md`](setup/SETUP.md). It walks through creating the S3 bucket,
IAM roles, Snowflake objects, and Databricks configuration from scratch.

The Snowflake setup script is at [`setup/snowflake_setup.sql`](setup/snowflake_setup.sql).
Teardown is at [`setup/teardown.sql`](setup/teardown.sql).

## S3 Layout

```
s3://<your-bucket>/
  iceberg/                      Snowflake-managed Iceberg tables (Parquet + metadata)
  ossie/
    ossie_from_snowflake.yaml   manual flow
    ossie_from_databricks.yaml  manual flow
    sales_model.yaml            automated flows: one shared model
    _state/snowflake.json       written only by Snowflake
    _state/databricks.json      written only by Databricks
```

One writer per state file, so there is no lock and no race. The schedules are offset by about
30 seconds.

## Background Tasks and Jobs

Every automated notebook runs two ways, calling the same code:

| | Manual | Background |
|---|---|---|
| Snowflake | `CALL SYNC_OSSIE(...)` or `EXECUTE TASK`, which works while suspended | `ALTER TASK ... RESUME` |
| Databricks | `run_once()` in the notebook | Jobs schedule, `max_concurrent_runs = 1` |

Tasks and jobs are **suspended by default**. Enable them during a live demo and disable them
immediately after.

## Known Limitations

Conflict resolution is crude: when both sides change within the same window, Snowflake wins
and the other edit is discarded with a log line. Fine for a demo, not for production. The
production treatment of this and everything else is in
[`docs/PRODUCTION_ARCHITECTURE.md`](docs/PRODUCTION_ARCHITECTURE.md).

## Project Structure

```
interoperable_semantics/
├── README.md
├── setup/
│   ├── SETUP.md                  (full setup guide for new environments)
│   ├── snowflake_setup.sql       (creates all Snowflake objects)
│   └── teardown.sql              (removes all Snowflake objects)
├── docs/
│   ├── DEMO_RUNBOOK_BIDIRECTIONAL.md
│   ├── DEMO_RUNBOOK_SNOWFLAKE_MANAGED.md
│   ├── PRODUCTION_ARCHITECTURE.md
│   └── plans/
├── assets/
│   ├── build_notebooks.py        (stamps ossie_sync into the notebooks)
│   ├── ossie_sync/               (the only editable copy of the sync logic)
│   │   ├── fingerprint.py        (canonical projection and hash)
│   │   ├── decide.py             (three-way comparison, one verdict)
│   │   ├── state.py              (per-platform base fingerprint)
│   │   └── shim.py               (Snowflake 0.1.1 <-> converter 0.2.0.dev0)
│   ├── notebooks/
│   │   ├── manual/               (the original cell-by-cell walkthrough)
│   │   ├── bidirectional/        (both platforms may publish; 00 setup + 3 demo notebooks)
│   │   └── unidirectional/       (Snowflake managed, consumers mirror)
│   ├── ossie_converter/          (vendored Apache Ossie Databricks converter)
│   └── data/                     (source CSVs for reference)
└── tests/
    ├── test_convergence.py       (fingerprint survives the round trip)
    └── test_no_loop.py           (two agents settle, timestamps do not)
```

