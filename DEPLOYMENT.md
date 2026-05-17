# Deployment Guide — auth-service Lambda

## Prerequisites

| Tool | Version | Install |
|---|---|---|
| Python | ≥ 3.12 | https://python.org |
| pip | ≥ 23 | bundled with Python |
| AWS CLI | ≥ 2.x | https://aws.amazon.com/cli/ |
| Docker | ≥ 24 | Required only for `--docker` / `make docker-build` |
| GNU Make | ≥ 3.81 | macOS: `xcode-select --install`; Linux: pre-installed |

---

## Quick start

### Linux / macOS

```bash
# 1. Make the script executable
chmod +x build.sh

# 2. Build the deployment ZIP
./build.sh

# 3. Deploy to AWS Lambda
aws lambda update-function-code \
  --function-name customer-auth-service \
  --zip-file fileb://dist/auth-service-lambda.zip
```

### Windows (PowerShell)

```powershell
# Run without modifying execution policy
powershell -ExecutionPolicy Bypass -File .\build.ps1

# Or set policy for the current session
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
.\build.ps1
```

### Make (Linux / macOS)

```bash
make build     # Full build
make test      # Run tests only
make package   # Re-zip without reinstalling deps
make deploy    # build + upload to Lambda
make clean     # Remove artifacts
```

---

## Build modes

### Standard (pip — fast, requires Python 3.12 locally)

```bash
./build.sh
```

Installs `manylinux2014_x86_64` wheels — compatible with Lambda's Amazon Linux 2 runtime.
Suitable for most cases.  psycopg2-binary and bcrypt ship pre-compiled manylinux wheels.

### Docker (recommended for CI or when local Python ≠ 3.12)

```bash
./build.sh --docker
# or
make docker-build
```

Runs `pip install` inside `public.ecr.aws/lambda/python:3.12` — the exact runtime image
AWS uses.  Guarantees binary compatibility at the cost of a Docker pull (~1 GB, cached).

---

## Script options

### build.sh

```
./build.sh [OPTIONS]

  --clean                Remove .build/ and dist/; exit
  --test                 Run pytest before packaging
  --install-deps         Install deps only; skip zip creation
  --package-only         Re-zip existing .build/ (skip pip install)
  --docker               Build inside Lambda Docker container
  --output <name.zip>    Override output filename
  --help                 Show usage
```

### build.ps1

```powershell
.\build.ps1 [-Clean] [-Test] [-InstallDeps] [-PackageOnly] [-Docker] [-Output <name.zip>]
```

---

## Make targets

```bash
make build          # Default: clean install deps + copy sources + zip
make clean          # rm -rf .build/ dist/
make test           # python -m pytest tests/ -v
make package        # Copy sources + zip (skips pip install)
make docker-build   # Pip inside Lambda container + zip
make deploy         # Upload dist/auth-service-lambda.zip to Lambda
make help           # Print all targets + variables
```

### Override variables

```bash
make deploy FUNCTION_NAME=my-prod-auth REGION=eu-west-1
make build  OUTPUT=auth-service-v2.zip
```

---

## First-time Lambda deployment (AWS CLI)

### 1. Create the IAM execution role

```bash
aws iam create-role \
  --role-name auth-service-lambda-role \
  --assume-role-policy-document '{
    "Version": "2012-10-17",
    "Statement": [{
      "Effect": "Allow",
      "Principal": {"Service": "lambda.amazonaws.com"},
      "Action": "sts:AssumeRole"
    }]
  }'

# Basic execution + VPC + CloudWatch
aws iam attach-role-policy \
  --role-name auth-service-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole

# Secrets Manager access — scope to your secret
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
aws iam put-role-policy \
  --role-name auth-service-lambda-role \
  --policy-name SecretsManagerAccess \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{
      \"Effect\": \"Allow\",
      \"Action\": \"secretsmanager:GetSecretValue\",
      \"Resource\": \"arn:aws:secretsmanager:us-east-1:${ACCOUNT_ID}:secret:prod/auth-service/db*\"
    }]
  }"
```

### 2. Create the Secrets Manager secret

```bash
aws secretsmanager create-secret \
  --name "prod/auth-service/db" \
  --secret-string '{
    "host":     "your-rds.cluster-xxxx.us-east-1.rds.amazonaws.com",
    "port":     5432,
    "dbname":   "authdb",
    "username": "authuser",
    "password": "REPLACE_ME"
  }'
```

### 3. Create the Lambda function

