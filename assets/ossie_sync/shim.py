# Licensed under Apache-2.0 (this file is original to the demo, not from apache/ossie).
"""Bridge between Snowflake's Ossie dialect and the Apache Ossie Databricks converter.

Why this exists
---------------
Snowflake's SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW emits Ossie **0.1.1** and the
vendored Apache converter tracks **0.2.0.dev0** (an exact-match check). The two spec
revisions differ in three concrete ways that this module reconciles:

1. version string           0.1.1                 <->  0.2.0.dev0
2. expression dialect       SNOWFLAKE             <->  ANSI_SQL / DATABRICKS
3. metric placement         dataset custom_ext    <->  model-level `metrics`

Item (3) is the load-bearing one: Snowflake stores metrics inside
`datasets[*].custom_extensions[SNOWFLAKE].data` as a JSON blob, while the Apache
converter reads a top-level `metrics` list. Without hoisting, the generated Metric
View has no measures at all.

The transforms are deliberately narrow and reversible so the interop story stays
honest: the semantic content (names, expressions, relationships) is untouched; only
the envelope (version tag, dialect label, metric location) is adapted.
"""

import json
import re

import yaml

CONVERTER_OSSIE_VERSION = "0.2.0.dev0"   # what the vendored Apache converter requires
SNOWFLAKE_OSSIE_VERSION = "0.1.1"        # what Snowflake emits / expects on import
SNOWFLAKE_DIALECT = "SNOWFLAKE"
ANSI_DIALECT = "ANSI_SQL"
DATABRICKS_DIALECT = "DATABRICKS"


def _relabel_dialects(expression_obj, frm, to):
    """Relabel every `dialect: <frm>` to `<to>` inside an Ossie expression object."""
    if not isinstance(expression_obj, dict):
        return
    for d in expression_obj.get("dialects", []) or []:
        if d.get("dialect") == frm:
            d["dialect"] = to


def snowflake_to_converter(ossie_yaml, drop_fact_fields=True):
    """Snowflake Ossie 0.1.1  ->  Apache-converter-ready Ossie 0.2.0.dev0.

    - bumps the version string
    - relabels SNOWFLAKE-dialect expressions to ANSI_SQL (the converter only reads
      DATABRICKS/ANSI_SQL)
    - hoists metrics out of each dataset's SNOWFLAKE custom_extension up to a
      model-level `metrics` list, stripping the `<dataset>.` qualifier so measure
      expressions are bare fact columns (the Databricks idiom: SUM(order_amount))
    - by default drops fact fields (those with no `dimension` marker) so they do not
      become groupable Metric View dimensions; they live on inside measure expressions
    """
    root = yaml.safe_load(ossie_yaml)
    root["version"] = CONVERTER_OSSIE_VERSION

    for model in root.get("semantic_model", []) or []:
        hoisted = []
        for ds in model.get("datasets", []) or []:
            ds_name = ds.get("name", "")
            qual = re.compile(re.escape(ds_name) + r"\.", re.IGNORECASE)

            # Hoist metrics from this dataset's SNOWFLAKE custom_extension.
            kept_ext = []
            for ext in ds.get("custom_extensions", []) or []:
                if ext.get("vendor_name") == SNOWFLAKE_DIALECT:
                    blob = json.loads(ext.get("data") or "{}")
                    for m in blob.get("metrics", []) or []:
                        expr = qual.sub("", m["expr"])  # SUM(orders.order_amount) -> SUM(order_amount)
                        hoisted.append({
                            "name": m["name"],
                            "expression": {
                                "dialects": [{"dialect": ANSI_DIALECT, "expression": expr}]
                            },
                        })
                else:
                    kept_ext.append(ext)
            if kept_ext:
                ds["custom_extensions"] = kept_ext
            else:
                ds.pop("custom_extensions", None)

            # Fields: relabel dialects, strip field-level SNOWFLAKE extensions, and
            # optionally drop facts (kept only if they carry a `dimension` marker).
            new_fields = []
            for f in ds.get("fields", []) or []:
                _relabel_dialects(f.get("expression"), SNOWFLAKE_DIALECT, ANSI_DIALECT)
                f.pop("custom_extensions", None)
                if drop_fact_fields and "dimension" not in f:
                    continue
                new_fields.append(f)
            if new_fields:
                ds["fields"] = new_fields
            else:
                ds.pop("fields", None)

        if hoisted:
            model["metrics"] = (model.get("metrics", []) or []) + hoisted

        # Metrics that are ALREADY model-level need the same treatment as hoisted ones.
        # This is the second-hop case: converter_to_snowflake leaves metrics at model
        # level, labelled SNOWFLAKE and re-qualified as SUM(ORDERS.order_amount). Without
        # this the converter finds "no DATABRICKS/ANSI_SQL dialect" and silently drops
        # every metric, so the second round trip loses the whole measure set and the sync
        # never converges.
        ds_names = [ds.get("name", "") for ds in model.get("datasets", []) or [] if ds.get("name")]
        for m in model.get("metrics", []) or []:
            _relabel_dialects(m.get("expression"), SNOWFLAKE_DIALECT, ANSI_DIALECT)
            for d in (m.get("expression") or {}).get("dialects", []) or []:
                if "expression" not in d:
                    continue
                for ds_name in ds_names:
                    d["expression"] = re.sub(
                        re.escape(ds_name) + r"\.", "", d["expression"], flags=re.IGNORECASE
                    )

    return yaml.safe_dump(root, sort_keys=False)


