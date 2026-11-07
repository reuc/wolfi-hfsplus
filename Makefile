# Wolfi toolchain image (Python 3.14.x, Go, Rust, C) with HFS/HFS+ utilities
# (hfsprogs). Runs as root with a busybox shell; meant for `docker run --privileged`.
#
#   make            build + smoke-test + CVE-gate the image
#   make help       list targets
#
# Requires: docker (BuildKit), grype, jq. Optional: syft (for `make sbom`).

SHELL       := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c
.DEFAULT_GOAL := all

# ---- Image settings -------------------------------------------------------
IMAGE          ?= wolfi-hfsplus
TAG            ?= $(shell date -u +%Y%m%d)
PLATFORM       ?= linux/amd64
# Pin by digest for reproducible builds, e.g.
#   make BASE_IMAGE=cgr.dev/chainguard/wolfi-base@sha256:...
BASE_IMAGE     ?= cgr.dev/chainguard/wolfi-base:latest
PYTHON_VERSION ?= 3.14
GO_PACKAGE     ?= go
RUST_PACKAGE   ?= rust
EXTRA_PACKAGES ?=
# Defaults to today so packages are re-resolved at least once a day.
APK_CACHE_BUST ?= $(shell date -u +%Y%m%d)
NO_CACHE       ?=

IMAGE_REF := $(IMAGE):$(TAG)

# ---- CVE limits (the gate fails when a count is ABOVE the max) -------------
# Policy: 0 Critical, <3 High, <5 Medium, <10 Low
MAX_CRITICAL ?= 0
MAX_HIGH     ?= 2
MAX_MEDIUM   ?= 4
MAX_LOW      ?= 9

GRYPE      ?= grype
SYFT       ?= syft
JQ         ?= jq
REPORT_DIR ?= reports

BUILD_ARGS = \
	--build-arg BASE_IMAGE=$(BASE_IMAGE) \
	--build-arg PYTHON_VERSION=$(PYTHON_VERSION) \
	--build-arg GO_PACKAGE=$(GO_PACKAGE) \
	--build-arg RUST_PACKAGE=$(RUST_PACKAGE) \
	--build-arg "EXTRA_PACKAGES=$(EXTRA_PACKAGES)" \
	--build-arg APK_CACHE_BUST=$(APK_CACHE_BUST) \
	--label org.opencontainers.image.created=$(shell date -u +%Y-%m-%dT%H:%M:%SZ) \
	--label org.opencontainers.image.base.name=$(BASE_IMAGE) \
	--label org.opencontainers.image.title=$(IMAGE)

# Shared by both smoke tests: read-only rootfs, writable tmpfs for /tmp and
# root's home, no network.
RUN_TEST = docker run --rm -i \
	--platform $(PLATFORM) \
	--read-only \
	--tmpfs /tmp:rw,exec,nosuid,size=2g \
	--tmpfs /root:rw,exec,nosuid,size=2g,mode=0700 \
	--network=none

# Everything that doesn't need a device, run with every capability dropped.
RUN_LOCKED = $(RUN_TEST) \
	--cap-drop=ALL \
	--security-opt=no-new-privileges

# The way the image is meant to be used: root with full device access.
RUN_PRIVILEGED = $(RUN_TEST) --privileged

.PHONY: all help build test test-locked test-privileged scan sbom run \
        check-tools clean image-ref

all: build test scan ## Build, smoke-test and CVE-gate the image

help: ## Show this help
	@grep -E '^[a-zA-Z_%-]+:.*?## ' $(MAKEFILE_LIST) | \
		awk 'BEGIN{FS=":.*?## "}{printf "  \033[36m%-18s\033[0m %s\n", $$1, $$2}'

# Print the image reference, e.g. `make -s image-ref` (used by CI).
image-ref: ; @echo $(IMAGE_REF)

# ---- Build ----------------------------------------------------------------
build: ## Build the image (root, busybox shell, hfsprogs, no apk)
	DOCKER_BUILDKIT=1 docker build --pull $(if $(NO_CACHE),--no-cache) \
		--platform $(PLATFORM) $(BUILD_ARGS) \
		-f Dockerfile -t $(IMAGE_REF) .

# ---- Smoke tests ----------------------------------------------------------
test: test-locked test-privileged ## Run both smoke tests

test-locked: ## Smoke-test with all capabilities dropped (toolchains + HFS on image files)
	$(RUN_LOCKED) -e EXPECT_PRIVILEGED=0 $(IMAGE_REF) python3 - < tests/smoke.py

test-privileged: ## Smoke-test with --privileged (adds loop-device mount of HFS+)
	$(RUN_PRIVILEGED) -e EXPECT_PRIVILEGED=1 $(IMAGE_REF) python3 - < tests/smoke.py

# ---- Run ------------------------------------------------------------------
run: ## Interactive privileged root shell, current directory at /work
	docker run --rm -it --platform $(PLATFORM) --privileged \
		-v "$(CURDIR)":/work -w /work $(IMAGE_REF)

# ---- CVE gate -------------------------------------------------------------
# $(1) = image ref, $(2) = report name
# Counts unique vulnerability IDs per severity (--by-cve folds GHSA ids into CVE ids).
define cve_gate
	@mkdir -p $(REPORT_DIR)
	$(GRYPE) docker:$(1) --by-cve -o table -o json=$(REPORT_DIR)/$(2)-grype.json
	@f=$(REPORT_DIR)/$(2)-grype.json; \
	count() { $(JQ) --arg s "$$1" '[.matches[] | select(.vulnerability.severity == $$s) | .vulnerability.id] | unique | length' "$$f"; }; \
	c=$$(count Critical); h=$$(count High); m=$$(count Medium); l=$$(count Low); \
	echo ""; \
	echo "CVE gate for $(1):"; \
	printf '  %-9s %3s (max %s)\n' Critical "$$c" $(MAX_CRITICAL) High "$$h" $(MAX_HIGH) Medium "$$m" $(MAX_MEDIUM) Low "$$l" $(MAX_LOW); \
	fail=0; \
	[ "$$c" -le $(MAX_CRITICAL) ] || { echo "  FAIL: Critical $$c > $(MAX_CRITICAL)"; fail=1; }; \
	[ "$$h" -le $(MAX_HIGH) ]     || { echo "  FAIL: High $$h > $(MAX_HIGH)"; fail=1; }; \
	[ "$$m" -le $(MAX_MEDIUM) ]   || { echo "  FAIL: Medium $$m > $(MAX_MEDIUM)"; fail=1; }; \
	[ "$$l" -le $(MAX_LOW) ]      || { echo "  FAIL: Low $$l > $(MAX_LOW)"; fail=1; }; \
	if [ $$fail -eq 0 ]; then echo "  PASS"; fi; \
	exit $$fail
endef

scan: check-tools ## CVE-gate the image with grype
	@$(GRYPE) db update >/dev/null
	$(call cve_gate,$(IMAGE_REF),image)

sbom: ## Write an SPDX SBOM (needs syft)
	@mkdir -p $(REPORT_DIR)
	$(SYFT) docker:$(IMAGE_REF) -o spdx-json=$(REPORT_DIR)/image-sbom.spdx.json

check-tools:
	@for t in docker $(GRYPE) $(JQ); do \
		command -v $$t >/dev/null || { echo "missing required tool: $$t"; exit 1; }; \
	done

clean: ## Remove the built image and reports
	-docker rmi $(IMAGE_REF) 2>/dev/null
	rm -rf $(REPORT_DIR)
