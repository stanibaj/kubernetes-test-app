# Stage 2: Container-ready app

In Stage 1 everything ran as Python processes on your machine. In this stage the same code is packaged into **container images** and run together with **Compose**. Along the way, the app is adjusted to follow the habits Kubernetes expects (health endpoints, signals, logs, configuration). Nothing here is Kubernetes-specific yet, but every item on the checklist at the end is something Stage 3 relies on.

On this host we use **Podman** (4.9) with **podman-compose** (1.0.6) instead of Docker. The files are standard Dockerfile/Compose files, so they also work with Docker (`make ... CONTAINER_TOOL=docker`).

## What was built

```
                 host (vps-01)                     compose network "kubernetes-test-app_default"
  browser ──▶ 100.x.y.z:8000 ──publish──▶ ┌──────────────────────────────────────────────┐
             (Tailscale IP only)          │  producer :8000 ──┐                           │
                                          │                   ├──▶ redis :6379 (no port   │
                                          │  worker_1 ────────┤         published)        │
                                          │  worker_2 ────────┤                           │
                                          │  worker_N ────────┘   found by DNS name "redis"│
                                          └──────────────────────────────────────────────┘
```

| File | What it is |
|---|---|
| `deploy/docker/producer.Dockerfile`, `deploy/docker/worker.Dockerfile` | Recipes for the two images. Built with the **repository root** as the build context. |
| `.dockerignore` | An allowlist of the files sent to the image build: only the app code and `requirements.txt` files. |
| `deploy/compose/docker-compose.yaml` | Redis + producer + N workers (`loop` mode) on one private network. |
| `Makefile` | `make test`, `make build`, `make push`, `make up`, `make down`. |
| `app/producer/app.py` (changed) | New `GET /healthz` and `GET /readyz`. The Redis client now fails fast. |
| `app/producer/tests/test_producer.py` (changed) | Tests for the two health endpoints. |

The worker code did **not** change. The next section explains why it was already container-ready.

## Changes to the Stage 1 code, and why

### 1. Health endpoints in the producer

Kubernetes asks every container two different questions, over and over:

- **Liveness: "are you alive?"** → `GET /healthz`. It returns `200 {"status":"ok"}` as long as the process can answer HTTP at all. It deliberately does **not** check Redis. If liveness fails, Kubernetes **restarts** the container. Restarting the producer would not fix a Redis outage; it would only add a crash loop on top of it.
- **Readiness: "can you do useful work right now?"** → `GET /readyz`. It sends `PING` to Redis and returns `200 {"status":"ready"}`, or `503 {"status":"not ready", "error": ...}` if Redis doesn't answer. If readiness fails, Kubernetes **keeps the container running but stops sending it traffic** (it removes the pod from the Service). Once Redis is back, readiness turns green and traffic returns, with no restart.

Rule of thumb: liveness checks only the process itself, while readiness checks the dependencies it needs to serve requests.

### 2. Fail fast when Redis is down

A readiness check that hangs is almost as bad as none: Kubernetes probes have a timeout (1 s by default) and count a hang as a failure anyway, and a hanging web request ties up the server. redis-py 8 **retries a failed connection 10 times with backoff by default**, and by default has no connect timeout. The producer's client is now created with:

```python
redis.Redis(..., socket_connect_timeout=2, socket_timeout=2,
            retry=Retry(NoBackoff(), retries=1))
```

With these settings, a dead Redis gives "not ready" within a few seconds. The worker keeps redis-py's default retries on purpose: riding out a short Redis blip is useful for a long-running worker.

### 3. Why the worker needed no changes

The spec asks you to check four things, and the worker already did all of them in Stage 1:

- **Configuration from environment variables only.** `Config.from_env()` reads everything; Compose sets `REDIS_HOST=redis`, `WORKER_MODE=loop` and `FAIL_RATE`.
- **Logs only to stdout.** `print(..., flush=True)`. The images also set `PYTHONUNBUFFERED=1`, so nothing sits in a buffer when the container stops.
- **No state on local disk.** All state is in Redis. The images also set `PYTHONDONTWRITEBYTECODE=1`, so Python doesn't even write `.pyc` files. That will let Stage 3 use `readOnlyRootFilesystem`.
- **SIGTERM as PID 1.** See the next section.

## Concepts

**Image vs container.** An *image* is a read-only package: a base OS layer, Python, the dependencies and our code. A *container* is a running instance of an image. One worker image gives you as many worker containers as you like. That is what scaling means from now on.

