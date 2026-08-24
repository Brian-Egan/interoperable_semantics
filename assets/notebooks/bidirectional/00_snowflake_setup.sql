/*
 * Bidirectional Demo: Snowflake Setup and Reset
 * =============================================
 *
 * Run this before every run of the bidirectional demo. It is idempotent and safe to
 * re-run: the Iceberg tables and the S3 plumbing are created only if missing, while the
 * demo-specific objects are reset every time.
 *
 * What it does
 *   1. Creates the file format, storage integration, external stage and external volume
 *      if they do not exist.
 *   2. Creates the CUSTOMERS and ORDERS Iceberg tables if they do not exist, and loads
 *      the demo rows only when the tables are empty.
 *   3. Resets the demo: drops the sync procedure and task, clears the Ossie files and
 *      sync state from S3.
 *   4. Creates SALES_SV in its BASELINE state: two metrics only. TOTAL_QUANTITY and
 *      AVG_ORDER_AMOUNT arrive during the demo, from Databricks and from Snowflake.
 *
 * Before running, replace:
 *   <YOUR_S3_BUCKET>       your S3 bucket name
 *   <YOUR_AWS_ACCOUNT_ID>  your 12-digit AWS account ID
 *
 * First-time setup on a brand new account also needs the IAM trust policy step. See
 * setup/SETUP.md. This script is the per-demo reset, not the one-time infrastructure build.
 *
 * Run the Databricks companion, 00_databricks_setup.ipynb, after this.
 */

SET s3_bucket     = '<YOUR_S3_BUCKET>';
SET aws_account_id = '<YOUR_AWS_ACCOUNT_ID>';
SET database_name = 'DEMOS';
SET schema_name   = 'EXT_SEMANTIC_INTEROP';

USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS IDENTIFIER($database_name);
CREATE SCHEMA IF NOT EXISTS IDENTIFIER($database_name || '.' || $schema_name);
USE SCHEMA IDENTIFIER($database_name || '.' || $schema_name);


-- ===========================================================================
-- 1. Plumbing: file format, storage integration, stage, external volume
-- ===========================================================================

-- Reads a whole YAML file as a single value rather than parsing it as CSV.
CREATE FILE FORMAT IF NOT EXISTS RAW_TEXT_FMT
  TYPE = 'CSV'
  FIELD_DELIMITER = NONE
  RECORD_DELIMITER = NONE
  ESCAPE_UNENCLOSED_FIELD = NONE;

CREATE STORAGE INTEGRATION IF NOT EXISTS OSSIE_S3_INT
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::' || $aws_account_id || ':role/snowflake-ossie-role'
  STORAGE_ALLOWED_LOCATIONS = ('s3://' || $s3_bucket || '/');

-- The directory table is what lets us see file timestamps from SQL.
CREATE STAGE IF NOT EXISTS OSSIE_S3_STAGE
  URL = 's3://' || $s3_bucket || '/ossie/'
  STORAGE_INTEGRATION = OSSIE_S3_INT
  DIRECTORY = (ENABLE = TRUE)
  FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
                 ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE);

CREATE EXTERNAL VOLUME IF NOT EXISTS OSSIE_ICEBERG_VOL
  STORAGE_LOCATIONS = (
    (NAME = 'us-west-2-ossie'
     STORAGE_BASE_URL = 's3://' || $s3_bucket || '/iceberg/'
     STORAGE_PROVIDER = 'S3'
     STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::' || $aws_account_id || ':role/snowflake-ossie-role')
  )
  ALLOW_WRITES = TRUE;


-- ===========================================================================
-- 2. Iceberg tables, created only if missing
-- ===========================================================================
-- Snowflake-managed Iceberg: Snowflake writes Parquet and Iceberg metadata to your own
-- S3 bucket, and Databricks reads those same files. No copy, no pipeline.

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

-- Load only when empty, so re-running the reset does not duplicate rows.
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

-- Integer-only, so the numbers are auditable by eye: EAST 750/5/12, WEST 700/5/11.
SELECT c.region,
       SUM(o.order_amount) AS total_order_amount,
       COUNT(o.order_id)   AS order_count,
       SUM(o.order_qty)    AS total_quantity
  FROM ORDERS o
  JOIN CUSTOMERS c USING (customer_id)
 GROUP BY c.region
 ORDER BY c.region;


-- ===========================================================================
-- 3. Reset the demo objects
-- ===========================================================================

-- Suspend before dropping, so a mid-flight run cannot recreate anything.
ALTER TASK IF EXISTS SYNC_OSSIE_TASK SUSPEND;
DROP TASK IF EXISTS SYNC_OSSIE_TASK;
DROP PROCEDURE IF EXISTS SYNC_OSSIE(STRING, STRING, STRING, STRING, STRING, STRING);
DROP PROCEDURE IF EXISTS EXPORT_TO_OSSIE(STRING, STRING, STRING, STRING, STRING);
DROP PROCEDURE IF EXISTS IMPORT_FROM_OSSIE(STRING, STRING, STRING, STRING, STRING);

-- Clear the shared model and both sync state files. A leftover state file makes the
-- first sync of the next demo report a conflict instead of a clean adoption.
REMOVE @OSSIE_S3_STAGE/sales_model.yaml;
REMOVE @OSSIE_S3_STAGE/_state/;
ALTER STAGE OSSIE_S3_STAGE REFRESH;

LIST @OSSIE_S3_STAGE;   -- expect no sales_model.yaml and no _state/ files


-- ===========================================================================
-- 4. The baseline semantic view: two metrics
-- ===========================================================================
-- TOTAL_QUANTITY is added from Databricks during the demo, and AVG_ORDER_AMOUNT from
-- Snowflake. Starting from two metrics is what makes those additions visible.

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
  COMMENT = 'Sales star for the Ossie interop demo (Iceberg on S3)';

SELECT * FROM SEMANTIC_VIEW(
  SALES_SV
  DIMENSIONS customers.region
  METRICS orders.total_order_amount, orders.order_count
) ORDER BY region;

SHOW SEMANTIC VIEWS LIKE 'SALES_SV';

/*
 * Snowflake side is reset.
 *
 * Next: run 00_databricks_setup.ipynb in Databricks, which registers the same Iceberg
 * tables in Unity Catalog and drops the Metric View so the demo starts with Databricks
 * having data but no semantic model.
 *
 * Then open 01_snowflake_semantic_view.ipynb to begin.
 */
