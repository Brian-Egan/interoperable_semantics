#!/usr/bin/env python3
"""Stamp the shared ossie_sync source into the sync notebooks.

The sync logic has to be identical on both platforms. If the Snowflake copy and the
Databricks copy of the fingerprint drift apart by one `.lower()`, the two sides never
agree on a fingerprint and the sync writes on every tick forever. Keeping one editable
copy is therefore not tidiness, it is correctness.

The notebooks still carry the code inline, because these are demo notebooks and the logic
should be readable on screen rather than hidden in an imported package. This script keeps
both properties: edit `assets/ossie_sync/*.py`, run this, and every notebook gets the same
source.

Usage
-----
    python3 assets/build_notebooks.py            stamp all notebooks
    python3 assets/build_notebooks.py --check    exit 1 if any notebook is stale

Only the region between the markers is touched. Everything else in the notebook, including
the prose and every other cell, is left exactly as it is, so notebooks can still be edited
by hand or in Snowsight and Databricks.

    # --- BEGIN GENERATED: ossie_sync.fingerprint ---
    ...replaced...
    # --- END GENERATED: ossie_sync.fingerprint ---
"""

import argparse
import json
import os
import re
import sys

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE_DIR = os.path.join(REPO, "assets", "ossie_sync")
NOTEBOOK_DIR = os.path.join(REPO, "assets", "notebooks")

# Which module each notebook needs. Snowflake reads and writes Ossie natively, so it never
# needs the shim or the Apache converter; Databricks carries its own shim inline, because
# explaining the shim is part of that demo.
SNOWFLAKE_MODULES = ["fingerprint", "decide", "state"]
DATABRICKS_MODULES = ["fingerprint", "decide", "state"]

NOTEBOOKS = {
    "bidirectional/02_databricks_metric_view.ipynb": DATABRICKS_MODULES,
    "bidirectional/03_snowflake_automation.ipynb": SNOWFLAKE_MODULES,
    "unidirectional/10_snowflake_managed_export.ipynb": SNOWFLAKE_MODULES,
    "unidirectional/11_databricks_managed_mirror.ipynb": DATABRICKS_MODULES + ["shim"],
}

BEGIN = "# --- BEGIN GENERATED: ossie_sync.{name} ---"
END = "# --- END GENERATED: ossie_sync.{name} ---"

HEADER = (
    "# Generated from assets/ossie_sync/{name}.py by assets/build_notebooks.py.\n"
    "# Edit that file and re-run the build; changes made here are overwritten.\n"
)


def module_source(name):
    """Module source with imports stripped.

    The notebooks import yaml, json, re and hashlib once in their own setup cell, and the
    relative `from .decide import ...` in __init__ has no meaning outside a package.
    """
    with open(os.path.join(MODULE_DIR, f"{name}.py")) as fh:
        text = fh.read()
    lines = []
    for line in text.splitlines():
        if re.match(r"^(import|from)\s+", line) and "ossie_sync" not in line:
            continue
        if re.match(r"^from \.", line):
            continue
        lines.append(line)
    return HEADER.format(name=name) + "\n".join(lines).strip() + "\n"


def stamp(cell_source, name, generated):
    """Replace the marked region in one cell's source. Returns None if no marker."""
    begin, end = BEGIN.format(name=name), END.format(name=name)
    if begin not in cell_source or end not in cell_source:
        return None
    prefix = cell_source.split(begin)[0]
    suffix = cell_source.split(end, 1)[1]
    return f"{prefix}{begin}\n{generated}{end}{suffix}"


def process(path, modules, check_only):
    with open(path) as fh:
        notebook = json.load(fh)

    changed, found = False, set()
    for cell in notebook.get("cells", []):
        if cell.get("cell_type") != "code":
            continue
        source = "".join(cell["source"])
        for name in modules:
            updated = stamp(source, name, module_source(name))
            if updated is None:
                continue
            found.add(name)
            if updated != source:
                changed = True
                source = updated
        if source != "".join(cell["source"]):
            cell["source"] = source.splitlines(keepends=True)

    missing = set(modules) - found
    if missing:
        print(f"  warning: {os.path.basename(path)} has no marker for: {', '.join(sorted(missing))}")

    if changed and not check_only:
        with open(path, "w") as fh:
            json.dump(notebook, fh, indent=1)
            fh.write("\n")

    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true",
                        help="report stale notebooks and exit 1 without writing")
    args = parser.parse_args()

    stale = []
    for relative, modules in NOTEBOOKS.items():
        path = os.path.join(NOTEBOOK_DIR, relative)
        if not os.path.exists(path):
            print(f"  skip    {relative} (not built yet)")
            continue
        if process(path, modules, args.check):
            stale.append(relative)
            print(f"  {'stale' if args.check else 'wrote'}   {relative}")
        else:
            print(f"  ok      {relative}")

    if args.check and stale:
        print(f"\n{len(stale)} notebook(s) out of date. Run: python3 assets/build_notebooks.py")
        return 1
    print("\nAll notebooks match assets/ossie_sync/." if not stale else "\nDone.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
