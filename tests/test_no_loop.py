"""Offline proof that two agents ticking every minute do not ping-pong.

Run: python3 tests/test_no_loop.py

test_convergence.py proves the fingerprint survives the round trip. This proves the thing
that actually worries you: that a Snowflake agent and a Databricks agent, both polling the
same file on a schedule, settle down after a change instead of trading the model back and
forth forever.

Both agents run the real fingerprint, the real decision function, the real shim and the
real Apache converter. Only the platforms are faked: S3 is a dict, the Semantic View and
the Metric View are strings. That is enough, because the loop is a property of the decision
logic and not of the storage.

The test also runs the timestamp-based scheme the earlier notebooks used, to show it
failing. That comparison is the reason the fingerprint exists.
"""

import os
import sys

import yaml

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(REPO, "assets"))
sys.path.insert(0, os.path.join(REPO, "tests"))

from ossie_sync import (
    BIDIRECTIONAL,
    SNOWFLAKE_MANAGED_MIRROR,
    SNOWFLAKE_MANAGED_SOURCE,
    base_of,
    decide,
    next_base,
    semantic_fingerprint,
    serialize_state,
    state_after,
)
from test_convergence import (
    SF_OSSIE,
    metric_view_to_ossie,
    ossie_to_metric_view,
)

MODEL = "ossie/sales_model.yaml"


class FakeS3(dict):
    """A dict that counts writes, so a loop shows up as a write count that never stops."""

    def __init__(self):
        super().__init__()
        self.writes = 0

    def put(self, key, body):
        self.writes += 1
        self[key] = body


class Agent:
    """One platform's sync loop. Holds a local model and its own state file."""

    def __init__(self, name, s3, allowed, state_key, local=None, conflict_winner="snowflake"):
        self.name = name
        self.s3 = s3
        self.allowed = allowed
        self.state_key = state_key
        self.local = local            # local model, as Snowflake-dialect Ossie YAML
        self.conflict_winner = conflict_winner
        self.actions = []

    def to_shared(self, ossie):
        """How this platform's local model is expressed in the shared file."""
        return ossie

    def from_shared(self, ossie):
        """How the shared file becomes this platform's local model."""
        return ossie

    def tick(self):
        shared = self.s3.get(MODEL)
        local_fp = semantic_fingerprint(self.local) if self.local else None
        remote_fp = semantic_fingerprint(shared) if shared else None
        base_fp = base_of(self.s3.get(self.state_key))

        decision = decide(local_fp, remote_fp, base_fp, allowed=self.allowed,
                          conflict_winner=self.conflict_winner, platform=self.name)

        if decision.action in ("IMPORT", "ADOPT", "REVERT_LOCAL_DRIFT"):
            self.local = self.from_shared(shared)
        elif decision.action == "EXPORT":
            self.s3.put(MODEL, self.to_shared(self.local))

        new_base = next_base(decision)
        if new_base:
            self.s3.put(self.state_key, serialize_state(state_after(decision, self.name, new_base)))

        self.actions.append(decision.action)
        return decision.action


class Databricks(Agent):
    """Databricks holds a Metric View, so the model crosses the converter both ways."""

    def to_shared(self, ossie):
        return ossie

    def from_shared(self, shared):
        # Import to a Metric View and read it back, which is what actually happens and is
        # where any lossiness would show up.
        return metric_view_to_ossie(ossie_to_metric_view(shared))


def run(snowflake, databricks, ticks=8):
    """Interleave the two agents, Snowflake first, as the offset schedules do."""
    log = []
    for _ in range(ticks):
        log.append(("snowflake", snowflake.tick()))
        log.append(("databricks", databricks.tick()))
    return log


def show(title, log, s3):
    print(f"\n{title}")
    print("-" * 62)
    for i in range(0, len(log), 2):
        sf, dbx = log[i], log[i + 1]
        print(f"  tick {i // 2 + 1}   snowflake {sf[1]:<20} databricks {dbx[1]}")
    print(f"  shared-file writes: {s3.writes}")


def settled(log, from_tick=2):
    """True if nothing but NO_CHANGE happens after the given tick."""
    tail = [action for _, action in log[from_tick * 2:]]
    return all(action == "NO_CHANGE" for action in tail)


def scenario_bidirectional_snowflake_edit():
    s3 = FakeS3()
    sf_yaml = yaml.safe_dump(SF_OSSIE, sort_keys=False)
    snowflake = Agent("snowflake", s3, BIDIRECTIONAL, "ossie/_state/snowflake.json", local=sf_yaml)
    databricks = Databricks("databricks", s3, BIDIRECTIONAL, "ossie/_state/databricks.json")

    log = run(snowflake, databricks)
    show("Bidirectional, converging from empty", log, s3)
    return settled(log), s3.writes


