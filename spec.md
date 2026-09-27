# Specification: Queue Worker Autoscaling Demo

## 1. Purpose and how to use this spec

This is a learning project. The end goal is to watch Kubernetes scale worker instances up and down based on demand, where demand means jobs waiting in a queue. The core rule of the app: **one worker instance processes exactly one job at a time.** When jobs are waiting and all workers are busy, more workers start. When the queue is empty, workers go away.

The project is built in **four stages**, each building on the previous one:

1. **Local app**: the plain Python app running on the developer's machine. This is the baseline.
2. **Container-ready app**: the same app packaged in containers and run with Docker Compose, prepared for Kubernetes.
3. **k3s deployment**: deployed to the user's self-managed k3s cluster, first with manual scaling, then with KEDA autoscaling.
4. **GKE deployment**: the same app on Google Kubernetes Engine, including node autoscaling.

### Working agreement for the implementer (Claude Code)

- **The repository already exists** and is named `kubernetes-test-app`. Before creating anything, inspect what is already in it. Do not overwrite or delete existing files without asking; build the structure described in section 7 around what exists, and mention any conflicts to the user.
- **Keep application code and deployment specifics separate.** Everything under `app/` is plain application source code that knows nothing about Docker or Kubernetes. Everything needed to package and run it (Dockerfiles, Compose, the Helm chart, deployment scripts) lives under `deploy/`. See section 7.
- **Implement one stage at a time.** Only implement the stage the user asks for. Do not create files that belong to later stages (no Dockerfiles in Stage 1, no Kubernetes manifests in Stage 2, and so on).
- **Stop at the end of each stage** and let the user run and verify it before continuing.
- **Explain as you go.** The user is learning. At the end of each stage, write `docs/stage-N.md` explaining what was built, the concepts involved, why each change was needed, and how to run the stage's experiments. When a later stage changes earlier code, explain why the change was necessary.
- **Keep the code simple, readable, and commented.** The app itself is intentionally trivial (workers "process" a job by sleeping); the interesting part is how it runs and scales.
- **Never create cloud resources or run commands that cost money.** For Stage 4, write the `gcloud` commands in the docs for the user to run themselves.

## 2. The application (shared by all stages)

### Components

1. **Redis**: the job queue and a small status store.
2. **Producer**: a small web app/API to submit jobs and view live status.
3. **Worker**: takes a job from the queue, processes it, records the result.

### Technology

- Python 3.12, `redis` (redis-py), `fastapi` + `uvicorn` for the producer. No other frameworks.
- Redis 7.
- Tests with `pytest` and `fakeredis`.
- All configuration via environment variables with sensible local defaults (this makes the later stages easy).

### Data model (Redis keys)

| Key | Type | Meaning |
|---|---|---|
| `jobs:queue` | List | Waiting jobs. Producer does `RPUSH`, worker pops from the left. |
| `jobs:processing` | Hash | Job ID → JSON with `worker`, `host`, `started_at`. Removed when the job finishes. |
| `jobs:completed` | Integer counter | Total completed jobs. |
| `jobs:failed` | Integer counter | Total job attempts that failed. |
| `jobs:dead` | List | Jobs that failed too many times (dead-letter list). |
| `jobs:history` | List (capped at 50) | Finished jobs as JSON: `id`, `worker`, `host`, `started_at`, `finished_at`, `result`. |

Job payload (JSON string in `jobs:queue`):

```json
{ "id": "uuid4", "created_at": "ISO-8601 UTC", "duration_seconds": 30, "attempts": 0 }
```

### Worker behavior

The worker supports two modes, selected with `WORKER_MODE`:

- **`once`**: take one job, process it, exit. If the queue is empty, log "no job available" and exit 0 (this is expected, not an error).
- **`loop`**: repeatedly wait for a job (`BLPOP` with a timeout), process it, repeat. One job at a time.

Processing a job:

