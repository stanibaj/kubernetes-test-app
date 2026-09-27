# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A learning project: a trivial Redis-backed job queue (producer + workers) used to watch Kubernetes scale workers based on queue length. **`spec.md` is the source of truth** for requirements, Redis data model, env vars, API, experiments, and the final repo layout. Read the relevant section before implementing anything.

The project is built in stages (1: local Python, 2: Docker Compose, 3a: k3s manual scaling, 3b: KEDA autoscaling, 4: GKE). **Stage 1 is implemented** (see `docs/stage-1.md`); nothing from later stages exists yet.

## Working agreement (from spec.md §1 — follow strictly)

- **One stage at a time.** Implement only the stage the user asks for, and never create files that belong to later stages (no Dockerfiles in Stage 1, no k8s manifests in Stage 2, etc.). Stage 3 is split: do 3a, stop, then 3b only when asked.
- **Stop at the end of each stage** so the user can run and verify it.
- **Write `docs/stage-N.md`** (`stage-3a.md` / `stage-3b.md` for Stage 3) at the end of each stage: what was built, concepts, why each change was needed, and how to run the experiments. The user is learning, so explain as you go. When a later stage changes earlier code, explain why.
- **Inspect before creating.** Don't overwrite or delete existing files without asking; mention conflicts.
- **Never create cloud resources or run commands that cost money.** For GKE, write the `gcloud` commands in the docs for the user to run.
- Keep code simple, readable, and commented.

## Architecture boundaries

- `app/` = plain application code (producer, worker, `tools/local_scaler.py`, tests). It must know nothing about Docker or Kubernetes. All config comes from environment variables with local defaults.
- `deploy/` = everything for packaging/running: `docker/` (Dockerfiles, built with the **repo root** as context), `compose/`, `helm/` (the `kubernetes-test-app/` chart + `values/` files for `k3s`, `pending-demo`, `scaledobject`, `gke`, layered with multiple `-f`), `scripts/`.
- Rule of thumb: if a file still makes sense with no containers or Kubernetes, it belongs in `app/`.
- The chart templates must stay platform-neutral. Use the standard `Ingress` with a configurable `ingressClassName` and no Traefik CRDs. Anything k3s- or GKE-specific is a value set in that environment's values file. The chart never installs KEDA CRDs and renders KEDA resources only when `worker.mode` selects them. The namespace comes from `--create-namespace`, not a template.

## Key design invariants (easy to break)

- **One worker processes exactly one job at a time.** The worker pops the job from `jobs:queue` when it starts, so the list length excludes in-progress jobs. This matters for the KEDA `scalingStrategy` choice in 3b (check the KEDA docs for the pinned version).
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

Planned Makefile targets (Stage 2+): `build`, `push`, `up`, `down`, `test`, with images parameterized by `REGISTRY` and `TAG`. Stage 3b adds `install-keda`, `deploy`, `deploy-pending-demo`, `undeploy`, `watch`, `logs-worker` (deploy = `helm upgrade --install`, undeploy = `helm uninstall`). Neither `helm` nor `kubectl` is installed on this host, so the user runs them against the cluster.

## Target environments

- k3s: self-managed on 3 GCE VMs (1 server, 2 agents), linux/amd64, with Traefik available. Artifact Registry pulls need an `imagePullSecret` or k3s `registries.yaml`.
- GKE Standard with node-pool autoscaling (Stage 4).

## Non-goals

No auth, persistent Redis, HA, Prometheus/Grafana, or automated cloud provisioning.