**Build context and `.dockerignore`.** `podman build -f deploy/docker/worker.Dockerfile .` sends the *context* (the trailing `.`, the repository root) to the builder, and the Dockerfile can only `COPY` from there. Using the root as context lets the Dockerfiles live in `deploy/` while the code stays in `app/`. `.dockerignore` works as an **allowlist**: `*` excludes everything, then `!app/worker/worker.py` and similar lines add back only what the images need. Tests, `.venv`, `.git` and docs never reach the builder, which makes builds faster and images smaller, and keeps secrets out of images by accident.

**Layer caching.** Each Dockerfile instruction produces a cached layer. That's why `requirements.txt` is copied and installed **before** the code: when you change only `worker.py`, the builder reuses the `pip install` layer and the rebuild takes seconds. (Look for `Using cache` in `make build` output.)

**Small, safe images.**
- The base is `docker.io/library/python:3.12-slim`, fully qualified because Podman here has no default registry.
- `pip install --no-cache-dir` keeps pip's download cache out of the image.
- There are no secrets in the images: configuration arrives at runtime through env vars.
- The results are the producer at about 145 MB and the worker at about 129 MB. Most of that is the Python base image.

**Non-root.** Both images create the user `app` with UID 10001 and switch to it with `USER 10001`. If someone breaks into the process, they are not root inside the container. The numeric UID matters: Kubernetes' `runAsNonRoot: true` (Stage 3a) can only verify a *number*, not a user name.

**PID 1 and signals.** Inside a container, your program is process number 1. Linux treats PID 1 specially: signals it hasn't installed a handler for are **ignored** rather than killing it. Two things make this work for us:
1. The worker installs its own SIGTERM/SIGINT handlers (Stage 1), so SIGTERM is never "unhandled". Uvicorn also handles SIGTERM itself.
2. `CMD ["python", "worker.py"]` uses the **exec form** (a JSON list), so Python really *is* PID 1. The shell form `CMD python worker.py` would make `/bin/sh` PID 1, and the shell would not forward SIGTERM. The container would then sit there until it was force-killed after the grace period, and the job would be lost instead of requeued.

`podman stop` (like Kubernetes) sends SIGTERM, waits for the *grace period*, then sends SIGKILL. Compose sets `stop_grace_period: 90s` for workers. That is a preview of Kubernetes' `terminationGracePeriodSeconds`, which must be longer than the longest job. Our worker doesn't need the full time, because it requeues and exits within a second.

**Listening on 0.0.0.0 *inside* the container.** A container has its own network namespace. If the producer listened on `127.0.0.1` inside it, only processes *in that container* could reach it, and neither port publishing nor (later) a Kubernetes Service could. So the producer image sets `ENV HOST=0.0.0.0`: that means "all interfaces **of the container**". It is not the host's 0.0.0.0. Which *host* address is exposed is decided by `ports:` in Compose, and ours says `${TS_IP}:8000:8000`. The code default in `app.py` is still `127.0.0.1`. Verify with `ss -ltn` on the host: you'll see `100.x.y.z:8000`, never `0.0.0.0:8000`.

**Compose networking and service DNS.** Compose creates a private network, and each service is reachable by its **service name**. That's why `REDIS_HOST=redis` works. Redis has **no** `ports:` entry, so it can't be reached from the host or the internet at all, only by the producer and the workers. Kubernetes Services (Stage 3a) work the same way: a name that other pods resolve.

**Manual scaling with Compose.** `deploy.replicas: ${WORKERS:-1}` runs N identical worker containers named `kubernetes-test-app_worker_1`, `_2`, and so on. The spec's `docker compose up --scale worker=4` would do the same, but **podman-compose 1.0.6 accepts `--scale` and silently ignores it**, so we use `replicas` driven by the `WORKERS` variable (`make up WORKERS=4`). Either way this is *manual* scaling: you choose the number and nothing reacts to the queue. Stage 3b's KEDA automates this, just as the Stage 1 local scaler did.

**Restarts.** The worker exits with code 1 when Redis is unreachable. That is a real error, as agreed in Stage 1. `restart: on-failure` restarts it in the common case, for example a worker starting a moment before Redis accepts connections. One Podman quirk showed up while testing: podman-compose links every container to Redis (`--requires`), and **Podman does not auto-restart a worker while the Redis container it requires is stopped**. After you bring Redis back, run `make up` again, which starts any exited containers. Kubernetes handles this better: it keeps restarting a crashed container with increasing delays (`CrashLoopBackOff`) until the dependency is back.

