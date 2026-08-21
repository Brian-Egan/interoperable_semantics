# Interoperable Semantics: Snowflake and Databricks via Apache Ossie

Move a metric definition between a Snowflake Semantic View and a Databricks Unity
Catalog Metric View, using Apache Ossie (the Open Semantic Interchange format) as
the file that crosses between them. You run the same query on both platforms and
get the same numbers, then add a metric on the Databricks side and carry it back to
Snowflake.

You move two Ossie files by hand: one out of Snowflake into Databricks, and one back.

## What's in this folder

| Item | Purpose |
|------|---------|
| `01_snowflake_setup_and_export.ipynb` | Snowflake: load tables from CSV, create the semantic view, export it to Ossie on a stage. |
| `02_databricks_ossie_to_metric_view.ipynb` | Databricks: build the Metric View from the Ossie file, add a measure, export Ossie back. |
| `03_snowflake_import_from_ossie.ipynb` | Snowflake: import the Databricks Ossie file as a semantic view. |
| `data/customers.csv`, `data/orders.csv` | The shared demo data. Upload the same two files to both platforms. |
| `ossie_converter/` | A pinned copy of the Apache Ossie Databricks converter. Only needed as a fallback if your Databricks cluster cannot install it from the internet (see notebook 2, Step 1). |
| `teardown.sql` | Removes everything the demo created. |

## Set your database and schema

Each notebook has a config cell at the top. Set the database and schema (Snowflake)
and the catalog and schema (Databricks) to names your role can create objects in.
Use the same names on both platforms so the table references inside the Ossie file
resolve without editing. The examples use `DEMOS` / `SEMANTIC_INTEROP` on Snowflake
and `demos` / `semantic_interop` on Databricks.

If you cannot match the names on Databricks, notebook 2 rewrites the source names for
you; see its Step 2. No admin role is required on either side.

## The data

Four customers, ten orders, all integers, so results are easy to check:

| region | total_order_amount | order_count | total_quantity |
|--------|--------------------|-------------|----------------|
| EAST   | 750                | 5           | 12             |
| WEST   | 700                | 5           | 11             |

`total_quantity` is the measure you add in Databricks and carry back to Snowflake.

## Run order

### Part A: Snowflake setup and export (notebook 1)

1. Open `01_snowflake_setup_and_export.ipynb` in a Snowflake notebook and run the
   Step 1 config cell.
2. Create the stage, then upload `data/customers.csv` and `data/orders.csv` to it
   (Snowsight stage browser, or `snow stage copy`).
3. Run the create-tables and load steps. Check the result against the table above.
4. Create the semantic view, then open it in Cortex Analyst to see it the way an
   analyst would (Step 5 explains this).
5. Export the view. This writes `ossie_from_snowflake.yaml` to the stage. Download it.

### Part B: Databricks (notebook 2)

1. Upload `ossie_from_snowflake.yaml` and the two CSVs into the notebook's workspace
   folder.
2. Open `02_databricks_ossie_to_metric_view.ipynb`, run the config cell, and install
   the converter (Step 1).
3. Create the tables from the CSVs, then convert the Ossie file into a Metric View
   and query it. You should see EAST 750/5, WEST 700/5.
4. Add `TOTAL_QUANTITY`, in code or in the Metric View editor, then query again for
   EAST 12, WEST 11.
5. Export the updated view. This writes `ossie_from_databricks.yaml`. Download it.

### Part C: Snowflake import (notebook 3)

1. Upload `ossie_from_databricks.yaml` to the Snowflake stage.
2. Open `03_snowflake_import_from_ossie.ipynb`, run the config cell, and read the file.
3. Choose the target view name (see below), import, and verify. You should see
   EAST 12/750/5, WEST 11/700/5, matching Databricks.

## Creating the tables from CSV

Snowflake, from a stage (notebook 1):

```sql
COPY INTO CUSTOMERS
  FROM @<database>.<schema>.INTEROP_STAGE/customers.csv
  FILE_FORMAT = (TYPE = CSV SKIP_HEADER = 1 FIELD_OPTIONALLY_ENCLOSED_BY = '"');
```

Databricks, from the notebook folder (notebook 2):

```python
import pandas as pd
from pyspark.sql.types import StructType, StructField, IntegerType, StringType
schema = StructType([StructField('customer_id', IntegerType()),
                     StructField('customer_name', StringType()),
                     StructField('region', StringType())])
df = spark.createDataFrame(pd.read_csv(f'{FOLDER}/customers.csv'), schema=schema)
df.write.mode('overwrite').saveAsTable(f'{CATALOG}.{SCHEMA}.customers')
```

Explicit integer types on both sides keep the sums identical.

## Choosing whether to overwrite your semantic view

Importing an Ossie file creates a semantic view named after the model inside the
file, and replaces any existing view of that name. The file from Databricks names
its model `SALES_SV_V2`, so a plain import creates a second view and leaves your
original `SALES_SV` alone.

Notebook 3, Step 3 sets `target_view`. Leave it at `SALES_SV_V2` to keep both, set it
to `SALES_SV` to replace the original, or use `SALES_SV_V3` and so on to keep a
history. The cell before the import tells you whether a view of that name already
exists.

## Why the notebook needs a small shim

Snowflake reads and writes Ossie with built-in functions
(`SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW`, `SYSTEM$CREATE_SEMANTIC_VIEW_FROM_OSSIE_YAML`).
Databricks has no native Ossie functions yet, so notebook 2 uses the open-source
Apache converter, which tracks a later draft of the spec with a slightly different
layout. A small adapter in notebook 2 reconciles the version tag, the dialect label,
and where metrics sit. It changes the envelope, not the meaning of the model.

## Teardown

Run `teardown.sql` on Snowflake. It also has a commented Databricks block; uncomment
it and run it in a Databricks editor to drop the catalog objects there.
