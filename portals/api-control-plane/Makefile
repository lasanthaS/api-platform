# --------------------------------------------------------------------
#
# WSO2 LLC. licenses this file to you under the Apache License,
# Version 2.0 (the "License"); you may not use this file except
# in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied. See the License for the
# specific language governing permissions and limitations
# under the License.
# --------------------------------------------------------------------

# Makefile for API Control Plane

SHELL := /bin/bash

VERSION ?= $(shell cat VERSION 2>/dev/null || echo "0.0.0-SNAPSHOT")

DOCKER_REGISTRY ?= ghcr.io/wso2/api-platform
IMAGE_NAME := $(DOCKER_REGISTRY)/api-control-plane

.PHONY: help run build bff-build bff-run bff-test bff-tidy test build-and-push-multiarch version-set version-bump-patch version-bump-minor version-bump-major version-bump-next-dev version-get-release dist clean-dist clean

# BFF (Backend-for-Frontend) — Go server that serves the SPA, proxies all
# browser->backend traffic, and owns authentication. Local dev runs it over
# HTTPS on its own port (8083, see configs/config-debug.toml — the shipped
# config.toml's 9743 would collide with a container/production instance on
# the same host); `make run`'s Vite dev server proxies same-origin BFF paths
# to it (see vite.config.ts).
BFF_DIR           := bff
CONTROL_PLANE_URL ?= https://localhost:9243
# The default CONTROL_PLANE_URL above points at platform-api's local dev
# listener, which uses a self-signed certificate (see
# platform-api/scripts/setup-local-dev.sh) — no real CA can validate it, so
# this defaults to true for that specific case. It is an explicit,
# overridable opt-out, not forced: point CONTROL_PLANE_URL at a real
# deployment and pass CONTROL_PLANE_TLS_SKIP_VERIFY=false alongside it.
CONTROL_PLANE_TLS_SKIP_VERIFY ?= true

help: ## Show this help message
	@echo 'API Control Plane Build System (Version: $(VERSION))'
	@echo ''
	@echo 'Available targets:'
	@awk 'BEGIN {FS = ":.*?## "} /^[a-zA-Z_-]+:.*?## / {printf "  %-25s %s\n", $$1, $$2}' $(MAKEFILE_LIST)

run: ## Start the console dev server locally (installs deps if needed; pair with `make bff-run`)
	@if [ ! -d node_modules ]; then \
		echo "node_modules not found — running npm install..."; \
		npm install; \
	fi
	npm run dev

# Runs the shipped configs/config.toml (the file the container mounts) layered
# with configs/config-debug.toml — a local-debug overlay that points the
# container-shaped defaults (listener :8083 + host cert/key, control-plane
# URL, debug logging) at this machine. -config is repeatable and merged
# last-wins, so config.toml stays untouched. To test against an external IdP,
# add APIP_ACP_AUTH_MODE=oidc and the matching APIP_ACP_AUTH_OIDC_* variables
# the [auth.oidc] tokens name.
bff-run: ## Run the BFF locally against the local Platform API (pair with `make run`)
	../scripts/setup.sh --certs-only
	cd $(BFF_DIR) && \
		APIP_ACP_CONTROL_PLANE_URL=$(CONTROL_PLANE_URL) \
		APIP_ACP_CONTROL_PLANE_TLS_SKIP_VERIFY=$(CONTROL_PLANE_TLS_SKIP_VERIFY) \
		GOWORK=off go run . -config ../configs/config.toml -config ../configs/config-debug.toml

bff-build: ## Build the BFF binary
	cd $(BFF_DIR) && GOWORK=off CGO_ENABLED=0 go build -o ../target/api-control-plane-bff .

bff-test: ## Run BFF unit tests
	cd $(BFF_DIR) && GOWORK=off go test ./...

bff-tidy: ## Tidy the BFF module
	cd $(BFF_DIR) && GOWORK=off go mod tidy

test: ## Run frontend and BFF tests
	npm test
	$(MAKE) bff-test

build: ## Build the production Docker image
	docker build -t $(IMAGE_NAME):$(VERSION) -t api-control-plane:$(VERSION) .

