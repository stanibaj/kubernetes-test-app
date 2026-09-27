# kubernetes-test-app

A learning project for watching Kubernetes scale workers up and down based on the number of jobs waiting in a queue. The app is deliberately trivial: a producer puts jobs into Redis, and each worker processes **exactly one job at a time** (by sleeping). The interesting part is how the app is run and scaled.

The full specification is in [`spec.md`](spec.md). The project is built in stages:

| Stage | What | Docs |
|---|---|---|
| 1 | Local Python app + a homemade "local scaler" | [docs/stage-1.md](docs/stage-1.md) |
| 2 | Containers + Docker Compose | [docs/stage-2.md](docs/stage-2.md) |
| 3a | k3s with a Helm chart, manual scaling | [docs/stage-3a.md](docs/stage-3a.md), [file-by-file manual](docs/stage-3a-manual.md) |
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

## Quick start (Stage 2: containers)

```bash
make test                  # pytest (uses the Stage 1 .venv)
make up                    # build images, start redis + producer + worker with Podman
                           # → http://$(tailscale ip -4):8000   (WORKERS=4 for more workers)
make down                  # stop and remove everything
```

Details, experiments and the registry/push instructions are in [docs/stage-2.md](docs/stage-2.md).

## Quick start (Stage 3a: k3s with Helm)

```bash
# once: kubeconfig, Tailscale grant, pull secret; see docs/stage-3a.md "One-time setup"
helm lint deploy/helm/kubernetes-test-app -f deploy/helm/values/k3s.yaml
helm upgrade --install kubernetes-test-app deploy/helm/kubernetes-test-app \
  -n kubernetes-test-app --create-namespace -f deploy/helm/values/k3s.yaml
kubectl -n kubernetes-test-app get pods -o wide
# → http://gcp-srv-02.beefalo-fort.ts.net/   (tailnet only)
```

## Layout

- `app/`: application code only (producer, worker, tools, tests). It knows nothing about Docker or Kubernetes.
- `deploy/`: packaging and deployment. `docker/` holds the Dockerfiles (built from the repo root), `compose/` holds the Compose file, and `helm/` holds the `kubernetes-test-app/` chart plus per-environment `values/` files.
- `Makefile`: `test`, `build`, `push`, `up`, `down`.
- `docs/`: one explanation per stage, plus [`cheatsheet.md`](docs/cheatsheet.md) (kubectl + Helm commands, grouped by the question they answer).
