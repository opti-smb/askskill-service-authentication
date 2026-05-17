#!/usr/bin/env bash
# =============================================================================
# build.sh — Lambda ZIP packaging script for auth-service
#
# Usage:
#   ./build.sh [OPTIONS]
#
# Options:
#   --clean            Remove build artifacts and exit
#   --test             Run unit tests before packaging
#   --install-deps     Install dependencies only (no zip)
#   --package-only     Skip dependency install; just re-zip existing build dir
#   --docker           Build deps inside Lambda-compatible Docker container
#   --output <name>    Override output ZIP filename (default: auth-service-lambda.zip)
#   --help             Show this message
#
# Output:
#   dist/auth-service-lambda.zip
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Colour helpers (gracefully degrade when no TTY)
# ---------------------------------------------------------------------------
if [ -t 1 ]; then
  RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
  CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'
else
  RED=''; GREEN=''; YELLOW=''; CYAN=''; BOLD=''; RESET=''
fi

log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_section() { echo -e "\n${BOLD}── $* ──────────────────────────────────────────${RESET}"; }

die() { log_error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD_DIR="${SCRIPT_DIR}/.build"
DIST_DIR="${SCRIPT_DIR}/dist"
OUTPUT_ZIP="auth-service-lambda.zip"

FLAG_CLEAN=false
FLAG_TEST=false
FLAG_INSTALL_DEPS=false
FLAG_PACKAGE_ONLY=false
FLAG_DOCKER=false

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
  case "$1" in
    --clean)        FLAG_CLEAN=true ;;
    --test)         FLAG_TEST=true ;;
    --install-deps) FLAG_INSTALL_DEPS=true ;;
    --package-only) FLAG_PACKAGE_ONLY=true ;;
    --docker)       FLAG_DOCKER=true ;;
    --output)
      [[ -n "${2-}" ]] || die "--output requires a filename argument"
      OUTPUT_ZIP="$2"
      shift
      ;;
    --help|-h)
      sed -n '2,25p' "$0" | sed 's/^# \?//'
      exit 0
      ;;
    *)
      die "Unknown option: $1  (use --help for usage)"
      ;;
  esac
  shift
done

OUTPUT_PATH="${DIST_DIR}/${OUTPUT_ZIP}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

require_cmd() {
  command -v "$1" &>/dev/null || die "'$1' is not installed or not on PATH"
}

check_file() {
  [[ -f "$1" ]] || die "Required file not found: $1"
}

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------
do_clean() {
  log_section "Clean"
  log_info "Removing build artifacts..."
  rm -rf "${BUILD_DIR}" "${DIST_DIR}"
  log_ok "Clean complete"
}