build-and-push-multiarch: ## Build and push multi-architecture Docker image (linux/amd64, linux/arm64)
	@echo "Building and pushing multi-arch api-control-plane Docker image: $(IMAGE_NAME):$(VERSION)"
	docker buildx build \
		--platform linux/amd64,linux/arm64 \
		--build-arg VERSION=$(VERSION) \
		-t $(IMAGE_NAME):$(VERSION) \
		--push \
		.

version-set: ## Set api-control-plane version
	@if [ -z "$(VERSION)" ]; then \
		echo "Error: VERSION required"; \
		echo "Usage: make version-set VERSION=1.0.0"; \
		exit 1; \
	fi
	@echo "$(VERSION)" > VERSION
	@(cd ../.. && bash scripts/update-docker-compose.sh api-control-plane $(VERSION))
	@echo "✓ Set api-control-plane version to $(VERSION)"

version-bump-patch: ## Bump patch version
	@$(MAKE) version-set VERSION=$$(cd ../.. && bash scripts/next-version.sh patch portals/api-control-plane)

version-bump-minor: ## Bump minor version
	@$(MAKE) version-set VERSION=$$(cd ../.. && bash scripts/next-version.sh minor portals/api-control-plane)

version-bump-major: ## Bump major version
	@$(MAKE) version-set VERSION=$$(cd ../.. && bash scripts/next-version.sh major portals/api-control-plane)

version-bump-next-dev: ## Bump to next minor dev version with SNAPSHOT suffix
	@$(MAKE) version-set VERSION=$$(cd ../.. && bash scripts/next-version.sh next-dev portals/api-control-plane)

version-get-release: ## Get release version (strips SNAPSHOT suffix)
	@VERSION=$$(cat VERSION 2>/dev/null | tr -d '[:space:]' | sed 's/-SNAPSHOT//'); \
	if [ -z "$$VERSION" ]; then \
		echo "Error: VERSION is empty or contains only whitespace. Check portals/api-control-plane/VERSION file." >&2; \
		exit 1; \
	fi; \
	echo "$$VERSION"

# Distribution Targets
DIST_VERSION := $(shell echo "$(VERSION)" | sed 's/-SNAPSHOT//')
DIST_NAME    := wso2apip-api-control-plane-$(DIST_VERSION)
DIST_DIR     := target/$(DIST_NAME)
DIST_ZIP     := target/$(DIST_NAME).zip

# Platform API is a first-class service of this distribution (not
# profile-gated behind an optional add-on), so both its image tag AND its
# config sections are pinned to a released version.
#
# The fallback is applied to the captured value rather than with `|| echo`: in a
# `sed … < file` pipeline the exit status is sed's, and sed succeeds on empty
# input, so a missing or empty VERSION file would otherwise yield an empty string
# — which would also propagate into PLATFORM_API_TAG, producing the malformed git
# tag "platform-api/v".
PLATFORM_API_IMAGE   := $(DOCKER_REGISTRY)/platform-api
PLATFORM_API_VERSION ?= $(shell v=$$(sed 's/-SNAPSHOT//' ../../platform-api/VERSION 2>/dev/null); echo "$${v:-0.0.0}")
PLATFORM_API_TAG     := platform-api/v$(PLATFORM_API_VERSION)

# When PLATFORM_API_VERSION is supplied explicitly (e.g. `make dist PLATFORM_API_VERSION=0.17.0`),
# the platform-api configs and db-scripts are fetched from the released git tag $(PLATFORM_API_TAG)
# so the distribution is reproducible for that exact release — the merged config.toml then matches
# the image it is mounted into. Otherwise they are taken from the working tree.
ifeq ($(origin PLATFORM_API_VERSION),command line)
PLATFORM_API_FROM_TAG := true
endif
ifeq ($(origin PLATFORM_API_VERSION),environment)
PLATFORM_API_FROM_TAG := true
endif

