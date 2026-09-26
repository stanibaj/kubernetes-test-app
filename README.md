# kubernetes-test-app

A learning project for watching Kubernetes scale workers up and down based on the number of jobs waiting in a queue. The app is deliberately trivial: a producer puts jobs into Redis, and each worker processes **exactly one job at a time** (by sleeping). The interesting part is how the app is run and scaled.

The full specification is in [`spec.md`](spec.md). The project is built in stages:

| Stage | What | Docs |
|---|---|---|
| 1 | Local Python app + a homemade "local scaler" | [docs/stage-1.md](docs/stage-1.md) |
| 2 | Containers + Docker Compose | not yet |
| 3a | k3s with manual scaling | not yet |
| 3b | k3s with KEDA autoscaling | not yet |
| 4 | GKE with node autoscaling | not yet |

## Quick start (Stage 1)

```bash
# This host: bind only to the Tailscale IP, never 0.0.0.0 (details in docs/stage-1.md)
export TS_IP=$(tailscale ip -4) REDIS_HOST=$(tailscale ip -4) HOST=$(tailscale ip -4)

podman run --rm --name redis -p $TS_IP:6379:6379 docker.io/library/redis:7
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements-dev.txt
pytest

python app/producer/app.py               # http://$HOST:8000
python app/worker/worker.py              # one worker in loop mode
python app/tools/local_scaler.py --max 5 # or: autoscale once-workers from queue length
```

## Layout

- `app/`: application code only (producer, worker, tools, tests). It knows nothing about Docker or Kubernetes.
- `deploy/`: packaging and deployment (added from Stage 2 on).
- `docs/`: one explanation per stage.
