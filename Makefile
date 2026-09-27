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

.PHONY: help test build push up down

help:
	@echo "make test   - run pytest in .venv"
	@echo "make build  - build $(PRODUCER_IMAGE) and $(WORKER_IMAGE)"
	@echo "make push   - push both images to REGISTRY (log in first, see docs/stage-2.md)"
	@echo "make up     - start redis + producer + worker (WORKERS=n to scale)"
	@echo "make down   - stop and remove the compose stack"

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
