# Setup Guide for CoCo

Instructions for an agent (Cortex Code) to stand this demo up in a **new** set of accounts.

**How to use this:** point CoCo at this file.

> Read `setup/COCO_SETUP_GUIDE.md` and set up the interoperable semantics demo in my
> Snowflake, AWS and Databricks accounts.

This is the one-time infrastructure build. Once it is done, the per-demo reset scripts
(`assets/notebooks/*/00_snowflake_setup.sql` and `00_databricks_setup.ipynb`) handle
everything else and need no configuration.

---

## A note on `setup/snowflake_setup.sql`

That file exists, and it looks like the thing to run. **Tell the user not to run it by
hand**, and do not simply execute it yourself as a shortcut for Phase 3.

It creates the Snowflake objects and stops there, which is the useless half of the job.
The storage integration and the external volume each mint an external ID that has to be
written into an AWS IAM trust policy before either can reach S3, and neither the AWS side
nor the Databricks side exists yet at that point. Run it alone and you get a schema full of
objects that cannot read the bucket, with an error message that points at permissions rather
than at the missing step.

It also has to be find-and-replaced in two places rather than configured at the top, because
`CREATE STORAGE INTEGRATION`, `CREATE STAGE` and `CREATE EXTERNAL VOLUME` reject session
variables. That is easy to get half-right.

Use the phases below instead. They contain the same DDL, in an order that works, with the
trust-policy handshake in the middle and a verification gate after it. Treat
`snowflake_setup.sql` as a reference for the object definitions if you want to read them in
one place.

---

## Agent instructions: read this part first

**Do not create anything before completing Phase 0.** The IAM setup has a
chicken-and-egg ordering that cannot be shortcut, and getting it wrong means deleting and
recreating objects rather than editing them.

**Constraints that have already cost time in this project, learned the hard way:**

1. `CREATE STORAGE INTEGRATION`, `CREATE STAGE` and `CREATE EXTERNAL VOLUME` accept only
   **literal** parameter values. They reject session variables and `||` concatenation with
   `syntax error ... unexpected '||'`. Substitute real values into the SQL text; do not
   parameterise these statements.
2. `IDENTIFIER()` takes a single session variable, not a concatenation. Build a
   `SET schema_fqn = $db || '.' || $schema;` first if you need a qualified name.
3. **Never `CREATE OR REPLACE` a storage integration or external volume** once its trust
   policy is working. Replacing it generates a new external ID and silently breaks the AWS
   trust relationship. Use `CREATE ... IF NOT EXISTS`, and if you must recreate, redo the
   trust policy in the same session.
4. The storage integration and the external volume can have **different external IDs**.
   Read each one separately; do not assume one value covers both.
5. Snowflake appends a random suffix to Iceberg `BASE_LOCATION`, for example
   `customers.6EWgT0se/`. Anything reading those files from outside Snowflake must discover
   the path rather than hardcode it.

**Ask before acting** on anything that deletes data or replaces an integration. Report
what you verified at the end of each phase rather than only at the end.

---

## Phase 0: gather inputs

Ask the user for these. Do not guess, and do not read them out of another account's config.

| Input | How the user can find it | Notes |
|---|---|---|
| S3 bucket name | they choose it | Must be globally unique and must not already exist |
| AWS region | e.g. `us-west-2` | Should match the Snowflake account region to avoid egress cost |
| AWS profile or credentials | `aws configure list-profiles` | Needs IAM and S3 write permission |
| Snowflake connection name | `snow connection list` | Must reach ACCOUNTADMIN |
| Databricks CLI profile | `databricks auth profiles` | Workspace must have Unity Catalog |
| Databricks catalog name | usually `demos` | Will be created if missing |

Then confirm access before doing anything else:

```bash
aws sts get-caller-identity --profile <PROFILE>       # note the Account field
snow sql -c <CONNECTION> -q "SELECT CURRENT_ACCOUNT(), CURRENT_REGION(), CURRENT_ROLE()"
databricks current-user me --profile <DBX_PROFILE>
```

Record the 12-digit AWS account ID from the first command. Every ARN below needs it.

**Stop if `aws sts get-caller-identity` fails.** Without AWS credentials, the IAM steps
cannot be automated and the user has to do them in the console. Say so rather than
proceeding and failing later.

Snowflake object names used throughout, which the demo scripts expect exactly:

```
database          DEMOS
schema            EXT_SEMANTIC_INTEROP
storage integ.    OSSIE_S3_INT
external stage    OSSIE_S3_STAGE       -> s3://<BUCKET>/ossie/
external volume   OSSIE_ICEBERG_VOL    -> s3://<BUCKET>/iceberg/
file format       RAW_TEXT_FMT
iceberg tables    CUSTOMERS, ORDERS
semantic view     SALES_SV
warehouse         any; the notebooks default to SI_DEMO_WH
```

