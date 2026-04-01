IMAGE_REPOSITORY ?= terraform-kubernetes-flux-operator-bootstrap
IMAGE_TAG ?= dev
IMAGE ?= $(IMAGE_REPOSITORY):$(IMAGE_TAG)

.PHONY: docker-build
docker-build:
	docker build -t $(IMAGE) .

E2E_LOG ?= e2e.log

.PHONY: e2e
e2e:
	stdbuf -oL -eL bash ./scripts/e2e.sh 2>&1 | tee $(E2E_LOG)
