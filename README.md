# kubernetes-test-app

A learning project for watching Kubernetes scale workers up and down based on the number of jobs waiting in a queue. The app is deliberately trivial: a producer puts jobs into Redis, and each worker processes **exactly one job at a time** (by sleeping). The interesting part is how the app is run and scaled.

The full specification is in [`spec.md`](spec.md). The project is built in stages:

| Stage | What | Docs |
|---|---|---|
| 1 | Local Python app + a homemade "local scaler" | [docs/stage-1.md](docs/stage-1.md) |
| 2 | Containers + Docker Compose | [docs/stage-2.md](docs/stage-2.md) |
| 3a | k3s with a Helm chart, manual scaling | [docs/stage-3a.md](docs/stage-3a.md), [file-by-file manual](docs/stage-3a-manual.md) |
| 3b | k3s with KEDA autoscaling | [docs/stage-3b.md](docs/stage-3b.md) |
| 4 | GKE with node autoscaling, reachable only over Tailscale | [docs/stage-4.md](docs/stage-4.md) |

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

## Quick start (Stage 3b: KEDA autoscaling)

```bash
make install-keda            # once per cluster: KEDA 2.21.0 into namespace keda
make deploy                  # k3s.yaml → worker.mode=scaledjob: one Job per waiting job, 0..10
make watch                   # live view (other terminal: make logs-worker)
# submit jobs on the page and watch workers appear and go back to 0; details in docs/stage-3b.md
```

## Quick start (Stage 4: GKE) 💰

```bash
# once: Tailscale OAuth client + policy, then Terraform (you run every apply): docs/stage-4.md
make tf-bootstrap tf-apply   # state bucket, then APIs/registry/SAs/firewall/k3s VMs (imported)/nightly delete
make gke-up                  # terraform apply of the cluster + get-credentials
make install-keda-gke install-tailscale-operator
make deploy-gke              # gke.yaml: Tailscale Ingress, no pull secret, no public IP
# → https://kubernetes-test-app.beefalo-fort.ts.net/   (tailnet only)
make deploy-gke-pending-demo # Pending pods → the cluster autoscaler adds nodes (make watch-nodes-gke)
make gke-down                # delete the cluster when done (a Cloud Scheduler job also deletes it nightly at 01:00)
```

## Layout

- `app/`: application code only (producer, worker, tools, tests). It knows nothing about Docker or Kubernetes.
- `deploy/`: packaging and deployment. `docker/` holds the Dockerfiles (built from the repo root), `compose/` holds the Compose file, `helm/` holds the `kubernetes-test-app/` chart plus per-environment `values/` files, `scripts/` holds `install-keda.sh`, `install-tailscale-operator.sh` and `logs-worker.sh`, and `terraform/` holds the GCP infrastructure (`bootstrap/`, `project/`, `gke/`).
- `Makefile`: `test`, `build`, `push`, `up`, `down`; for k3s + KEDA `install-keda`, `deploy`, `deploy-pending-demo`, `deploy-scaledobject`, `undeploy`, `watch`, `logs-worker`; the same with a `-gke` suffix for GKE, plus `install-tailscale-operator`. Every k8s target names its kube context (`K3S_CONTEXT`, `GKE_CONTEXT`).
- `docs/`: one explanation per stage, plus [`cheatsheet.md`](docs/cheatsheet.md) (kubectl + Helm commands, grouped by the question they answer).
