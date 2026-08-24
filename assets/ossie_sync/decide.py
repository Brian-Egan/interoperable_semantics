"""The sync decision: compare three fingerprints, return one verdict.

Both platforms and both architectures run this same function. The only thing that varies
is `allowed`, which is what stops the unidirectional variant from being a fork of the
bidirectional one.

The three inputs
----------------
    local   fingerprint of the model as it exists on this platform right now
    remote  fingerprint of the shared Ossie file on S3
    base    fingerprint this platform last agreed on, from its own state file

`base` is what makes this terminate. Without it there is no way to tell "the other side
changed" from "I changed", so both sides write and the model ping-pongs forever. With it,
each side can see which of the two moved, act once, record the new base, and go quiet.
"""

NO_CHANGE = "NO_CHANGE"
ADOPT = "ADOPT"
IMPORT = "IMPORT"
EXPORT = "EXPORT"
CONFLICT = "CONFLICT"
REVERT_LOCAL_DRIFT = "REVERT_LOCAL_DRIFT"

BIDIRECTIONAL = ("IMPORT", "EXPORT")
SNOWFLAKE_MANAGED_SOURCE = ("EXPORT",)      # Snowflake in the managed architecture
SNOWFLAKE_MANAGED_MIRROR = ("IMPORT",)      # Databricks in the managed architecture

REASONS = {
    NO_CHANGE: "local and shared model agree, nothing to do",
    ADOPT: "no recorded base, taking the shared model as the starting point",
    IMPORT: "shared model changed, replacing the local model",
    EXPORT: "local model changed, publishing to the shared Ossie file",
    CONFLICT: "both sides changed since the last agreement",
    REVERT_LOCAL_DRIFT: "local edit is not authoritative, restoring from the shared model",
}


class Decision:
    """A verdict plus the fingerprints that produced it, so it can be logged and read."""

    def __init__(self, action, reason, local, remote, base):
        self.action = action
        self.reason = reason
        self.local = local
        self.remote = remote
        self.base = base

    @property
    def writes(self):
        return self.action in (IMPORT, EXPORT, ADOPT, REVERT_LOCAL_DRIFT)

    def __str__(self):
        return f"{self.action} - {self.reason}"

    def to_dict(self):
        return {
            "action": self.action,
            "reason": self.reason,
            "local_fingerprint": self.local,
            "remote_fingerprint": self.remote,
            "base_fingerprint": self.base,
        }


def decide(local, remote, base, allowed=BIDIRECTIONAL, conflict_winner=None, platform=None):
    """Return a Decision.

    allowed
        Which write directions this platform may take. Bidirectional passes both.
        The managed architecture passes ("EXPORT",) on Snowflake and ("IMPORT",) on
        Databricks; an EXPORT that is not allowed becomes REVERT_LOCAL_DRIFT.

    conflict_winner, platform
        When both sides changed, the platform named by `conflict_winner` keeps its
        version. Anything else imports. Demoware: the losing edit is discarded with
        nothing more than a log line. See docs/PRODUCTION_ARCHITECTURE.md.
    """
    def verdict(action):
        return Decision(action, REASONS[action], local, remote, base)

    if local and remote and local == remote:
        return verdict(NO_CHANGE)

    if not local:
        # Nothing here yet, so there is no local change to protect.
        return verdict(ADOPT if remote else NO_CHANGE)

    if not remote:
        # Local model exists but the shared file does not.
        return verdict(EXPORT if EXPORT in allowed else NO_CHANGE)

    if base is None:
        return verdict(ADOPT)

    if local == base:
        action = IMPORT
    elif remote == base:
        action = EXPORT
    else:
        if conflict_winner and platform and conflict_winner == platform:
            return verdict(EXPORT if EXPORT in allowed else CONFLICT)
        if conflict_winner and platform:
            return verdict(IMPORT if IMPORT in allowed else CONFLICT)
        return verdict(CONFLICT)

    if action == EXPORT and EXPORT not in allowed:
        # Managed architecture: a locally edited mirror is drift, not a contribution.
        return verdict(REVERT_LOCAL_DRIFT)
    if action == IMPORT and IMPORT not in allowed:
        return verdict(NO_CHANGE)

    return verdict(action)


def next_base(decision):
    """The fingerprint to record after acting, or None to leave the base unchanged."""
    if decision.action in (IMPORT, ADOPT, REVERT_LOCAL_DRIFT):
        return decision.remote
    if decision.action == EXPORT:
        return decision.local
    return None