def converter_to_snowflake(ossie_yaml, dialect=SNOWFLAKE_DIALECT, model_name=None):
    """Apache-converter Ossie 0.2.0.dev0  ->  Snowflake-importable Ossie 0.1.1.

    Databricks Metric Views don't carry Snowflake's fact/dimension distinction, and the
    forward trip dropped the fact columns, so this reverse trip must rebuild what
    Snowflake's importer needs:

    - resets the version string and relabels DATABRICKS-dialect expressions to SNOWFLAKE
    - qualifies each measure's bare columns with the fact table (COUNT(order_id) ->
      COUNT(ORDERS.order_id)); Snowflake derived metrics need a logical-table-qualified
      column
    - reconstructs the referenced fact columns as fields on the fact dataset (no
      `dimension` marker => facts) so the metric expressions resolve
    - marks every field on a non-fact (joined) dataset with `dimension: {}` so Snowflake
      classifies region/customer_name as dimensions, not facts
    - optionally renames the model (the new semantic view name) without touching the
      fact dataset name
    """
    root = yaml.safe_load(ossie_yaml)
    root["version"] = SNOWFLAKE_OSSIE_VERSION
    for model in root.get("semantic_model", []) or []:
        datasets = model.get("datasets", []) or []

        # Normalize dataset names to uppercase. Snowflake's importer resolves
        # metric table-qualifiers against dataset names case-sensitively, and
        # unquoted Snowflake identifiers are uppercase internally. Without this,
        # a lowercase dataset name (from a Databricks table named "orders")
        # causes "invalid identifier" errors on import.
        name_map = {}
        for ds in datasets:
            old_name = ds["name"]
            ds["name"] = old_name.upper()
            if old_name != ds["name"]:
                name_map[old_name] = ds["name"]
        for rel in model.get("relationships", []) or []:
            if "from" in rel:
                rel["from"] = rel["from"].upper()
            if "to" in rel:
                rel["to"] = rel["to"].upper()

        fact_ds_name = datasets[0]["name"] if datasets else None

        # Fields: relabel dialects; mark joined-dataset fields as dimensions.
        for ds in datasets:
            is_fact = ds.get("name") == fact_ds_name
            for f in ds.get("fields", []) or []:
                _relabel_dialects(f.get("expression"), DATABRICKS_DIALECT, dialect)
                if not is_fact:
                    f.setdefault("dimension", {})

        # Metrics: relabel, qualify bare columns with the fact table, then collect
        # every fact column the metric references - whether it arrived bare
        # (COUNT(order_id)) or already qualified (SUM(ORDERS.order_qty)) - so the
        # fact fields can be rebuilt for all of them.
        fact_cols = []
        ref_re = re.compile(re.escape(fact_ds_name) + r"\.([A-Za-z_]\w*)") if fact_ds_name else None
        for m in model.get("metrics", []) or []:
            _relabel_dialects(m.get("expression"), DATABRICKS_DIALECT, dialect)
            if not fact_ds_name:
                continue
            for d in (m.get("expression") or {}).get("dialects", []) or []:
                if "expression" in d:
                    # Fix case of pre-existing qualifiers that arrived lowercase
                    # (e.g. "orders.order_id" -> "ORDERS.order_id") so they match
                    # the uppercased dataset name.
                    for old, new in name_map.items():
                        d["expression"] = re.sub(
                            r"\b" + re.escape(old) + r"\.", new + ".", d["expression"])
                    d["expression"] = _qualify_columns(d["expression"], fact_ds_name)
                    for c in ref_re.findall(d["expression"]):
                        if c not in fact_cols:
                            fact_cols.append(c)

        # Rebuild the referenced columns as fact fields on the fact dataset.
        if fact_ds_name and fact_cols:
            fact_ds = datasets[0]
            existing = {f["name"].lower() for f in fact_ds.get("fields", []) or []}
            flds = fact_ds.setdefault("fields", [])
            for c in fact_cols:
                if c.lower() not in existing:
                    flds.append({
                        "name": c.upper(),
                        "expression": {"dialects": [{"dialect": dialect, "expression": c}]},
                    })

        if model_name:
            model["name"] = model_name
    return yaml.safe_dump(root, sort_keys=False)


# Prefix each bare column with the fact table; SQL function names (followed by "(")
# and already-qualified names (customer.c_name, ORDERS.order_qty) are left alone.
def _qualify_columns(expr, table):
    return re.sub(
        r"(?<![\w.])([A-Za-z_]\w*)(?!\s*\()(?![\w.])",
        lambda m: f"{table}.{m.group(1)}",
        expr,
    )
