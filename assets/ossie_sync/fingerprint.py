"""Canonical semantic fingerprint for an Ossie document.

Why this exists
---------------
The Snowflake <-> Databricks round trip is not byte-stable. The same semantic model
comes back with different dataset name casing, `primary_key` renamed to `unique_keys`,
facts dropped, dialect labels rewritten, and expressions gaining or losing table
qualifiers (`SUM(orders.order_amount)` on one side, `SUM(order_amount)` on the other).

So a sync that compares raw YAML, or a hash of it, never sees the two sides as equal and
writes forever. A sync that compares file timestamps is worse: every write makes the
writer the most recent change, so the model ping-pongs between platforms.

`semantic_fingerprint` solves this by hashing only the part of the model that both
platforms can express, in a normalized form that survives the trip. Two models with the
same fingerprint are treated as the same model, which is what lets the sync go quiet.

What is included
----------------
    tables          alias and source table, lowercased, last path component only
    relationships   from, to, and the join columns
    dimensions      qualified dimension names, sorted
    metrics         name and expression, sorted, table qualifiers stripped

What is excluded, and why
-------------------------
    Ossie `version`         differs by spec revision (0.1.1 against 0.2.0.dev0)
    dialect labels          SNOWFLAKE against ANSI_SQL against DATABRICKS
    comments, descriptions  Databricks does not round-trip them
    FACTS                   Snowflake-only concept, dropped by the converter
    relationship names      the converter rewrites their casing
    primary keys            Snowflake `primary_key` becomes `unique_keys` and back
    field and key order     not semantically meaningful

Excluding these has a real cost: editing only a comment, or only a fact, propagates
nothing. That is the deliberate trade. Including them would mean the two sides never
agree and the sync would write on every tick forever.
"""

import hashlib
import json
import re

import yaml

FINGERPRINT_VERSION = "1"

# Matches a leading table qualifier on a column reference, e.g. the "orders." in
# "orders.order_amount". Stripped so that SUM(orders.order_amount) on the Snowflake side
# and SUM(order_amount) on the Databricks side produce the same fingerprint.
_QUALIFIER = re.compile(r"\b[A-Za-z_]\w*\.(?=[A-Za-z_]\w*)")
_WHITESPACE = re.compile(r"\s+")


def normalize_expression(expr):
    """Reduce a SQL expression to a comparable form.

    Lowercases, collapses whitespace, strips table qualifiers, and removes spaces
    around punctuation so that formatting differences do not register as changes.

        >>> normalize_expression("SUM( orders.order_amount )")
        'sum(order_amount)'
        >>> normalize_expression("sum(order_amount)")
        'sum(order_amount)'
    """
    if not expr:
        return ""
    text = _QUALIFIER.sub("", str(expr))
    text = _WHITESPACE.sub(" ", text).strip().lower()
    for token in ("(", ")", ",", "+", "-", "*", "/"):
        text = text.replace(" " + token, token).replace(token + " ", token)
    return text


def _last_identifier(source):
    """DEMOS.EXT_SEMANTIC_INTEROP.ORDERS -> orders"""
    return str(source or "").split(".")[-1].strip().strip('"').lower()


def _pick_expression(expression_obj):
    """Return the first expression string from an Ossie expression object.

    Dialect is ignored on purpose. The same expression labelled SNOWFLAKE, ANSI_SQL or
    DATABRICKS is the same expression for fingerprint purposes.
    """
    if not isinstance(expression_obj, dict):
        return ""
    for dialect in expression_obj.get("dialects") or []:
        if dialect.get("expression"):
            return dialect["expression"]
    return ""


def semantic_projection(ossie_yaml):
    """Reduce an Ossie document to the platform-neutral structure that gets hashed.

    Returned separately from the hash so notebooks can print it and show exactly what
    is being compared. When a sync will not converge, diffing two projections is the
    fastest way to find out which field is to blame.
    """
    root = yaml.safe_load(ossie_yaml) if isinstance(ossie_yaml, str) else ossie_yaml
    models = root.get("semantic_model") or []

    tables, relationships, dimensions, metrics = [], [], [], []

    for model in models:
        datasets = model.get("datasets") or []

        for dataset in datasets:
            alias = _last_identifier(dataset.get("name"))
            tables.append({"alias": alias, "source": _last_identifier(dataset.get("source"))})

            for field in dataset.get("fields") or []:
                # Only dimensions are portable. Snowflake facts have no `dimension` key
                # and are dropped by the Databricks converter, so including them here
                # would break convergence.
                if "dimension" not in field:
                    continue
                dimensions.append(f"{alias}.{str(field.get('name','')).lower()}")

        for rel in model.get("relationships") or []:
            # Ossie spells the join columns from_columns / to_columns. Only the join
            # columns are fingerprinted; the relationship's own name is not, because the
            # converter rewrites its casing (ORDERS_TO_CUSTOMERS -> ORDERS_to_CUSTOMERS).
            relationships.append({
                "from": _last_identifier(rel.get("from")),
                "to": _last_identifier(rel.get("to")),
                "from_columns": sorted(_last_identifier(c) for c in rel.get("from_columns") or []),
                "to_columns": sorted(_last_identifier(c) for c in rel.get("to_columns") or []),
            })

        # Snowflake stores metrics inside datasets[*].custom_extensions as a JSON blob;
        # the Apache converter uses a top-level `metrics` list. Read both.
        for metric in model.get("metrics") or []:
            metrics.append({
                "name": str(metric.get("name", "")).lower(),
                "expr": normalize_expression(_pick_expression(metric.get("expression"))),
            })

        for dataset in datasets:
            for ext in dataset.get("custom_extensions") or []:
                if ext.get("vendor_name") != "SNOWFLAKE":
                    continue
                try:
                    blob = json.loads(ext.get("data") or "{}")
                except (ValueError, TypeError):
                    continue
                for metric in blob.get("metrics") or []:
                    metrics.append({
                        "name": str(metric.get("name", "")).lower(),
                        "expr": normalize_expression(metric.get("expr")),
                    })

    def dedupe(rows, key):
        seen, out = set(), []
        for row in rows:
            marker = key(row)
            if marker not in seen:
                seen.add(marker)
                out.append(row)
        return out

    return {
        "fingerprint_version": FINGERPRINT_VERSION,
        "tables": sorted(dedupe(tables, lambda t: t["alias"]), key=lambda t: t["alias"]),
        "relationships": sorted(
            dedupe(relationships, lambda r: (r["from"], r["to"], tuple(r["from_columns"]))),
            key=lambda r: (r["from"], r["to"]),
        ),
        "dimensions": sorted(set(dimensions)),
        "metrics": sorted(dedupe(metrics, lambda m: m["name"]), key=lambda m: m["name"]),
    }


def semantic_fingerprint(ossie_yaml):
    """sha256 over the canonical projection. Stable across the round trip."""
    canonical = json.dumps(semantic_projection(ossie_yaml), sort_keys=True, separators=(",", ":"))
    return "sha256:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest()


def describe(fingerprint):
    """Short form for log lines and notebook output."""
    if not fingerprint:
        return "(none)"
    return fingerprint.split(":")[-1][:12]
