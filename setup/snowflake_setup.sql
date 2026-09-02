/*
 * Snowflake Setup Script: Interoperable Semantics Demo
 *
 * Creates the one-time, shared Snowflake objects for all three demo flows.
 * Run with ACCOUNTADMIN.
 *
 * PREFERRED PATH: do not run this by hand. Point Cortex Code at
 * setup/COCO_SETUP_GUIDE.md instead. This script is only half the job: the storage
 * integration and external volume each mint an external ID that has to be written into an
 * AWS IAM trust policy before anything can read S3, and the Databricks side needs its own
 * credential and external location. The guide sequences all of that and verifies each step.
 * Running this script on its own leaves you with objects that cannot reach the bucket.
 *
 * ---------------------------------------------------------------------------
 * NO AWS KEYS ARE INVOLVED
 * ---------------------------------------------------------------------------
 * Authentication is IAM role trust: Snowflake mints an external ID, you allow it in the
 * role's trust policy. There is no access key or token anywhere in this file, so nothing
 * here is unsafe to show on screen. The only sensitive value is your AWS account ID.
 *
 * ---------------------------------------------------------------------------
 * HOW TO SUPPLY YOUR BUCKET AND ACCOUNT ID
 * ---------------------------------------------------------------------------
 * Values come from the `env` section of a gitignored snowflake.yml, so they are never
 * typed on the command line, never land in shell history, and never get committed.
 * Copy snowflake.yml.example to snowflake.yml, fill it in, then:
 *
 *   snow sql -c <your-connection> -f setup/snowflake_setup.sql
 *
 * The <% ctx.env.* %> placeholders are substituted client-side before Snowflake ever
 * parses the statement. That matters, because CREATE STORAGE INTEGRATION, CREATE STAGE
 * and CREATE EXTERNAL VOLUME accept only literal parameter values: a session variable or
 * a concatenation fails with "syntax error ... unexpected '||'". Client-side templating
 * satisfies that constraint where SET variables cannot. Do not convert these to SET.
 *
 * ---------------------------------------------------------------------------
 * THIS SCRIPT IS SAFE TO RE-RUN
 * ---------------------------------------------------------------------------
 * Everything is IF NOT EXISTS, and the data load is guarded on an empty table. This is
 * deliberate, and the reason is not obvious:
 *
 *   - CREATE OR REPLACE STORAGE INTEGRATION mints a NEW external ID. The old one is what
 *     your AWS trust policy allows, so replacing the integration silently breaks S3
 *     access until you edit AWS again. The failure surfaces later as an opaque
 *     permissions error on the stage, which is slow to diagnose.
 *   - CREATE OR REPLACE EXTERNAL VOLUME does the same with its own, separate external ID.
 *   - CREATE OR REPLACE ICEBERG TABLE destroys the data and allocates a NEW random
 *     base-location suffix on S3. The Databricks notebooks discover tables by scanning
 *     for those suffixes, so replacing a table breaks the Databricks side too.
 *
 * After running, note the outputs from DESC INTEGRATION and DESC EXTERNAL VOLUME:
 * you need STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID from each to update the
 * IAM trust policy. See SETUP.md, or let the guide handle it.
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS SCRIPT DOES NOT DO
 * ---------------------------------------------------------------------------
 * It creates no semantic view and exports no Ossie file. Each flow owns its own baseline
 * semantic view, because each flow keeps it in its own schema and writes to its own S3
 * prefix. Infrastructure setup and demo content are separate jobs.
 */

-- ===========================================================================
-- CONFIGURATION
-- ===========================================================================
-- Object names only. Bucket and AWS account come from snowflake.yml.
--
-- Layout: one bucket, one storage integration, one set of Iceberg tables, and three
-- flow schemas that each own a semantic view and a stage scoped to its own S3 prefix.
--
--   DEMOS.EXT_SEMANTIC_INTEROP                    tables + external volume  iceberg/
--   DEMOS.DEMO_SEMANTIC_INTEROP                   view + stage              ossie/demo/
--   DEMOS.LIVE_SEMANTIC_INTEROP                   view + stage              ossie/live/
--   DEMOS.SNOWFLAKE_MANAGED_SEMANTIC_INTEROP      view + stage              ossie/snowflake_managed/
--
-- The tables stay shared on purpose. Snowflake appends a random suffix to each Iceberg
-- base location, and the Databricks notebooks discover tables by scanning iceberg/ for
-- those suffixes. A second copy of CUSTOMERS or ORDERS would put a second
-- customers.<suffix>/ under the same prefix, and the discovery would match both and keep
-- whichever the listing returned last.
SET database_name = 'DEMOS';
SET data_schema = 'EXT_SEMANTIC_INTEROP';

