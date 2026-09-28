# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A learning project: a trivial Redis-backed job queue (producer + workers) used to watch Kubernetes scale workers based on queue length. **`spec.md` is the source of truth** for requirements, Redis data model, env vars, API, experiments, and the final repo layout. Read the relevant section before implementing anything.

The project is built in stages (1: local Python, 2: Docker Compose, 3a: k3s manual scaling, 3b: KEDA autoscaling, 4: GKE). **All stages (1, 2, 3a, 3b, 4) are implemented** (see `docs/stage-*.md`). KEDA 2.21.0 is installed on k3s (namespace `keda`), and `k3s.yaml` sets `worker.mode: scaledjob`. Stage 4 targets GKE cluster `kta-gke` (zonal `us-central1-a`, e2-standard-2 Spot, autoscaling 1–4). It comes from Terraform (`make gke-up`), and a Cloud Scheduler job (`kta-gke-nightly-delete`) deletes it nightly at 01:00 Europe/Berlin, so it often doesn't exist.

## Working agreement (from spec.md §1 — follow strictly)

- **One stage at a time.** Implement only the stage the user asks for, and never create files that belong to later stages (no Dockerfiles in Stage 1, no k8s manifests in Stage 2, etc.). Stage 3 is split: do 3a, stop, then 3b only when asked.
- **Stop at the end of each stage** so the user can run and verify it.
- **Write `docs/stage-N.md`** (`stage-3a.md` / `stage-3b.md` for Stage 3) at the end of each stage: what was built, concepts, why each change was needed, and how to run the experiments. The user is learning, so explain as you go. When a later stage changes earlier code, explain why.
- **Inspect before creating.** Don't overwrite or delete existing files without asking; mention conflicts.
- **Never create cloud resources or run commands that cost money.** GCP resources are Terraform code under `deploy/terraform/`. Claude writes it and runs only `terraform fmt`/`validate`/`plan` (read-only); **the user runs every `apply`** (Makefile targets never pass `-auto-approve`). Don't create GCP resources with gcloud either; gcloud is only for read-only checks and `get-credentials`.
- Keep code simple, readable, and commented.

## Architecture boundaries

- `app/` = plain application code (producer, worker, `tools/local_scaler.py`, tests). It must know nothing about Docker or Kubernetes. All config comes from environment variables with local defaults.
- `deploy/` = everything for packaging/running: `docker/` (Dockerfiles, built with the **repo root** as context), `compose/`, `helm/` (the `kubernetes-test-app/` chart + `values/` files for `k3s`, `pending-demo`, `scaledobject`, `gke`, layered with multiple `-f`), `scripts/`, `terraform/` (GCP infrastructure, see below).
- Rule of thumb: if a file still makes sense with no containers or Kubernetes, it belongs in `app/`.
- The chart templates must stay platform-neutral. Use the standard `Ingress` with a configurable `ingressClassName` and no Traefik CRDs. Anything k3s- or GKE-specific is a value set in that environment's values file. The chart never installs KEDA CRDs and renders KEDA resources only when `worker.mode` selects them. The namespace comes from `--create-namespace`, not a template.

## Key design invariants (easy to break)

- **One worker processes exactly one job at a time.** The worker pops the job from `jobs:queue` when it starts, so the list length excludes in-progress jobs. That's why the ScaledJob uses `scalingStrategy: accurate`, and why the ScaledObject's `cooldownPeriod` must exceed the longest job.
- The worker's Redis `socket_timeout` (`SOCKET_TIMEOUT`) must stay longer than `BLPOP_TIMEOUT`. redis-py 8 defaults to 5 s, the same as the BLPOP wait, so across k3s nodes the empty-queue reply arrived late and the worker crash-looped (Stage 3a). `redis.TimeoutError` counts as a real error, like `ConnectionError` (exit 1).
- Worker modes: `WORKER_MODE=once` (one job then exit; an empty queue exits 0) is used by the local scaler and KEDA ScaledJob. `loop` (BLPOP with timeout) is used by Compose, the k8s Deployment, and ScaledObject.
- On SIGTERM/SIGINT mid-job, the worker requeues the job, cleans up `jobs:processing`, and exits. It must work as PID 1 in a container. The k8s `terminationGracePeriodSeconds` must exceed the longest job.
- Exit code is 0 for all expected outcomes, including simulated failures. Non-zero is only for real errors such as Redis being unreachable.
- Logs are single lines on stdout that include the worker ID and job ID.
- The producer web page is a single HTML file with inline CSS/JS, no build step, and no external assets.

## Host network rule

On this host **nothing may bind to `0.0.0.0`**, only to the Tailscale IP (`tailscale ip -4`). That means `HOST=$TS_IP` for the producer, `REDIS_HOST=$TS_IP`, and `podman run -p $TS_IP:6379:6379 …`, never a bare `-p 6379:6379`. Code defaults must never be `0.0.0.0`; the producer's `HOST` defaults to `127.0.0.1`. Apply the same rule to Compose `ports:`, published container ports, and any port-forward (`kubectl port-forward --address $TS_IP`) in later stages. Check with `ss -ltn`.

## Stack and commands

Python 3.12, redis-py, FastAPI + uvicorn (producer only; no other frameworks), Redis 7, pytest + fakeredis. Pinned versions are in each component's `requirements.txt`. For local development, one root `.venv` is built from `requirements-dev.txt`, which includes both components plus the test tools. Docker is not installed here, and Podman needs fully qualified image names.

