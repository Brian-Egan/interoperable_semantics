# Vendored converter provenance

These files are copied verbatim from the Apache Ossie repository so the demo runs
offline with no PyPI dependency (the `apache-ossie-databricks` package is not yet
published).

- Repository: https://github.com/apache/ossie
- Path in repo: `converters/databricks/src/ossie_databricks/`
- Pinned commit: `01058aa416423cf43a74e7f9fb7f5f70981a418e` (also in `.pinned_commit`)
- License: Apache-2.0 (headers retained in each file)
- Runtime dependency: PyYAML only. Python 3.11+.

Public API:

```python
from ossie_databricks import convert_ossie_to_metric_view, convert_metric_view_to_ossie
```

## Version note (why the shim exists)

`_common.py` pins `OSSIE_VERSION = "0.2.0.dev0"` and checks it exactly. Snowflake's
`SYSTEM$READ_OSSIE_YAML_FROM_SEMANTIC_VIEW` emits Ossie `0.1.1`, and the converter
only reads `DATABRICKS`/`ANSI_SQL` expression dialects (not `SNOWFLAKE`). The
`ossie_shim.py` module in the project root bridges the two: it rewrites the version
string and relabels expression dialects in both directions. See that file for detail.

To re-vendor from a newer commit, re-run the curl loop in the demo build notes with a
new pin and re-check `OSSIE_VERSION` in `_common.py`.
