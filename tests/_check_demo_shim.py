import ast
import json
import sys
import types
import warnings

sys.path.insert(0, 'assets')
import yaml

from ossie_converter import convert_metric_view_to_ossie, convert_ossie_to_metric_view
from ossie_sync import semantic_fingerprint

stub = types.ModuleType("ossie_databricks")
stub.convert_metric_view_to_ossie = convert_metric_view_to_ossie
stub.convert_ossie_to_metric_view = convert_ossie_to_metric_view
sys.modules["ossie_databricks"] = stub

NB = 'assets/notebooks/manual/DBX/01_ossie_to_metric_view.ipynb'
nb = json.load(open(NB))
src = next(''.join(c['source']) for c in nb['cells']
           if c['cell_type'] == 'code' and 'def snowflake_to_converter' in ''.join(c['source']))
ast.parse(src)
print("demo DBX shim cell parses")
for token in ("def _pop_synonyms", "def _keep_synonyms_as_extension",
              "_keep_synonyms_as_extension(m)", '"ai_context"] = {"synonyms"',
              'ds.pop("primary_key", None)', 'target["primary_key"] = keys',
              "_drop_object_ai_context(root)"):
    print(f"  present: {token!r} -> {token in src}")

shim_only = src.split('def import_ossie_to_metric_view')[0]
ns = {}
exec(shim_only, ns)
s2c, c2s = ns['snowflake_to_converter'], ns['converter_to_snowflake']

SF, DBX = "DEMOS.EXT_SEMANTIC_INTEROP", "demos.ext_semantic_interop"
SF_OSSIE = {"version": "0.1.1", "semantic_model": [{
    "name": "SALES_SV",
    "datasets": [
        {"name": "CUSTOMERS", "source": f"{SF}.CUSTOMERS", "primary_key": ["CUSTOMER_ID"],
         "fields": [{"name": "REGION",
                     "expression": {"dialects": [{"dialect": "SNOWFLAKE", "expression": "region"}]},
                     "dimension": {}, "description": "Sales region",
                     "custom_extensions": [{"vendor_name": "SNOWFLAKE",
                        "data": '{"synonyms":["area","territory"],"access_modifier":"public_access"}'}]}]},
        {"name": "ORDERS", "source": f"{SF}.ORDERS", "primary_key": ["ORDER_ID"],
         "fields": [{"name": "ORDER_QTY",
                     "expression": {"dialects": [{"dialect": "SNOWFLAKE", "expression": "order_qty"}]}}],
         "custom_extensions": [{"vendor_name": "SNOWFLAKE", "data": json.dumps({"metrics": [
             {"synonyms": ["units", "quantity shipped"], "name": "TOTAL_QUANTITY",
              "description": "Total units shipped", "expr": "SUM(orders.order_qty)"}]})}]}],
    "relationships": [{"name": "ORDERS_TO_CUSTOMERS", "from": "ORDERS", "to": "CUSTOMERS",
                       "from_columns": ["CUSTOMER_ID"], "to_columns": ["CUSTOMER_ID"]}]}]}

sf_yaml = yaml.safe_dump(SF_OSSIE, sort_keys=False)


def to_mv(doc):
    with warnings.catch_warnings(record=True) as caught:
        warnings.simplefilter("always")
        mv = convert_ossie_to_metric_view(s2c(doc)).replace(SF, DBX)
    parsed = yaml.safe_load(mv)
    for join in parsed.get('joins') or []:
        join.pop('rely', None)
    return yaml.safe_dump(parsed, sort_keys=False), len(caught)


def to_ossie(mv):
    return c2s(convert_metric_view_to_ossie(mv).replace(DBX, SF), model_name="SALES_SV")


mv, nwarn = to_mv(sf_yaml)
mvd = yaml.safe_load(mv)
print()
print("Snowflake -> Databricks")
print("  warnings:", nwarn)
print("  dimension synonyms:", [(d['name'], d.get('synonyms')) for d in mvd.get('dimensions', [])])
print("  measure synonyms:", [(m['name'], m.get('synonyms')) for m in mvd.get('measures', [])])

back = to_ossie(mv)
bd = yaml.safe_load(back)
model = bd['semantic_model'][0]
print()
print("Databricks -> Snowflake")
print("  metrics are top level (queryable):", 'metrics' in model)
print("  metric names:", [m['name'] for m in model.get('metrics', [])])
print("  synonyms retained in file:", 'area' in back and 'units' in back)
print("  object ai_context remaining:", 'ai_context' in back)

base, cur, ok = semantic_fingerprint(sf_yaml), sf_yaml, True
for hop in (1, 2):
    cur = to_ossie(to_mv(cur)[0])
    same = semantic_fingerprint(cur) == base
    ok &= same
    print(f"  fingerprint hop {hop}: {'ok' if same else 'MISMATCH'}")

good = (nwarn == 0 and ok and 'metrics' in model
        and 'area' in back and 'units' in back and 'ai_context' not in back)
print()
print("DEMO DBX SHIM OK" if good else "PROBLEM")
