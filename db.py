"""
Database access layer — connection pooling, query helpers, transaction management.

The connection pool is initialised once per Lambda container and reused across
warm invocations.  psycopg2's ThreadedConnectionPool is used so the pool is
safe to share across any future threading model.
"""

import logging
from contextlib import contextmanager
from typing import Any, Generator, List, Optional

import psycopg2
from psycopg2 import pool as pg_pool
from psycopg2.extras import RealDictCursor

from config import get_db_config

logger = logging.getLogger(__name__)

_connection_pool: Optional[pg_pool.ThreadedConnectionPool] = None

# Tune these via environment if needed; kept small for Lambda concurrency model.
_POOL_MIN = 1
_POOL_MAX = 5


# ---------------------------------------------------------------------------
# Pool management
# ---------------------------------------------------------------------------

def _get_pool() -> pg_pool.ThreadedConnectionPool:
    global _connection_pool
    if _connection_pool is None or _connection_pool.closed:
        config = get_db_config()
        logger.info("Initialising database connection pool (min=%d, max=%d)", _POOL_MIN, _POOL_MAX)
        _connection_pool = pg_pool.ThreadedConnectionPool(
            minconn=_POOL_MIN,
            maxconn=_POOL_MAX,
            connect_timeout=5,
            application_name="auth-service",
            **config,
        )
    return _connection_pool


@contextmanager
def _get_connection() -> Generator[Any, None, None]:
    """Yield a connection from the pool; always return it afterward."""
    conn_pool = _get_pool()
    conn = conn_pool.getconn()
    try:
        yield conn
    except Exception:
        conn.rollback()
        raise
    finally:
        conn_pool.putconn(conn)


# ---------------------------------------------------------------------------
# Query helpers
# ---------------------------------------------------------------------------

def fetch_one(query: str, params: tuple) -> Optional[dict]:
    """Execute a SELECT and return a single row as a dict, or None."""
    with _get_connection() as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(query, params)
            row = cur.fetchone()
            return dict(row) if row else None


def fetch_all(query: str, params: tuple) -> List[dict]:
    """Execute a SELECT and return all rows as a list of dicts."""
    with _get_connection() as conn:
        with conn.cursor(cursor_factory=RealDictCursor) as cur:
            cur.execute(query, params)
            return [dict(row) for row in cur.fetchall()]


def execute(query: str, params: tuple) -> int:
    """Execute an INSERT/UPDATE/DELETE, commit, and return the row count."""
    with _get_connection() as conn:
        with conn.cursor() as cur:
            cur.execute(query, params)
            conn.commit()
            return cur.rowcount