```bash
ROLE_ARN=$(aws iam get-role --role-name auth-service-lambda-role \
  --query Role.Arn --output text)

aws lambda create-function \
  --function-name customer-auth-service \
  --runtime python3.12 \
  --architectures arm64 \
  --handler lambda_function.lambda_handler \
  --role "$ROLE_ARN" \
  --zip-file fileb://dist/auth-service-lambda.zip \
  --memory-size 256 \
  --timeout 30 \
  --environment "Variables={
    DB_SECRET_NAME=prod/auth-service/db,
    JWT_SECRET=REPLACE_WITH_32_CHAR_MIN_SECRET,
    JWT_EXPIRY_HOURS=1,
    MAX_FAILED_ATTEMPTS=5,
    CORS_ORIGIN=https://your-frontend.example.com,
    LOG_LEVEL=INFO
  }" \
  --vpc-config "SubnetIds=subnet-aaa,subnet-bbb,SecurityGroupIds=sg-xxx" \
  --tracing-config Mode=Active
```

### 4. Update function code on subsequent deployments

```bash
./build.sh
aws lambda update-function-code \
  --function-name customer-auth-service \
  --zip-file fileb://dist/auth-service-lambda.zip
```

### 5. Update environment variables

```bash
aws lambda update-function-configuration \
  --function-name customer-auth-service \
  --environment "Variables={
    DB_SECRET_NAME=prod/auth-service/db,
    JWT_SECRET=NEW_SECRET_VALUE,
    JWT_EXPIRY_HOURS=1,
    MAX_FAILED_ATTEMPTS=5,
    CORS_ORIGIN=https://your-frontend.example.com,
    LOG_LEVEL=INFO
  }"
```

---

## CI/CD pipeline (GitHub Actions)

```yaml
# .github/workflows/deploy.yml
name: Deploy Lambda

on:
  push:
    branches: [main]

jobs:
  deploy:
    runs-on: ubuntu-latest
    permissions:
      id-token: write   # for OIDC
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Set up Python 3.12
        uses: actions/setup-python@v5
        with:
          python-version: "3.12"

      - name: Run tests
        run: python -m pytest tests/ -v

      - name: Build Lambda package
        run: |
          chmod +x build.sh
          ./build.sh

      - name: Configure AWS credentials (OIDC)
        uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::${{ secrets.AWS_ACCOUNT_ID }}:role/github-deploy-role
          aws-region: us-east-1

      - name: Deploy to Lambda
        run: |
          aws lambda update-function-code \
            --function-name customer-auth-service \
            --zip-file fileb://dist/auth-service-lambda.zip
```

---

## Verify deployment

```bash
# Check function state
aws lambda get-function-configuration \
  --function-name customer-auth-service \
  --query '{State: State, Runtime: Runtime, LastModified: LastModified}'

# Invoke with test payload
aws lambda invoke \
  --function-name customer-auth-service \
  --payload fileb://events/login.json \
  --cli-binary-format raw-in-base64-out \
  /tmp/response.json && cat /tmp/response.json

# Tail CloudWatch logs
aws logs tail /aws/lambda/customer-auth-service --follow
```

---

## ZIP package layout

The final ZIP must have all files at the root (not nested):

```
auth-service-lambda.zip
├── lambda_function.py      ← Lambda handler entry point
├── auth.py
├── db.py
├── validators.py
├── config.py
├── bcrypt/                 ← installed dependency
├── jwt/
├── psycopg2/
├── email_validator/
└── ...
```

---

## Troubleshooting

| Problem | Cause | Fix |
|---|---|---|
| `Unable to import module 'lambda_function'` | Source files not at ZIP root | Ensure `cd .build && zip ...` (not `zip -r .build/`) |
| `psycopg2` import error in Lambda | Wrong binary wheel platform | Use `--docker` build mode |
| `bcrypt` import error | Same — wrong binary | Use `--docker` build mode |
| ZIP > 50 MB upload limit | Too many deps | Use S3 upload: `aws s3 cp ... && lambda update-function-code --s3-bucket ...` |
| Cold start > 3 s | Large package | Use Lambda Layers for heavy deps |
| `Secret not found` | Wrong `DB_SECRET_NAME` env var | Double-check secret name and IAM permissions |

---

## Security checklist

- [ ] `.env` files are in `.gitignore`
- [ ] `samconfig.toml` is in `.gitignore` (may contain account IDs)
- [ ] `JWT_SECRET` is set via environment variable, not hardcoded
- [ ] `DB_SECRET_NAME` points to a Secrets Manager secret (not inline credentials)
- [ ] Lambda execution role is scoped to the specific secret ARN
- [ ] Lambda runs inside a VPC with no public IP
- [ ] CORS_ORIGIN is set to your specific frontend domain, not `*` in production
