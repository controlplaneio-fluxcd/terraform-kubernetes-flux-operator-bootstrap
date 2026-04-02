IMAGE_REPOSITORY ?= terraform-kubernetes-flux-operator-bootstrap-test
IMAGE_TAG ?= dev
IMAGE ?= $(IMAGE_REPOSITORY):$(IMAGE_TAG)

SHELL := /bin/bash -o pipefail

.PHONY: docker-build
docker-build:
	docker build -t $(IMAGE) .

E2E_LOG ?= e2e.log

.PHONY: e2e
e2e:
	stdbuf -oL -eL bash ./scripts/e2e.sh 2>&1 | tee $(E2E_LOG)

.PHONY: e2e-batch-1
e2e-batch-1:
	stdbuf -oL -eL bash ./scripts/e2e-batch-1.sh 2>&1 | tee $(E2E_LOG)

.PHONY: e2e-batch-2
e2e-batch-2:
	stdbuf -oL -eL bash ./scripts/e2e-batch-2.sh 2>&1 | tee $(E2E_LOG)
