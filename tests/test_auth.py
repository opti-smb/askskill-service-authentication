"""
Unit tests for the auth service.

All external dependencies (database, AWS Secrets Manager, bcrypt) are mocked so
tests run without any infrastructure.
"""

import importlib
import json
import os
import sys
import types
import unittest
from unittest.mock import MagicMock, patch

# ---------------------------------------------------------------------------
# Stub AWS / heavy dependencies before importing service modules
# ---------------------------------------------------------------------------

# Minimal boto3 stub
boto3_stub = types.ModuleType("boto3")
boto3_stub.client = MagicMock()
sys.modules.setdefault("boto3", boto3_stub)

# Stub botocore.exceptions
botocore_stub = types.ModuleType("botocore")
botocore_exceptions = types.ModuleType("botocore.exceptions")
botocore_exceptions.ClientError = Exception
botocore_stub.exceptions = botocore_exceptions
sys.modules.setdefault("botocore", botocore_stub)
sys.modules.setdefault("botocore.exceptions", botocore_exceptions)

# Stub psycopg2
psycopg2_stub = types.ModuleType("psycopg2")
psycopg2_pool_stub = types.ModuleType("psycopg2.pool")
psycopg2_extras_stub = types.ModuleType("psycopg2.extras")


class _RealDictCursor:
    pass


psycopg2_extras_stub.RealDictCursor = _RealDictCursor
psycopg2_pool_stub.ThreadedConnectionPool = MagicMock
psycopg2_stub.pool = psycopg2_pool_stub
psycopg2_stub.extras = psycopg2_extras_stub
sys.modules.setdefault("psycopg2", psycopg2_stub)
sys.modules.setdefault("psycopg2.pool", psycopg2_pool_stub)
sys.modules.setdefault("psycopg2.extras", psycopg2_extras_stub)

# Stub python-json-logger
jsonlogger_stub = types.ModuleType("pythonjsonlogger")
jsonlogger_inner = types.ModuleType("pythonjsonlogger.jsonlogger")


class _JsonFormatter:
    def __init__(self, *a, **kw):
        pass

    def format(self, record):
        return ""


jsonlogger_inner.JsonFormatter = _JsonFormatter
jsonlogger_stub.jsonlogger = jsonlogger_inner
sys.modules.setdefault("pythonjsonlogger", jsonlogger_stub)
sys.modules.setdefault("pythonjsonlogger.jsonlogger", jsonlogger_inner)

# Set minimum required env vars before importing config
os.environ.setdefault("DB_SECRET_NAME", "test/db/secret")
os.environ.setdefault("JWT_SECRET", "supersecrettestkey1234567890abcd")
os.environ.setdefault("JWT_EXPIRY_HOURS", "1")
os.environ.setdefault("MAX_FAILED_ATTEMPTS", "5")
os.environ.setdefault("LOG_LEVEL", "WARNING")
os.environ.setdefault("CORS_ORIGIN", "*")

# Add project root to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), ".."))

import validators  # noqa: E402
from validators import validate_login_request  # noqa: E402


# ---------------------------------------------------------------------------
# Test: validators
# ---------------------------------------------------------------------------

class TestValidators(unittest.TestCase):

    def test_valid_payload(self):
        ok, err = validate_login_request({"email": "user@example.com", "password": "Secret123!"})
        self.assertTrue(ok)
        self.assertIsNone(err)

    def test_missing_email(self):
        ok, err = validate_login_request({"password": "Secret123!"})
        self.assertFalse(ok)
        self.assertIn("email", err.lower())

    def test_missing_password(self):
        ok, err = validate_login_request({"email": "user@example.com"})
        self.assertFalse(ok)
        self.assertIn("password", err.lower())

    def test_invalid_email_format(self):
        ok, err = validate_login_request({"email": "not-an-email", "password": "Secret123!"})
        self.assertFalse(ok)

    def test_empty_email(self):
        ok, err = validate_login_request({"email": "   ", "password": "Secret123!"})
        self.assertFalse(ok)

    def test_empty_password(self):
        ok, err = validate_login_request({"email": "user@example.com", "password": ""})
        self.assertFalse(ok)

    def test_password_too_long(self):
        ok, err = validate_login_request({"email": "user@example.com", "password": "x" * 129})
        self.assertFalse(ok)

    def test_non_dict_body(self):
        ok, err = validate_login_request("not a dict")
        self.assertFalse(ok)

    def test_non_string_email(self):
        ok, err = validate_login_request({"email": 123, "password": "pass"})
        self.assertFalse(ok)