Databricks: catalog `demos`, schema `ext_semantic_interop`, external location
`ossie-interop-s3`, storage credential `ossie-s3-credential`, metric view
`sales_metric_view`.

If the user wants different names, change them consistently in both `00` scripts and in
the notebook config cells. The Snowflake database and schema should match the Databricks
catalog and schema, because the Ossie file carries three-part table names and matching
names mean no rewriting.

---

## Phase 1: S3 bucket

```bash
aws s3api create-bucket --bucket <BUCKET> --region <REGION> \
  --create-bucket-configuration LocationConstraint=<REGION> --profile <PROFILE>

aws s3api put-public-access-block --bucket <BUCKET> --profile <PROFILE> \
  --public-access-block-configuration \
  "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
```

Note: `us-east-1` rejects `LocationConstraint`; omit that flag for that region.

Verify: `aws s3 ls s3://<BUCKET> --profile <PROFILE>` returns without error.

---

## Phase 2: IAM policy and roles

One policy, two roles: one assumed by Snowflake, one by Databricks Unity Catalog.

```bash
cat > /tmp/ossie-s3-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetObject","s3:GetObjectVersion","s3:PutObject","s3:DeleteObject"],
      "Resource": "arn:aws:s3:::<BUCKET>/*"
    },
    {
      "Effect": "Allow",
      "Action": ["s3:ListBucket","s3:GetBucketLocation"],
      "Resource": "arn:aws:s3:::<BUCKET>"
    }
  ]
}
JSON

aws iam create-policy --policy-name ossie-s3-access \
  --policy-document file:///tmp/ossie-s3-policy.json --profile <PROFILE>
```

`PutObject` and `DeleteObject` are required: Snowflake writes Iceberg data and the Ossie
file, and the reset scripts remove files.

Create both roles with a **placeholder** trust policy. The real principals are not known
until Phase 3.

```bash
cat > /tmp/placeholder-trust.json <<JSON
{"Version":"2012-10-17","Statement":[{"Effect":"Allow",
 "Principal":{"AWS":"arn:aws:iam::<AWS_ACCOUNT_ID>:root"},"Action":"sts:AssumeRole"}]}
JSON

for ROLE in snowflake-ossie-role databricks-ossie-role; do
  aws iam create-role --role-name $ROLE \
    --assume-role-policy-document file:///tmp/placeholder-trust.json --profile <PROFILE>
  aws iam attach-role-policy --role-name $ROLE \
    --policy-arn arn:aws:iam::<AWS_ACCOUNT_ID>:policy/ossie-s3-access --profile <PROFILE>
done
```

---

## Phase 3: Snowflake objects, and the trust policy handshake

Substitute real literals into this SQL. Do not use session variables here; see constraint
1 above.

```sql
USE ROLE ACCOUNTADMIN;
CREATE DATABASE IF NOT EXISTS DEMOS;
CREATE SCHEMA IF NOT EXISTS DEMOS.EXT_SEMANTIC_INTEROP;
USE SCHEMA DEMOS.EXT_SEMANTIC_INTEROP;

CREATE FILE FORMAT IF NOT EXISTS RAW_TEXT_FMT
  TYPE = 'CSV' FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
  ESCAPE_UNENCLOSED_FIELD = NONE;

CREATE STORAGE INTEGRATION IF NOT EXISTS OSSIE_S3_INT
  TYPE = EXTERNAL_STAGE
  STORAGE_PROVIDER = 'S3'
  ENABLED = TRUE
  STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<AWS_ACCOUNT_ID>:role/snowflake-ossie-role'
  STORAGE_ALLOWED_LOCATIONS = ('s3://<BUCKET>/');

CREATE EXTERNAL VOLUME IF NOT EXISTS OSSIE_ICEBERG_VOL
  STORAGE_LOCATIONS = (
    (NAME = '<REGION>-ossie'
     STORAGE_BASE_URL = 's3://<BUCKET>/iceberg/'
     STORAGE_PROVIDER = 'S3'
     STORAGE_AWS_ROLE_ARN = 'arn:aws:iam::<AWS_ACCOUNT_ID>:role/snowflake-ossie-role')
  )
  ALLOW_WRITES = TRUE;
```

Now read both external IDs. They are usually different.

```sql
DESC INTEGRATION OSSIE_S3_INT;        -- STORAGE_AWS_IAM_USER_ARN, STORAGE_AWS_EXTERNAL_ID
DESC EXTERNAL VOLUME OSSIE_ICEBERG_VOL;  -- STORAGE_AWS_IAM_USER_ARN, STORAGE_AWS_EXTERNAL_ID
```

`DESC EXTERNAL VOLUME` returns its values inside a JSON blob in the `property_value`
column; parse it rather than reading a flat column.

Write the real trust policy with **both** external IDs allowed:

