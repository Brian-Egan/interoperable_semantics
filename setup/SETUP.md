# Setup Guide: Interoperable Semantics Demo

This guide walks you through setting up the demo from scratch on any Snowflake
account with any AWS account. The process takes about 15 minutes.

> **Faster option:** point Cortex Code at [`COCO_SETUP_GUIDE.md`](COCO_SETUP_GUIDE.md) and
> have it do this for you. Same steps, executed in order, with a verification gate after
> each phase.
>
> **Either way, do not run [`snowflake_setup.sql`](snowflake_setup.sql) on its own.** It is
> only the Snowflake half, and the objects it creates cannot reach S3 until the IAM trust
> policy has been updated with external IDs that do not exist until after the script runs.
> Follow the ordered steps below.

## Prerequisites

- AWS CLI installed and authenticated (`aws sts get-caller-identity` works)
- Snowflake account with ACCOUNTADMIN access
- Databricks workspace on AWS with Unity Catalog enabled and admin access
- Databricks CLI installed and authenticated (`databricks current-user me` works)

## Step 1: Choose Your Configuration

Edit these values before running anything:

```bash
# AWS
export AWS_ACCOUNT_ID="123456789012"       # Your AWS account ID
export AWS_REGION="us-west-2"              # Must match your Snowflake region
export S3_BUCKET="snowflake-ossie-interop" # Pick a globally unique name

# Snowflake
export SF_DATABASE="DEMOS"
export SF_DATA_SCHEMA="EXT_SEMANTIC_INTEROP"   # Iceberg tables, shared
export SF_SCHEMA="DEMO_SEMANTIC_INTEROP"       # one per flow: DEMO_, LIVE_, SNOWFLAKE_MANAGED_

# Databricks
export DBX_CATALOG="demos"
export DBX_DATA_SCHEMA="ext_semantic_interop"  # Iceberg tables, shared
export DBX_SCHEMA="demo_semantic_interop"      # one per flow
```

## Step 2: Create the S3 Bucket

```bash
aws s3api create-bucket \
  --bucket $S3_BUCKET \
  --region $AWS_REGION \
  --create-bucket-configuration LocationConstraint=$AWS_REGION
```

## Step 3: Create the IAM Policy

```bash
aws iam create-policy \
  --policy-name snowflake-ossie-s3-access \
  --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:GetObjectVersion",
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:ListBucket",
        "s3:GetBucketLocation"
      ],
      "Resource": [
        "arn:aws:s3:::'$S3_BUCKET'",
        "arn:aws:s3:::'$S3_BUCKET'/*"
      ]
    }
  ]
}'
```

## Step 4: Create the IAM Role for Snowflake

```bash
# Create with a placeholder trust policy (updated after Snowflake provides its ARN)
aws iam create-role \
  --role-name snowflake-ossie-role \
  --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::'$AWS_ACCOUNT_ID':root"},
      "Action": "sts:AssumeRole"
    }
  ]
}'

aws iam attach-role-policy \
  --role-name snowflake-ossie-role \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/snowflake-ossie-s3-access
```

## Step 5: Run the Snowflake Setup Script

Run `setup/snowflake_setup.sql` in your Snowflake account. Before running, replace
the placeholder values at the top of the script:

Values come from a gitignored `snowflake.yml`, not from editing the SQL:

```bash
cp snowflake.yml.example snowflake.yml   # then fill in s3_bucket and aws_account_id
snow sql -c <your-connection> -f setup/snowflake_setup.sql
```

The script reads them as `<% ctx.env.s3_bucket %>` and `<% ctx.env.aws_account_id %>`,
substituted client-side, so nothing sensitive reaches the command line or shell history.
Add `--silent` if you are running it on a shared screen: the CLI echoes the rendered SQL.

No AWS access key or secret is involved anywhere. Authentication is IAM role trust.

The script will output two values you need:
- `STORAGE_AWS_IAM_USER_ARN` -- Snowflake's IAM user
- `STORAGE_AWS_EXTERNAL_ID` -- two external IDs (one for stage, one for volume)

## Step 6: Update the IAM Trust Policy

After running the Snowflake setup, update the trust policy with the ARN and
external IDs that Snowflake provided:

