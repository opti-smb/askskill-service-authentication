# =============================================================================
# Makefile — auth-service Lambda build automation
#
# Targets:
#   make build        Build deployment ZIP (default)
#   make clean        Remove all build artifacts
#   make test         Run unit tests
#   make package      Re-zip existing build directory (skip dep install)
#   make docker-build Build with Lambda-compatible Docker container
#   make deploy       Deploy ZIP to AWS Lambda
#   make help         Show this help
#
# Variables (override on command line):
#   FUNCTION_NAME   AWS Lambda function name   (default: customer-auth-service)
#   REGION          AWS region                  (default: us-east-1)
#   OUTPUT          ZIP filename                (default: auth-service-lambda.zip)
#   PYTHON          Python interpreter          (default: python3)
#   PIP             pip interpreter             (default: pip3)
# =============================================================================

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
FUNCTION_NAME ?= customer-auth-service
REGION        ?= us-east-1
OUTPUT        ?= auth-service-lambda.zip

PYTHON        ?= python3
PIP           ?= pip3
DOCKER_IMAGE  := public.ecr.aws/lambda/python:3.12

SCRIPT_DIR    := $(shell pwd)
BUILD_DIR     := $(SCRIPT_DIR)/.build
DIST_DIR      := $(SCRIPT_DIR)/dist
OUTPUT_PATH   := $(DIST_DIR)/$(OUTPUT)

SOURCE_FILES  := lambda_function.py auth.py db.py validators.py config.py

