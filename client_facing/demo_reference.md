---

## Technical Reference: Snowflake ↔ Ossie ↔ Databricks Interoperability Demo

This document provides the technical components, API surfaces, and documentation references needed to build a demo. You (the demo agent) own sequencing, dataset design, narrative, and code authoring.

---

### 1. Snowflake: Semantic View Creation

**What it is:** A schema-level object that models business metrics, dimensions, relationships, and facts over physical tables.

**Documentation:**
- Overview: https://docs.snowflake.com/en/user-guide/views-semantic/overview
- DDL authoring: https://docs.snowflake.com/en/user-guide/views-semantic/sql
- CREATE SEMANTIC VIEW syntax: https://docs.snowflake.com/en/sql-reference/sql/create-semantic-view
- Full TPC-H example: https://docs.snowflake.com/en/user-guide/views-semantic/example
- YAML vs DDL comparison: https://docs.snowflake.com/en/user-guide/views-semantic/yaml-vs-ddl

**DDL structure:**
```sql
CREATE SEMANTIC VIEW <db>.<schema>.<name>
  TABLES (...)
  RELATIONSHIPS (...)
  FACTS (...)
  DIMENSIONS (...)
  METRICS (...)
  COMMENT = '...';
```

**Required privileges:** `CREATE SEMANTIC VIEW` on schema, `SELECT` on referenced tables.

---

### 2. Snowflake: Export Semantic View → Ossie YAML

**System function:** `SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW`  
**Status:** Preview Feature — Open (all accounts)  
**Documentation:** https://docs.snowflake.com/en/sql-reference/functions/system_read_ossie_yaml_from_semantic_view

**Syntax:**
```sql
SELECT SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW('<db>.<schema>.<view_name>');
```

**Returns:** VARCHAR containing Ossie YAML (version `0.1.1`, `semantic_model` array with one entry).

**Snowflake → Ossie mapping:**
| Snowflake | Ossie |
|---|---|
| tables | datasets |
| base_table (table ref) | datasets[*].source (dotted name) |
| primary_key.columns | datasets[*].primary_key |
| dimensions | fields with `dimension.is_time: false` |
| time_dimensions | fields with `dimension.is_time: true` |
| facts | fields without dimension marker |
| metrics | metrics (model-level) |
| relationships (EQUI only) | relationships |
| Snowflake-only features | `custom_extensions[SNOWFLAKE]` |

**Preserved in custom_extensions[SNOWFLAKE]:** synonyms, custom_instructions, verified_queries, variables, tags, sample_values, is_enum, cortex_search_service, non_additive_dimensions, max_staleness.

**Dropped:** Non-EQUI relationships (ASOF, RANGE), field labels, data types, multi-dialect expressions (only SNOWFLAKE dialect returned).

---

### 3. Snowflake: Import Ossie YAML → Semantic View

**Stored procedure:** `SYSTEM$CREATE_SEMANTIC_VIEW_FROM_OSSIE_YAML`  
**Documentation:** https://docs.snowflake.com/en/sql-reference/stored-procedures/system_create_semantic_view_from_ossie_yaml

**Syntax:**
```sql
CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_OSSIE_YAML(
  '<db>.<schema>',
  $$<ossie_yaml_string>$$
);
```

**Expression dialect priority:** SNOWFLAKE > ANSI_SQL. Fields with only unsupported dialects are silently omitted.

---

### 4. Apache Ossie Databricks Converter

**Repository:** https://github.com/apache/ossie  
**Converter directory:** `converters/databricks/`  
**Runtime requirements:** Python 3.11+, PyYAML (sole dependency). Pure offline — no Databricks connection needed.

**Installation:**
```bash
pip install -e converters/databricks/   # from repo checkout
# or: pip install apache-ossie-databricks  (once published)
```

#### 4a. Export: Ossie → Databricks Metric View

**CLI:**
```bash
ossie-databricks export -i model.yaml -o view.yaml [--source <fact_dataset>]
```