# Merge an API Control Plane config and a Platform API config into one unified
# multi-component config file: $(call merge_config,<acp-toml>,<cp-toml>,<out>).
# The components share no top-level keys ([api_control_plane.*] vs
# [platform_api.*]), so the merge is a banner-separated concatenation — each
# service reads only its own root table and ignores the other's tokens.
define merge_config
	@printf '%s\n' \
		'# =============================================================================' \
		'# UNIFIED API PLATFORM CONFIGURATION' \
		'# =============================================================================' \
		'# One file, multiple components. Each service reads ONLY its own root table' \
		'# (e.g. [api_control_plane], [platform_api]) and ignores the other sections and' \
		'# their tokens. GENERATED by `make dist` from the per-component source configs.' \
		'' '' \
		'# #############################################################################' \
		'# #  API CONTROL PLANE' \
		'# #############################################################################' \
		'' > $(3)
	@cat $(1) >> $(3)
	@printf '%s\n' \
		'' '' \
		'# #############################################################################' \
		'# #  PLATFORM API' \
		'# #############################################################################' \
		'' >> $(3)
	@cat $(2) >> $(3)
endef

dist: clean-dist ## Build standalone API Control Plane distribution zip (target/wso2apip-api-control-plane-<VERSION>.zip)
	@echo "Building distribution $(DIST_NAME)..."
	@echo "  platform-api image pinned to $(PLATFORM_API_IMAGE):$(PLATFORM_API_VERSION)"
	@mkdir -p $(DIST_DIR)/configs $(DIST_DIR)/scripts $(DIST_DIR)/resources/certificates $(DIST_DIR)/resources/platform-api/db-scripts
# Stage platform-api configs + db-scripts (from tag or working tree) for the merge below.
ifeq ($(PLATFORM_API_FROM_TAG),true)
	@echo "Fetching platform-api db-scripts from tag $(PLATFORM_API_TAG)..."
	@tag="$(PLATFORM_API_TAG)"; dest="$(DIST_DIR)/resources/platform-api/db-scripts"; \
	if ! git -C ../.. rev-parse -q --verify "refs/tags/$$tag" >/dev/null 2>&1; then \
		git -C ../.. fetch --tags --quiet || true; \
	fi; \
	if ! git -C ../.. rev-parse -q --verify "refs/tags/$$tag" >/dev/null 2>&1; then \
		echo "Error: tag $$tag not found (check PLATFORM_API_VERSION)" >&2; exit 1; \
	fi; \
	files=$$(git -C ../.. ls-tree -r --name-only "$$tag" -- platform-api/internal/database | grep 'schema\.[^.]*\.sql$$'); \
	if [ -z "$$files" ]; then echo "Error: no .sql files found under platform-api/internal/database at $$tag" >&2; exit 1; fi; \
	for f in $$files; do git -C ../.. show "$$tag:$$f" > "$$dest/$$(basename $$f)"; done; \
	echo "✓ Fetched $$(echo "$$files" | wc -l | tr -d ' ') db-script(s) from $$tag"
	@git -C ../.. show "$(PLATFORM_API_TAG):platform-api/config/config.toml" \
		> $(DIST_DIR)/configs/.pa-config.toml
	@git -C ../.. show "$(PLATFORM_API_TAG):platform-api/config/config-template.toml" \
		> $(DIST_DIR)/configs/.pa-config-template.toml
	@git -C ../.. show "$(PLATFORM_API_TAG):platform-api/resources/role-to-scope-mapping.yaml" \
		> $(DIST_DIR)/resources/role-to-scope-mapping.yaml
else
	@cp ../../platform-api/internal/database/schema.*.sql $(DIST_DIR)/resources/platform-api/db-scripts/
	@cp ../../platform-api/config/config.toml $(DIST_DIR)/configs/.pa-config.toml
	@cp ../../platform-api/config/config-template.toml $(DIST_DIR)/configs/.pa-config-template.toml
	@cp ../../platform-api/resources/role-to-scope-mapping.yaml $(DIST_DIR)/resources/role-to-scope-mapping.yaml
endif
# Require a [platform_api] root table — pre-unified configs would merge into a broken file.
	@if ! grep -q '^\[platform_api' $(DIST_DIR)/configs/.pa-config.toml; then \
		echo "Error: the platform-api config for $(PLATFORM_API_VERSION) has no [platform_api] root table." >&2; \
		echo "That version predates the unified multi-component config and cannot be bundled — pick a newer PLATFORM_API_VERSION." >&2; \
		exit 1; \
	fi