## Setup

```bash
cd ~/kubernetes-learning/kubernetes-test-app
make test          # 29 tests, same .venv as Stage 1
make build         # builds localhost/kubernetes-test-app-{producer,worker}:dev
make up            # redis + producer + 1 worker, producer on $TS_IP:8000
```

`make up` builds first, reads `TS_IP` from `tailscale ip -4`, and starts everything in the background. Open `http://<tailscale-ip>:8000`.

**Port 8000 already in use?** That is probably the Stage 1 producer (`python app/producer/app.py`) still running. Stop it with Ctrl+C in its terminal. Alternatively, publish on another port with `make up PRODUCER_PORT=8001`. The Stage 1 `redis` container doesn't conflict, because the Compose Redis publishes no port.

Useful commands (Podman names the containers `kubernetes-test-app_<service>_<n>`):

```bash
podman ps --filter label=com.docker.compose.project=kubernetes-test-app   # what's running
podman logs -f kubernetes-test-app_worker_1                                # one worker's log
podman logs -f kubernetes-test-app_producer_1
ss -ltn | grep 8000                                                        # only the Tailscale IP
curl http://$(tailscale ip -4):8000/healthz; curl http://$(tailscale ip -4):8000/readyz
make down          # SIGTERM → stop → remove all project containers and the network
```

Variables you can pass to `make` (all optional): `WORKERS`, `FAIL_RATE`, `PRODUCER_PORT`, `REGISTRY`, `TAG`, `TS_IP`, `CONTAINER_TOOL`.

**After changing code**, run `make down && make up`. `make up` rebuilds the images, but Podman simply restarts containers that already exist, so they keep the old image until they are recreated. For the same reason, to go from 4 workers *down* to 2, run `make down` first.

## Experiments

### 1. Repeat the Stage 1 job experiments in containers

```bash
make up                       # 1 worker
podman logs -f kubernetes-test-app_worker_1
```

Submit 5 jobs of 10 s on the page. **Expect:** they run one after another, and the dashboard's host column shows the worker's **container ID** (for example `3b853a492df7`) instead of your machine's name. Inside a container, the hostname is the container ID. In Kubernetes, we'll inject the node name instead.

Failures:

```bash
make down && make up WORKERS=3 FAIL_RATE=0.3
```

Submit 20 jobs of 5 s. **Expect:** Completed + Dead-lettered = 20 once the queue drains, so no job is lost.

### 2. Four parallel workers (manual scaling)

```bash
make down && make up WORKERS=4
```

Submit 12 jobs of 20 s. **Expect:** 4 jobs processing at any moment, with 4 different hosts (container IDs) on the dashboard. The queue drains 4 at a time. Note that *you* picked 4. Nothing reacts to the queue length; that's what KEDA adds in Stage 3b.

### 3. Stopping workers mid-job requeues the jobs (SIGTERM inside containers)

With the 4 workers from experiment 2, submit 4 jobs of 60 s and wait until all 4 are processing. Then stop all the workers:

```bash
podman stop $(podman ps -q --filter label=com.docker.compose.project=kubernetes-test-app \
                           --filter label=com.docker.compose.service=worker)
podman logs --tail 3 kubernetes-test-app_worker_1
podman inspect -f '{{.State.ExitCode}}' kubernetes-test-app_worker_1
```

**Expect:**
- The stop is almost instant, well under the 90 s grace period.
- Each worker logs:

  ```
  [3b853a492df7-1] job 98d8db11… interrupted by shutdown signal, returned to queue
  [3b853a492df7-1] received SIGTERM, exiting
  ```

- The exit code is `0`.
- The dashboard shows **Waiting = 4, Processing = 0**. The worker ID ends in `-1` because the worker is PID 1 in its container.

`make up WORKERS=4` starts them again, and they pick the jobs up.

If the stop took about 90 s instead and the jobs vanished, SIGTERM never reached Python. That is the shell-form `CMD` problem described above.

### 4. Readiness vs liveness when Redis stops

```bash
make up
T=$(tailscale ip -4):8000
curl -s -w ' %{http_code}\n' $T/readyz      # {"status":"ready"} 200
podman stop kubernetes-test-app_redis_1
curl -s -w ' %{http_code}\n' $T/healthz     # {"status":"ok"} 200
curl -s -w ' %{http_code}\n' $T/readyz      # {"status":"not ready","error":"... redis:6379 ..."} 503
```