```bash
python3 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt
.venv/bin/pytest                                          # all tests (pytest.ini sets pythonpath)
.venv/bin/pytest app/worker/tests/test_worker.py::test_history_is_capped
export TS_IP=$(tailscale ip -4) REDIS_HOST=$(tailscale ip -4) HOST=$(tailscale ip -4)
podman run --rm --name redis -p $TS_IP:6379:6379 docker.io/library/redis:7
python app/producer/app.py                                # http://$HOST:8000
python app/worker/worker.py                               # WORKER_MODE=loop by default
python app/tools/local_scaler.py --max 5                  # starts once-workers from LLEN
```

Components are script directories, not packages. Tests import `app`, `worker` and `local_scaler` directly via `pytest.ini`'s `pythonpath`. The producer's Redis client is injected through the `get_redis` dependency, and tests override it with fakeredis. `process_job` takes injectable `sleep`/`rand`. `fakeredis.TcpFakeServer` can stand in for a real Redis in end-to-end smoke tests.

Makefile targets: `build`, `push`, `up`, `down`, `test` (images parameterized by `REGISTRY` and `TAG`), and for k3s `install-keda`, `deploy`, `deploy-pending-demo`, `deploy-scaledobject`, `undeploy`, `watch`, `logs-worker` (deploy = `helm upgrade --install` with the `-f` files; extra flags via `HELM_ARGS`). The GKE equivalents have a `-gke` suffix, plus `install-tailscale-operator` and `watch-nodes-gke`. Every k8s target passes an explicit context (`K3S_CONTEXT=default`, `GKE_CONTEXT=gke_dns-chatbot-sb_us-central1-a_kta-gke`), because `get-credentials` switches the current context. The scripts honor `KUBE_CONTEXT`. Helm v4.3.0 and kubectl v1.36 are in `~/.local/bin`. `~/.kube/config` points at the k3s API over the tailnet (`https://100.112.126.75:6443`). Helm 4 uses server-side apply, so drift from `kubectl scale` makes `helm upgrade` fail with a conflict unless `--force-conflicts` is passed.

## Target environments

- k3s v1.36: self-managed on 3 GCE VMs in project `dns-chatbot-sb`, `us-central1-a` (server `gcp-srv-02`, agents `gcp-srv-03`/`04`), linux/amd64, with Traefik available. Images live in `us-central1-docker.pkg.dev/dns-chatbot-sb/kubernetes-test-app`. Pulls use the `artifact-registry` imagePullSecret, made from the `k3s-puller` SA key at `~/.config/kubernetes-test-app/` (never commit it).
- The app must be reachable **only over Tailscale**. The GCP firewall rule `deny-ingress-tailscale-only` blocks the nodes' public IPs. Chart Services stay ClusterIP, and the Ingress host is the tailnet MagicDNS name.
- GKE Standard with node-pool autoscaling (Stage 4, `gke.yaml`), also **tailnet-only**. The Ingress uses `ingressClassName: tailscale` (Tailscale operator 1.102.4, `deploy/scripts/install-tailscale-operator.sh`, OAuth creds in `~/.config/kubernetes-test-app/tailscale-oauth.env`), never `gce`/Gateway, because those create public LBs. The operator names the device from `producer.ingress.tls[0].hosts[0]` and ignores rules whose `host` differs, so `host` stays empty there. Never add the `tailscale.com/funnel` annotation. There are no LoadBalancer/NodePort Services. Nodes pull as SA `gke-nodes` (no pull secret). Don't put the `tailscale-only` tag on GKE nodes: that rule denies all traffic, internal traffic included.

## Non-goals

No auth, persistent Redis, HA, Prometheus/Grafana, or CI/CD for infrastructure (Terraform is applied by hand).

## Terraform (`deploy/terraform/`, Terraform 1.16.4 in `~/.local/bin`, google provider `~> 8.4`)

- Three stacks, split by lifetime: `bootstrap/` (state bucket `dns-chatbot-sb-tfstate`, local state), `project/` (long-lived: APIs, AR repo + IAM, SAs `k3s-puller`/`gke-nodes`/`gke-reaper`, firewall rules, k3s VMs + `k3s-lab-schedule`, the nightly delete job), `gke/` (only the cluster + node pool; recreated after each nightly delete). State in GCS, prefix `kubernetes-test-app/<stack>`. Targets: `tf-bootstrap`, `tf-plan`, `tf-apply`, `gke-plan`, `gke-up`, `gke-down`.
- Pre-existing resources are adopted with `import` blocks (`project/imports.tf`). An imported resource must plan with **0 changes**; if not, fix the code to match reality, never the other way round. The one known exception: on import the VMs show `+` for `labels`/`terraform_labels` (provider v5+ leaves `labels` empty on import; `effective_labels` is unchanged, so the apply is a no-op). The first plan also prints the VMs' startup script, so never save or paste that plan output.
- The k3s VMs (`gcp-srv-02..04`) have `prevent_destroy` and `ignore_changes` on `metadata` (the startup script holds a secret: never read it or put it in code) and on `boot_disk[0].initialize_params`. They are stopped nightly at 23:00 Europe/Prague by `k3s-lab-schedule`, so the k3s API is often unreachable. Start them with `gcloud compute instances start gcp-srv-02 gcp-srv-03 gcp-srv-04 --zone us-central1-a`.
- `dns-chatbot-sb` is a shared project: only non-authoritative IAM (`*_iam_member`), never `*_iam_binding`/`*_iam_policy`; `google_project_service` always has `disable_on_destroy = false`. Never `terraform destroy` the `project/` stack.
- Secrets (SA keys, the Tailscale OAuth client) are never created by Terraform, because they would land in the state.
- The Tailscale policy lives in `~/homelab-iac/tailscale/policy.hujson` (applied by that repo's CI), not here.