# Merge api-control-plane + platform-api into one config.toml — each service reads only its own root table.
	$(call merge_config,configs/config.toml,$(DIST_DIR)/configs/.pa-config.toml,$(DIST_DIR)/configs/config.toml)
	$(call merge_config,configs/config-template.toml,$(DIST_DIR)/configs/.pa-config-template.toml,$(DIST_DIR)/configs/config-template.toml)
	@rm -f $(DIST_DIR)/configs/.pa-config.toml $(DIST_DIR)/configs/.pa-config-template.toml
	@printf '%s\n' \
		'# Generated secrets — never commit these.' \
		'*.env' \
		'resources/certificates/*' \
		> $(DIST_DIR)/.gitignore
	@cp ../scripts/setup.sh $(DIST_DIR)/scripts/setup.sh
	@chmod +x $(DIST_DIR)/scripts/setup.sh
# Bake this pack's default COMPOSE_PROFILES into setup.sh so `docker compose
# up -d` (no --profile flag) starts API Control Plane + Platform API out of
# the box once setup.sh has run. setup.sh writes it to .env at setup time —
# .env is not shipped in the zip itself, only this pack's default value for it.
	@sed -i.bak \
	    -e 's|^DEFAULT_COMPOSE_PROFILES=.*|DEFAULT_COMPOSE_PROFILES="api-control-plane,platform-api"|' \
	    -e 's|^DEFAULT_PACK_NAME=.*|DEFAULT_PACK_NAME="api-control-plane"|' \
	    -e 's|^DEFAULT_DIST_VERSION=.*|DEFAULT_DIST_VERSION="$(DIST_VERSION)"|' \
	    $(DIST_DIR)/scripts/setup.sh
	@rm -f $(DIST_DIR)/scripts/setup.sh.bak
# Windows counterpart of setup.sh — same flags, same generated files. The same
# three values are baked in the same way (the PowerShell assignment spells them
# `$VAR = '...'`).
	@cp ../scripts/setup.ps1 $(DIST_DIR)/scripts/setup.ps1
	@sed -i.bak \
	    -e "s|^\$$DEFAULT_COMPOSE_PROFILES = .*|\$$DEFAULT_COMPOSE_PROFILES = 'api-control-plane,platform-api'|" \
	    -e "s|^\$$DEFAULT_PACK_NAME = .*|\$$DEFAULT_PACK_NAME = 'api-control-plane'|" \
	    -e "s|^\$$DEFAULT_DIST_VERSION = .*|\$$DEFAULT_DIST_VERSION = '$(DIST_VERSION)'|" \
	    $(DIST_DIR)/scripts/setup.ps1
	@rm -f $(DIST_DIR)/scripts/setup.ps1.bak
# Point the platform-api mount at the merged config so both containers share one file.
	@sed -e 's#\.\./\.\./platform-api/config/config\.toml:#./configs/config.toml:#' \
	     -e 's#\.\./\.\./platform-api/resources/role-to-scope-mapping\.yaml:#./resources/role-to-scope-mapping.yaml:#' \
		docker-compose.yaml > $(DIST_DIR)/docker-compose.yaml
	@sed -i.bak -E \
	    -e 's|^([[:space:]]*image:[[:space:]]*.*/api-control-plane):[^[:space:]]*|\1:$(DIST_VERSION)|' \
	    -e 's|^([[:space:]]*image:[[:space:]]*.*/platform-api):[^[:space:]]*|\1:$(PLATFORM_API_VERSION)|' \
	    $(DIST_DIR)/docker-compose.yaml
	@rm -f $(DIST_DIR)/docker-compose.yaml.bak
	@cp distribution/README.md $(DIST_DIR)/README.md
	@cd target && zip -rq $(DIST_NAME).zip $(DIST_NAME)
	@rm -rf $(DIST_DIR)
	@echo "✓ Built $(DIST_ZIP)"

clean-dist: ## Remove distribution staging dir and zip
	@rm -rf target/wso2apip-api-control-plane-*

clean: clean-dist ## Clean all build artifacts
	@echo "Cleaned api-control-plane build artifacts"