```bash
# Replace these with actual values from DESC INTEGRATION / DESC EXTERNAL VOLUME
SF_IAM_USER_ARN="arn:aws:iam::XXXXXXXXX:user/YYYYYYYY"
SF_EXTERNAL_ID_STAGE="your_stage_external_id"
SF_EXTERNAL_ID_VOLUME="your_volume_external_id"

aws iam update-assume-role-policy \
  --role-name snowflake-ossie-role \
  --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": "'$SF_IAM_USER_ARN'"},
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {
          "sts:ExternalId": ["'$SF_EXTERNAL_ID_STAGE'", "'$SF_EXTERNAL_ID_VOLUME'"]
        }
      }
    }
  ]
}'
```

## Step 7: Set Up Databricks Access

Create a second IAM role for Databricks:

```bash
aws iam create-role \
  --role-name databricks-ossie-role \
  --assume-role-policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::'$AWS_ACCOUNT_ID':root"},
      "Action": "sts:AssumeRole"
    }
  ]
}'

aws iam attach-role-policy \
  --role-name databricks-ossie-role \
  --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/snowflake-ossie-s3-access
```

Create the storage credential (this returns the Unity Catalog ARN and external ID):

```bash
databricks storage-credentials create --json '{
  "name": "ossie-s3-credential",
  "aws_iam_role": {
    "role_arn": "arn:aws:iam::'$AWS_ACCOUNT_ID':role/databricks-ossie-role"
  },
  "comment": "Credential for interoperable semantics S3 bucket"
}'
```

From the output, note:
- `unity_catalog_iam_arn` (e.g., `arn:aws:iam::414351767826:role/unity-catalog-prod-UCMasterRole-XXXXX`)
- `external_id` (e.g., your Databricks account ID)

Update the Databricks IAM role trust policy:

```bash
UC_IAM_ARN="arn:aws:iam::414351767826:role/unity-catalog-prod-UCMasterRole-XXXXX"
DBX_EXTERNAL_ID="your-databricks-external-id"

aws iam update-assume-role-policy \
  --role-name databricks-ossie-role \
  --policy-document '{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {"AWS": "'$UC_IAM_ARN'"},
      "Action": "sts:AssumeRole",
      "Condition": {
        "StringEquals": {"sts:ExternalId": "'$DBX_EXTERNAL_ID'"}
      }
    },
    {
      "Effect": "Allow",
      "Principal": {"AWS": "arn:aws:iam::'$AWS_ACCOUNT_ID':role/databricks-ossie-role"},
      "Action": "sts:AssumeRole"
    }
  ]
}'
```

Create the external location (wait 30s after updating trust policy):

```bash
sleep 30
databricks external-locations create --json '{
  "name": "ossie-interop-s3",
  "url": "s3://'$S3_BUCKET'/",
  "credential_name": "ossie-s3-credential",
  "comment": "Shared S3 bucket for Snowflake-Databricks Ossie interop",
  "skip_validation": true
}'
```

Create the Databricks schema:

```bash
databricks schemas create --json '{
  "catalog_name": "'$DBX_CATALOG'",
  "name": "'$DBX_SCHEMA'",
  "comment": "External semantic interop demo using S3 backbone and Iceberg tables"
}'
```

## Step 8: Verify

1. In Snowflake, run: `LIST @DEMOS.DEMO_SEMANTIC_INTEROP.DEMO_OSSIE_STAGE;`
2. In AWS: `aws s3 ls s3://$S3_BUCKET/iceberg/ --recursive | head`
3. In Databricks: `dbutils.fs.ls("s3://<bucket>/ossie/")`

## Step 9: Run the Demo Notebooks

1. Run notebook 1 in Snowflake (creates semantic view, exports Ossie to S3)
2. Run notebook 2 in Databricks (reads Ossie, creates Metric View, exports back)
3. Run notebook 3 in Snowflake (imports Databricks export, verifies round-trip)

## Teardown

To remove everything:

```bash
# Snowflake (run setup/teardown.sql)
# AWS
aws s3 rb s3://$S3_BUCKET --force
aws iam detach-role-policy --role-name snowflake-ossie-role --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/snowflake-ossie-s3-access
aws iam detach-role-policy --role-name databricks-ossie-role --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/snowflake-ossie-s3-access
aws iam delete-role --role-name snowflake-ossie-role
aws iam delete-role --role-name databricks-ossie-role
aws iam delete-policy --policy-arn arn:aws:iam::${AWS_ACCOUNT_ID}:policy/snowflake-ossie-s3-access
# Databricks
databricks external-locations delete ossie-interop-s3
databricks storage-credentials delete ossie-s3-credential
```
