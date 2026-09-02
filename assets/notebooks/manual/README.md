# Demo flow (manual sync)

The interop story moved by hand, one step at a time, so an audience can see each crossing.
Nothing runs on a schedule here. For the automated version see `../bidirectional` (the
live flow); for read-only downstream mirrors see `../unidirectional`.

## Run order

The notebooks are numbered within each platform, so the order alternates between them:

| Step | Notebook | Platform |
|---|---|---|
| 1 | `Snowflake/01_setup` | Snowflake |
| 2 | `Snowflake/02_demo_and_export` | Snowflake |
| 3 | `DBX/01_ossie_to_metric_view` | Databricks |
| 4 | `Snowflake/03_import_from_ossie` | Snowflake |

Step 1 creates the semantic view. Step 2 shows the data and the model, then exports Ossie
to S3. Step 3 builds the Metric View from that file, adds `TOTAL_QUANTITY`, and exports
back. Step 4 imports the Databricks change into Snowflake.

## Where things live

| Object | Location |
|---|---|
| Semantic view, stage, tasks | `DEMOS.DEMO_SEMANTIC_INTEROP` |
| Metric view | `demos.demo_semantic_interop` |
| Iceberg tables, external volume | `DEMOS.EXT_SEMANTIC_INTEROP` (shared) |
| Ossie files | `s3://<bucket>/ossie/demo/` |

Each flow owns a schema and an S3 prefix, so all three can be set up at once and a live
sync running in the background cannot overwrite the file this demo just produced.

The Iceberg tables are deliberately shared rather than duplicated per flow. Snowflake
appends a random suffix to each table's base location, and the Databricks notebooks
discover tables by scanning `iceberg/` for those suffixes. A second copy of `CUSTOMERS`
would put a second `customers.<suffix>/` under the same prefix, and the discovery would
match both and keep whichever the listing happened to return last.

## Numbers to expect

| Region | Amount | Orders | Quantity |
|---|---|---|---|
| EAST | 750 | 5 | 12 |
| WEST | 700 | 5 | 11 |

Quantity only appears after step 3, since `TOTAL_QUANTITY` is the measure added in
Databricks.

## Showing an empty stage

Directory tables do not auto-refresh on these stages. If you want to show the stage empty
and then watch the Ossie file arrive, run `ALTER STAGE ... REFRESH` after deleting the
file, or the deleted file will still be listed. The same applies after an export: the
`DIRECTORY()` view will not show the new file until a refresh, though `LIST` reads live.

## A known limitation

Synonyms travel from Snowflake into the Databricks Metric View, where they are visible and
editable, and they are preserved in the Ossie file on the way back. Snowflake's importer
does not currently register synonyms from an Ossie file in any form, verified against a
DDL-created control, so they will not reappear on an imported semantic view yet. This is a
platform gap rather than a limitation of the shim.

## Prerequisites

`setup/snowflake_setup.sql` must have been run once for the account, and the AWS IAM trust
policy must allow both the storage integration and the external volume. Do not run that
script by hand: point Cortex Code at `setup/COCO_SETUP_GUIDE.md`, which sequences the
Snowflake, AWS and Databricks sides together.
