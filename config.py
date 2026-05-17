"""
Configuration loader — reads from environment variables and AWS Secrets Manager.
Uses lru_cache so Secrets Manager is called at most once per Lambda container lifetime.
"""

import json
import logging
import os
from functools import lru_cache

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger(__name__)


@lru_cache(maxsize=1)
def get_db_config() -> dict:
    """Fetch RDS credentials from Secrets Manager and return a psycopg2-ready dict."""
    secret_name = _require_env("DB_SECRET_NAME")
    region = os.environ.get("AWS_REGION", "us-east-1")

    client = boto3.client("secretsmanager", region_name=region)
    try:
        response = client.get_secret_value(SecretId=secret_name)
    except ClientError as exc:
        logger.error("Failed to retrieve secret '%s': %s", secret_name, exc.response["Error"]["Code"])
        raise RuntimeError("Could not load database configuration") from exc

    secret = json.loads(response["SecretString"])

    return {
        "host": secret["host"],
        "port": int(secret.get("port", 5432)),
        "dbname": secret["dbname"],
        "user": secret["username"],
        "password": secret["password"],
    }


def get_jwt_secret() -> str:
    """Return the JWT signing secret from environment."""
    return _require_env("JWT_SECRET")


def get_jwt_expiry_hours() -> int:
    return int(os.environ.get("JWT_EXPIRY_HOURS", "1"))


def get_max_failed_attempts() -> int:
    return int(os.environ.get("MAX_FAILED_ATTEMPTS", "5"))


def get_log_level() -> str:
    return os.environ.get("LOG_LEVEL", "INFO").upper()


def get_cors_origin() -> str:
    return os.environ.get("CORS_ORIGIN", "*")


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise EnvironmentError(f"Required environment variable '{name}' is not set")
    return value
