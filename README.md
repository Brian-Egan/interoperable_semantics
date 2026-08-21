# Interoperable Semantics: Snowflake + Databricks via Apache Ossie

Bidirectional semantic model interoperability between Snowflake Semantic Views and Databricks Metric Views, using [Apache Ossie](https://github.com/apache/ossie) as the interchange format and S3 as the shared transport layer.

## What This Demonstrates

1. **Shared physical data** -- Snowflake-managed Iceberg tables on S3, readable by both platforms without data duplication
2. **Semantic model exchange** -- A Snowflake Semantic View exports to Ossie YAML, which Databricks converts into a Metric View (and vice versa)
3. **Continuous sync** -- Background tasks (suspended by default) on both platforms poll the shared S3 bucket every minute, keeping views in sync during a live demo

## Architecture

```
┌─────────────────────────────────────────────────────────────────────┐
│                    S3: <your-bucket>                                │
│                                                                     │
│   ossie/                          iceberg/                          │
│   ├── ossie_from_snowflake.yaml   ├── customers/ (Parquet + meta)   │
│   └── ossie_from_databricks.yaml  └── orders/    (Parquet + meta)   │
└──────────────┬──────────────────────────────────┬───────────────────┘
               │                                  │
    ┌──────────┴──────────┐            ┌──────────┴──────────┐
    │   Snowflake         │            │   Databricks        │
    │                     │            │                     │
    │ External Stage      │            │ External Location   │
    │ External Volume     │            │ Storage Credential  │
    │ Iceberg Tables      │            │ Iceberg Table Read  │
    │ Semantic View       │            │ Metric View         │
    │ Sync Task (1 min)   │            │ Sync Job (1 min)    │
    └─────────────────────┘            └─────────────────────┘
```

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

## Setup (New Environment)

For a fresh setup on a new Snowflake/AWS/Databricks account, see
[`setup/SETUP.md`](setup/SETUP.md). It walks through creating the S3 bucket,
IAM roles, Snowflake objects, and Databricks configuration from scratch.

The Snowflake setup script is at [`setup/snowflake_setup.sql`](setup/snowflake_setup.sql).
Teardown is at [`setup/teardown.sql`](setup/teardown.sql).

## Quick Start (After Setup)

### 1. Infrastructure (run once)

The Snowflake notebook `01_snowflake_setup_and_export.ipynb` creates:
- Semantic View over the pre-existing Iceberg tables
- Initial Ossie export to S3
- A suspended sync task (enable during demo)

### 2. Databricks Conversion

The Databricks notebook `02_databricks_ossie_to_metric_view.ipynb`:
- Reads the Ossie YAML from S3
- Converts it to a Databricks Metric View using the Apache Ossie converter
- Adds a new metric (`total_quantity`) on the Databricks side
- Exports the updated model back to S3 as Ossie YAML
- Includes a suspended sync job (enable during demo)

### 3. Round-Trip Import

The Snowflake notebook `03_snowflake_import_from_ossie.ipynb`:
- Reads the Databricks-exported Ossie from S3
- Imports it as a new Semantic View (`SALES_SV_V2`)
- Verifies the new metric appears and returns correct results

## Background Sync Tasks

Both platforms include a background task that runs every 1 minute when enabled:

- **Snowflake**: `DEMOS.EXT_SEMANTIC_INTEROP.OSSIE_SYNC_TASK` -- exports the latest semantic view to S3 and imports the latest Databricks export
- **Databricks**: Scheduled workflow -- reads Ossie from S3, updates the metric view, exports back

These are **suspended by default**. Enable them during a live demo to show real-time sync, then disable immediately after.

## Project Structure

```
interoperable_semantics/
├── README.md                 (this file)
├── setup/
│   ├── SETUP.md              (full setup guide for new environments)
│   ├── snowflake_setup.sql   (creates all Snowflake objects)
│   └── teardown.sql          (removes all Snowflake objects)
├── client_facing/
│   ├── 01_snowflake_setup_and_export.ipynb
│   ├── 02_databricks_ossie_to_metric_view.ipynb
│   ├── 03_snowflake_import_from_ossie.ipynb
│   ├── ossie_converter/      (vendored Apache Ossie Databricks converter)
│   ├── data/                  (source CSVs for reference)
│   │   ├── customers.csv
│   │   └── orders.csv
│   └── README.md             (original client walkthrough)
└── .gitignore
```
