# Stage 1: Local app (the baseline)

In this stage everything runs as plain Python processes on your machine. There are no containers and no Kubernetes yet. The goal is to understand what "scaling workers" means before any platform does it for you.

## What was built

```
  browser ──HTTP──▶ producer (FastAPI)          worker(s)
                      │ RPUSH jobs:queue            ▲ LPOP / BLPOP jobs:queue
                      ▼                             │
                  ┌──────────────── Redis ──────────┴──────────────┐
                  │ jobs:queue       list of waiting jobs           │
                  │ jobs:processing  hash: job id → worker, host    │
                  │ jobs:completed   counter                        │
                  │ jobs:failed      counter (failed attempts)      │
                  │ jobs:dead        list of jobs that gave up      │
                  │ jobs:history     last 50 finished jobs          │
                  └─────────────────────────────────────────────────┘
                      ▲ LLEN jobs:queue
                      │
               local_scaler.py ──starts──▶ worker processes (WORKER_MODE=once)
```

| Piece | File | What it does |
|---|---|---|
| Producer | `app/producer/app.py`, `static/index.html` | `POST /api/jobs` adds jobs, `GET /api/status` reports everything, `POST /api/reset` wipes it all. `/` is a live dashboard that refreshes every 2 s. |
| Worker | `app/worker/worker.py` | Takes **one** job, "processes" it by sleeping, and records the result. It can simulate failures. |
| Local scaler | `app/tools/local_scaler.py` | A tiny homemade autoscaler: one `once` worker per waiting job, up to `--max`. |
| Tests | `app/*/tests/` | pytest + fakeredis (an in-memory Redis), so you don't need a real Redis to run them. |

The producer and worker don't import each other. Each one defines the Redis key names itself. That's deliberate: in Stage 2 each becomes its own container image, and the only thing they share is Redis.

## Concepts

**A queue decouples producers from workers.** The producer only puts jobs in a Redis list; it doesn't know or care how many workers exist. That's what makes it possible to change the number of workers freely, and later to let Kubernetes do it.

**One worker = one job at a time.** A worker never takes a second job until the first one is finished. That means "how many workers do I need?" has a simple answer: as many as there are waiting jobs (up to some limit). This is exactly the rule KEDA will apply in Stage 3b.

