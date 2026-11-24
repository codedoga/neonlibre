from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from fixtures.neon_fixtures import NeonEnv


def test_lwlsn_cache_overflow(neon_simple_env: NeonEnv):
    """
    Writing more blocks than neon.last_written_lsn_cache_size must evict, not fail.

    The cache inserts the new entry before removing the LRU victim. PG19 shared
    hashes cannot grow past their preallocated size, so without one spare element
    every insert into a full cache failed with "out of shared memory".
    """
    endpoint = neon_simple_env.endpoints.create_start(
        "main",
        config_lines=[
            "neon.last_written_lsn_cache_size=1024",  # the minimum
            "shared_buffers=1MB",  # force evictions, each one records a last-written LSN
        ],
    )
    # ~20MB, i.e. ~2500 heap blocks: more than twice the cache size
    endpoint.safe_psql("CREATE TABLE t AS SELECT g, repeat('x', 100) AS v FROM generate_series(1, 150000) g")
    endpoint.safe_psql("UPDATE t SET v = v || 'y'")
    assert endpoint.safe_psql("SELECT count(*) FROM t")[0][0] == 150000
