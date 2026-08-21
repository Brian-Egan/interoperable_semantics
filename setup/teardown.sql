/*
 * Teardown Script: Interoperable Semantics Demo
 *
 * Removes all Snowflake objects created by snowflake_setup.sql.
 * Run with ACCOUNTADMIN role.
 *
 * Note: This does NOT remove AWS or Databricks resources.
 * See SETUP.md "Teardown" section for those commands.
 */

USE ROLE ACCOUNTADMIN;

-- Suspend and drop the sync task
ALTER TASK IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.OSSIE_SYNC_TASK SUSPEND;
DROP TASK IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.OSSIE_SYNC_TASK;

-- Drop semantic views
DROP SEMANTIC VIEW IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.SALES_SV;
DROP SEMANTIC VIEW IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.SALES_SV_V2;

-- Drop Iceberg tables
DROP ICEBERG TABLE IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.CUSTOMERS;
DROP ICEBERG TABLE IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.ORDERS;

-- Drop stage and file format
DROP STAGE IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.OSSIE_S3_STAGE;
DROP FILE FORMAT IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.RAW_TEXT_FMT;

-- Drop external volume
DROP EXTERNAL VOLUME IF EXISTS OSSIE_ICEBERG_VOL;

-- Drop storage integration
DROP STORAGE INTEGRATION IF EXISTS OSSIE_S3_INT;

-- Drop schema (only if empty or you want full cleanup)
DROP SCHEMA IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP;

-- Optionally drop the database if nothing else lives there:
-- DROP DATABASE IF EXISTS DEMOS;