**Two worker modes.**
- `loop`: a long-running process that waits for jobs with `BLPOP`, a *blocking* pop that sleeps inside Redis until a job arrives or 5 s pass. This is the model of a normal Kubernetes Deployment (Stage 3a).
- `once`: take one job (or find none), finish, exit. Starting a process per job is the model of a Kubernetes Job (Stage 3b's ScaledJob). If the queue is empty, it logs `no job available` and exits with code 0, because that's expected, not an error.

**Job lifecycle.** A worker pops the job off `jobs:queue`, records it in `jobs:processing`, sleeps (logging progress every 5 s), then:
- On **success**, it increments `jobs:completed`.
- On a **simulated failure** (probability `FAIL_RATE`), it increments `jobs:failed` and the job's `attempts`. If `attempts < MAX_ATTEMPTS` (default 3), the job goes to the back of the queue to be retried. Otherwise it goes to `jobs:dead`, a *dead-letter list* where jobs that keep failing are parked so they stop consuming workers.
- In **either case**, the job leaves `jobs:processing` and an entry is added to `jobs:history`.

A job therefore always ends up either completed or dead-lettered, never lost. Note that `jobs:failed` counts failed *attempts*, so it can be larger than the number of dead jobs.

**Graceful shutdown.** When a process is asked to stop, it gets a signal: `SIGINT` from Ctrl+C, or `SIGTERM`, which is what Docker and Kubernetes send. The worker turns both into a `ShutdownRequested` exception. That interrupts the sleep immediately, puts the job back at the **front** of the queue (it doesn't count as an attempt, because it wasn't the job's fault), removes it from `jobs:processing`, and exits with code 0. Kubernetes will rely on this constantly, because it stops pods whenever it scales down or moves work around.

**Exit codes.** `0` means "everything went as expected", including simulated failures and shutdowns. `1` is reserved for real problems, such as Redis being unreachable. Kubernetes uses exit codes to decide whether a Job succeeded, so this distinction matters later.

**The local scaler is KEDA in miniature.** Every `--interval` seconds it:
1. forgets workers that have exited,
2. reads the queue length (`LLEN jobs:queue`),
3. computes `to_start = min(queue, max - running)` and prints its reasoning, e.g. `queue=7 running=3 max=5 → starting 2`,
4. starts that many `once` workers as subprocesses.

Waiting jobs and running workers never overlap, because a worker removes its job from the queue as it starts. So "one worker per waiting job" is the right target. There's one small race: a worker started on the previous tick that hasn't popped its job yet is counted both as running *and* as a waiting job, so the scaler can occasionally start one worker too many. That worker just logs `no job available` and exits. Keep this in mind for Stage 3b, where you'll choose how KEDA counts in-progress jobs.

## Setup

### 1. Network rule: bind to the Tailscale IP only

On this host, nothing may listen on `0.0.0.0` (all interfaces, including the public one). Local services bind only to the Tailscale IP. Set these variables once in **every terminal** you use for the experiments:

```bash
export TS_IP=$(tailscale ip -4)      # e.g. 100.110.243.10
export REDIS_HOST=$TS_IP             # producer, worker and scaler connect here
export HOST=$TS_IP                   # producer listens here
```

Workers and the scaler inherit `REDIS_HOST` from the shell (and the scaler passes it on to its workers), so no other command needs changing.

Check what's actually listening at any time with `ss -ltn`. Every line for 6379 or 8000 should show `100.x.y.z:port`, never `0.0.0.0`, `*` or `[::]`.

### 2. Redis

Run Redis in a container with Podman (Stage 1 allows a container for Redis only). Note the IP in `-p`:

```bash
podman run --rm --name redis -p $TS_IP:6379:6379 docker.io/library/redis:7
podman exec -it redis redis-cli ping      # → PONG
```

- **Publish on one IP only.** `-p 6379:6379` is shorthand for `-p 0.0.0.0:6379:6379` and would expose Redis, which has no password here, on the public interface. `-p $TS_IP:6379:6379` publishes it only on the Tailscale address. The same pattern comes back in Stage 2 for Compose `ports:`.
- **Fully qualified image name.** Docker quietly expands `redis:7` to `docker.io/library/redis:7`, but Podman doesn't guess a registry. With a short name, it fails with `short-name "redis:7" did not resolve to an alias` unless `unqualified-search-registries` is set in `/etc/containers/registries.conf`. Writing the registry explicitly works everywhere and makes it obvious where the image comes from.

(If you'd rather use the apt package `redis-server`: it binds to loopback by default. Change the `bind` line in `/etc/redis/redis.conf` to your Tailscale IP and restart the service.)

To clear everything between experiments, use the dashboard's Reset button, or `podman exec redis sh -c "redis-cli --scan --pattern 'jobs:*' | xargs -r redis-cli del"`.

### 3. Python environment

Each component has its own `requirements.txt` (`app/producer/`, `app/worker/`), and these are what the container images will install in Stage 2. For local development, a single virtual environment at the repo root holds both plus the test tools:

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements-dev.txt
```

All commands below assume the venv is active and you're in the repo root.

### 4. Tests

```bash
pytest                                              # everything
pytest app/worker                                   # one component
pytest app/worker/tests/test_worker.py::test_interrupt_returns_job_to_front_of_queue
```

### 5. Configuration

Everything is set through environment variables. On this host you set `REDIS_HOST` and `HOST` as shown above; the other defaults are fine.

| Variable | Default | Used by |
|---|---|---|
| `REDIS_HOST` / `REDIS_PORT` | `localhost` / `6379` | all |
| `QUEUE_NAME` | `jobs:queue` | all |
| `HOST` | `127.0.0.1` | producer: address to listen on (never defaults to `0.0.0.0`) |
| `PORT` | `8000` | producer |
| `WORKER_MODE` | `loop` | worker (`loop` or `once`) |
| `FAIL_RATE` | `0.0` | worker |
| `MAX_ATTEMPTS` | `3` | worker |
| `WORKER_ID` | `<hostname>-<pid>` | worker |
| `HOST_NAME` | hostname | worker |

## Experiments

Remember the `export` lines from setup step 1 in each terminal. Open a terminal for the producer and keep it running throughout:

```bash
python app/producer/app.py        # listens on $HOST:8000
```

Then open `http://<tailscale-ip>:8000` from any device on your tailnet.

Jobs can be submitted from the web page, or from the command line:

```bash
curl -s -X POST $HOST:8000/api/jobs -H 'Content-Type: application/json' \
     -d '{"count": 5, "duration_seconds": 10}'
curl -s $HOST:8000/api/status | python -m json.tool
```

Short durations (10 s) keep the experiments quick. Press **Reset** between experiments.

### 1. One worker processes jobs one after another

```bash
WORKER_ID=worker-1 python app/worker/worker.py
```

Submit 5 jobs of 10 s. **Expect:** "Processing now" never shows more than one row, "Waiting" counts down 4 → 0, and the whole batch takes about 50 s. The worker keeps running, waiting for more.

### 2. Three workers process in parallel

Stop the worker with Ctrl+C, then start three, each in its own terminal:

```bash
WORKER_ID=worker-1 python app/worker/worker.py
WORKER_ID=worker-2 python app/worker/worker.py
WORKER_ID=worker-3 python app/worker/worker.py
```

Submit 9 jobs of 10 s. **Expect:** three jobs are processed at a time, and the batch finishes in about 30 s instead of 90 s. This is *manual* scaling: you decided how many workers to run.

### 3. The local scaler scales up to 5 and back down to 0

Stop all workers, then run:

```bash
python app/tools/local_scaler.py --max 5
```

Submit 12 jobs of 10 s. **Expect** lines like:

```
[scaler] queue=12 running=0 max=5 → starting 5
[scaler] queue=7 running=5 max=5 → nothing to do
[scaler] queue=7 running=0 max=5 → starting 5
...
[scaler] queue=0 running=0 max=5 → nothing to do
```

The dashboard never shows more than 5 jobs processing at once. When the queue empties, no worker processes are left: `pgrep -f worker.py` prints nothing. This is *scale to zero*. You'll see Kubernetes and KEDA do the same with pods in Stage 3b.

Try `"duration_seconds": "random"` to see workers finish at different times and the scaler backfill free slots one by one.

### 4. Failures end up completed or dead-lettered

Stop the scaler, then start it again with failures enabled:

```bash
FAIL_RATE=0.3 python app/tools/local_scaler.py --max 5
```

The scaler passes its environment on to the workers it starts. You could also run a `loop` worker with `FAIL_RATE=0.3` instead.

Submit 20 jobs of 5 s. **Expect:** some history rows say `failed` (retried later) and maybe a few say `dead`. When everything is done, **Completed + Dead-lettered = 20**, so no job is lost. Failed attempts will be higher than Dead-lettered, because most failed jobs succeed on a retry.

### 5. Ctrl+C mid-job returns the job to the queue

Start a single `loop` worker and submit 1 job of 60 s:

```bash
WORKER_ID=worker-1 python app/worker/worker.py
```

While the job is running, press Ctrl+C. **Expect:**

```
[worker-1] job 3f2a1b7c… interrupted by shutdown signal, returned to queue
[worker-1] received SIGINT, exiting
```

The dashboard shows Waiting = 1 and nothing processing. Start the worker again and it picks the same job up from the beginning.

This also works with the scaler: Ctrl+C in the scaler's terminal reaches the scaler *and* its workers, because they share the terminal's process group. Every running job is requeued before the scaler exits. `kill <scaler-pid>` (SIGTERM) behaves the same, because the scaler forwards the signal to its workers.

## What carries forward

- **Configuration only through env vars:** in Kubernetes these come from a ConfigMap and the Downward API.
- **Logs only to stdout:** containers and Kubernetes collect stdout; nothing is written to local files.
- **Workers are stateless:** all state lives in Redis, so any worker can be killed or added at any time.
- **SIGTERM handling:** this is how pods get stopped. Stage 2 checks it still works when the worker runs as PID 1 in a container.
- **`once` mode + a scaler reading `LLEN`:** this becomes KEDA's ScaledJob in Stage 3b.
