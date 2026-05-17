"""
Authentication business logic — password verification, JWT generation,
failed-login tracking, and account locking.

Deliberately uses a single generic failure message for all negative outcomes
(user not found, wrong password, inactive account) to prevent user enumeration.
Account-locked responses use a distinct message because the lock state is
visible to the user via other channels (e.g., support email).
"""

import logging
import uuid
from datetime import datetime, timedelta, timezone
from typing import Dict, Optional, Tuple

import bcrypt
import jwt

import db
from config import get_jwt_expiry_hours, get_jwt_secret, get_max_failed_attempts

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Public constants — callers may inspect these for structured error handling
# ---------------------------------------------------------------------------
AUTH_FAILURE_MSG = "Invalid email or password"
ACCOUNT_LOCKED_MSG = "Account locked"

AuthStatus = str  # "success" | "failure" | "locked"


# ---------------------------------------------------------------------------
# Password helpers
# ---------------------------------------------------------------------------

def verify_password(plain_password: str, hashed_password: str) -> bool:
    """Constant-time bcrypt comparison.  Returns False on any error."""
    try:
        return bcrypt.checkpw(
            plain_password.encode("utf-8"),
            hashed_password.encode("utf-8"),
        )
    except Exception as exc:
        logger.error("bcrypt comparison error: %s", type(exc).__name__)
        return False


def hash_password(plain_password: str) -> str:
    """Generate a bcrypt hash (cost factor 12).  Used by provisioning scripts."""
    return bcrypt.hashpw(
        plain_password.encode("utf-8"),
        bcrypt.gensalt(rounds=12),
    ).decode("utf-8")


# ---------------------------------------------------------------------------
# JWT helpers
# ---------------------------------------------------------------------------

def generate_jwt(user_id: str, email: str, first_name: str) -> str:
    """Return a signed HS256 JWT with standard claims."""
    secret = get_jwt_secret()
    expiry_hours = get_jwt_expiry_hours()
    now = datetime.now(timezone.utc)

    payload = {
        "sub": user_id,
        "email": email,
        "first_name": first_name,
        "iat": now,
        "exp": now + timedelta(hours=expiry_hours),
        "jti": str(uuid.uuid4()),  # unique token ID — enables future revocation
    }

    return jwt.encode(payload, secret, algorithm="HS256")


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

_SELECT_USER = """
    SELECT
        id::text,
        email,
        password_hash,
        first_name,
        last_name,
        is_active,
        is_locked,
        failed_attempts,
        last_login,
        created_at
    FROM users
    WHERE email = %s
    LIMIT 1
"""

_UPDATE_FAILED_ATTEMPTS = """
    UPDATE users
    SET
        failed_attempts = %s,
        is_locked       = %s,
        updated_at      = NOW()
    WHERE id = %s::uuid
"""

_UPDATE_LOGIN_SUCCESS = """
    UPDATE users
    SET
        failed_attempts = 0,
        last_login      = NOW(),
        updated_at      = NOW()
    WHERE id = %s::uuid
"""


def _get_user_by_email(email: str) -> Optional[dict]:
    return db.fetch_one(_SELECT_USER, (email,))


def _increment_failed_attempts(user_id: str, current_attempts: int, max_attempts: int) -> bool:
    """
    Increment failed_attempts counter.  Lock the account if the new total
    reaches max_attempts.  Returns True if the account was just locked.
    """
    new_attempts = current_attempts + 1
    should_lock = new_attempts >= max_attempts
    db.execute(_UPDATE_FAILED_ATTEMPTS, (new_attempts, should_lock, user_id))
    logger.info(
        "Failed attempt recorded user_id=%s attempts=%d locked=%s",
        user_id, new_attempts, should_lock,
    )
    return should_lock


def _record_successful_login(user_id: str) -> None:
    db.execute(_UPDATE_LOGIN_SUCCESS, (user_id,))


# ---------------------------------------------------------------------------
# Main authentication flow
# ---------------------------------------------------------------------------

def authenticate(email: str, password: str) -> Tuple[AuthStatus, Dict]:
    """
    Authenticate a user by email and password.

    Returns a (status, data) tuple:
        ("success", {"token": str, "user": {"id", "email", "first_name"}})
        ("failure", {"message": str})
        ("locked",  {"message": str})
    """
    max_attempts = get_max_failed_attempts()

    # --- Step 1: lookup user ---
    user = _get_user_by_email(email)
    if not user:
        logger.info("Authentication failed: no account for supplied email")
        return "failure", {"message": AUTH_FAILURE_MSG}

    user_id = user["id"]

    # --- Step 2: account status checks (locked before inactive) ---
    if user["is_locked"]:
        logger.info("Authentication failed: account locked user_id=%s", user_id)
        return "locked", {"message": ACCOUNT_LOCKED_MSG}

    if not user["is_active"]:
        # Return generic message — do not reveal that the account is inactive.
        logger.info("Authentication failed: account inactive user_id=%s", user_id)
        return "failure", {"message": AUTH_FAILURE_MSG}

    # --- Step 3: password verification ---
    if not verify_password(password, user["password_hash"]):
        logger.info("Authentication failed: invalid password user_id=%s", user_id)
        just_locked = _increment_failed_attempts(user_id, user["failed_attempts"], max_attempts)
        if just_locked:
            return "locked", {"message": ACCOUNT_LOCKED_MSG}
        return "failure", {"message": AUTH_FAILURE_MSG}

    # --- Step 4: success ---
    _record_successful_login(user_id)
    token = generate_jwt(user_id, user["email"], user["first_name"])
    logger.info("Authentication successful user_id=%s", user_id)

    return "success", {
        "token": token,
        "user": {
            "id": user_id,
            "email": user["email"],
            "first_name": user["first_name"],
        },
    }
