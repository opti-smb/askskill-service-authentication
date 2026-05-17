# auth-service

Production-grade AWS Lambda authentication service — email/password → JWT.

## Architecture

```
API Gateway (REST)
    │
    ▼ POST /auth/login
AWS Lambda (Python 3.12, Graviton2)
    ├── validators.py   — input validation
    ├── auth.py         — bcrypt + JWT + lock logic
    ├── db.py           — psycopg2 connection pool
    └── config.py       — Secrets Manager + env vars
    │
    ▼
Amazon RDS (PostgreSQL)
```

## Project layout

```
auth-service/
├── lambda_function.py   # Lambda entry point
├── auth.py
├── db.py
├── validators.py
├── config.py
├── requirements.txt
├── template.yaml        # AWS SAM
├── events/
│   └── login.json       # Sample API Gateway event
└── tests/
    └── test_auth.py
```

---

## Prerequisites

| Tool | Version |
|---|---|
| Python | 3.12 |
| AWS SAM CLI | ≥ 1.100 |
| AWS CLI | ≥ 2.x |
| Docker | Required for `sam build` with `--use-container` |

---

## Database setup

Create the `users` table before deploying:

```sql
CREATE EXTENSION IF NOT EXISTS "pgcrypto";

CREATE TABLE users (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    email           VARCHAR(254) NOT NULL UNIQUE,
    password_hash   VARCHAR(72)  NOT NULL,  -- bcrypt output is 60 chars; 72 is safe
    first_name      VARCHAR(100) NOT NULL,
    last_name       VARCHAR(100) NOT NULL,
    is_active       BOOLEAN      NOT NULL DEFAULT TRUE,
    is_locked       BOOLEAN      NOT NULL DEFAULT FALSE,
    failed_attempts INTEGER      NOT NULL DEFAULT 0,
    last_login      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at      TIMESTAMPTZ  NOT NULL DEFAULT NOW()
);

CREATE INDEX idx_users_email ON users (email);
```

---

## Secrets Manager

Create a secret with the following JSON structure:

```json
{
  "host":     "your-rds-endpoint.rds.amazonaws.com",
  "port":     5432,
  "dbname":   "your_database",
  "username": "your_db_user",
  "password": "your_db_password"
}
```

```bash
aws secretsmanager create-secret \
  --name "prod/auth-service/db" \
  --secret-string file://db-secret.json
```

---

## Environment variables

| Variable | Required | Default | Description |
|---|---|---|---|
| `DB_SECRET_NAME` | Yes | — | Secrets Manager secret name |
| `JWT_SECRET` | Yes | — | HS256 signing key (≥ 32 chars) |
| `JWT_EXPIRY_HOURS` | No | `1` | Token lifetime in hours |
| `MAX_FAILED_ATTEMPTS` | No | `5` | Failures before account lock |
| `CORS_ORIGIN` | No | `*` | `Access-Control-Allow-Origin` value |
| `LOG_LEVEL` | No | `INFO` | Python log level |

---

## Deploy

### 1. Build

```bash
cd auth-service
sam build
```

### 2. First-time deploy (guided)

```bash
sam deploy --guided
```

You will be prompted for all parameters.  Answers are saved to `samconfig.toml`.

### 3. Subsequent deploys

```bash
sam deploy
```

---

## Local testing (without AWS)

### Run unit tests

```bash
pip install -r requirements.txt pytest
python -m pytest tests/test_auth.py -v
```

### Invoke locally with SAM (requires Docker + real RDS or local PG)

```bash
export DB_SECRET_NAME=local/db
export JWT_SECRET=localdevonlysecret1234567890abcdef

sam local invoke AuthFunction \
  --event events/login.json \
  --env-vars local-env.json
```

`local-env.json` example:
```json
{
  "AuthFunction": {
    "DB_SECRET_NAME": "local/db",
    "JWT_SECRET": "localdevonlysecret1234567890abcdef"
  }
}
```

---

## API reference

### `POST /auth/login`

**Request**

```json
{
  "email": "customer@example.com",
  "password": "PlainTextPassword"
}
```

**Responses**

| Status | Meaning | Body |
|---|---|---|
| 200 | Authenticated | `{ "success": true, "token": "...", "user": {...} }` |
| 400 | Validation error | `{ "success": false, "message": "Invalid request" }` |
| 401 | Bad credentials | `{ "success": false, "message": "Invalid email or password" }` |
| 423 | Account locked | `{ "success": false, "message": "Account locked" }` |
| 500 | Server error | `{ "success": false, "message": "Internal server error" }` |

**200 response body**

```json
{
  "success": true,
  "message": "Authentication successful",
  "token": "<signed JWT>",
  "user": {
    "id": "11111111-...",
    "email": "customer@example.com",
    "first_name": "Ada"
  }
}
```

**JWT payload**

```json
{
  "sub": "<user UUID>",
  "email": "customer@example.com",
  "first_name": "Ada",
  "iat": 1716000000,
  "exp": 1716003600,
  "jti": "<uuid4>"
}
```

---

## curl example

```bash
curl -X POST https://<api-id>.execute-api.<region>.amazonaws.com/prod/auth/login \
  -H "Content-Type: application/json" \
  -d '{"email":"customer@example.com","password":"PlainTextPassword"}'
```

---

## Security notes

- **Generic error messages** — "Invalid email or password" is returned for wrong password, unknown user, and inactive account to prevent user enumeration.
- **bcrypt cost factor 12** — tuned to ~250 ms on a modern CPU; adjust `rounds` in `auth.hash_password` as hardware scales.
- **Account locking** — stored in the database (not Lambda memory) so lock state survives restarts and concurrent invocations.
- **Parameterized queries** — all SQL uses `%s` placeholders; no string interpolation in queries.
- **Secrets Manager caching** — credentials are fetched once per Lambda container and cached via `lru_cache`.
- **VPC isolation** — Lambda runs inside the same VPC as RDS; no public exposure of the database.
- **JWT `jti`** — each token has a unique ID enabling future revocation via a token denylist.
- **No password logging** — passwords and hashes are never written to logs at any level.
- **OWASP A02:2021 (Cryptographic Failures)** — passwords stored as bcrypt hashes only; plaintext never persisted.
- **OWASP A03:2021 (Injection)** — parameterized queries throughout.
- **OWASP A07:2021 (Identification and Authentication Failures)** — account lockout, generic messages, bcrypt.
