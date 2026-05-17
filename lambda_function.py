"""
AWS Lambda entry point for the customer authentication service.

Handles:
  POST /auth/login  — email + password → JWT
  OPTIONS *         — CORS preflight

All business logic lives in auth.py / validators.py.
This module is intentionally thin: parse → validate → delegate → respond.
"""

import json
import logging
import os

from pythonjsonlogger import jsonlogger

import auth
from config import get_cors_origin, get_log_level
from validators import validate_login_request

# ---------------------------------------------------------------------------
# Logging — structured JSON for CloudWatch Insights
# ---------------------------------------------------------------------------

def _configure_logging() -> None:
    root = logging.getLogger()
    # Remove default Lambda handler to avoid duplicate output
    if root.handlers:
        root.handlers.clear()

    handler = logging.StreamHandler()
    formatter = jsonlogger.JsonFormatter(
        fmt="%(asctime)s %(name)s %(levelname)s %(message)s",
        rename_fields={"asctime": "timestamp", "levelname": "level", "name": "logger"},
    )
    handler.setFormatter(formatter)
    root.addHandler(handler)
    root.setLevel(get_log_level())


_configure_logging()
logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Response helpers
# ---------------------------------------------------------------------------

def _cors_headers() -> dict:
    return {
        "Access-Control-Allow-Origin": get_cors_origin(),
        "Access-Control-Allow-Headers": "Content-Type,Authorization,X-Amz-Date,X-Api-Key",
        "Access-Control-Allow-Methods": "POST,OPTIONS",
        "Content-Type": "application/json",
    }


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": _cors_headers(),
        "body": json.dumps(body, default=str),
    }


def _bad_request(message: str = "Invalid request") -> dict:
    return _response(400, {"success": False, "message": message})


def _unauthorized() -> dict:
    return _response(401, {"success": False, "message": auth.AUTH_FAILURE_MSG})


def _locked() -> dict:
    return _response(423, {"success": False, "message": auth.ACCOUNT_LOCKED_MSG})


def _server_error() -> dict:
    return _response(500, {"success": False, "message": "Internal server error"})


# ---------------------------------------------------------------------------
# Lambda handler
# ---------------------------------------------------------------------------

def lambda_handler(event: dict, context: object) -> dict:
    """
    API Gateway proxy integration handler.

    Expected event shape (API Gateway REST / HTTP):
        {
            "httpMethod": "POST",
            "body": "{\"email\": \"...\", \"password\": \"...\"}"
        }
    """
    request_id = getattr(context, "aws_request_id", "local")
    http_method = event.get("httpMethod", event.get("requestContext", {}).get("http", {}).get("method", "UNKNOWN"))

    logger.info("Request received", extra={"request_id": request_id, "method": http_method})

    # --- CORS preflight ---
    if http_method == "OPTIONS":
        return _response(200, {})

    # --- Parse body ---
    raw_body = event.get("body") or "{}"
    try:
        body = json.loads(raw_body) if isinstance(raw_body, str) else raw_body
    except json.JSONDecodeError:
        logger.warning("Malformed JSON body", extra={"request_id": request_id})
        return _bad_request()

    # --- Validate ---
    is_valid, validation_error = validate_login_request(body)
    if not is_valid:
        logger.warning("Validation failed", extra={"request_id": request_id, "reason": validation_error})
        return _bad_request()

    # Normalise email before touching the DB
    email: str = body["email"].strip().lower()
    password: str = body["password"]

    # --- Authenticate ---
    try:
        status, data = auth.authenticate(email, password)
    except Exception:
        logger.exception("Unexpected error during authentication", extra={"request_id": request_id})
        return _server_error()

    # --- Map result to HTTP response ---
    if status == "success":
        return _response(200, {
            "success": True,
            "message": "Authentication successful",
            "token": data["token"],
            "user": data["user"],
        })

    if status == "locked":
        return _locked()

    # "failure" — invalid credentials
    return _unauthorized()