# ---------------------------------------------------------------------------
# Colour output (suppressed if not a terminal)
# ---------------------------------------------------------------------------
ifneq (,$(findstring xterm,$(TERM)))
  RED    := \033[0;31m
  GREEN  := \033[0;32m
  YELLOW := \033[1;33m
  CYAN   := \033[0;36m
  RESET  := \033[0m
else
  RED := GREEN := YELLOW := CYAN := RESET :=
endif

define log_info
	@echo -e "$(CYAN)[INFO]$(RESET)  $(1)"
endef
define log_ok
	@echo -e "$(GREEN)[OK]$(RESET)    $(1)"
endef
define log_section
	@echo -e "\n$(YELLOW)── $(1) ──────────────────────────────────────────$(RESET)"
endef

# ---------------------------------------------------------------------------
# Default target
# ---------------------------------------------------------------------------
.DEFAULT_GOAL := build

.PHONY: build clean test package docker-build deploy help \
        _preflight _install-deps _copy-sources _zip

# ---------------------------------------------------------------------------
# help
# ---------------------------------------------------------------------------
help:
	@echo ""
	@echo "auth-service — Lambda build targets"
	@echo ""
	@echo "  make build           Install deps, copy sources, create ZIP"
	@echo "  make clean           Remove .build/ and dist/"
	@echo "  make test            Run unit tests"
	@echo "  make package         Re-zip existing build dir (no dep install)"
	@echo "  make docker-build    Build with Lambda Docker container"
	@echo "  make deploy          Deploy ZIP to AWS Lambda"
	@echo ""
	@echo "Variables:"
	@echo "  FUNCTION_NAME=$(FUNCTION_NAME)"
	@echo "  REGION=$(REGION)"
	@echo "  OUTPUT=$(OUTPUT)"
	@echo "  PYTHON=$(PYTHON)"
	@echo "  PIP=$(PIP)"
	@echo ""

# ---------------------------------------------------------------------------
# clean
# ---------------------------------------------------------------------------
clean:
	$(call log_section,Clean)
	$(call log_info,Removing .build/ and dist/)
	@rm -rf "$(BUILD_DIR)" "$(DIST_DIR)"
	$(call log_ok,Clean complete)

# ---------------------------------------------------------------------------
# test
# ---------------------------------------------------------------------------
test:
	$(call log_section,Tests)
	@$(PYTHON) -m pytest tests/ -v --tb=short
	$(call log_ok,Tests passed)

# ---------------------------------------------------------------------------
# Preflight checks (internal)
# ---------------------------------------------------------------------------
_preflight:
	$(call log_section,Preflight)
	@command -v $(PYTHON) >/dev/null 2>&1 || \
		(echo "ERROR: $(PYTHON) not found" && exit 1)
	@command -v $(PIP) >/dev/null 2>&1 || \
		(echo "ERROR: $(PIP) not found" && exit 1)
	@test -f requirements.txt || \
		(echo "ERROR: requirements.txt not found" && exit 1)
	@test -f lambda_function.py || \
		(echo "ERROR: lambda_function.py not found" && exit 1)
	$(call log_ok,Preflight passed)

# ---------------------------------------------------------------------------
# Install dependencies — manylinux wheels for Lambda
# ---------------------------------------------------------------------------
_install-deps: _preflight
	$(call log_section,Install dependencies)
	@mkdir -p "$(BUILD_DIR)"
	$(call log_info,Installing Python packages into $(BUILD_DIR)...)
	@$(PIP) install \
		--requirement requirements.txt \
		--target "$(BUILD_DIR)" \
		--upgrade \
		--no-cache-dir \
		--platform manylinux2014_x86_64 \
		--implementation cp \
		--python-version 3.12 \
		--only-binary=:all:
	$(call log_ok,Dependencies installed)

# ---------------------------------------------------------------------------
# Copy application source files
# ---------------------------------------------------------------------------
_copy-sources:
	$(call log_section,Copy source files)
	@for f in $(SOURCE_FILES); do \
		if [ -f "$$f" ]; then \
			cp "$$f" "$(BUILD_DIR)/$$f"; \
			echo "  Copied: $$f"; \
		else \
			echo "  WARN: $$f not found, skipping"; \
		fi; \
	done
	@find "$(BUILD_DIR)" -type d -name "__pycache__" -exec rm -rf {} + 2>/dev/null || true
	@find "$(BUILD_DIR)" -type d -name "*.dist-info" -exec rm -rf {} + 2>/dev/null || true
	@find "$(BUILD_DIR)" -name "*.pyc" -delete 2>/dev/null || true
	@find "$(BUILD_DIR)" -name "*.pyo" -delete 2>/dev/null || true
	$(call log_ok,Source files copied)

# ---------------------------------------------------------------------------
# Create ZIP
# ---------------------------------------------------------------------------
_zip:
	$(call log_section,Package)
	@mkdir -p "$(DIST_DIR)"
	@rm -f "$(OUTPUT_PATH)"
	$(call log_info,Creating $(OUTPUT_PATH)...)
	@cd "$(BUILD_DIR)" && zip -qr "$(OUTPUT_PATH)" . \
		--exclude "*.pyc" \
		--exclude "*/__pycache__/*" \
		--exclude "*.pyo"
	@ZIP_SIZE=$$(du -sh "$(OUTPUT_PATH)" | cut -f1); \
	 FILE_COUNT=$$(unzip -l "$(OUTPUT_PATH)" | tail -1 | awk '{print $$2}'); \
	 echo "  Size: $$ZIP_SIZE  |  Files: $$FILE_COUNT"
	$(call log_ok,Package created: $(OUTPUT_PATH))

# ---------------------------------------------------------------------------
# build — full pipeline
# ---------------------------------------------------------------------------
build: _preflight _install-deps _copy-sources _zip
	$(call log_section,Done)
	$(call log_ok,Build complete → $(OUTPUT_PATH))
	@echo ""
	@echo "  Deploy:"
	@echo "    aws lambda update-function-code \\"
	@echo "      --function-name $(FUNCTION_NAME) \\"
	@echo "      --zip-file fileb://$(OUTPUT_PATH)"

# ---------------------------------------------------------------------------
# package — re-zip without reinstalling deps
# ---------------------------------------------------------------------------
package: _preflight _copy-sources _zip
	$(call log_ok,Package only complete → $(OUTPUT_PATH))

# ---------------------------------------------------------------------------
# docker-build — Lambda-compatible binary deps via Docker
# ---------------------------------------------------------------------------
docker-build: _preflight
	$(call log_section,Docker build)
	@command -v docker >/dev/null 2>&1 || (echo "ERROR: docker not found" && exit 1)
	$(call log_info,Pulling $(DOCKER_IMAGE)...)
	@docker pull "$(DOCKER_IMAGE)" 2>&1 | tail -3
	@mkdir -p "$(BUILD_DIR)"
	$(call log_info,Building dependencies inside Lambda container...)
	@docker run --rm \
		-v "$(SCRIPT_DIR):/src:ro" \
		-v "$(BUILD_DIR):/out" \
		"$(DOCKER_IMAGE)" \
		pip install \
			--requirement /src/requirements.txt \
			--target /out \
			--upgrade \
			--no-cache-dir
	$(call log_ok,Docker dep install complete)
	@$(MAKE) _copy-sources _zip
	$(call log_ok,Docker build complete → $(OUTPUT_PATH))

# ---------------------------------------------------------------------------
# deploy — upload ZIP to AWS Lambda
# ---------------------------------------------------------------------------
deploy:
	$(call log_section,Deploy)
	@test -f "$(OUTPUT_PATH)" || \
		(echo "ERROR: $(OUTPUT_PATH) not found — run 'make build' first" && exit 1)
	@command -v aws >/dev/null 2>&1 || \
		(echo "ERROR: AWS CLI not found" && exit 1)
	$(call log_info,Uploading to Lambda function: $(FUNCTION_NAME))
	@aws lambda update-function-code \
		--function-name "$(FUNCTION_NAME)" \
		--zip-file "fileb://$(OUTPUT_PATH)" \
		--region "$(REGION)" \
		--output json | \
		python3 -c "import sys,json; d=json.load(sys.stdin); \
		print(f'  Function : {d[\"FunctionName\"]}'); \
		print(f'  Runtime  : {d[\"Runtime\"]}'); \
		print(f'  State    : {d[\"State\"]}'); \
		print(f'  Modified : {d[\"LastModified\"]}')"
	$(call log_ok,Deploy complete)

# ---------------------------------------------------------------------------
# Prevent make from treating filenames as targets
# ---------------------------------------------------------------------------
%:
	@echo "Unknown target: $@  (use 'make help')" && exit 1
