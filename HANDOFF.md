# Handoff: Interoperable Semantics (Snowflake ↔ Ossie ↔ Databricks)

**Prepared for:** New CoCo session on a different machine  
**Next objective:** Extend the demo to use S3 as the backbone — Snowflake writes Ossie YAML to an external S3 stage; Databricks reads from the same S3 bucket automatically, eliminating the manual file hand-offs.

---

## What was built

A working bidirectional interop demo: a Snowflake Semantic View exports to Apache Ossie YAML, that file becomes a Databricks Unity Catalog Metric View, a new metric is added on the Databricks side, Ossie is exported back, and Snowflake imports it as a new Semantic View. The same query returns identical numbers on both platforms.

The repo is at: **https://github.com/Snowflake-Solutions/interoperable_semantics**

The commit on that repo is a local `first commit` that has NOT been pushed yet (the push command was given but never completed due to shell issues in the session). The local repo at:

```
/Users/began/Dev/cortex_cli/demos/interoperable_semantics/
```

contains two self-contained shareable packages:
- `client_facing/` — the three notebooks, data CSVs, converter fallback, teardown, client README.
- `snowflake_demo/` — same notebooks plus the shim source, offline round-trip test, technical reference, fuller README.

---

## Repository layout

```
interoperable_semantics/
├── README.md                          (project root, describes the two packages)
├── client_facing/
│   ├── README.md                      (client walkthrough)
│   ├── 01_snowflake_setup_and_export.ipynb
│   ├── 02_databricks_ossie_to_metric_view.ipynb
│   ├── 03_snowflake_import_from_ossie.ipynb
│   ├── data/customers.csv, orders.csv
│   ├── ossie_converter/               (vendored Apache converter, offline fallback)
│   └── teardown.sql
└── snowflake_demo/
    ├── README.md                      (SE walkthrough + experimentation notes)
    ├── 01_snowflake_setup_and_export.ipynb
    ├── 02_databricks_ossie_to_metric_view.ipynb
    ├── 03_snowflake_import_from_ossie.ipynb
    ├── data/customers.csv, orders.csv
    ├── ossie_shim.py                  (the adapter — see full source below)
    ├── ossie_converter/               (vendored Apache converter)
    ├── test_roundtrip.py              (offline verification, no connection needed)
    ├── demo_reference.md              (API/mapping reference)
    └── teardown.sql
```

---

## How the interop works

```
Snowflake SALES_SV
  └─ SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW()
       └─ ossie_from_snowflake.yaml   (crosses the boundary)
            └─ snowflake_to_converter() shim
                 └─ Apache converter: convert_ossie_to_metric_view()
                      └─ Databricks Metric View (CREATE VIEW ... WITH METRICS LANGUAGE YAML)
                           └─ user adds TOTAL_QUANTITY measure
                                └─ SHOW CREATE TABLE / get_metric_view_yaml()
                                     └─ Apache converter: convert_metric_view_to_ossie()
                                          └─ converter_to_snowflake() shim
                                               └─ ossie_from_databricks.yaml  (crosses back)
                                                    └─ SYSTEM$CREATE_SEMANTIC_VIEW_FROM_OSSIE_YAML()
                                                         └─ Snowflake SALES_SV_V2
```

**Key asymmetry**: Snowflake has native Ossie functions built in. Databricks does not yet; it uses the open-source Apache converter.

---

## The demo data

```
CUSTOMERS(customer_id PK, customer_name, region)   — 4 rows
ORDERS(order_id PK, customer_id FK, order_amount INT, order_qty INT)  — 10 rows
```

Expected grouped result (auditable by eye — integer-only so no float drift):

| region | total_order_amount | order_count | total_quantity |
|--------|--------------------|-------------|----------------|
| EAST   | 750                | 5           | 12             |
| WEST   | 700                | 5           | 11             |

`total_quantity = SUM(order_qty)` is the metric added on the Databricks side and carried back.

---

## Snowflake object names

All hardcoded/parameterized in the notebooks (Python config cell at top of each):
- Database: `DEMOS`
- Schema: `SEMANTIC_INTEROP`
- Stage: `INTEROP_STAGE`
- Semantic views: `SALES_SV` (original), `SALES_SV_V2` (round-tripped)
- File format: `RAW_TEXT_FMT` (TYPE=CSV FIELD_DELIMITER=NONE RECORD_DELIMITER=NONE)