```bash
cat > /tmp/snowflake-trust.json <<JSON
{"Version":"2012-10-17","Statement":[{
  "Effect":"Allow",
  "Principal":{"AWS":"<STORAGE_AWS_IAM_USER_ARN>"},
  "Action":"sts:AssumeRole",
  "Condition":{"StringEquals":{"sts:ExternalId":["<INTEGRATION_EXTERNAL_ID>","<VOLUME_EXTERNAL_ID>"]}}
}]}
JSON

aws iam update-assume-role-policy --role-name snowflake-ossie-role \
  --policy-document file:///tmp/snowflake-trust.json --profile <PROFILE>
```

IAM propagation takes up to a minute. Then verify, and do not continue until this passes:

```sql
SELECT SYSTEM$VALIDATE_STORAGE_INTEGRATION('OSSIE_S3_INT', 's3://<BUCKET>/ossie/', 'test.txt', 'write');
```

Create the stage only after validation succeeds:

```sql
CREATE STAGE IF NOT EXISTS OSSIE_S3_STAGE
  URL = 's3://<BUCKET>/ossie/'
  STORAGE_INTEGRATION = OSSIE_S3_INT
  DIRECTORY = (ENABLE = TRUE)
  FILE_FORMAT = (TYPE = CSV FIELD_DELIMITER = NONE RECORD_DELIMITER = NONE
                 ESCAPE_UNENCLOSED_FIELD = NONE COMPRESSION = NONE);

LIST @OSSIE_S3_STAGE;   -- empty result is success; an error is not
```

`DIRECTORY = (ENABLE = TRUE)` is required. The demo reads file timestamps from the
directory table.

---

## Phase 4: Iceberg tables and demo data

```sql
CREATE ICEBERG TABLE IF NOT EXISTS CUSTOMERS (
  customer_id INT, customer_name STRING, region STRING)
  CATALOG = 'SNOWFLAKE' EXTERNAL_VOLUME = 'OSSIE_ICEBERG_VOL' BASE_LOCATION = 'customers/';

CREATE ICEBERG TABLE IF NOT EXISTS ORDERS (
  order_id INT, customer_id INT, order_amount INT, order_qty INT)
  CATALOG = 'SNOWFLAKE' EXTERNAL_VOLUME = 'OSSIE_ICEBERG_VOL' BASE_LOCATION = 'orders/';
```

Load the rows from `assets/data/customers.csv` and `assets/data/orders.csv`, or use the
`INSERT` statements in `assets/notebooks/bidirectional/00_snowflake_setup.sql`. Then:

```sql
SELECT c.region, SUM(o.order_amount), COUNT(o.order_id), SUM(o.order_qty)
  FROM ORDERS o JOIN CUSTOMERS c USING (customer_id)
 GROUP BY c.region ORDER BY c.region;
```

**Expected: EAST 750/5/12, WEST 700/5/11.** Integers only, so it is checkable by eye. If
these numbers are wrong, stop and fix the data before going near Databricks.

Note the actual paths, which you will need to confirm Databricks can see them:

```sql
SHOW ICEBERG TABLES IN SCHEMA DEMOS.EXT_SEMANTIC_INTEROP;   -- read BASE_LOCATION
```

Expect a random suffix such as `customers.6EWgT0se/`. That is normal.

---

## Phase 5: Databricks

Get the Unity Catalog principal by creating the storage credential first, then fix its
trust policy, exactly as with Snowflake.

```bash
databricks storage-credentials create --profile <DBX_PROFILE> --json '{
  "name": "ossie-s3-credential",
  "aws_iam_role": {"role_arn": "arn:aws:iam::<AWS_ACCOUNT_ID>:role/databricks-ossie-role"},
  "comment": "Interoperable semantics demo"
}'
```

The response contains `aws_iam_role.unity_catalog_iam_arn` and `external_id`. The
`unity_catalog_iam_arn` is in a **Databricks-owned AWS account**, not the user's; that is
expected. Then the trust policy needs both that principal and the role itself, because
Unity Catalog performs a self-assume:

```bash
cat > /tmp/dbx-trust.json <<JSON
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Principal":{"AWS":"<UNITY_CATALOG_IAM_ARN>"},
  "Action":"sts:AssumeRole",
  "Condition":{"StringEquals":{"sts:ExternalId":"<EXTERNAL_ID>"}}},
 {"Effect":"Allow","Principal":{"AWS":"arn:aws:iam::<AWS_ACCOUNT_ID>:role/databricks-ossie-role"},
  "Action":"sts:AssumeRole"}
]}
JSON

aws iam update-assume-role-policy --role-name databricks-ossie-role \
  --policy-document file:///tmp/dbx-trust.json --profile <PROFILE>
```

Then the external location and catalog:

