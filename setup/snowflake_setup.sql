/*
 * Snowflake Setup Script: Interoperable Semantics Demo
 *
 * This script creates all Snowflake objects needed for the demo.
 * Run with ACCOUNTADMIN role.
 *
 * Before running, replace these placeholders:
 *   <YOUR_S3_BUCKET>       -- your S3 bucket name (e.g. snowflake-ossie-interop)
 *   <YOUR_AWS_ACCOUNT_ID>  -- your 12-digit AWS account ID
 *
 * After running, note the outputs from DESC INTEGRATION and DESC EXTERNAL VOLUME
 * -- you need STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID to update the
 * IAM trust policy. See SETUP.md Step 6.
 */

-- ===========================================================================
-- CONFIGURATION (edit these)
-- ===========================================================================
SET s3_bucket = '<YOUR_S3_BUCKET>';
SET aws_account_id = '<YOUR_AWS_ACCOUNT_ID>';
SET database_name = 'DEMOS';
SET schema_name = 'EXT_SEMANTIC_INTEROP';

-- ===========================================================================
-- CREATE DATABASE AND SCHEMA
-- ===========================================================================
USE ROLE ACCOUNTADMIN;

CREATE DATABASE IF NOT EXISTS IDENTIFIER($database_name);
CREATE SCHEMA IF NOT EXISTS IDENTIFIER($database_name || '.' || $schema_name);
USE SCHEMA IDENTIFIER($database_name || '.' || $schema_name);

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
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::' || $aws_account_id || ':role/snowflake-ossie-role'
  STORAGE_ALLOWED_LOCATIONS = ('s3://' || $s3_bucket || '/');

-- >>> IMPORTANT: Note these values for your IAM trust policy <<<
DESC INTEGRATION OSSIE_S3_INT;
-- Look for: STORAGE_AWS_IAM_USER_ARN and STORAGE_AWS_EXTERNAL_ID

-- ===========================================================================
-- EXTERNAL STAGE (for Ossie YAML files)
-- ===========================================================================
CREATE OR REPLACE STAGE OSSIE_S3_STAGE
  URL = 's3://' || $s3_bucket || '/ossie/'
  STORAGE_INTEGRATION = OSSIE_S3_INT
  FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
                 ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE);

-- ===========================================================================
-- EXTERNAL VOLUME (for Iceberg tables)
-- ===========================================================================
CREATE OR REPLACE EXTERNAL VOLUME OSSIE_ICEBERG_VOL
  STORAGE_LOCATIONS = (
    (NAME = 'us-west-2-ossie'
     STORAGE_BASE_URL = 's3://' || $s3_bucket || '/iceberg/'
     STORAGE_PROVIDER = 'S3'
     STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::' || $aws_account_id || ':role/snowflake-ossie-role')
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
-- SYNC TASK (suspended by default -- enable during demo)
-- ===========================================================================
CREATE OR REPLACE TASK OSSIE_SYNC_TASK
  WAREHOUSE = COMPUTE_WH
  SCHEDULE = '1 MINUTE'
  COMMENT = 'Exports semantic view to S3 and imports Databricks export. SUSPENDED by default.'
AS
BEGIN
  COPY INTO @OSSIE_S3_STAGE/ossie_from_snowflake.yaml
  FROM (SELECT SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW('DEMOS.EXT_SEMANTIC_INTEROP.SALES_SV'))
  FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
                 ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE)
  SINGLE = TRUE OVERWRITE = TRUE;

  LET yaml_content VARCHAR := (
    SELECT $1 FROM @OSSIE_S3_STAGE/ossie_from_databricks.yaml
    (FILE_FORMAT => 'DEMOS.EXT_SEMANTIC_INTEROP.RAW_TEXT_FMT')
  );
  IF (:yaml_content IS NOT NULL) THEN
    CALL SYSTEM$CREATE_SEMANTIC_VIEW_FROM_OSSIE_YAML('DEMOS.EXT_SEMANTIC_INTEROP', :yaml_content);
  END IF;
END;

-- Verify task is suspended
SHOW TASKS;

-- ===========================================================================
-- DONE
-- ===========================================================================
-- Next steps:
-- 1. Update the IAM trust policy with the ARN and external IDs from above (see SETUP.md Step 6)
-- 2. Verify: LIST @OSSIE_S3_STAGE should show ossie_from_snowflake.yaml
-- 3. Set up Databricks (see SETUP.md Step 7)
-- 4. Run notebook 2 in Databricks
-- 5. Run notebook 3 in Snowflake to complete the round-trip