**Python API:**
```python
from ossie_databricks import convert_ossie_to_metric_view
metric_view_yaml = convert_ossie_to_metric_view(ossie_yaml_str, source="orders")
```

**Function:** `convert_ossie_to_metric_view(ossie_yaml_str, source=None)` — `converters/databricks/src/ossie_databricks/ossie_to_metric_view.py:62`

**`--source` behavior:** Names the dataset to use as the Metric View's fact/grain. When omitted, auto-selects the dataset that is never a relationship `to` target (the FK-sink). Naming a coarser-grain dataset unlocks `one_to_many` joins.

**Mapping (Ossie → Metric View v1.1):**
| Ossie | Metric View |
|---|---|
| root dataset | `source` (3-part table name or subquery) |
| other datasets | nested `joins[]` |
| from_columns/to_columns | `on` (differing names) or `using` (shared names) |
| from/to direction | `cardinality` (many_to_one implicit default; one_to_many explicit) |
| primary_key/unique_keys | `rely.at_most_one_match` |
| fields across all datasets | flat `dimensions[]` (joined columns qualified by join path: `customer.c_name`) |
| metrics | `measures[]` (fact columns bare: `SUM(amount)`) |
| field.label | `display_name` |
| description | `comment` |
| ai_context.synonyms | `synonyms` |

**Dropped with warnings:** `dimension.is_time`, non-DATABRICKS/ANSI_SQL dialects, foreign-vendor custom_extensions, relationship ai_context, dataset descriptions.

**Errors (ConversionError):** Cyclic graph, multiple candidate facts without `--source`, non-3-part source name (unless subquery), duplicate dataset names.

#### 4b. Import: Databricks Metric View → Ossie

**CLI:**
```bash
ossie-databricks import -i view.yaml -o model.yaml [--name <model_name>]
```

**Python API:**
```python
from ossie_databricks import convert_metric_view_to_ossie
ossie_yaml = convert_metric_view_to_ossie(mv_yaml_str, model_name="my_model")
```

**Function:** `convert_metric_view_to_ossie(mv_yaml_str, model_name=None)` — `converters/databricks/src/ossie_databricks/metric_view_to_ossie.py:75`

**Round-trip preservation:** Metric View features without native Ossie fields (`filter`, `window`, `format`, `rely`, `cardinality`, `parameters`, `materialization`) are stashed in `custom_extensions[DATABRICKS]`. Converting back (`import` → `export`) restores them losslessly.

**Errors:** Non-equi join conditions, cross joins (no `on`/`using`), duplicate join names, `source` as a join name, Metric View version != `1.1`.

---

### 5. Data Mirroring Requirement

The demo requires the same underlying tables to exist in both Snowflake and Databricks Unity Catalog so that the converted Metric View YAML is deployable against real data.

**Options to evaluate:**

| Approach | How | Tradeoffs |
|---|---|---|
| TPC-H in both | Snowflake: `SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.*`. Databricks: use `tpch` generator via `dbutils` or pre-load Parquet. | Simplest; data is identical; no sync needed. |
| Iceberg shared storage | Write Iceberg tables from Snowflake, read from Databricks via Unity Catalog external tables over the same S3/GCS path. | Shows real interop but adds infra complexity. |
| Delta Sharing | Publish from Databricks via Delta Sharing, consume in Snowflake (or vice versa). | Adds a sharing demo angle but conflates the narrative. |
| Simple Parquet copy | Export from Snowflake to stage → S3 → Databricks external table. | Low complexity, one-time setup. |

**Recommendation for demo simplicity:** Use TPC-H data natively available on both sides. Databricks has built-in sample datasets (`samples.tpch.*`) or you can generate via `spark.range`. Snowflake has `SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.*`. The table names in the generated Metric View YAML will reference Snowflake's catalog names (`SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS`) — the demo agent should plan a **source rewriting step** (sed/Python string replace) to map these to the Databricks catalog path (e.g., `samples.tpch.orders` or `demo_catalog.tpch.orders`).