1. Register the job in `jobs:processing` with the worker's identity (`WORKER_ID`) and host (`HOST_NAME`).
2. Sleep `duration_seconds`, logging progress every ~5 seconds.
3. Simulated failure: with probability `FAIL_RATE`, the job fails. Increment `attempts`; if `attempts < MAX_ATTEMPTS`, push the job back onto the queue, otherwise push it to `jobs:dead`. Increment `jobs:failed`.
4. On success, increment `jobs:completed`.
5. Remove the job from `jobs:processing`, append to `jobs:history` (trim to 50).
6. On `SIGTERM` or `SIGINT` mid-job: push the job back onto the queue, clean up `jobs:processing`, log that this happened, and exit.

Exit code is 0 in all expected cases, including simulated failures (handled by requeueing). Non-zero exits are reserved for real errors, such as Redis being unreachable.

Logs are plain single lines on stdout, each including the job ID and worker ID, e.g. `[worker-3] job 3f2a… started on host laptop (30s)`.

### Worker configuration

| Variable | Default | Meaning |
|---|---|---|
| `REDIS_HOST` | `localhost` | |
| `REDIS_PORT` | `6379` | |
| `QUEUE_NAME` | `jobs:queue` | |
| `WORKER_MODE` | `loop` | `loop` or `once` |
| `FAIL_RATE` | `0.0` | Probability 0.0–1.0 that a job fails |
| `MAX_ATTEMPTS` | `3` | Attempts before dead-lettering |
| `WORKER_ID` | generated (hostname + PID) | Shown in status and logs |
| `HOST_NAME` | machine hostname | Where the worker runs (becomes the node name in Kubernetes) |

### Producer

API:

- `POST /api/jobs` with `{ "count": 10, "duration_seconds": 30 }`. Defaults `count=1`, `duration_seconds=30`; `"duration_seconds": "random"` picks 10–60 seconds per job. Validate `count` between 1 and 200. Returns created job IDs.
- `GET /api/status`: queue length, processing jobs (with worker and host), completed, failed, dead counts, last 20 history entries.
- `POST /api/reset`: clears all `jobs:*` keys.

Web page at `GET /`: a single HTML page (inline CSS/JS, no build step, no external assets) with a form to submit N jobs (fixed or random duration), live status polled every 2 seconds (queue length, processing jobs table with running time, counters, recent history), processing jobs grouped or colored by host, and a Reset button.

Configuration: `REDIS_HOST`, `REDIS_PORT`, `QUEUE_NAME` (same defaults as the worker), `PORT` (default `8000`).

---

## 3. Stage 1: Local app (the baseline)

**Goal:** a working app on the developer's machine, and a hands-on feel for what "scaling workers" means before any containers or Kubernetes are involved.

### Scope

- Producer, worker, and tests as described in section 2.
- Redis can be run however is simplest locally (a local install, or a single `docker run redis:7` command documented in the README; Redis is the only thing that may use Docker in this stage).
- A Python virtual environment and `requirements.txt` per component.
- A **local scaler script** (`app/tools/local_scaler.py`) that imitates what KEDA will do later: every few seconds it checks the queue length, and starts `worker` processes in `once` mode (as subprocesses) so there is one worker per waiting job, up to `--max` workers at once. It prints what it decides and why (e.g., `queue=7 running=3 max=5 → starting 2`). This makes Stage 3 easier to understand, because the user will already have seen the logic.

### Experiments (document in `docs/stage-1.md`)

1. Start Redis, the producer, and one worker in `loop` mode. Submit 5 jobs; observe they run one after another.
2. Start three workers in `loop` mode in separate terminals; submit 9 jobs; observe parallel processing.
3. Stop the workers and run the local scaler with `--max 5`; submit 12 jobs; observe it scaling up to 5 and back down to 0.
4. Set `FAIL_RATE=0.3`; confirm every job ends up completed or dead-lettered.
5. Press Ctrl+C on a worker mid-job; confirm the job returns to the queue.

### Done when

All experiments behave as described and `pytest` passes.

---

## 4. Stage 2: Container-ready app

**Goal:** package the app in containers and make it follow the practices Kubernetes expects, then run everything with Docker Compose.

### Scope

