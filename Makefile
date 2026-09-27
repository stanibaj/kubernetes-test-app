# Convenience targets so you don't have to remember the longer commands.
# Everything is overridable, e.g.:
#   make build REGISTRY=europe-docker.pkg.dev/my-project/my-repo TAG=v1
#   make up WORKERS=4
#   make up CONTAINER_TOOL=docker       (on a machine with Docker instead of Podman)

CONTAINER_TOOL ?= podman
PROJECT        ?= kubernetes-test-app
COMPOSE        ?= $(CONTAINER_TOOL) compose -p $(PROJECT) -f deploy/compose/docker-compose.yaml
REGISTRY       ?= localhost
TAG            ?= dev
# Host rule: published ports bind only to the Tailscale IP.
TS_IP          ?= $(shell tailscale ip -4)
WORKERS        ?= 1
PRODUCER_PORT  ?= 8000

PRODUCER_IMAGE := $(REGISTRY)/kubernetes-test-app-producer:$(TAG)
WORKER_IMAGE   := $(REGISTRY)/kubernetes-test-app-worker:$(TAG)

# Make these visible to the compose file's ${...} variables.
export REGISTRY TAG TS_IP WORKERS PRODUCER_PORT

# Kubernetes (Stage 3): the Helm release, its namespace, and the values files.
# Later -f files override earlier ones. Extra flags: make deploy HELM_ARGS="--set config.failRate=0.3"
NS         ?= kubernetes-test-app
RELEASE    ?= kubernetes-test-app
CHART      := deploy/helm/kubernetes-test-app
VALUES     := deploy/helm/values
K3S_VALUES := -f $(VALUES)/k3s.yaml
HELM_ARGS  ?=
HELM_DEPLOY = helm upgrade --install $(RELEASE) $(CHART) -n $(NS) --create-namespace

.PHONY: help test build push up down \
        install-keda deploy deploy-pending-demo deploy-scaledobject undeploy watch logs-worker

help:
	@echo "make test   - run pytest in .venv"
	@echo "make build  - build $(PRODUCER_IMAGE) and $(WORKER_IMAGE)"
	@echo "make push   - push both images to REGISTRY (log in first, see docs/stage-2.md)"
	@echo "make up     - start redis + producer + worker (WORKERS=n to scale)"
	@echo "make down   - stop and remove the compose stack"
	@echo "make install-keda        - install KEDA into the cluster (once per cluster)"
	@echo "make deploy              - helm upgrade --install with k3s.yaml (KEDA ScaledJob)"
	@echo "make deploy-pending-demo - same + pending-demo.yaml (1 CPU per worker, max 20)"
	@echo "make deploy-scaledobject - same + scaledobject.yaml (KEDA-scaled Deployment)"
	@echo "make undeploy            - helm uninstall (the namespace stays)"
	@echo "make watch               - live view of ScaledJob/ScaledObject/HPA/Jobs/pods"
	@echo "make logs-worker         - follow the logs of every worker pod, new ones too"

test:
	.venv/bin/pytest

# The build context is the repository root (the trailing "."); .dockerignore
# decides which files are sent.
build:
	$(CONTAINER_TOOL) build -f deploy/docker/producer.Dockerfile -t $(PRODUCER_IMAGE) .
	$(CONTAINER_TOOL) build -f deploy/docker/worker.Dockerfile -t $(WORKER_IMAGE) .

push:
	$(CONTAINER_TOOL) push $(PRODUCER_IMAGE)
	$(CONTAINER_TOOL) push $(WORKER_IMAGE)

up: build
	$(COMPOSE) up -d

# `compose down` only knows the containers of the *current* WORKERS value, so
# first stop (SIGTERM, up to 90 s grace) and remove every container of our
# project, however many workers were started. Redis goes last because the
# other containers depend on it. Finally remove the project network
# (podman-compose 1.0.6's own `down` leaves it behind).
LIST = $(CONTAINER_TOOL) ps -aq --filter label=com.docker.compose.project=$(PROJECT)
down:
	@for svc in worker producer redis; do \
	  ids="$$($(LIST) --filter label=com.docker.compose.service=$$svc)"; \
	  if [ -n "$$ids" ]; then \
	    $(CONTAINER_TOOL) stop -t 90 $$ids >/dev/null && $(CONTAINER_TOOL) rm $$ids >/dev/null; \
	  fi; \
	done
	@$(CONTAINER_TOOL) network rm $(PROJECT)_default >/dev/null 2>&1 || true

# --- Kubernetes + KEDA (Stage 3b) -------------------------------------------

install-keda:
	deploy/scripts/install-keda.sh

deploy:
	$(HELM_DEPLOY) $(K3S_VALUES) $(HELM_ARGS)

deploy-pending-demo:
	$(HELM_DEPLOY) $(K3S_VALUES) -f $(VALUES)/pending-demo.yaml $(HELM_ARGS)

deploy-scaledobject:
	$(HELM_DEPLOY) $(K3S_VALUES) -f $(VALUES)/scaledobject.yaml $(HELM_ARGS)

undeploy:
	helm uninstall $(RELEASE) -n $(NS)

# "No resources found" for kinds of the other mode is normal.
watch:
	watch -n1 kubectl -n $(NS) get scaledjob,scaledobject,hpa,jobs,pods -o wide

logs-worker:
	deploy/scripts/logs-worker.sh $(NS)
