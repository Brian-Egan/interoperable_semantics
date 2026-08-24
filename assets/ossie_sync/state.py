"""Per-platform sync state, stored as JSON next to the shared Ossie file.

    s3://<bucket>/ossie/
      sales_model.yaml            shared model, either side may write
      _state/snowflake.json       written only by Snowflake
      _state/databricks.json      written only by Databricks

One writer per file, so there is no lock and no race. Each side reads only its own state
to answer "what did I last agree to", which is the `base` argument to decide().

Reading and writing the file is left to the caller, because the two runtimes do it very
differently: Databricks has dbutils.fs, Snowflake has stage COPY INTO. These helpers only
handle the JSON shape.
"""

import json
from datetime import datetime, timezone

STATE_VERSION = "1"


def new_state(base_fingerprint=None, last_action=None, platform=None):
    return {
        "state_version": STATE_VERSION,
        "base_fingerprint": base_fingerprint,
        "last_action": last_action,
        "by": platform,
        "at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
    }


def parse_state(text):
    """Tolerant read. A missing, empty or corrupt state file means no recorded base.

    Returning an empty state rather than raising is deliberate: decide() treats a base of
    None as ADOPT, which is the safe first-run behaviour and also the recovery path if
    someone deletes the file mid-demo.
    """
    if not text:
        return new_state()
    try:
        loaded = json.loads(text)
    except (ValueError, TypeError):
        return new_state()
    if not isinstance(loaded, dict):
        return new_state()
    return {
        "state_version": loaded.get("state_version", STATE_VERSION),
        "base_fingerprint": loaded.get("base_fingerprint"),
        "last_action": loaded.get("last_action"),
        "by": loaded.get("by"),
        "at": loaded.get("at"),
    }


def base_of(text):
    """The recorded base fingerprint from raw state-file text, or None."""
    return parse_state(text).get("base_fingerprint")


def serialize_state(state):
    return json.dumps(state, indent=2, sort_keys=True)


def state_after(decision, platform, next_base_fingerprint):
    """Build the state to persist after acting on a decision."""
    return new_state(
        base_fingerprint=next_base_fingerprint or decision.base,
        last_action=decision.action,
        platform=platform,
    )
