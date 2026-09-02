/*
 * Teardown Script: Interoperable Semantics Demo
 *
 * Removes the Snowflake objects created by snowflake_setup.sql and by the three demo
 * flows. Run with ACCOUNTADMIN.
 *
 * This does NOT remove AWS or Databricks resources, and it does NOT delete the Ossie
 * files or Iceberg data on S3. See SETUP.md "Teardown" for those.
 *
 * Ordering matters: tasks before the views they touch, stages before their schemas, and
 * the external volume after the Iceberg tables that depend on it.
 */

USE ROLE ACCOUNTADMIN;

-- ===========================================================================
-- FLOW OBJECTS: tasks
-- ===========================================================================
-- Tasks must be suspended before they can be dropped if they are running.
ALTER TASK IF EXISTS DEMOS.DEMO_SEMANTIC_INTEROP.MONITOR_SV_CHANGES SUSPEND;
ALTER TASK IF EXISTS DEMOS.DEMO_SEMANTIC_INTEROP.MONITOR_OSSIE_IMPORT SUSPEND;
DROP TASK IF EXISTS DEMOS.DEMO_SEMANTIC_INTEROP.MONITOR_SV_CHANGES;
DROP TASK IF EXISTS DEMOS.DEMO_SEMANTIC_INTEROP.MONITOR_OSSIE_IMPORT;

ALTER TASK IF EXISTS DEMOS.LIVE_SEMANTIC_INTEROP.SYNC_OSSIE_TASK SUSPEND;
DROP TASK IF EXISTS DEMOS.LIVE_SEMANTIC_INTEROP.SYNC_OSSIE_TASK;

ALTER TASK IF EXISTS DEMOS.SNOWFLAKE_MANAGED_SEMANTIC_INTEROP.SYNC_OSSIE_TASK SUSPEND;
DROP TASK IF EXISTS DEMOS.SNOWFLAKE_MANAGED_SEMANTIC_INTEROP.SYNC_OSSIE_TASK;

-- Legacy name, from before each flow owned its own schema.
ALTER TASK IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.OSSIE_SYNC_TASK SUSPEND;
DROP TASK IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.OSSIE_SYNC_TASK;

-- ===========================================================================
-- FLOW OBJECTS: semantic views, stages, procedures
-- ===========================================================================
DROP SEMANTIC VIEW IF EXISTS DEMOS.DEMO_SEMANTIC_INTEROP.SALES_SV;
DROP SEMANTIC VIEW IF EXISTS DEMOS.DEMO_SEMANTIC_INTEROP.SALES_SV_V2;
DROP SEMANTIC VIEW IF EXISTS DEMOS.LIVE_SEMANTIC_INTEROP.SALES_SV;
DROP SEMANTIC VIEW IF EXISTS DEMOS.SNOWFLAKE_MANAGED_SEMANTIC_INTEROP.SALES_SV;

DROP STAGE IF EXISTS DEMOS.DEMO_SEMANTIC_INTEROP.DEMO_OSSIE_STAGE;
DROP STAGE IF EXISTS DEMOS.LIVE_SEMANTIC_INTEROP.LIVE_OSSIE_STAGE;
DROP STAGE IF EXISTS DEMOS.SNOWFLAKE_MANAGED_SEMANTIC_INTEROP.SNOWFLAKE_MANAGED_OSSIE_STAGE;

DROP FILE FORMAT IF EXISTS DEMOS.DEMO_SEMANTIC_INTEROP.RAW_TEXT_FMT;
DROP FILE FORMAT IF EXISTS DEMOS.LIVE_SEMANTIC_INTEROP.RAW_TEXT_FMT;
DROP FILE FORMAT IF EXISTS DEMOS.SNOWFLAKE_MANAGED_SEMANTIC_INTEROP.RAW_TEXT_FMT;

DROP SCHEMA IF EXISTS DEMOS.DEMO_SEMANTIC_INTEROP;
DROP SCHEMA IF EXISTS DEMOS.LIVE_SEMANTIC_INTEROP;
DROP SCHEMA IF EXISTS DEMOS.SNOWFLAKE_MANAGED_SEMANTIC_INTEROP;

-- ===========================================================================
-- RETIRED: the root-scoped stage
-- ===========================================================================
-- OSSIE_S3_STAGE pointed at ossie/ and so listed every flow's files, because LIST is
-- recursive. Each flow now has its own prefix-scoped stage. Dropping it does not touch
-- the files on S3.
DROP STAGE IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.OSSIE_S3_STAGE;

-- ===========================================================================
-- SHARED DATA
-- ===========================================================================
-- Everything below is shared by all three flows. Only run this part if you are tearing
-- the whole demo down, not when resetting one flow.
DROP ICEBERG TABLE IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.CUSTOMERS;
DROP ICEBERG TABLE IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.ORDERS;
DROP FILE FORMAT IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP.RAW_TEXT_FMT;
DROP SCHEMA IF EXISTS DEMOS.EXT_SEMANTIC_INTEROP;

-- The external volume must go after the Iceberg tables that reference it.
DROP EXTERNAL VOLUME IF EXISTS OSSIE_ICEBERG_VOL;

-- ===========================================================================
-- STORAGE INTEGRATION
-- ===========================================================================
-- Dropping this invalidates nothing in AWS, but recreating it later mints a NEW external
-- ID, which means editing the IAM trust policy again. Leave it in place unless you are
-- genuinely finished with the demo.
-- DROP STORAGE INTEGRATION IF EXISTS OSSIE_S3_INT;

-- Optionally drop the database if nothing else lives there:
-- DROP DATABASE IF EXISTS DEMOS;