**Expect:**
- `/healthz` stays 200, because the process is fine.
- `/readyz` returns 503 within a fraction of a second.
- The workers exit with code 1 (a real error) after redis-py gives up retrying.

Bring Redis back:

```bash
podman start kubernetes-test-app_redis_1
curl -s -w ' %{http_code}\n' $T/readyz      # ready again, and the producer was never restarted
make up                                     # start the exited workers again (see "Restarts")
```

Why the `dns_opt` lines in the Compose file? When the Redis container is stopped, its name disappears from Podman's DNS. Each failed lookup of `redis` then took about 10 s (glibc's default is a 5 s timeout × 2 attempts), and `/readyz` needed 35 s to answer. Setting `timeout:1` and `attempts:1` for the two app containers fixes it. In Kubernetes this particular problem goes away: a Service name keeps resolving even when no pod is behind it, and the connection simply fails quickly.

## Registry, tags and pushing

Images are named `$(REGISTRY)/kubernetes-test-app-<component>:$(TAG)`. The defaults are `REGISTRY=localhost` and `TAG=dev`, which gives local-only images that are never pushed. To push to **Google Artifact Registry** later, run the following yourself. Creating the repository is a cloud resource, and storing a few hundred MB costs a few cents a month:

```bash
# once: create a Docker repository (pick your region and project)
gcloud artifacts repositories create kubernetes-test-app \
  --repository-format=docker --location=europe-west1

# log Podman in (gcloud auth configure-docker only configures Docker)
gcloud auth print-access-token | \
  podman login -u oauth2accesstoken --password-stdin europe-west1-docker.pkg.dev

# build and push with a unique tag
make build push \
  REGISTRY=europe-west1-docker.pkg.dev/<PROJECT_ID>/kubernetes-test-app \
  TAG=$(git rev-parse --short HEAD)
```

Notes:
- **Prefer unique, immutable tags** (a git SHA or `v1`, `v2`) over reusing `latest`/`dev`. Kubernetes nodes cache images by tag, so if you re-push the same tag, some nodes keep running the old image.
- **Any registry works.** For example, `REGISTRY=docker.io/<your-user>` or `ghcr.io/<your-user>`, after `podman login` to it. A *public* repository would let k3s pull without credentials (Stage 3).
- **Architecture:** this host is `x86_64`, so the images are `linux/amd64`, the same as the k3s VMs. When building on an ARM machine (for example Apple Silicon), add `--platform linux/amd64` to the build.
- The access token from `print-access-token` expires after about an hour. Log in again if a push says `unauthorized`.

## What makes an app ready for Kubernetes

A checklist based on this stage:

- [x] **Stateless process.** All state is in an external service (Redis); nothing is kept on local disk, and the root filesystem could be read-only.
- [x] **Configuration only through environment variables**, with defaults, so the same image runs everywhere (Compose now, a ConfigMap later).
- [x] **Logs are single lines on stdout/stderr**, unbuffered. The platform collects them (`podman logs`, later `kubectl logs`).
- [x] **Handles SIGTERM as PID 1.** An exec-form `CMD` and a real signal handler. It finishes or hands back work, then exits within the grace period.
- [x] **Meaningful exit codes.** `0` for expected outcomes and non-zero only for real errors, so restarts and Job success are judged correctly.
- [x] **Separate liveness and readiness endpoints.** Liveness checks the process only; readiness checks the dependencies it needs.
- [x] **Fails fast** when a dependency is down: short timeouts, no endless retries in the request path.
- [x] **Listens on all interfaces inside the container** and on a configurable port. Exposure is decided outside the app.
- [x] **Small image, non-root numeric UID, no secrets baked in**, with dependencies in a cached layer.
- [x] **Versioned images in a registry** (`REGISTRY`/`TAG`), so a cluster can pull exactly what you built.
- [x] **Horizontally scalable.** N identical copies work together with no coordination other than the queue.

## What carries forward

- The **images** are what Stage 3a's Deployments run. Nothing in `app/` changes for Kubernetes.
- `/healthz` and `/readyz` become the producer's `livenessProbe` and `readinessProbe`.
- `stop_grace_period` becomes `terminationGracePeriodSeconds`.
- `USER 10001` enables `runAsNonRoot`, and "no disk writes" enables `readOnlyRootFilesystem`.
- `WORKERS=4` becomes `kubectl scale deployment worker --replicas=4`, and later KEDA sets it for you.
- The Compose service name `redis` becomes a Kubernetes Service called `redis`, so `REDIS_HOST=redis` stays the same.
