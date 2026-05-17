"""
Input validation — schema checks and email format validation.
Returns structured (is_valid, error_message) tuples so callers stay clean.
"""

import logging
from typing import Optional, Tuple

from email_validator import EmailNotValidError, validate_email

logger = logging.getLogger(__name__)

_MAX_PASSWORD_LEN = 128
_MAX_EMAIL_LEN = 254  # RFC 5321


def validate_login_request(body: object) -> Tuple[bool, Optional[str]]:
    """
    Validate an authentication request payload.

    Returns:
        (True, None)           — payload is valid
        (False, error_string)  — payload is invalid; string describes why
    """
    if not isinstance(body, dict):
        return False, "Request body must be a JSON object"

    email = body.get("email")
    password = body.get("password")

    # Presence checks
    if email is None:
        return False, "email is required"
    if password is None:
        return False, "password is required"

    # Type checks
    if not isinstance(email, str):
        return False, "email must be a string"
    if not isinstance(password, str):
        return False, "password must be a string"

    # Normalise before further checks (mirrors what lambda_function does pre-auth)
    email = email.strip()

    # Empty / length checks
    if not email:
        return False, "email must not be empty"
    if not password:
        return False, "password must not be empty"
    if len(email) > _MAX_EMAIL_LEN:
        return False, "email is too long"
    if len(password) > _MAX_PASSWORD_LEN:
        return False, "password is too long"

    # Format check (no network lookup)
    try:
        validate_email(email, check_deliverability=False)
    except EmailNotValidError as exc:
        logger.debug("Email validation failed: %s", exc)
        return False, "Invalid email format"

    return True, None