-- IDENTIFIER() takes a single session variable, not a concatenation, so build the
-- qualified name once.
SET data_schema_fqn = $database_name || '.' || $data_schema;

-- ===========================================================================
-- DATABASE AND SCHEMAS
-- ===========================================================================
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS IDENTIFIER($database_name);
CREATE SCHEMA IF NOT EXISTS IDENTIFIER($data_schema_fqn);

CREATE SCHEMA IF NOT EXISTS DEMOS.DEMO_SEMANTIC_INTEROP
  COMMENT = 'Manual demo flow: semantic view and stage on ossie/demo/';
CREATE SCHEMA IF NOT EXISTS DEMOS.LIVE_SEMANTIC_INTEROP
  COMMENT = 'Bidirectional live sync flow: semantic view and stage on ossie/live/';
CREATE SCHEMA IF NOT EXISTS DEMOS.SNOWFLAKE_MANAGED_SEMANTIC_INTEROP
  COMMENT = 'Snowflake-managed flow: semantic view and stage on ossie/snowflake_managed/';

USE SCHEMA IDENTIFIER($data_schema_fqn);

-- ===========================================================================
-- FILE FORMAT (read raw YAML as a single value)
-- ===========================================================================
CREATE FILE FORMAT IF NOT EXISTS RAW_TEXT_FMT
  TYPE = 'CSV'
  FIELD_DELIMITER = NONE
  RECORD_DELIMITER = NONE
  ESCAPE_UNENCLOSED_FIELD = NONE;

-- ===========================================================================
-- STORAGE INTEGRATION
-- ===========================================================================
-- IF NOT EXISTS: replacing this rotates the external ID and breaks your AWS trust policy.
CREATE STORAGE INTEGRATION IF NOT EXISTS OSSIE_S3_INT
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<% ctx.env.aws_account_id %>:role/snowflake-ossie-role'
  STORAGE_ALLOWED_LOCATIONS = ('s3://<% ctx.env.s3_bucket %>/');

-- >>> Note these values for your IAM trust policy <<<
DESC INTEGRATION OSSIE_S3_INT;
-- Look for: STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID

-- ===========================================================================
-- EXTERNAL STAGES, ONE PER FLOW
-- ===========================================================================
-- All three share OSSIE_S3_INT. A stage does not hold its own AWS trust: it inherits the
-- integration's role and external ID, so adding stages needs no AWS-side change at all.
--
-- Each is scoped to its own subfolder for two reasons. LIST is recursive, so a stage at
-- ossie/ would show every flow's files at once; and a flow needs to be able to show an
-- empty stage that then fills up, without another flow's automation writing into it.
--
-- The subfolders sit under the existing ossie/ prefix rather than at the bucket root. The
-- integration allows the whole bucket, but if your IAM role policy happens to be scoped
-- to ossie/*, a new top-level prefix would fail with an opaque permissions error.
--
-- DIRECTORY = (ENABLE = TRUE) is required: the demos read file timestamps from the
-- directory table. Note it does not auto-refresh, so a reset that deletes a file must
-- also run ALTER STAGE <name> REFRESH, or the deleted file still appears.

CREATE STAGE IF NOT EXISTS DEMOS.DEMO_SEMANTIC_INTEROP.DEMO_OSSIE_STAGE
  URL = 's3://<% ctx.env.s3_bucket %>/ossie/demo/'
  STORAGE_INTEGRATION = OSSIE_S3_INT
  DIRECTORY = (ENABLE = TRUE)
  FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
                 ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE);

CREATE STAGE IF NOT EXISTS DEMOS.LIVE_SEMANTIC_INTEROP.LIVE_OSSIE_STAGE
  URL = 's3://<% ctx.env.s3_bucket %>/ossie/live/'
  STORAGE_INTEGRATION = OSSIE_S3_INT
  DIRECTORY = (ENABLE = TRUE)
  FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
                 ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE);

CREATE STAGE IF NOT EXISTS DEMOS.SNOWFLAKE_MANAGED_SEMANTIC_INTEROP.SNOWFLAKE_MANAGED_OSSIE_STAGE
  URL = 's3://<% ctx.env.s3_bucket %>/ossie/snowflake_managed/'
  STORAGE_INTEGRATION = OSSIE_S3_INT
  DIRECTORY = (ENABLE = TRUE)
  FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
                 ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE);

-- ===========================================================================
-- EXTERNAL VOLUME (for Iceberg tables)
-- ===========================================================================
-- IF NOT EXISTS: this mints its own external ID, separate from the integration's.
CREATE EXTERNAL VOLUME IF NOT EXISTS OSSIE_ICEBERG_VOL
  STORAGE_LOCATIONS = (
    (NAME = 'us-west-2-ossie'
     STORAGE_BASE_URL = 's3://<% ctx.env.s3_bucket %>/iceberg/'
     STORAGE_PROVIDER = 'S3'
     STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<% ctx.env.aws_account_id %>:role/snowflake-ossie-role')
  )
  ALLOW_WRITES = TRUE;

-- >>> Note the external ID here too. It differs from the integration's. <<<
DESC EXTERNAL VOLUME OSSIE_ICEBERG_VOL;

-- ===========================================================================
-- ICEBERG TABLES (shared by all three flows)
-- ===========================================================================
-- IF NOT EXISTS: replacing these destroys the data and allocates new random base-location
-- suffixes, which breaks the Databricks path discovery.
CREATE ICEBERG TABLE IF NOT EXISTS CUSTOMERS (
  customer_id    INT,
  customer_name  STRING,
  region         STRING
)
  CATALOG = 'SNOWFLAKE'
  EXTERNAL_VOLUME = 'OSSIE_ICEBERG_VOL'
  BASE_LOCATION = 'customers/';

CREATE ICEBERG TABLE IF NOT EXISTS ORDERS (
  order_id       INT,
  customer_id    INT,
  order_amount   INT,
  order_qty      INT
)
  CATALOG = 'SNOWFLAKE'
  EXTERNAL_VOLUME = 'OSSIE_ICEBERG_VOL'
  BASE_LOCATION = 'orders/';

-- ===========================================================================
-- LOAD DEMO DATA (only if the tables are empty)
-- ===========================================================================
-- Guarded so a second run does not double the rows and change the demo numbers.
INSERT INTO CUSTOMERS
SELECT * FROM VALUES
  (1, 'Ava',  'EAST'),
  (2, 'Ben',  'WEST'),
  (3, 'Cara', 'EAST'),
  (4, 'Dan',  'WEST')
WHERE (SELECT COUNT(*) FROM CUSTOMERS) = 0;

INSERT INTO ORDERS
SELECT * FROM VALUES
  (101, 1, 100, 2),
  (102, 1, 150, 3),
  (103, 2, 200, 1),
  (104, 2,  50, 5),
  (105, 3, 300, 2),
  (106, 3, 100, 4),
  (107, 4, 250, 1),
  (108, 4, 100, 2),
  (109, 1, 100, 1),
  (110, 2, 100, 2)
WHERE (SELECT COUNT(*) FROM ORDERS) = 0;

-- Verify: expect EAST 750/5/12, WEST 700/5/11
SELECT c.region,
       SUM(o.order_amount) AS total_order_amount,
       COUNT(*) AS order_count,
       SUM(o.order_qty) AS total_quantity
FROM ORDERS o
JOIN CUSTOMERS c ON o.customer_id = c.customer_id
GROUP BY c.region
ORDER BY c.region;

-- ===========================================================================
-- SYNC TASK: removed on purpose
-- ===========================================================================
-- This file used to create an OSSIE_SYNC_TASK that exported the semantic view and
-- imported the Databricks export on every run, unconditionally. That task loops: the
-- import replaces the semantic view, which makes it look newer than the file, which
-- triggers another export, and so on. It never settles.
--
-- Each demo flow now creates its own task, and those compare a fingerprint of what the
-- model means before writing anything. See:
--   assets/notebooks/bidirectional/03_snowflake_automation.ipynb
--   assets/notebooks/unidirectional/10_snowflake_managed_export.ipynb
--
-- Do not re-add a task here. Infrastructure setup and demo automation are separate jobs.

SHOW TASKS IN DATABASE DEMOS;   -- expect none after a fresh setup

-- ===========================================================================
-- DONE
-- ===========================================================================
-- Next steps:
-- 1. Update the IAM trust policy with the ARN and external IDs from above
--    (see SETUP.md Step 6). Both the integration and the volume need allowing.
-- 2. Set up Databricks (see SETUP.md Step 7).
-- 3. Run a flow's own setup notebook to create its baseline semantic view.
