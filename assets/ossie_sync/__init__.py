"""Shared sync logic for the Snowflake <-> Ossie <-> Databricks demos.

One implementation, four notebooks. The fingerprint and decision functions are stamped
into the notebooks by assets/build_notebooks.py so the code is visible on screen during a
demo while remaining editable in exactly one place.
"""

from .decide import (  # noqa: F401
    ADOPT,
    BIDIRECTIONAL,
    CONFLICT,
    EXPORT,
    IMPORT,
    NOOP,
    REVERT_LOCAL_DRIFT,
    SNOWFLAKE_MANAGED_MIRROR,
    SNOWFLAKE_MANAGED_SOURCE,
    Decision,
    decide,
    next_base,
)
from .fingerprint import (  # noqa: F401
    describe,
    normalize_expression,
    semantic_fingerprint,
    semantic_projection,
)
from .state import (  # noqa: F401
    base_of,
    new_state,
    parse_state,
    serialize_state,
    state_after,
)
