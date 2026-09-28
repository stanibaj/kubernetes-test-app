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

# Kubernetes (Stages 3-4): the Helm release, its namespace, and the values files.
# Later -f files override earlier ones. Extra flags: make deploy HELM_ARGS="--set config.failRate=0.3"
NS         ?= kubernetes-test-app
RELEASE    ?= kubernetes-test-app
CHART      := deploy/helm/kubernetes-test-app
VALUES     := deploy/helm/values
K3S_VALUES := -f $(VALUES)/k3s.yaml
GKE_VALUES := -f $(VALUES)/gke.yaml
HELM_ARGS  ?=
# Every target names its cluster (kubeconfig context) explicitly, because
# `gcloud container clusters get-credentials` switches the CURRENT context to
# GKE: without this, `make deploy` would then send k3s values to GKE.
K3S_CONTEXT ?= default
GKE_CONTEXT ?= gke_dns-chatbot-sb_us-central1-a_kta-gke
HELM_DEPLOY = helm upgrade --install $(RELEASE) $(CHART) -n $(NS) --create-namespace

.PHONY: help test build push up down \
        install-keda deploy deploy-pending-demo deploy-scaledobject undeploy watch logs-worker \
        install-keda-gke install-tailscale-operator deploy-gke deploy-gke-pending-demo \
        deploy-gke-scaledobject undeploy-gke watch-gke watch-nodes-gke logs-worker-gke \
        tf-bootstrap tf-plan tf-apply gke-plan gke-up gke-down

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
	@echo "  (k3s targets use context $(K3S_CONTEXT); the -gke ones use $(GKE_CONTEXT))"
	@echo "make install-keda-gke           - install KEDA into the GKE cluster"
	@echo "make install-tailscale-operator - install the Tailscale operator into GKE (OAuth client needed)"
	@echo "make deploy-gke                 - helm upgrade --install with gke.yaml (tailnet-only Ingress)"
	@echo "make deploy-gke-pending-demo    - same + pending-demo.yaml (triggers the cluster autoscaler)"
	@echo "make deploy-gke-scaledobject    - same + scaledobject.yaml"
	@echo "make undeploy-gke / watch-gke / watch-nodes-gke / logs-worker-gke"
	@echo "Terraform (GCP resources; every apply shows the plan and asks first):"
	@echo "make tf-bootstrap   - create the state bucket (once)"
	@echo "make tf-plan / tf-apply - APIs, registry, SAs, firewall, k3s VMs, nightly GKE delete"
	@echo "make gke-plan / gke-up  - create (or re-create) the GKE cluster + get-credentials"
	@echo "make gke-down           - destroy the GKE cluster"

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

# --- Kubernetes + KEDA on k3s (Stage 3b) ------------------------------------

install-keda:
	KUBE_CONTEXT=$(K3S_CONTEXT) deploy/scripts/install-keda.sh

deploy:
	$(HELM_DEPLOY) --kube-context $(K3S_CONTEXT) $(K3S_VALUES) $(HELM_ARGS)

deploy-pending-demo:
	$(HELM_DEPLOY) --kube-context $(K3S_CONTEXT) $(K3S_VALUES) -f $(VALUES)/pending-demo.yaml $(HELM_ARGS)

deploy-scaledobject:
	$(HELM_DEPLOY) --kube-context $(K3S_CONTEXT) $(K3S_VALUES) -f $(VALUES)/scaledobject.yaml $(HELM_ARGS)

undeploy:
	helm uninstall $(RELEASE) -n $(NS) --kube-context $(K3S_CONTEXT)

# "No resources found" for kinds of the other mode is normal.
watch:
	watch -n1 kubectl --context $(K3S_CONTEXT) -n $(NS) get scaledjob,scaledobject,hpa,jobs,pods -o wide

logs-worker:
	KUBE_CONTEXT=$(K3S_CONTEXT) deploy/scripts/logs-worker.sh $(NS)

# --- GCP resources with Terraform (Stage 4) ---------------------------------
# Three stacks under deploy/terraform/ (docs/stage-4.md "Provisioning with
# Terraform"). No -auto-approve anywhere: apply prints the plan and waits
# for "yes".
TF := terraform -chdir=deploy/terraform

tf-bootstrap:
	$(TF)/bootstrap init -input=false
	$(TF)/bootstrap apply

tf-plan:
	$(TF)/project init -input=false
	$(TF)/project plan

tf-apply:
	$(TF)/project init -input=false
	$(TF)/project apply

gke-plan:
	$(TF)/gke init -input=false
	$(TF)/gke plan

# Creates the cluster (or re-creates it after the nightly delete), then adds
# it to ~/.kube/config. get-credentials makes GKE the CURRENT context, so
# switch back to k3s (all targets pass --kube-context anyway).
gke-up:
	$(TF)/gke init -input=false
	$(TF)/gke apply
	gcloud container clusters get-credentials kta-gke --zone us-central1-a --project dns-chatbot-sb
	kubectl config set-context $(GKE_CONTEXT) --namespace $(NS)
	kubectl config use-context $(K3S_CONTEXT)

gke-down:
	$(TF)/gke init -input=false
	$(TF)/gke destroy
	-kubectl config delete-context $(GKE_CONTEXT)

# --- GKE (Stage 4): same chart, gke.yaml instead of k3s.yaml ----------------
# The cluster itself comes from Terraform (make gke-up).

install-keda-gke:
	KUBE_CONTEXT=$(GKE_CONTEXT) deploy/scripts/install-keda.sh

install-tailscale-operator:
	KUBE_CONTEXT=$(GKE_CONTEXT) deploy/scripts/install-tailscale-operator.sh

deploy-gke:
	$(HELM_DEPLOY) --kube-context $(GKE_CONTEXT) $(GKE_VALUES) $(HELM_ARGS)

deploy-gke-pending-demo:
	$(HELM_DEPLOY) --kube-context $(GKE_CONTEXT) $(GKE_VALUES) -f $(VALUES)/pending-demo.yaml $(HELM_ARGS)

deploy-gke-scaledobject:
	$(HELM_DEPLOY) --kube-context $(GKE_CONTEXT) $(GKE_VALUES) -f $(VALUES)/scaledobject.yaml $(HELM_ARGS)

undeploy-gke:
	helm uninstall $(RELEASE) -n $(NS) --kube-context $(GKE_CONTEXT)

watch-gke:
	watch -n1 kubectl --context $(GKE_CONTEXT) -n $(NS) get scaledjob,scaledobject,hpa,jobs,pods -o wide

# Nodes appearing and disappearing (cluster autoscaler), with pod counts.
watch-nodes-gke:
	watch -n5 'kubectl --context $(GKE_CONTEXT) get nodes; echo; kubectl --context $(GKE_CONTEXT) -n $(NS) get pods -o wide'

logs-worker-gke:
	KUBE_CONTEXT=$(GKE_CONTEXT) deploy/scripts/logs-worker.sh $(NS)