- A Dockerfile for the producer and one for the worker, stored in `deploy/docker/` (`producer.Dockerfile`, `worker.Dockerfile`). Use the repository root as the build context (e.g. `docker build -f deploy/docker/worker.Dockerfile .`) and add a root `.dockerignore` so only the needed parts of `app/` are sent to Docker. Images: `python:3.12-slim` base, non-root user, small image, dependencies installed in a cached layer, no secrets baked in.
- Producer health endpoints: `GET /healthz` (process is alive) and `GET /readyz` (ready only when Redis responds to `PING`). Explain the difference between liveness and readiness in the docs.
- Verify and, if needed, adjust the app so that it: reads all configuration from environment variables, logs only to stdout/stderr, handles `SIGTERM` correctly when running as PID 1 in a container, and keeps no state on local disk.
- `deploy/compose/docker-compose.yaml` with Redis, the producer, and the worker (`loop` mode).
- Image tagging and pushing documented with a configurable registry (`REGISTRY`, `TAG`), e.g. Google Artifact Registry.
- A root `Makefile` with `build`, `push`, `up`, `down`, `test`, so the user doesn't need to remember the longer paths.

### Experiments (document in `docs/stage-2.md`)

1. `docker compose up`; repeat the Stage 1 job experiments.
2. `docker compose up --scale worker=4`; observe 4 parallel workers. Note that this is manual scaling.
3. `docker compose stop worker` mid-job; confirm jobs are requeued (tests the `SIGTERM` handling inside containers).
4. Stop Redis; confirm the producer's `/readyz` reports not ready while `/healthz` stays OK.

The docs should include a short checklist titled "What makes an app ready for Kubernetes" based on what was done in this stage.

### Done when

All experiments pass and images can be built and pushed to the chosen registry.

---

## 5. Stage 3: Deploy to k3s

**Target cluster:** self-managed k3s on 3 Google Cloud VMs (1 server, 2 agents), linux/amd64, already installed. Default Traefik ingress is available, but the chart uses only the standard `Ingress` resource with a configurable `ingressClassName` (no Traefik CRDs), to stay portable to GKE.

**Packaging:** the app is deployed with a **Helm chart** written for this project (Helm 3+ / chart `apiVersion: v2`; document the Helm version used). The chart's templates are platform-neutral. Each environment gets its own values file, and variants are layered on top with multiple `-f` flags (later files override earlier ones). The user is learning Helm, so the docs must explain the chart's structure, templates and `_helpers.tpl`, how values flow into templates, and how to inspect the output with `helm lint` and `helm template` before installing.

**Image pulls:** k3s on plain VMs does not automatically authenticate to Artifact Registry. Document the options (an `imagePullSecret` from a service account key, or k3s `registries.yaml`), and note that a public registry works by just changing the image prefix.

This stage has two parts. Implement 3a first and stop; implement 3b when the user asks.

### Stage 3a: Plain Kubernetes, manual scaling

Helm chart layout:

```
deploy/helm/
  kubernetes-test-app/        # the chart (the reusable, platform-neutral package)
    Chart.yaml                # chart name, version, appVersion
    values.yaml               # defaults for every setting, each one commented
    templates/
      _helpers.tpl            # shared names and labels
      NOTES.txt               # printed after install: how to open the page, useful commands
      configmap.yaml          # app configuration (REDIS_HOST, QUEUE_NAME, FAIL_RATE, ...)
      redis.yaml              # Deployment + ClusterIP Service, emptyDir storage
      producer.yaml           # Deployment + Service + Ingress (Ingress optional via values), probes
      worker-deployment.yaml  # Deployment, WORKER_MODE=loop, replicas from values (default 1)
  values/
    k3s.yaml                  # registry/image, ingress host and class, pull secret
```

The namespace is not a chart template. It is created by `helm upgrade --install … --namespace kubernetes-test-app --create-namespace`, which is the usual Helm practice (explain why in the docs).

Requirements:

