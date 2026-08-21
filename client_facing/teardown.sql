-- Interop demo teardown. Reverses everything the demo created.
-- Run on the coco_demo connection with a role that owns the objects (ACCOUNTADMIN).

USE ROLE ACCOUNTADMIN;

-- Semantic views (original + round-tripped; add any SALES_SV_V3+ you created).
DROP SEMANTIC VIEW IF EXISTS DEMOS.SEMANTIC_INTEROP.SALES_SV;
DROP SEMANTIC VIEW IF EXISTS DEMOS.SEMANTIC_INTEROP.SALES_SV_V2;

-- Stage, file format, tables.
DROP STAGE IF EXISTS DEMOS.SEMANTIC_INTEROP.INTEROP_STAGE;
DROP FILE FORMAT IF EXISTS DEMOS.SEMANTIC_INTEROP.RAW_TEXT_FMT;
DROP TABLE IF EXISTS DEMOS.SEMANTIC_INTEROP.ORDERS;
DROP TABLE IF EXISTS DEMOS.SEMANTIC_INTEROP.CUSTOMERS;

-- Drop the whole schema (removes anything else created under it).
DROP SCHEMA IF EXISTS DEMOS.SEMANTIC_INTEROP;

-- ---------------------------------------------------------------------------
-- Databricks side (run in a Databricks SQL editor / notebook, not Snowflake).
-- Uses catalog `demos` to match Snowflake; change if you used a different catalog.
-- ---------------------------------------------------------------------------
-- DROP VIEW   IF EXISTS demos.semantic_interop.sales_metric_view;
-- DROP TABLE  IF EXISTS demos.semantic_interop.orders;
-- DROP TABLE  IF EXISTS demos.semantic_interop.customers;
-- DROP SCHEMA IF EXISTS demos.semantic_interop;
