IMAGE_REPOSITORY ?= terraform-kubernetes-flux-operator-bootstrap-test
IMAGE_TAG ?= dev
IMAGE ?= $(IMAGE_REPOSITORY):$(IMAGE_TAG)

SHELL := /bin/bash -o pipefail

.PHONY: docker-build
docker-build:
	docker build -t $(IMAGE) .

.PHONY: e2e
e2e:
	stdbuf -oL -eL bash ./scripts/e2e.sh 2>&1 | tee e2e.log

.PHONY: e2e-batch-1
e2e-batch-1:
	stdbuf -oL -eL bash ./scripts/e2e-batch-1.sh 2>&1 | tee e2e-batch-1.log

.PHONY: e2e-batch-2
e2e-batch-2:
	stdbuf -oL -eL bash ./scripts/e2e-batch-2.sh 2>&1 | tee e2e-batch-2.log

.PHONY: e2e-batch-3
e2e-batch-3:
	stdbuf -oL -eL bash ./scripts/e2e-batch-3.sh 2>&1 | tee e2e-batch-3.log

.PHONY: e2e-batch-4
e2e-batch-4:
	stdbuf -oL -eL bash ./scripts/e2e-batch-4.sh 2>&1 | tee e2e-batch-4.log

.PHONY: e2e-migration
e2e-migration:
	stdbuf -oL -eL bash ./scripts/e2e-migration.sh 2>&1 | tee e2e-migration.log

.PHONY: e2e-critical-components
e2e-critical-components:
	stdbuf -oL -eL bash ./scripts/e2e-critical-components.sh 2>&1 | tee e2e-critical-components.log

# e2e-debug-shell is a Windows-focused smoke test that exercises the
# debug_on_failure local-exec template against a fake kubectl. It does not
# need Docker or kind and is intentionally invoked without stdbuf so it stays
# portable to Git Bash on Windows (no GNU coreutils stdbuf binary). The full
# Linux end-to-end is covered by e2e-batch-2.
.PHONY: e2e-debug-shell
e2e-debug-shell:
	bash ./scripts/e2e-debug-shell.sh 2>&1 | tee e2e-debug-shell.log