def scenario_bidirectional_databricks_edit():
    s3 = FakeS3()
    sf_yaml = yaml.safe_dump(SF_OSSIE, sort_keys=False)
    snowflake = Agent("snowflake", s3, BIDIRECTIONAL, "ossie/_state/snowflake.json", local=sf_yaml)
    databricks = Databricks("databricks", s3, BIDIRECTIONAL, "ossie/_state/databricks.json")
    run(snowflake, databricks, ticks=3)          # settle first
    writes_before = s3.writes

    # Databricks adds a measure, the demo's step (c).
    mv = yaml.safe_load(ossie_to_metric_view(s3[MODEL]))
    mv.setdefault("measures", []).append({"name": "TOTAL_QUANTITY", "expr": "SUM(order_qty)"})
    databricks.local = metric_view_to_ossie(yaml.safe_dump(mv, sort_keys=False))

    log = run(snowflake, databricks, ticks=6)
    show("Bidirectional, measure added on Databricks", log, s3)

    reached = "TOTAL_QUANTITY" in (snowflake.local or "").upper()
    print(f"  measure reached Snowflake: {reached}")
    return settled(log, from_tick=2) and reached, s3.writes - writes_before


def scenario_managed_drift():
    s3 = FakeS3()
    sf_yaml = yaml.safe_dump(SF_OSSIE, sort_keys=False)
    snowflake = Agent("snowflake", s3, SNOWFLAKE_MANAGED_SOURCE, "ossie/_state/snowflake.json",
                      local=sf_yaml)
    databricks = Databricks("databricks", s3, SNOWFLAKE_MANAGED_MIRROR,
                            "ossie/_state/databricks.json")
    run(snowflake, databricks, ticks=3)

    # A Databricks user edits the mirror. It must be reverted, not published.
    mv = yaml.safe_load(ossie_to_metric_view(s3[MODEL]))
    mv.setdefault("measures", []).append({"name": "LOCAL_DRIFT", "expr": "SUM(order_qty) * 2"})
    databricks.local = metric_view_to_ossie(yaml.safe_dump(mv, sort_keys=False))
    writes_before = s3.writes

    log = run(snowflake, databricks, ticks=4)
    show("Snowflake-managed, drift on the mirror", log, s3)

    reverted = "REVERT_LOCAL_DRIFT" in [a for _, a in log]
    leaked = "LOCAL_DRIFT" in s3[MODEL].upper()
    print(f"  reverted: {reverted}   leaked into shared file: {leaked}")
    return reverted and not leaked, s3.writes - writes_before


def scenario_timestamps_for_contrast():
    """The scheme the manual notebooks use. Included to show why it cannot work."""
    clock = [0]
    sv_time, mv_time, file_time = [1], [0], [0]
    writes = 0
    print("\nTimestamps, for contrast (the loop this design replaces)")
    print("-" * 62)
    for tick in range(1, 7):
        clock[0] += 1
        actions = []
        if sv_time[0] > file_time[0]:            # Snowflake exports
            file_time[0] = clock[0]
            writes += 1
            actions.append("EXPORT")
        else:
            actions.append("noop")
        clock[0] += 1
        if file_time[0] > mv_time[0]:            # Databricks imports, which bumps the view
            mv_time[0] = clock[0]
            actions.append("IMPORT")
            clock[0] += 1
            if mv_time[0] > file_time[0]:        # then looks newer than the file, so exports
                file_time[0] = clock[0]
                writes += 1
                actions.append("EXPORT")
        clock[0] += 1
        if file_time[0] > sv_time[0]:            # Snowflake imports, which bumps the view
            sv_time[0] = clock[0]
            actions.append("IMPORT")
        print(f"  tick {tick}   {' -> '.join(actions)}")
    print(f"  shared-file writes: {writes}  (never stops)")
    return writes >= 6


def main():
    results = []
    ok, writes = scenario_bidirectional_snowflake_edit()
    results.append(("bidirectional converges from empty", ok, writes))

    ok, writes = scenario_bidirectional_databricks_edit()
    results.append(("Databricks edit reaches Snowflake and settles", ok, writes))

    ok, writes = scenario_managed_drift()
    results.append(("managed mirror reverts drift without publishing", ok, writes))

    loops = scenario_timestamps_for_contrast()
    results.append(("timestamp scheme demonstrably loops", loops, None))

    print("\nResults")
    print("-" * 62)
    failed = 0
    for label, ok, writes in results:
        suffix = "" if writes is None else f"  ({writes} write(s))"
        print(f"  {'ok  ' if ok else 'FAIL'}  {label}{suffix}")
        failed += 0 if ok else 1

    print()
    if failed:
        print(f"FAILED: {failed} scenario(s). Do not enable the tasks.")
        return 1
    print("No loops. Each change produces a bounded number of writes, then silence.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