- Install and upgrade with a single idempotent command: `helm upgrade --install kubernetes-test-app deploy/helm/kubernetes-test-app -n kubernetes-test-app --create-namespace -f deploy/helm/values/k3s.yaml`.
- Keep the templates readable: use `_helpers.tpl` for names and labels, avoid clever template logic, and comment anything that isn't obvious. `helm lint` must pass with no warnings.
- Image registry, repository, and tag, along with `imagePullSecrets`, ingress class and host, resources, and worker replicas all come from values. Nothing environment-specific is hard-coded in the templates.
- A pod-template annotation with a checksum of the ConfigMap (e.g. `checksum/config`), so changing configuration values rolls the pods on `helm upgrade`. Explain this common Helm pattern.
- Every container has resource requests and limits (worker default: `cpu: 250m`, `memory: 64Mi`).
- `WORKER_ID` and `HOST_NAME` injected via the Downward API (pod name and `spec.nodeName`).
- Worker `terminationGracePeriodSeconds` longer than the longest job (e.g., 90 s), relying on the `SIGTERM` handling.
- Labels: `app.kubernetes.io/name`, `app.kubernetes.io/component`, `app.kubernetes.io/part-of: kubernetes-test-app`, plus the standard Helm labels `app.kubernetes.io/instance`, `app.kubernetes.io/managed-by`, and `helm.sh/chart`, all generated in `_helpers.tpl`. Selectors use only the labels that never change (name, instance, and component), because Deployment selectors are immutable.
- Non-root, no privileged containers, `readOnlyRootFilesystem` where practical.
- Configuration passed with a `ConfigMap`.
- Also document `kubectl port-forward` as the simplest way to open the web page.

Experiments (`docs/stage-3a.md`):

1. **Inspect before installing:** `helm lint`, then `helm template … -f deploy/helm/values/k3s.yaml` to see the exact YAML that will be applied. Change a value with `--set` and see the rendered output change.
2. **Deploy** with `helm upgrade --install`, then `helm list` and `helm status`. Submit jobs.
3. **Manual scaling:** `kubectl scale deployment worker --replicas=4` and watch pods spread across both agent nodes (`kubectl get pods -o wide`). Then run `helm upgrade` again and see the replicas snap back to the values file. Explain this drift: Helm owns the desired state, so the lasting way to scale is `--set worker.replicas=4` or editing values. This also shows why an autoscaler, and not Helm, should own the replica count in 3b.
4. **Self-healing:** delete a worker pod mid-job and see the job requeued and the pod replaced by the Deployment.
5. **Scale to 0** (through values) and see jobs wait.
6. **Release history:** change a config value (e.g. `FAIL_RATE`) with `helm upgrade`, watch the pods roll because of the ConfigMap checksum, then `helm history` and `helm rollback` to the previous revision.
7. **Uninstall:** `helm uninstall` and note what it does and doesn't remove (the namespace stays).

### Stage 3b: Autoscaling with KEDA

- `deploy/scripts/install-keda.sh`: installs KEDA with its official Helm chart at a pinned current stable version.
- A chart value `worker.mode` selects how workers run: `deployment` (3a behavior), `scaledjob`, or `scaledobject`. The templates `worker-scaledjob.yaml` and `worker-scaledobject.yaml` are rendered only when selected, using a simple `if`. The KEDA CRDs are installed separately by the script below, never by this chart, so the chart must not render KEDA resources unless asked. Explain in the docs why the CRDs aren't bundled.
- Make `scaledjob` the mode used for 3b by setting it in `deploy/helm/values/k3s.yaml`. Explain whether it should become the chart default.
- The KEDA **ScaledJob** (`worker.mode: scaledjob`):
  - Worker in `WORKER_MODE=once`.
  - `redis` scaler on `jobs:queue` with `listLength: "1"` (one Job per waiting item).
  - `pollingInterval: 5`, `maxReplicaCount: 10`.
  - Job template: `restartPolicy: Never`, `backoffLimit: 0`, `activeDeadlineSeconds: 600`; keep 5 successful and 5 failed Jobs in history.
  - **Scaling strategy:** the worker removes an item from the list when it starts, so the list length excludes in-progress jobs. Choose `scalingStrategy` accordingly after checking the KEDA docs for the pinned version, and explain it in a manifest comment. Experiment 2 below must confirm workers track waiting jobs without systematic over- or under-scaling.
