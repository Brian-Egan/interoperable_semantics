/*
 * Snowflake Setup Script: Interoperable Semantics Demo
 *
 * Creates the one-time Snowflake objects for the demo. Run with ACCOUNTADMIN.
 *
 * PREFERRED PATH: do not run this by hand. Point Cortex Code at
 * setup/COCO_SETUP_GUIDE.md instead. This script is only half the job: the storage
 * integration and external volume each mint an external ID that has to be written into an
 * AWS IAM trust policy before anything can read S3, and the Databricks side needs its own
 * credential and external location. The guide sequences all of that and verifies each step.
 * Running this script on its own leaves you with objects that cannot reach the bucket.
 *
 * If you do run it manually, replace these two tokens THROUGHOUT the file:
 *   <YOUR_S3_BUCKET>       -- your S3 bucket name (e.g. snowflake-ossie-interop)
 *   <YOUR_AWS_ACCOUNT_ID>  -- your 12-digit AWS account ID
 *
 * They are deliberately literal tokens rather than session variables. CREATE STORAGE
 * INTEGRATION, CREATE STAGE and CREATE EXTERNAL VOLUME accept only literal parameter
 * values; passing a session variable or a concatenation fails with
 * "syntax error ... unexpected '||'". Do not convert them back to SET variables.
 *
 * After running, note the outputs from DESC INTEGRATION and DESC EXTERNAL VOLUME:
 * you need STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID from each to update the
 * IAM trust policy. See SETUP.md, or let the guide handle it.
 */

-- ===========================================================================
-- CONFIGURATION
-- ===========================================================================
-- Object names only. The bucket and AWS account are literal tokens above.
SET database_name = 'DEMOS';
SET schema_name = 'EXT_SEMANTIC_INTEROP';

-- IDENTIFIER() takes a single session variable, not a concatenation, so build the
-- qualified name once.
SET schema_fqn = $database_name || '.' || $schema_name;

-- ===========================================================================
-- CREATE DATABASE AND SCHEMA
-- ===========================================================================
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS IDENTIFIER($database_name);
CREATE SCHEMA IF NOT EXISTS IDENTIFIER($schema_fqn);
USE SCHEMA IDENTIFIER($schema_fqn);

-- ===========================================================================
-- FILE FORMAT (for reading raw YAML as single value)
-- ===========================================================================
CREATE OR REPLACE FILE FORMAT RAW_TEXT_FMT
  TYPE = 'CSV'
  FIELD_DELIMITER = NONE
  RECORD_DELIMITER = NONE
  ESCAPE_UNENCLOSED_FIELD = NONE;

-- ===========================================================================
-- STORAGE INTEGRATION
-- ===========================================================================
CREATE OR REPLACE STORAGE INTEGRATION OSSIE_S3_INT
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/snowflake-ossie-role'
  STORAGE_ALLOWED_LOCATIONS = ('s3://<YOUR_S3_BUCKET>/');

-- >>> IMPORTANT: Note these values for your IAM trust policy <<<
DESC INTEGRATION OSSIE_S3_INT;
-- Look for: STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID

-- ===========================================================================
-- EXTERNAL STAGE (for Ossie YAML files)
-- ===========================================================================
-- DIRECTORY = (ENABLE = TRUE) is required: the demo reads file timestamps from the
-- directory table.
CREATE OR REPLACE STAGE OSSIE_S3_STAGE
  URL = 's3://<YOUR_S3_BUCKET>/ossie/'
  STORAGE_INTEGRATION = OSSIE_S3_INT
  DIRECTORY = (ENABLE = TRUE)
  FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
                 ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE);