```bash
databricks external-locations create --profile <DBX_PROFILE> --json '{
  "name": "ossie-interop-s3",
  "url": "s3://<BUCKET>/",
  "credential_name": "ossie-s3-credential",
  "comment": "Shared bucket for Ossie interop and Iceberg tables"
}'
```

```sql
CREATE CATALOG IF NOT EXISTS demos;
CREATE SCHEMA IF NOT EXISTS demos.ext_semantic_interop;
```

Verify Databricks can actually read the bucket, which is the real test of Phase 5:

```sql
LIST 's3://<BUCKET>/iceberg/'
```

It should show the `customers.<suffix>/` and `orders.<suffix>/` directories from Phase 4.
If this fails, the trust policy is wrong; do not continue.

---

## Phase 6: hand over to the demo scripts

Everything from here is already scripted and needs no configuration.

1. Update `S3_BUCKET` in the notebook config cells if the bucket name differs from the
   default. The value can also be read from Unity Catalog rather than hardcoded:
   `DESCRIBE EXTERNAL LOCATION` returns a `url` column.
2. Run the offline gate, which needs no cloud access:
   ```
   python3 tests/test_convergence.py
   python3 tests/test_no_loop.py
   ```
3. Run `assets/notebooks/bidirectional/00_snowflake_setup.sql`.
4. Run `assets/notebooks/bidirectional/00_databricks_setup.ipynb`.
5. Follow `docs/DEMO_RUNBOOK_BIDIRECTIONAL.md`.

---

## Final verification, to report back to the user

| Check | Command | Expected |
|---|---|---|
| Snowflake data | region aggregate on `ORDERS`/`CUSTOMERS` | EAST 750/5/12, WEST 700/5/11 |
| Semantic view | `SELECT * FROM SEMANTIC_VIEW(SALES_SV ...)` | EAST 750/5, WEST 700/5 |
| Stage writable | `SYSTEM$VALIDATE_STORAGE_INTEGRATION(... 'write')` | passes |
| Directory table | `SELECT * FROM DIRECTORY(@OSSIE_S3_STAGE)` | runs, may be empty |
| Databricks data | same aggregate in `demos.ext_semantic_interop` | identical numbers |
| Databricks S3 read | `LIST 's3://<BUCKET>/iceberg/'` | both table directories |
| Offline gate | the two test scripts | all checks pass |

State plainly which of these you ran and which you did not.

---

## Known pitfalls

**Storage integration DDL rejects variables.** Covered above, and worth repeating because
the error message (`unexpected '||'`) does not point at the cause.

**Snowflake randomises the Iceberg base location.** Recreating a table produces a new
suffix while the old directory may remain on S3, so external readers can see two
directories for one table and pick the wrong one. When recreating tables, clear the stale
directories. Without AWS credentials this can be done from Snowflake with a temporary stage
over the `iceberg/` prefix and `REMOVE`, or from Databricks with `dbutils.fs.rm`.

**Databricks file arrival triggers do not fire on same-name overwrites.** The demo rewrites
`sales_model.yaml` in place, so a file-arrival trigger will never fire on it. Use versioned
filenames if you want event-driven sync on that side. Snowflake's equivalent, a directory
table with `AUTO_REFRESH` plus an S3 event notification to the Snowflake-managed SQS queue,
does work.

**Serverless compute and `%pip`.** Installing the Apache Ossie converter from GitHub costs
45 to 75 seconds per cold run. For repeated use, install `ossie-databricks` as a cluster
library or environment dependency.

**Region mismatch.** A bucket in a different region from the Snowflake account works but
adds egress cost and latency. Keep them together unless there is a reason not to.

**Cross-account IAM.** If the S3 bucket is in a different AWS account from the IAM roles,
the bucket policy needs to grant access as well as the role policy. Simpler to keep both in
one account.

---

## Teardown

`setup/teardown.sql` removes the Snowflake objects. On the other two:

```bash
databricks external-locations delete ossie-interop-s3 --profile <DBX_PROFILE>
databricks storage-credentials delete ossie-s3-credential --profile <DBX_PROFILE>

aws s3 rm s3://<BUCKET> --recursive --profile <PROFILE>
aws s3api delete-bucket --bucket <BUCKET> --profile <PROFILE>
for ROLE in snowflake-ossie-role databricks-ossie-role; do
  aws iam detach-role-policy --role-name $ROLE \
    --policy-arn arn:aws:iam::<AWS_ACCOUNT_ID>:policy/ossie-s3-access --profile <PROFILE>
  aws iam delete-role --role-name $ROLE --profile <PROFILE>
done
aws iam delete-policy --policy-arn arn:aws:iam::<AWS_ACCOUNT_ID>:policy/ossie-s3-access --profile <PROFILE>
```

Confirm with the user before running any of this. Dropping the Snowflake catalog for
managed Iceberg tables deletes the underlying Parquet files.
