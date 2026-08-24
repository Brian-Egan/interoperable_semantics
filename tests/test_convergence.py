"""Offline proof that the sync converges. No Snowflake or Databricks connection needed.

Run: python3 tests/test_convergence.py

The sync in these demos writes only when two fingerprints disagree. That is only safe if
a model that has been through the Snowflake -> Ossie -> Metric View -> Ossie -> Snowflake
round trip fingerprints the same as it did going in. If it does not, both sides see a
change on every tick and the model ping-pongs between platforms forever.

This test runs the full transform chain twice, in process, against the vendored Apache
converter, and asserts the fingerprint never moves. It is the gate to clear before
touching either platform, because it fails in one second where the live version fails
slowly and confusingly.

The fixture below is the exact structure Snowflake's
SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW returned for SALES_SV, including the metrics
buried in a dataset custom_extensions JSON blob.
"""

import os
import sys

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "assets"))

from ossie_converter import convert_metric_view_to_ossie, convert_ossie_to_metric_view
from ossie_sync import semantic_fingerprint, semantic_projection
from ossie_sync.shim import converter_to_snowflake, snowflake_to_converter

SF_NAMESPACE = "DEMOS.EXT_SEMANTIC_INTEROP"
DBX_NAMESPACE = "demos.ext_semantic_interop"

SF_OSSIE = {
    "version": "0.1.1",
    "semantic_model": [{
        "name": "SALES_SV",
        "description": "Sales star for Ossie interop demo",
        "datasets": [
            {"name": "CUSTOMERS", "source": f"{SF_NAMESPACE}.CUSTOMERS",
             "primary_key": ["CUSTOMER_ID"],
             "fields": [
                 {"name": "CUSTOMER_NAME",
                  "expression": {"dialects": [{"dialect": "SNOWFLAKE", "expression": "customer_name"}]},
                  "dimension": {}},
                 {"name": "REGION",
                  "expression": {"dialects": [{"dialect": "SNOWFLAKE", "expression": "region"}]},
                  "dimension": {}},
             ]},
            {"name": "ORDERS", "source": f"{SF_NAMESPACE}.ORDERS",
             "primary_key": ["ORDER_ID"],
             "fields": [
                 {"name": "ORDER_AMOUNT",
                  "expression": {"dialects": [{"dialect": "SNOWFLAKE", "expression": "order_amount"}]},
                  "custom_extensions": [{"vendor_name": "SNOWFLAKE", "data": '{"access_modifier":"public_access"}'}]},
                 {"name": "ORDER_QTY",
                  "expression": {"dialects": [{"dialect": "SNOWFLAKE", "expression": "order_qty"}]},
                  "custom_extensions": [{"vendor_name": "SNOWFLAKE", "data": '{"access_modifier":"public_access"}'}]},
             ],
             "custom_extensions": [{"vendor_name": "SNOWFLAKE", "data":
                 '{"metrics":[{"name":"ORDER_COUNT","expr":"COUNT(orders.order_id)"},'
                 '{"name":"TOTAL_ORDER_AMOUNT","expr":"SUM(orders.order_amount)"}]}'}]},
        ],
        "relationships": [
            {"name": "ORDERS_TO_CUSTOMERS", "from": "ORDERS", "to": "CUSTOMERS",
             "from_columns": ["CUSTOMER_ID"], "to_columns": ["CUSTOMER_ID"]}
        ],
    }],
}

UNSUPPORTED_JOIN_FIELDS = ("rely",)


def strip_unsupported_fields(mv_yaml_text):
    """Remove join fields that older Databricks serdes reject."""
    mv = yaml.safe_load(mv_yaml_text)

    def clean(joins):
        for join in joins or []:
            for field in UNSUPPORTED_JOIN_FIELDS:
                join.pop(field, None)
            clean(join.get("joins"))

    clean(mv.get("joins"))
    return yaml.safe_dump(mv, sort_keys=False)


def ossie_to_metric_view(ossie_yaml):
    """The Databricks import path, exactly as notebook 21 runs it."""
    mv_yaml = convert_ossie_to_metric_view(snowflake_to_converter(ossie_yaml))
    return strip_unsupported_fields(mv_yaml.replace(SF_NAMESPACE, DBX_NAMESPACE))


def metric_view_to_ossie(mv_yaml, model_name="SALES_SV"):
    """The Databricks export path, exactly as notebook 21 runs it."""
    ossie = convert_metric_view_to_ossie(mv_yaml).replace(DBX_NAMESPACE, SF_NAMESPACE)
    return converter_to_snowflake(ossie, model_name=model_name)


def round_trip(ossie_yaml):
    """One full hop out to Databricks and back."""
    return metric_view_to_ossie(ossie_to_metric_view(ossie_yaml))


def check(label, actual, expected, failures):
    ok = actual == expected
    print(f"  {'ok  ' if ok else 'FAIL'}  {label:<44} {actual.split(':')[-1][:12]}")
    if not ok:
        failures.append(label)
    return ok


def main():
    failures = []
    sf_yaml = yaml.safe_dump(SF_OSSIE, sort_keys=False)
    baseline = semantic_fingerprint(sf_yaml)

    print("\nProjection being fingerprinted")
    print("-" * 62)
    projection = semantic_projection(sf_yaml)
    for key in ("tables", "relationships", "dimensions", "metrics"):
        print(f"  {key:<15} {projection[key]}")

    print("\nFingerprint stability across two round trips")
    print("-" * 62)
    print(f"  base  Snowflake export                              {baseline.split(':')[-1][:12]}")

    current = sf_yaml
    for hop in (1, 2):
        mv_yaml = ossie_to_metric_view(current)
        check(f"hop {hop} Metric View", semantic_fingerprint(metric_view_to_ossie(mv_yaml)),
              baseline, failures)
        current = round_trip(current)
        check(f"hop {hop} back to Snowflake Ossie", semantic_fingerprint(current), baseline,
              failures)

    print("\nA real change must change the fingerprint")
    print("-" * 62)
    mv = yaml.safe_load(ossie_to_metric_view(sf_yaml))
    mv.setdefault("measures", []).append({"name": "TOTAL_QUANTITY", "expr": "SUM(order_qty)"})
    with_measure = metric_view_to_ossie(yaml.safe_dump(mv, sort_keys=False))
    added = semantic_fingerprint(with_measure)
    if added == baseline:
        print("  FAIL  adding TOTAL_QUANTITY did not change the fingerprint")
        failures.append("added measure not detected")
    else:
        print(f"  ok    TOTAL_QUANTITY changed it            {added.split(':')[-1][:12]}")

    # And the changed model must itself be stable, or step (d) of the demo loops.
    check("added measure survives a round trip", semantic_fingerprint(round_trip(with_measure)),
          added, failures)

    print("\nCosmetic differences must NOT change the fingerprint")
    print("-" * 62)
    noisy = yaml.safe_load(sf_yaml)
    noisy["version"] = "0.2.0.dev0"
    noisy["semantic_model"][0]["description"] = "a completely different comment"
    noisy["semantic_model"][0]["datasets"][0]["name"] = "customers"
    for dialect in noisy["semantic_model"][0]["datasets"][0]["fields"][0]["expression"]["dialects"]:
        dialect["dialect"] = "DATABRICKS"
    check("version, comment, casing, dialect ignored",
          semantic_fingerprint(yaml.safe_dump(noisy, sort_keys=False)), baseline, failures)

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s): {', '.join(failures)}")
        print("The sync will not converge. Do not enable the tasks.")
        return 1
    print("All checks passed. The fingerprint is stable across the round trip.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