-- ===========================================================================
-- EXTERNAL VOLUME (for Iceberg tables)
-- ===========================================================================
CREATE OR REPLACE EXTERNAL VOLUME OSSIE_ICEBERG_VOL
  STORAGE_LOCATIONS = (
    (NAME = 'us-west-2-ossie'
     STORAGE_BASE_URL = 's3://<YOUR_S3_BUCKET>/iceberg/'
     STORAGE_PROVIDER = 'S3'
     STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<YOUR_AWS_ACCOUNT_ID>:role/snowflake-ossie-role')
  )
  ALLOW_WRITES = TRUE;

-- >>> IMPORTANT: Note the external ID here too (may differ from integration) <<<
DESC EXTERNAL VOLUME OSSIE_ICEBERG_VOL;

-- ===========================================================================
-- ICEBERG TABLES
-- ===========================================================================
CREATE OR REPLACE ICEBERG TABLE CUSTOMERS (
  customer_id    INT,
  customer_name  STRING,
  region         STRING
)
  CATALOG = 'SNOWFLAKE'
  EXTERNAL_VOLUME = 'OSSIE_ICEBERG_VOL'
  BASE_LOCATION = 'customers/';

CREATE OR REPLACE ICEBERG TABLE ORDERS (
  order_id       INT,
  customer_id    INT,
  order_amount   INT,
  order_qty      INT
)
  CATALOG = 'SNOWFLAKE'
  EXTERNAL_VOLUME = 'OSSIE_ICEBERG_VOL'
  BASE_LOCATION = 'orders/';

-- ===========================================================================
-- LOAD DEMO DATA
-- ===========================================================================
INSERT INTO CUSTOMERS VALUES
  (1, 'Ava',  'EAST'),
  (2, 'Ben',  'WEST'),
  (3, 'Cara', 'EAST'),
  (4, 'Dan',  'WEST');

INSERT INTO ORDERS VALUES
  (101, 1, 100, 2),
  (102, 1, 150, 3),
  (103, 2, 200, 1),
  (104, 2,  50, 5),
  (105, 3, 300, 2),
  (106, 3, 100, 4),
  (107, 4, 250, 1),
  (108, 4, 100, 2),
  (109, 1, 100, 1),
  (110, 2, 100, 2);

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
-- SEMANTIC VIEW
-- ===========================================================================
CREATE OR REPLACE SEMANTIC VIEW SALES_SV
  TABLES (
    orders AS ORDERS PRIMARY KEY (order_id),
    customers AS CUSTOMERS PRIMARY KEY (customer_id)
  )
  RELATIONSHIPS (
    orders_to_customers AS orders (customer_id) REFERENCES customers (customer_id)
  )
  FACTS (
    orders.order_amount AS order_amount,
    orders.order_qty AS order_qty
  )
  DIMENSIONS (
    customers.region AS region,
    customers.customer_name AS customer_name
  )
  METRICS (
    orders.total_order_amount AS SUM(orders.order_amount),
    orders.order_count AS COUNT(orders.order_id)
  )
  COMMENT = 'Sales star for Ossie interop demo (Iceberg on S3)';

-- Verify semantic view works
SELECT * FROM SEMANTIC_VIEW(
  SALES_SV
  DIMENSIONS customers.region
  METRICS orders.total_order_amount, orders.order_count
) ORDER BY region;

-- ===========================================================================
-- EXPORT OSSIE TO S3
-- ===========================================================================
COPY INTO @OSSIE_S3_STAGE/ossie_from_snowflake.yaml
FROM (SELECT SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW(
  $database_name || '.' || $schema_name || '.SALES_SV'))
FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
               ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE)
SINGLE = TRUE OVERWRITE = TRUE;

-- Confirm file is on S3
LIST @OSSIE_S3_STAGE;

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

SHOW TASKS;   -- expect none in this schema after a fresh setup

-- ===========================================================================
-- DONE
-- ===========================================================================
-- Next steps:
-- 1. Update the IAM trust policy with the ARN and external IDs from above (see SETUP.md Step 6)
-- 2. Verify: LIST @OSSIE_S3_STAGE should show ossie_from_snowflake.yaml
-- 3. Set up Databricks (see SETUP.md Step 7)
-- 4. Run notebook 2 in Databricks
-- 5. Run notebook 3 in Snowflake to complete the round-trip