The notebooks use `{{DATABASE}}.{{SCHEMA}}` Jinja variable substitution (Snowflake Notebooks feature). The Python config cell assigns `DATABASE` and `SCHEMA`; every SQL cell references `{{DATABASE}}.{{SCHEMA}}`. No `USE ROLE` needed — notebooks run with caller's rights.

**Role gotcha on coco_demo**: the session role resets to `CORTEX_CLI_USER_ROLE` which lacks `CREATE SEMANTIC VIEW`. SQL scripts (not notebooks) need `USE ROLE ACCOUNTADMIN` prepended. Notebooks run under the notebook's configured role.

---

## Databricks object names

- Catalog: `demos` (or whatever the user's workspace allows — configure at top of notebook 2)
- Schema: `semantic_interop`
- Tables: `customers`, `orders`
- Metric View: `sales_metric_view`

Use the **same names as Snowflake** (database ↔ catalog, schema ↔ schema) to maximize source-name compatibility. The Ossie file embeds the Snowflake 3-part source names; if the Databricks names match (case-insensitively), no rewrite is needed.

---

## The shim (ossie_shim.py) — full current source

This is the most important artifact. It bridges the Snowflake ↔ Apache converter format differences and handles all the discovered edge cases. The inlined copy in notebook 2's shim cell should always match this file.

```python
# Licensed under Apache-2.0 (this file is original to the demo, not from apache/ossie).
"""Bridge between Snowflake's Ossie dialect and the Apache Ossie Databricks converter.

Why this exists
---------------
Snowflake's SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW emits Ossie **0.1.1** and the
vendored Apache converter tracks **0.2.0.dev0** (an exact-match check). The two spec
revisions differ in three concrete ways that this module reconciles:

1. version string           0.1.1                 <->  0.2.0.dev0
2. expression dialect       SNOWFLAKE             <->  ANSI_SQL / DATABRICKS
3. metric placement         dataset custom_ext    <->  model-level `metrics`

Item (3) is the load-bearing one: Snowflake stores metrics inside
`datasets[*].custom_extensions[SNOWFLAKE].data` as a JSON blob, while the Apache
converter reads a top-level `metrics` list. Without hoisting, the generated Metric
View has no measures at all.

The transforms are deliberately narrow and reversible so the interop story stays
honest: the semantic content (names, expressions, relationships) is untouched; only
the envelope (version tag, dialect label, metric location) is adapted.
"""

import json
import re

import yaml

CONVERTER_OSSIE_VERSION = "0.2.0.dev0"   # what the vendored Apache converter requires
SNOWFLAKE_OSSIE_VERSION = "0.1.1"        # what Snowflake emits / expects on import
SNOWFLAKE_DIALECT = "SNOWFLAKE"
ANSI_DIALECT = "ANSI_SQL"
DATABRICKS_DIALECT = "DATABRICKS"


def _relabel_dialects(expression_obj, frm, to):
    """Relabel every `dialect: <frm>` to `<to>` inside an Ossie expression object."""
    if not isinstance(expression_obj, dict):
        return
    for d in expression_obj.get("dialects", []) or []:
        if d.get("dialect") == frm:
            d["dialect"] = to


def snowflake_to_converter(ossie_yaml, drop_fact_fields=True):
    """Snowflake Ossie 0.1.1  ->  Apache-converter-ready Ossie 0.2.0.dev0."""
    root = yaml.safe_load(ossie_yaml)
    root["version"] = CONVERTER_OSSIE_VERSION

    for model in root.get("semantic_model", []) or []:
        hoisted = []
        for ds in model.get("datasets", []) or []:
            ds_name = ds.get("name", "")
            qual = re.compile(re.escape(ds_name) + r"\.", re.IGNORECASE)

            kept_ext = []
            for ext in ds.get("custom_extensions", []) or []:
                if ext.get("vendor_name") == SNOWFLAKE_DIALECT:
                    blob = json.loads(ext.get("data") or "{}")
                    for m in blob.get("metrics", []) or []:
                        expr = qual.sub("", m["expr"])
                        hoisted.append({
                            "name": m["name"],
                            "expression": {
                                "dialects": [{"dialect": ANSI_DIALECT, "expression": expr}]
                            },
                        })
                else:
                    kept_ext.append(ext)
            if kept_ext:
                ds["custom_extensions"] = kept_ext
            else:
                ds.pop("custom_extensions", None)

            new_fields = []
            for f in ds.get("fields", []) or []:
                _relabel_dialects(f.get("expression"), SNOWFLAKE_DIALECT, ANSI_DIALECT)
                f.pop("custom_extensions", None)
                if drop_fact_fields and "dimension" not in f:
                    continue
                new_fields.append(f)
            if new_fields:
                ds["fields"] = new_fields
            else:
                ds.pop("fields", None)

        if hoisted:
            model["metrics"] = (model.get("metrics", []) or []) + hoisted

    return yaml.safe_dump(root, sort_keys=False)


def converter_to_snowflake(ossie_yaml, dialect=SNOWFLAKE_DIALECT, model_name=None):
    """Apache-converter Ossie 0.2.0.dev0  ->  Snowflake-importable Ossie 0.1.1."""
    root = yaml.safe_load(ossie_yaml)
    root["version"] = SNOWFLAKE_OSSIE_VERSION
    for model in root.get("semantic_model", []) or []:
        datasets = model.get("datasets", []) or []

        # Normalize dataset names to uppercase. Snowflake's importer resolves
        # metric table-qualifiers against dataset names case-sensitively, and
        # unquoted Snowflake identifiers are uppercase internally. Without this,
        # a lowercase dataset name (from a Databricks table named "orders")
        # causes "invalid identifier" errors on import.
        name_map = {}
        for ds in datasets:
            old_name = ds["name"]
            ds["name"] = old_name.upper()
            if old_name != ds["name"]:
                name_map[old_name] = ds["name"]
        for rel in model.get("relationships", []) or []:
            if "from" in rel:
                rel["from"] = rel["from"].upper()
            if "to" in rel:
                rel["to"] = rel["to"].upper()

        fact_ds_name = datasets[0]["name"] if datasets else None

        for ds in datasets:
            is_fact = ds.get("name") == fact_ds_name
            for f in ds.get("fields", []) or []:
                _relabel_dialects(f.get("expression"), DATABRICKS_DIALECT, dialect)
                if not is_fact:
                    f.setdefault("dimension", {})

        fact_cols = []
        ref_re = re.compile(re.escape(fact_ds_name) + r"\.([A-Za-z_]\w*)") if fact_ds_name else None
        for m in model.get("metrics", []) or []:
            _relabel_dialects(m.get("expression"), DATABRICKS_DIALECT, dialect)
            if not fact_ds_name:
                continue
            for d in (m.get("expression") or {}).get("dialects", []) or []:
                if "expression" in d:
                    for old, new in name_map.items():
                        d["expression"] = re.sub(
                            r"\b" + re.escape(old) + r"\.", new + ".", d["expression"])
                    d["expression"] = _qualify_columns(d["expression"], fact_ds_name)
                    for c in ref_re.findall(d["expression"]):
                        if c not in fact_cols:
                            fact_cols.append(c)

        if fact_ds_name and fact_cols:
            fact_ds = datasets[0]
            existing = {f["name"].lower() for f in fact_ds.get("fields", []) or []}
            flds = fact_ds.setdefault("fields", [])
            for c in fact_cols:
                if c.lower() not in existing:
                    flds.append({
                        "name": c.upper(),
                        "expression": {"dialects": [{"dialect": dialect, "expression": c}]},
                    })

        if model_name:
            model["name"] = model_name
    return yaml.safe_dump(root, sort_keys=False)


def _qualify_columns(expr, table):
    """Prefix each bare column with the fact table; skip function names and already-qualified names."""
    return re.sub(
        r"(?<![\w.])([A-Za-z_]\w*)(?!\s*\()(?![\w.])",
        lambda m: f"{table}.{m.group(1)}",
        expr,
    )
```

---

## Helper functions in the Databricks notebook

### `strip_unsupported_fields(mv_yaml_text)` — remove fields rejected by older Databricks serdes

Some Databricks workspace versions reject the `rely` join field (and potentially `cardinality`). The converter emits `rely` when a primary key covers the join columns. Strip it before creating the Metric View. Do NOT strip `cardinality` — it is semantic (determines join direction) and silently removing it would produce wrong results.

```python
import yaml

UNSUPPORTED_JOIN_FIELDS = ("rely",)

def strip_unsupported_fields(mv_yaml_text):
    mv = yaml.safe_load(mv_yaml_text)

    def clean(joins):
        for j in joins or []:
            for field in UNSUPPORTED_JOIN_FIELDS:
                j.pop(field, None)
            clean(j.get("joins"))

    clean(mv.get("joins"))
    return yaml.safe_dump(mv, sort_keys=False)
```

Apply after conversion:
```python
mv_yaml = convert_ossie_to_metric_view(converter_ready)
mv_yaml = mv_yaml.replace(SF_NAMESPACE, DBX_NAMESPACE)
mv_yaml = strip_unsupported_fields(mv_yaml)
```

### `create_metric_view(fqname, yaml_body)` — create or replace a Metric View

Must NOT use f-strings for the YAML body (YAML can contain `{}` braces that break Python f-string parsing). Use concatenation.

```python
def create_metric_view(fqname, yaml_body):
    spark.sql("CREATE OR REPLACE VIEW " + fqname + " WITH METRICS LANGUAGE YAML AS $$\n" + yaml_body + "\n$$")
```

### `get_metric_view_yaml(metric_view_name)` — read the deployed YAML back from Databricks

Used for the reverse trip. Reads from `SHOW CREATE TABLE` and parses between the `$$` delimiters.

```python
def get_metric_view_yaml(metric_view_name):
    ddl = spark.sql(f"SHOW CREATE TABLE {metric_view_name}").collect()[0][0]
    start = ddl.index("$") + 2
    end = ddl.index("$", start)
    return ddl[start:end].strip()
```

---

## Snowflake SQL patterns

### Export Ossie to stage

```sql
-- Write to an internal stage (for current demo)
COPY INTO @{{DATABASE}}.{{SCHEMA}}.INTEROP_STAGE/ossie_from_snowflake.yaml
FROM (SELECT SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW('{{DATABASE}}.{{SCHEMA}}.SALES_SV'))
FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
               ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE)
SINGLE = TRUE OVERWRITE = TRUE;

-- For S3 (next iteration): same syntax, different stage pointing at s3://
```

### Read an Ossie file from stage into a variable

```sql
CREATE FILE FORMAT IF NOT EXISTS {{DATABASE}}.{{SCHEMA}}.RAW_TEXT_FMT
  TYPE = 'CSV' FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE ESCAPE_UNENCLOSED_FIELD = NONE;

SET yaml_content = (
  SELECT $1 FROM @{{DATABASE}}.{{SCHEMA}}.INTEROP_STAGE/ossie_from_databricks.yaml
  (FILE_FORMAT => '{{DATABASE}}.{{SCHEMA}}.RAW_TEXT_FMT')
);
```

### Import Ossie as a Semantic View (with target-name choice)

```sql
SET target_view = 'SALES_SV_V2';                    -- change to rename; default = new view, no overwrite
SET yaml_to_import = (SELECT REPLACE($yaml_content, 'SALES_SV_V2', $target_view));
CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_OSSIE_YAML('{{DATABASE}}.{{SCHEMA}}', $yaml_to_import);
```

The proc REPLACES existing views of the same name silently. Default `SALES_SV_V2` leaves the original `SALES_SV` untouched.

### Verify with IDENTIFIER (needs fully-qualified name)

```sql
SET target_fqn = '{{DATABASE}}.{{SCHEMA}}.' || $target_view;
SELECT * FROM SEMANTIC_VIEW(
  IDENTIFIER($target_fqn)
  DIMENSIONS region
  METRICS total_quantity, total_order_amount, order_count
) ORDER BY region;
```

Note: `IDENTIFIER($var)` requires the variable to hold a FULLY-QUALIFIED 3-part name. Using a bare name without the db.schema prefix silently resolves against the current schema context.

### Check if a view exists (SHOW LIKE doesn't accept variables)

```sql
-- This does NOT work: SHOW SEMANTIC VIEWS LIKE $target_view   <- syntax error
-- Use this instead:
SHOW SEMANTIC VIEWS IN SCHEMA {{DATABASE}}.{{SCHEMA}};
SELECT "name" AS existing_view FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()))
WHERE "name" = $target_view;
```

---

## Bugs / edge cases discovered and fixed

### 1. `rely` field rejected by older Databricks serdes

The Apache converter emits `rely.at_most_one_match: true` on joins where a primary key covers the join columns. Older Databricks workspace versions (serde.v11) only accept `name`, `source`, `on`, `using`, `joins` and reject `rely`. Fix: `strip_unsupported_fields()` above.

Do NOT strip `cardinality` — it's semantic. Let that one fail loudly so you know the model needs reshaping.

### 2. Backslash doubling during file transfer

Moving the Ossie file between platforms (download from Snowflake stage, upload to Databricks workspace folder) can double the backslashes in `custom_extensions` JSON strings: `data: "{\"access_modifier\":...}"` becomes `data: "{\\"access_modifier\\":...}"`, which is invalid YAML.

Fix applied in notebook 2's file-read cell:
```python
try:
    yaml.safe_load(ossie_v1)
except yaml.YAMLError:
    ossie_v1 = ossie_v1.replace('\\\\', '\\')
    yaml.safe_load(ossie_v1)  # raises if still malformed
```

This is a no-op on clean files (no `\\` present). For S3-based transfer, this corruption may not occur (binary copy rather than text copy through editors), but keeping the guard costs nothing.

### 3. Case sensitivity for dataset names

If Databricks tables are named lowercase (e.g. `orders`), the reverse converter produces a lowercase dataset name in the Ossie. Snowflake's importer resolves metric table-qualifiers case-sensitively and fails with "invalid identifier" when the dataset name is lowercase.

Fix in `converter_to_snowflake`: uppercase all dataset names, relationship from/to, and fix existing lowercase qualifiers in metric expressions via the `name_map`. This fix is in the current shim above.

### 4. Metrics not at model level in Snowflake's Ossie export

Snowflake's `SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW` stores metrics inside `datasets[*].custom_extensions[SNOWFLAKE].data` as a JSON blob. The Apache converter reads a model-level `metrics` list. Without hoisting, the Metric View has zero measures.

Fix: `snowflake_to_converter()` extracts and hoists them. This is the load-bearing transformation.

### 5. Fact columns need to be declared AND metric columns qualified

On the reverse trip, the Snowflake importer needs:
- Fact columns declared as fields on the fact dataset (no `dimension` marker).
- Metric expressions qualified with the logical table name: `COUNT(ORDERS.order_id)`, not just `COUNT(order_id)`.

The `converter_to_snowflake()` function handles both: it collects fact column references from metric expressions (post-qualification) and rebuilds them as fields.

### 6. Dimension markers required

Joined-table fields need `dimension: {}` in the Ossie so Snowflake classifies them as dimensions, not facts. The `converter_to_snowflake()` function adds this automatically for all non-fact datasets.

---

## S3 extension plan (next session goal)

The current demo moves files manually. The S3 extension makes the Ossie files automatically available to both platforms via shared storage.

### Architecture

```
Snowflake external stage --> S3 bucket <-- Databricks external location
         COPY INTO                              dbutils.fs / spark.read
```

### Snowflake side: external stage

1. Create a storage integration (needs ACCOUNTADMIN):
```sql
CREATE STORAGE INTEGRATION ossie_s3_int
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_ALLOWED_LOCATIONS = ('s3://your-bucket/ossie/');
```

2. Note the IAM role ARN from `DESC INTEGRATION ossie_s3_int` → add trust policy on the S3 bucket's IAM role.

3. Create the external stage:
```sql
CREATE STAGE ossie_s3_stage
  URL = 's3://your-bucket/ossie/'
  STORAGE_INTEGRATION = ossie_s3_int
  FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE COMPRESSION = NONE);
```

4. Export Ossie to S3 (same COPY INTO, different stage):
```sql
COPY INTO @ossie_s3_stage/ossie_from_snowflake.yaml
FROM (SELECT SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW('DEMOS.SEMANTIC_INTEROP.SALES_SV'))
FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
               ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE)
SINGLE = TRUE OVERWRITE = TRUE;
```

### Databricks side: external location

Configure an external location in Unity Catalog pointing at the same S3 bucket. Requires a service credential (IAM role or storage credential) in your Databricks metastore.

```sql
-- In Databricks SQL:
CREATE EXTERNAL LOCATION ossie_s3
  URL 's3://your-bucket/ossie/'
  WITH (STORAGE CREDENTIAL your_credential);
```

Read the Ossie file from S3 in the notebook:
```python
ossie_v1 = dbutils.fs.head("s3://your-bucket/ossie/ossie_from_snowflake.yaml")
# or
ossie_v1 = spark.read.text("s3://your-bucket/ossie/ossie_from_snowflake.yaml").collect()[0][0]
```

Write the reverse Ossie back to S3:
```python
dbutils.fs.put("s3://your-bucket/ossie/ossie_from_databricks.yaml", ossie_v2, overwrite=True)
```

Snowflake then reads it:
```sql
SET yaml_content = (
  SELECT $1 FROM @ossie_s3_stage/ossie_from_databricks.yaml
  (FILE_FORMAT => 'DEMOS.SEMANTIC_INTEROP.RAW_TEXT_FMT')
);
```

### Permissions to sort out

- S3 bucket must allow both the Snowflake storage integration IAM role and the Databricks service credential role.
- For Snowflake: `GET INTEGRATION snowflake_s3_iam_role` from `DESC STORAGE INTEGRATION` and add a trust relationship for Snowflake's account ID + external ID.
- For Databricks: depends on whether you use instance profile, service principal, or Unity Catalog storage credential.

### Key design note

The Ossie files are plain YAML text, not binary. Both platforms can read and write them with no encoding concerns. The backslash-doubling issue (bug #2 above) may not occur via S3 binary copy, but keep the guard in the notebook anyway.

---

## Documentation links

| Topic | URL |
|-------|-----|
| Snowflake Ossie export function | https://docs.snowflake.com/en/sql-reference/functions/system_read_ossie_yaml_from_semantic_view |
| Snowflake Ossie import procedure | https://docs.snowflake.com/en/sql-reference/stored-procedures/system_create_semantic_view_from_ossie_yaml |
| Snowflake Semantic View DDL | https://docs.snowflake.com/en/sql-reference/sql/create-semantic-view |
| Snowflake Semantic View overview | https://docs.snowflake.com/en/user-guide/views-semantic/overview |
| Apache Ossie repo | https://github.com/apache/ossie |
| Ossie Databricks converter README | https://github.com/apache/ossie/blob/main/converters/databricks/README.md |
| Databricks Metric View overview | https://docs.databricks.com/aws/en/business-semantics/metric-views/ |
| Databricks Metric View YAML reference | https://docs.databricks.com/aws/en/business-semantics/metric-views/yaml-reference |
| Databricks CREATE VIEW ... WITH METRICS | https://docs.databricks.com/aws/en/metric-views/create/sql |
| Databricks external locations | https://docs.databricks.com/aws/en/connect/unity-catalog/external-locations.html |
| Snowflake external stages (S3) | https://docs.snowflake.com/en/user-guide/data-load-s3-create-stage |
| Snowflake storage integrations | https://docs.snowflake.com/en/sql-reference/sql/create-storage-integration |
| Snowflake Notebooks variable reference | https://docs.snowflake.com/en/user-guide/ui-snowsight/notebooks-develop-run (see "Referencing variables in SQL code") |

---

## Vendored converter details

The Apache Ossie Databricks converter is vendored (not pip-installed) at `ossie_converter/`. Key internal facts:

- `OSSIE_VERSION = "0.2.0.dev0"` in `_common.py` — exact-match check; if this changes, the shim's `CONVERTER_OSSIE_VERSION` constant must be updated.
- Pinned commit: `01058aa416423cf43a74e7f9fb7f5f70981a418e` (recorded in `ossie_converter/.pinned_commit` and `SOURCE.md`).
- Package is **not on PyPI** (confirmed). On Databricks, install via:
  ```
  %pip install "git+https://github.com/apache/ossie.git@01058aa416423cf43a74e7f9fb7f5f70981a418e#subdirectory=converters/databricks"
  ```
  Import name: `ossie_databricks` (not `ossie_converter`). If cluster has no internet, upload `ossie_converter/` to workspace folder and `sys.path.insert(0, FOLDER)`.

---

## Git status

The local repo at `/Users/began/Dev/cortex_cli/demos/interoperable_semantics/` has a single commit `first commit` on branch `main`. Remote is set to `https://github.com/Snowflake-Solutions/interoperable_semantics.git`. The push never ran — to complete it:

```bash
cd /Users/began/Dev/cortex_cli/demos/interoperable_semantics
git push -u origin main
```

The commit includes `interoperable_semantics_client.zip` which should probably be gitignored before pushing. Add `*.zip` to `.gitignore` and `git rm --cached interoperable_semantics_client.zip` if you want to exclude it.

---

## Suggested skills for the new session

- **`iceberg`** — for the S3/external stage and external location setup on both platforms.
- **`integrations`** — for creating the Snowflake storage integration pointed at S3.
- **`snowflake-workspace`** — if deploying or syncing notebooks to/from a Snowflake workspace.
- **`sql-author`** — for writing/debugging new SQL cells in the notebooks.
- **`snowpark-python`** — if the S3 workflow needs Python-side orchestration.

---

*This handoff was generated at the end of the interoperable semantics build session. The full conversation history is in the CoCo session archive if detail is needed on any decision.*