# ---------------------------------------------------------------------------
# Test: auth module
# ---------------------------------------------------------------------------

class TestAuth(unittest.TestCase):

    def setUp(self):
        # Import auth fresh with patches active
        import auth as auth_module
        self.auth = auth_module

    def _make_user(self, **overrides) -> dict:
        base = {
            "id": "11111111-1111-1111-1111-111111111111",
            "email": "user@example.com",
            "password_hash": "$2b$12$KIXb1i3j4/FakeHashValue/OaEAui73SgHXFOr2CgPCPHKEh8cGHRBuQa",
            "first_name": "Ada",
            "last_name": "Lovelace",
            "is_active": True,
            "is_locked": False,
            "failed_attempts": 0,
            "last_login": None,
            "created_at": "2024-01-01T00:00:00",
        }
        base.update(overrides)
        return base

    @patch("auth.db.execute")
    @patch("auth.db.fetch_one")
    def test_user_not_found_returns_failure(self, mock_fetch, mock_exec):
        mock_fetch.return_value = None
        status, data = self.auth.authenticate("unknown@example.com", "pass")
        self.assertEqual(status, "failure")
        self.assertEqual(data["message"], self.auth.AUTH_FAILURE_MSG)
        mock_exec.assert_not_called()

    @patch("auth.verify_password", return_value=True)
    @patch("auth.db.execute")
    @patch("auth.db.fetch_one")
    def test_successful_authentication(self, mock_fetch, mock_exec, mock_verify):
        mock_fetch.return_value = self._make_user()
        status, data = self.auth.authenticate("user@example.com", "correct-pass")
        self.assertEqual(status, "success")
        self.assertIn("token", data)
        self.assertEqual(data["user"]["email"], "user@example.com")
        mock_exec.assert_called_once()  # reset failed attempts + last_login

    @patch("auth.verify_password", return_value=False)
    @patch("auth.db.execute")
    @patch("auth.db.fetch_one")
    def test_wrong_password_increments_attempts(self, mock_fetch, mock_exec, mock_verify):
        mock_fetch.return_value = self._make_user(failed_attempts=2)
        status, data = self.auth.authenticate("user@example.com", "wrong-pass")
        self.assertEqual(status, "failure")
        # Verify execute was called to increment attempts
        mock_exec.assert_called_once()
        call_args = mock_exec.call_args[0]
        # New attempts = 3, not yet locked (< 5)
        self.assertEqual(call_args[1][0], 3)
        self.assertFalse(call_args[1][1])  # is_locked = False

    @patch("auth.verify_password", return_value=False)
    @patch("auth.db.execute")
    @patch("auth.db.fetch_one")
    def test_fifth_failed_attempt_locks_account(self, mock_fetch, mock_exec, mock_verify):
        mock_fetch.return_value = self._make_user(failed_attempts=4)
        status, data = self.auth.authenticate("user@example.com", "wrong-pass")
        self.assertEqual(status, "locked")
        call_args = mock_exec.call_args[0]
        self.assertTrue(call_args[1][1])  # is_locked = True

    @patch("auth.db.execute")
    @patch("auth.db.fetch_one")
    def test_locked_account_returns_locked(self, mock_fetch, mock_exec):
        mock_fetch.return_value = self._make_user(is_locked=True)
        status, data = self.auth.authenticate("user@example.com", "any-pass")
        self.assertEqual(status, "locked")
        self.assertEqual(data["message"], self.auth.ACCOUNT_LOCKED_MSG)
        mock_exec.assert_not_called()  # no DB write for already-locked

    @patch("auth.db.execute")
    @patch("auth.db.fetch_one")
    def test_inactive_account_returns_generic_failure(self, mock_fetch, mock_exec):
        mock_fetch.return_value = self._make_user(is_active=False)
        status, data = self.auth.authenticate("user@example.com", "any-pass")
        self.assertEqual(status, "failure")
        self.assertEqual(data["message"], self.auth.AUTH_FAILURE_MSG)
        mock_exec.assert_not_called()

    def test_verify_password_correct(self):
        import bcrypt
        hashed = bcrypt.hashpw(b"MyPassword1!", bcrypt.gensalt()).decode()
        self.assertTrue(self.auth.verify_password("MyPassword1!", hashed))

    def test_verify_password_wrong(self):
        import bcrypt
        hashed = bcrypt.hashpw(b"MyPassword1!", bcrypt.gensalt()).decode()
        self.assertFalse(self.auth.verify_password("WrongPassword", hashed))

    def test_verify_password_bad_hash_returns_false(self):
        self.assertFalse(self.auth.verify_password("pass", "not-a-valid-hash"))

    def test_generate_jwt_contains_expected_claims(self):
        import jwt as pyjwt
        token = self.auth.generate_jwt("uuid-123", "u@e.com", "Ada")
        payload = pyjwt.decode(token, os.environ["JWT_SECRET"], algorithms=["HS256"])
        self.assertEqual(payload["sub"], "uuid-123")
        self.assertEqual(payload["email"], "u@e.com")
        self.assertEqual(payload["first_name"], "Ada")
        self.assertIn("jti", payload)
        self.assertIn("exp", payload)