- A `deploy/helm/values/pending-demo.yaml` values file, layered after `k3s.yaml`. It raises the worker CPU request (e.g., `cpu: "1"`, adjusted to VM size) and `maxReplicaCount` to 20, so the two agents run out of room.
- An alternative `deploy/helm/values/scaledobject.yaml` values file (`worker.mode: scaledobject`). It runs the worker `Deployment` in `loop` mode, scaled by a KEDA **ScaledObject** (`minReplicaCount: 0`), for comparison with ScaledJob. In this mode the Deployment must not set `replicas`, because KEDA owns it. This connects back to the drift experiment in 3a. The docs should explain the trade-off: scaling down a Deployment can interrupt a worker mid-job, which the `SIGTERM` handling and grace period must cover, whereas ScaledJob lets each job run to completion.
- Makefile targets: `install-keda`, `deploy`, `deploy-pending-demo`, `undeploy`, `watch`, `logs-worker`. `deploy` targets use `helm upgrade --install` with the right `-f` files, and `undeploy` uses `helm uninstall`.

Experiments (`docs/stage-3b.md`), relating each back to the Stage 1 local scaler:

1. **Scale to zero:** empty queue → no worker pods.
2. **Scale up:** 5 jobs → 5 worker pods within ~10 s; all complete; back to 0.
3. **Maximum respected:** 30 jobs with max 10 → never more than 10 at once; all 30 complete.
4. **Spreading:** during experiment 3, workers run on both agent nodes.
5. **Failures:** `FAIL_RATE=0.3` → every job completed or dead-lettered; none lost.
6. **Capacity limit:** pending-demo values + 20 jobs → some pods `Pending`; `kubectl describe pod` shows insufficient CPU.
7. **Interrupted worker:** delete a worker pod mid-job → job requeued and picked up again.
8. **ScaledJob vs ScaledObject:** run experiment 3 in both modes and compare.

---

## 6. Stage 4: Deploy to GKE

**Goal:** run the same app on managed Kubernetes and learn what changes, including node autoscaling that k3s on fixed VMs cannot do.

### Scope

- A `deploy/helm/values/gke.yaml` values file. The chart templates should not need changes. If something turns out to be k3s-specific, make it configurable through values, set it in `k3s.yaml`, and explain why.
- Image pulls from Artifact Registry without key files (GKE node service account permissions, or Workload Identity if appropriate).
- Ingress using GKE's ingress class or the Gateway API (pick one, explain the choice).
- KEDA installed on GKE with the same script.
- Documentation (`docs/stage-4.md`) with the `gcloud` commands for the user to run: creating a small GKE Standard cluster with a node pool that has autoscaling enabled (e.g., min 1, max 4 nodes), getting credentials, creating the Artifact Registry repository if needed, and deleting everything afterwards.
- A clear cost warning at the top of the docs, and a note about GKE Autopilot as an alternative (and why resource requests on every container matter there).

### Experiments

1. Repeat Stage 3b experiments 1–5 on GKE.
2. Repeat the capacity-limit experiment: this time `Pending` pods should trigger the **cluster autoscaler** to add nodes, and after the queue drains, nodes should be removed (this can take around 10 minutes). Document the commands to watch it (`kubectl get nodes -w`, `kubectl get events`).
3. Write down every difference between the `k3s.yaml` and `gke.yaml` values files in a short table in the docs.
4. Tear down the cluster.

---

## 7. Repository layout (final state after all stages)

```
kubernetes-test-app/
  README.md                  # overview + links to docs per stage
  Makefile                   # convenience targets (test, build, push, up, deploy, ...)
  .dockerignore              # Stage 2
  docs/                      # stage-1.md ... stage-4.md
  app/                       # application source code only: no Docker or Kubernetes files
    producer/                # app.py, static/index.html, requirements.txt, tests/
    worker/                  # worker.py, requirements.txt, tests/
    tools/local_scaler.py    # Stage 1
  deploy/                    # everything needed to package and run the app
    docker/                  # Stage 2: producer.Dockerfile, worker.Dockerfile
    compose/                 # Stage 2: docker-compose.yaml
    helm/                    # Stage 3–4: kubernetes-test-app/ chart + values/ (k3s, pending-demo, scaledobject, gke)
    scripts/                 # Stage 3–4: install-keda.sh, helper scripts
```

The rule of thumb: if a file would still make sense with no containers or Kubernetes at all, it belongs in `app/`; if it only exists to build, ship, or run the app somewhere, it belongs in `deploy/`.

## 8. Non-goals

No authentication, no persistent Redis storage, no high availability, no metrics stack (Prometheus/Grafana), no automated cloud provisioning.