---

### 6. Where to Run the Ossie Converter

The converter is pure Python (PyYAML only). It does not need a Databricks or Snowflake connection. Options:

| Option | Pros | Cons |
|---|---|---|
| **Snowflake Notebook (Python cell)** | Runs in Snowflake UI, easy to show alongside the semantic view. Can `pip install` from a stage or git repo. | Audience sees it as "Snowflake doing the work" rather than neutral. |
| **Local Python / CI script** | Simplest. Shows the converter is vendor-neutral. | Less "demo-able" in a live setting. |
| **Snowpark Container Services** | Could wrap it as a service/function, but massive overkill for a 50ms conversion. | Over-engineering; deployment complexity distracts from the point. |
| **Snowflake Stored Procedure (Python)** | Package the converter as a UDF/procedure, call it inline with SQL. | Good for automation; requires staging the package. |

**Recommendation:** A **Snowflake Notebook with a Python cell** is the best demo vehicle. It lets you run the Snowflake SQL (Steps 1-2) and the Python conversion (Steps 3-4) in one artifact. Install the converter with `!pip install /path/to/ossie-databricks` or inline the code.

---

### 7. Databricks Execution: Deploying and Validating the Metric View

This is the portion that requires planning. A Databricks Metric View is defined as a YAML file and deployed to Unity Catalog.

**Databricks Metric View documentation:** https://docs.databricks.com/aws/en/metric-views/

**Deployment options:**

| Method | How |
|---|---|
| **Databricks CLI** | `databricks metric-views create --json '{"name": "...", "catalog": "...", "schema": "...", "definition": "<yaml_content>"}'` |
| **REST API** | `POST /api/2.1/unity-catalog/metric-views` with the YAML payload in the request body. |
| **Databricks Notebook (SQL)** | `CREATE METRIC VIEW <catalog>.<schema>.<name> AS '<yaml_content>'` (if SQL syntax is supported in your workspace version). |
| **Databricks Asset Bundles (DABs)** | Define the metric view YAML as a resource in a `databricks.yml` bundle and deploy with `databricks bundle deploy`. Most production-grade approach. |

**What the demo agent needs to design:**
1. **Catalog/schema target** — Where in Unity Catalog to deploy (e.g., `demo_catalog.tpch_interop.tpch_metric_view`).
2. **Source name rewriting** — The exported YAML will have Snowflake-style 3-part names (`SNOWFLAKE_SAMPLE_DATA.TPCH_SF1.ORDERS`). These must be rewritten to Databricks catalog paths before deployment.
3. **Dialect consideration** — The Snowflake export emits `SNOWFLAKE` dialect expressions. The Ossie→Metric View converter prefers `DATABRICKS` dialect, then falls back to `ANSI_SQL`. If expressions use Snowflake-specific SQL functions (e.g., `YEAR(x)`), they may need translation for Databricks execution. For TPC-H with simple column references and standard aggregates, this is usually fine.
4. **Validation** — After deployment, query the metric view in Databricks to confirm dimensions and measures resolve correctly against the underlying tables.

**Authentication:** The demo will need a Databricks workspace with Unity Catalog enabled, a service principal or PAT for API calls, and a catalog where the demo user has CREATE METRIC VIEW privileges.

---

### 8. Open Questions for the Demo Agent to Resolve

- **Dataset choice:** TPC-H is safe and universally available. Does the client narrative benefit from a different domain (e.g., retail, ad-tech)?
- **Live Databricks execution:** Will the demo execute against a real Databricks workspace, or mock the Databricks side with the YAML output shown as "what you'd deploy"?
- **Reverse direction:** Should the demo also show starting from a Databricks Metric View and importing into Snowflake (full bidirectional), or is Snowflake→Databricks sufficient?
- **Source rewriting strategy:** Automated (Python function that maps catalog names) or manual (show the diff as a talking point about multi-cloud catalog differences)?