# ---------------------------------------------------------------------------
# Test: lambda_handler
# ---------------------------------------------------------------------------

class TestLambdaHandler(unittest.TestCase):

    def setUp(self):
        import lambda_function
        self.handler = lambda_function.lambda_handler
        self.ctx = MagicMock()
        self.ctx.aws_request_id = "test-req-id"

    def _event(self, body: dict | None = None, method: str = "POST") -> dict:
        return {
            "httpMethod": method,
            "body": json.dumps(body) if body is not None else None,
        }

    def test_options_preflight_returns_200(self):
        resp = self.handler(self._event(method="OPTIONS"), self.ctx)
        self.assertEqual(resp["statusCode"], 200)

    def test_invalid_json_body_returns_400(self):
        event = {"httpMethod": "POST", "body": "{invalid json"}
        resp = self.handler(event, self.ctx)
        self.assertEqual(resp["statusCode"], 400)

    def test_validation_failure_returns_400(self):
        resp = self.handler(self._event({"email": "bad", "password": "pass"}), self.ctx)
        self.assertEqual(resp["statusCode"], 400)
        body = json.loads(resp["body"])
        self.assertFalse(body["success"])

    @patch("lambda_function.auth.authenticate", return_value=("success", {
        "token": "jwt.token.here",
        "user": {"id": "uid", "email": "u@e.com", "first_name": "Ada"},
    }))
    def test_successful_login_returns_200(self, mock_auth):
        resp = self.handler(self._event({"email": "u@e.com", "password": "Correct1!"}), self.ctx)
        self.assertEqual(resp["statusCode"], 200)
        body = json.loads(resp["body"])
        self.assertTrue(body["success"])
        self.assertEqual(body["token"], "jwt.token.here")
        self.assertIn("user", body)

    @patch("lambda_function.auth.authenticate", return_value=("failure", {"message": "Invalid email or password"}))
    def test_auth_failure_returns_401(self, mock_auth):
        resp = self.handler(self._event({"email": "u@e.com", "password": "Wrong1!"}), self.ctx)
        self.assertEqual(resp["statusCode"], 401)
        body = json.loads(resp["body"])
        self.assertFalse(body["success"])

    @patch("lambda_function.auth.authenticate", return_value=("locked", {"message": "Account locked"}))
    def test_locked_account_returns_423(self, mock_auth):
        resp = self.handler(self._event({"email": "u@e.com", "password": "Pass1!"}), self.ctx)
        self.assertEqual(resp["statusCode"], 423)

    @patch("lambda_function.auth.authenticate", side_effect=Exception("DB down"))
    def test_unexpected_error_returns_500(self, mock_auth):
        resp = self.handler(self._event({"email": "u@e.com", "password": "Pass1!"}), self.ctx)
        self.assertEqual(resp["statusCode"], 500)
        body = json.loads(resp["body"])
        self.assertFalse(body["success"])

    def test_cors_headers_present(self):
        resp = self.handler(self._event(method="OPTIONS"), self.ctx)
        self.assertIn("Access-Control-Allow-Origin", resp["headers"])
        self.assertIn("Access-Control-Allow-Methods", resp["headers"])

    def test_email_normalised_to_lowercase(self):
        with patch("lambda_function.auth.authenticate", return_value=("success", {
            "token": "t", "user": {"id": "1", "email": "u@e.com", "first_name": "Ada"},
        })) as mock_auth:
            self.handler(self._event({"email": "  U@E.COM  ", "password": "Pass1!"}), self.ctx)
            called_email = mock_auth.call_args[0][0]
            self.assertEqual(called_email, "u@e.com")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    unittest.main()