# ---------------------------------------------------------------------------
# Preflight checks
# ---------------------------------------------------------------------------
do_preflight() {
  log_section "Preflight"

  require_cmd python3
  require_cmd pip3

  # Verify Python version >= 3.12
  PYTHON_VERSION=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
  PYTHON_MAJOR=$(echo "$PYTHON_VERSION" | cut -d. -f1)
  PYTHON_MINOR=$(echo "$PYTHON_VERSION" | cut -d. -f2)
  if [[ "$PYTHON_MAJOR" -lt 3 ]] || { [[ "$PYTHON_MAJOR" -eq 3 ]] && [[ "$PYTHON_MINOR" -lt 12 ]]; }; then
    log_warn "Python ${PYTHON_VERSION} detected; Lambda runtime is 3.12. Build may still work for pure-Python deps."
  else
    log_ok "Python ${PYTHON_VERSION}"
  fi

  check_file "${SCRIPT_DIR}/requirements.txt"
  check_file "${SCRIPT_DIR}/lambda_function.py"

  if $FLAG_DOCKER; then
    require_cmd docker
    log_ok "Docker available"
  fi

  log_ok "Preflight passed"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
do_test() {
  log_section "Tests"
  require_cmd python3

  if ! python3 -m pytest tests/ -v --tb=short 2>&1; then
    die "Tests failed — aborting build"
  fi
  log_ok "All tests passed"
}

# ---------------------------------------------------------------------------
# Install dependencies (native)
# ---------------------------------------------------------------------------
do_install_deps_native() {
  log_section "Install dependencies (native pip)"

  mkdir -p "${BUILD_DIR}"

  log_info "Installing into ${BUILD_DIR}..."
  pip3 install \
    --requirement "${SCRIPT_DIR}/requirements.txt" \
    --target "${BUILD_DIR}" \
    --upgrade \
    --no-cache-dir \
    --platform manylinux2014_x86_64 \
    --implementation cp \
    --python-version 3.12 \
    --only-binary=:all: \
    2>&1 | sed 's/^/    /'

  log_ok "Dependencies installed"
}

# ---------------------------------------------------------------------------
# Install dependencies (Docker — Linux-compatible binary wheels)
# ---------------------------------------------------------------------------
do_install_deps_docker() {
  log_section "Install dependencies (Docker — Lambda-compatible)"

  DOCKER_IMAGE="public.ecr.aws/lambda/python:3.12"

  log_info "Pulling image: ${DOCKER_IMAGE}"
  docker pull "${DOCKER_IMAGE}" 2>&1 | tail -5

  mkdir -p "${BUILD_DIR}"

  log_info "Running pip inside Lambda container..."
  docker run --rm \
    -v "${SCRIPT_DIR}:/src:ro" \
    -v "${BUILD_DIR}:/out" \
    "${DOCKER_IMAGE}" \
    pip install \
      --requirement /src/requirements.txt \
      --target /out \
      --upgrade \
      --no-cache-dir \
    2>&1 | sed 's/^/    /'

  log_ok "Dependencies installed (Docker)"
}

# ---------------------------------------------------------------------------
# Copy application source files
# ---------------------------------------------------------------------------
do_copy_sources() {
  log_section "Copy source files"

  EXCLUDED=(
    "tests"
    "__pycache__"
    ".pytest_cache"
    ".git"
    ".gitignore"
    ".DS_Store"
    "*.pyc"
    "*.pyo"
    "build.sh"
    "build.ps1"
    "Makefile"
    "README.md"
    "requirements.txt"
    "template.yaml"
    "samconfig.toml"
    "dist"
    ".build"
    ".env"
    "*.env"
    "venv"
    ".venv"
    "env"
    "events"
    ".idea"
    ".vscode"
  )

  SOURCE_FILES=(
    "lambda_function.py"
    "auth.py"
    "db.py"
    "validators.py"
    "config.py"
  )

  for f in "${SOURCE_FILES[@]}"; do
    if [[ -f "${SCRIPT_DIR}/${f}" ]]; then
      cp "${SCRIPT_DIR}/${f}" "${BUILD_DIR}/${f}"
      log_info "Copied: ${f}"
    else
      log_warn "Source file not found (skipping): ${f}"
    fi
  done

  # Remove any test directories accidentally pulled in via deps
  find "${BUILD_DIR}" -type d -name "tests" -exec rm -rf {} + 2>/dev/null || true
  find "${BUILD_DIR}" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
  find "${BUILD_DIR}" -type d -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true
  find "${BUILD_DIR}" -name "*.pyc" -delete 2>/dev/null || true
  find "${BUILD_DIR}" -name "*.pyo" -delete 2>/dev/null || true

  log_ok "Source files copied"
}

# ---------------------------------------------------------------------------
# Package ZIP
# ---------------------------------------------------------------------------
do_package() {
  log_section "Package"

  mkdir -p "${DIST_DIR}"

  if [[ -f "${OUTPUT_PATH}" ]]; then
    log_info "Removing existing ZIP: ${OUTPUT_PATH}"
    rm -f "${OUTPUT_PATH}"
  fi

  log_info "Creating ZIP: ${OUTPUT_PATH}"
  (
    cd "${BUILD_DIR}"
    zip -r "${OUTPUT_PATH}" . \
      --exclude "*.pyc" \
      --exclude "*/__pycache__/*" \
      --exclude "*.pyo" \
      --exclude "*.dist-info/*" \
      2>&1 | tail -5
  )

  ZIP_SIZE=$(du -sh "${OUTPUT_PATH}" | cut -f1)
  FILE_COUNT=$(unzip -l "${OUTPUT_PATH}" | tail -1 | awk '{print $2}')

  log_ok "Package created: ${OUTPUT_PATH}"
  log_info "Size: ${ZIP_SIZE}  |  Files: ${FILE_COUNT}"

  # Lambda hard limit: 250 MB unzipped
  UNZIPPED_MB=$(unzip -l "${OUTPUT_PATH}" | tail -1 | awk '{printf "%.0f", $1/1048576}')
  if [[ "${UNZIPPED_MB}" -gt 200 ]]; then
    log_warn "Unzipped size is ~${UNZIPPED_MB} MB — approaching Lambda 250 MB limit"
  fi

  log_ok "lambda_function.py at ZIP root: $(unzip -l "${OUTPUT_PATH}" | grep -c 'lambda_function.py') entry/entries"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
echo -e "${BOLD}auth-service Lambda Build${RESET}  $(date '+%Y-%m-%d %H:%M:%S')"
echo "  Script dir : ${SCRIPT_DIR}"
echo "  Build dir  : ${BUILD_DIR}"
echo "  Output     : ${OUTPUT_PATH}"

if $FLAG_CLEAN; then
  do_clean
  exit 0
fi

do_preflight

if $FLAG_TEST; then
  do_test
fi

if ! $FLAG_PACKAGE_ONLY; then
  if $FLAG_DOCKER; then
    do_install_deps_docker
  else
    do_install_deps_native
  fi
fi

if ! $FLAG_INSTALL_DEPS; then
  do_copy_sources
  do_package
fi

log_section "Done"
log_ok "Build complete → ${OUTPUT_PATH}"
echo ""
echo "  Deploy with:"
echo "    aws lambda update-function-code \\"
echo "      --function-name customer-auth-service \\"
echo "      --zip-file fileb://${OUTPUT_PATH}"
