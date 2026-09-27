# Stage 3b: autoscaling with KEDA

In 3a you chose the number of workers: `worker.replicas`, or `kubectl scale`. In this stage **KEDA** makes that decision from the number of jobs waiting in Redis. It starts workers when jobs arrive, stops at a maximum, and goes back to **zero** when the queue is empty.

This is exactly what `app/tools/local_scaler.py` did in Stage 1:

| Stage 1 local scaler | Stage 3b KEDA ScaledJob |
|---|---|
| every 2 s: `LLEN jobs:queue` | every 5 s (`pollingInterval`): the `redis` scaler runs `LLEN jobs:queue` |
| `running` = its own live subprocesses | `running` / `pending` = its own Jobs that haven't finished |
| starts `min(queue, max - running)` new `worker.py` processes with `WORKER_MODE=once` | starts new Kubernetes **Jobs**, each one pod running the worker image with `WORKER_MODE=once` |
| `--max 5` | `maxReplicaCount: 10` |
| a subprocess exits → slot free | a Job completes → slot free |

**No application code changed in this stage.** `once` mode, exit code 0 on an empty queue, and SIGTERM requeueing were all built in Stage 1 for this moment. The images are still `0.2.0`.

## What was built

```
                     keda namespace (installed once per cluster)
                     ┌────────────────────────────────────────────┐
                     │ keda-operator ── every 5 s: LLEN jobs:queue ─┼──────┐
                     │   │ creates Jobs (ScaledJob mode)              │      │
                     │   │ or drives an HPA (ScaledObject mode)       │      │
                     │ keda-operator-metrics-apiserver (for the HPA)  │      │
                     │ keda-admission-webhooks (validates our YAML)   │      │
                     └───┼────────────────────────────────────────────┘      │
                         ▼                                                   ▼
 namespace kubernetes-test-app                                     Service redis ─▶ redis pod
   ScaledJob "worker" ──creates──▶ Job worker-xxxxx ─▶ pod (once) ─▶ LPOP one job, sleep, exit 0
                                   Job worker-yyyyy ─▶ pod (once) ─▶ ...
   (or: ScaledObject "worker" ─▶ HPA keda-hpa-worker ─▶ Deployment "worker" (loop) 0..10 replicas)
```

| File | What it is |
|---|---|
| `deploy/scripts/install-keda.sh` | **New.** Installs KEDA **2.21.0** with its official Helm chart into namespace `keda`. Idempotent. |
| `deploy/scripts/logs-worker.sh` | **New.** Follows the logs of all worker pods, including ones that start later. |
| `templates/worker-scaledjob.yaml` | **New.** KEDA `ScaledJob` (only when `worker.mode: scaledjob`). |
| `templates/worker-scaledobject.yaml` | **New.** KEDA `ScaledObject` for the worker Deployment (only when `worker.mode: scaledobject`). |
| `deploy/helm/values/pending-demo.yaml` | **New.** 1 CPU per worker, max 20: more workers than the nodes can fit. |
| `deploy/helm/values/scaledobject.yaml` | **New.** `worker.mode: scaledobject`, for the comparison. |
| `templates/_helpers.tpl` | **Changed.** Adds `workerPodSpec` (shared worker pod), `redisTrigger` (shared KEDA trigger) and `validateWorkerMode`. |
| `templates/worker-deployment.yaml` | **Changed.** Rendered only in `deployment`/`scaledobject` mode. It sets `replicas` only in `deployment` mode. |
| `values.yaml` | **Changed.** New `worker.mode`, `worker.keda`, `worker.scaledJob`, `worker.scaledObject`. |
| `values/k3s.yaml` | **Changed.** `worker.mode: scaledjob`, and `replicas: 8` removed. |
| `Chart.yaml` | **Changed.** Chart `version` 0.1.0 → 0.2.0 (the templates changed; `appVersion` did not). |
| `templates/NOTES.txt` | **Changed.** Shows the worker mode. |
| `Makefile` | **Changed.** `install-keda`, `deploy`, `deploy-pending-demo`, `deploy-scaledobject`, `undeploy`, `watch`, `logs-worker`. |

Versions: **KEDA 2.21.0** (released 2026-09-23). KEDA 2.21 supports Kubernetes 1.34–1.36. 2.20 only goes up to 1.35, so for k3s v1.36 it had to be 2.21. Helm v4.3.0, kubectl v1.36.

## Concepts

### What KEDA is

KEDA (Kubernetes Event-Driven Autoscaling) is not part of Kubernetes. It's an add-on made of three Deployments in the `keda` namespace:

- **keda-operator**: the brain. It watches `ScaledJob`/`ScaledObject` objects, asks each **scaler** (here `redis`) for a number, and acts on it: it creates Jobs itself, or it creates and feeds an HPA.
- **keda-operator-metrics-apiserver**: makes KEDA's numbers available through the Kubernetes *external metrics* API, which is where an HPA reads them.
- **keda-admission-webhooks**: checks our ScaledJob/ScaledObject when we apply them (e.g. two ScaledObjects targeting the same Deployment are rejected).

It also brings **CRDs** (CustomResourceDefinitions). These teach the API server new object kinds: `ScaledJob`, `ScaledObject`, `TriggerAuthentication`, … Before `make install-keda`, `kubectl get scaledjob` answers *"the server doesn't have a resource type"*.

### Why our chart doesn't bundle KEDA or its CRDs

- **CRDs are cluster-wide and shared.** There's one `ScaledJob` definition per cluster, used by every app in every namespace. If our chart installed it, a second app's chart would collide with it. And `helm uninstall kubernetes-test-app` could remove a definition that other apps' ScaledJobs depend on (deleting a CRD deletes **every** object of that kind).
- **Helm handles CRDs carefully on purpose.** CRDs in a chart's `crds/` folder are installed once and never upgraded or deleted, exactly because of that blast radius.
- **Different owners, different lifecycles.** KEDA is cluster infrastructure (like Traefik or CoreDNS), installed and upgraded by whoever runs the cluster. Our app just *uses* it. In Stage 4, the same script installs it on GKE.

That's why the chart renders KEDA objects only when `worker.mode` asks for them. With the default `deployment` mode, the chart installs on a cluster without KEDA.

### `worker.mode`: three ways to run workers

| mode | objects | worker | who sets the count |
|---|---|---|---|
| `deployment` (chart default) | Deployment | `loop` | you (`worker.replicas`) |
| `scaledjob` (k3s.yaml) | ScaledJob → Jobs → pods | `once` | KEDA creates one Job per waiting job |
| `scaledobject` | ScaledObject → HPA → Deployment | `loop` | KEDA + HPA set `replicas` 0..10 |

The templates use one simple `if` each (`{{- if eq .Values.worker.mode "scaledjob" }}`). A misspelt mode fails the render with a clear message instead of silently deploying no workers:

```
Error: execution error at (kubernetes-test-app/templates/worker-deployment.yaml:1:4): worker.mode must be deployment, scaledjob or scaledobject (got "bogus")
```

**Should `scaledjob` be the chart default?** No. A chart default should work anywhere the chart can be installed, and `scaledjob` fails on any cluster without KEDA (`no matches for kind "ScaledJob"`). Whether a cluster has KEDA is an environment fact, so it belongs in the environment's values file: `k3s.yaml` now, `gke.yaml` in Stage 4. The same logic kept the Ingress off by default in 3a.

### ScaledJob: one Job per waiting job

A Kubernetes **Job** runs pods until one completes. KEDA's ScaledJob creates plain Jobs from the `jobTargetRef` template. Our settings:

- `restartPolicy: Never` + `backoffLimit: 0`: a pod runs once. If it fails, it isn't retried. Simulated job failures don't fail the pod: the worker requeues the job itself and exits 0 (Stage 1). So a *failed* Job means a real error, like Redis being unreachable, and the retry happens at the queue level: the next poll sees the job and starts a new Job.
- `activeDeadlineSeconds: 600`: a safety net. A pod stuck for 10 minutes is killed.
- `successfulJobsHistoryLimit: 5`, `failedJobsHistoryLimit: 5`: KEDA deletes older finished Jobs (the default is 100). The last few stay around so you can `kubectl logs` them.
- `rollout.strategy: gradual`: when the ScaledJob changes (e.g. `helm upgrade --set config.failRate=0.3` changes the checksum annotation), running Jobs are left to finish and only new Jobs get the new spec. The default rollout **deletes** the running Jobs, and each worker's SIGTERM handler would requeue its job, which is safe but wasteful.

The worker pod is exactly the same container as the Deployment's, because both templates include the new `workerPodSpec` helper. Only `WORKER_MODE` (`once` vs `loop`) and `restartPolicy` (`Never` vs `Always`) differ.

### The scaling strategy: why `accurate`

Each poll, KEDA computes `maxScale = min(ceil(listLength / 1), maxReplicaCount)` and then decides how many **new** Jobs to create. The strategy decides how Jobs that already exist are subtracted:

- **`default`**: `maxScale − running`. This assumes the queue length *includes* in-progress items (like messages locked but not yet deleted from a cloud queue), so each running Job already accounts for one of them.
- **`accurate`**: `if maxScale + running > max: max − running, else: maxScale − pending`. This is for queues whose length **excludes** in-progress items. "Pending" = Jobs created but whose pod isn't running yet.

**Our worker pops (`LPOP`) the job as the first thing it does**, so `jobs:queue` contains only *waiting* jobs, and running ones are already gone from it. That is the `accurate` case (KEDA's docs: *"if the scaler returns queueLength that does not include the number of locked messages"*). A worked example, with max 20, 10 jobs waiting and 5 Jobs running:

| strategy | calculation | new Jobs | result |
|---|---|---|---|
| default | 10 − 5 | 5 | 5 jobs keep waiting: **under-scaling** |
| accurate | 10 + 5 ≤ 20 → 10 − 0 pending | 10 | one worker per waiting job ✔ |

With max 10 instead, both give 5 (10 + 5 > 10 → 10 − 5), and the 10-at-once limit is respected.

**A race to know about** (seen in experiment 2): a pod counts as *running* as soon as its container starts, but the Python worker needs a moment to import, connect and `LPOP`. If a poll lands in that gap, KEDA sees "5 running, 2 still waiting" and starts 2 extra Jobs. Those pods find the list empty, log `no job available` and exit 0 within a few seconds. The extras don't process anything and no job is lost or run twice. It shows up at the start of a burst, and the extra count is at most the number of jobs that hadn't been popped yet. Closing the gap completely would need a readiness signal from the worker ("I have my job") plus KEDA's `pendingPodConditions`, which is more machinery than it's worth here.

### ScaledObject: KEDA drives an HPA

A ScaledObject scales an existing **Deployment**. KEDA creates an HPA (`keda-hpa-worker`) that reads the list length through the metrics API and sets `replicas = ceil(listLength / 1)`, capped at 10. The HPA can't go below 1, so KEDA handles 0 ↔ 1 itself: it activates on the first waiting job, and goes back to 0 after `cooldownPeriod` seconds of an empty list.

**Why the Deployment must not set `replicas` in this mode.** Remember 3a experiment 3: `kubectl scale` took ownership of `.spec.replicas`, and the next `helm upgrade` fought it (a conflict under Helm 4, a silent reset under Helm 3). The HPA is just another writer of the same field. If the chart kept `replicas: 1`, every deploy would fight KEDA. So in `scaledobject` mode, `worker-deployment.yaml` leaves the field out. Helm 4's server-side apply then gives up its ownership, and the HPA is the only writer.

**The trade-off vs ScaledJob.** The HPA knows *how many* pods, not *which* ones are busy:

- The list excludes running jobs. As soon as 10 workers pop their jobs, the list shrinks and the HPA wants **fewer** pods, while those pods are working. When it scales down, the ReplicaSet picks pods to delete, busy or not. The SIGTERM handler saves the job (requeue), but the work done so far is lost and the job starts over.
- Two settings keep this in check:
  - `scaleDownStabilizationSeconds: 300` (the HPA default): the HPA only scales down to the *highest* recommendation of the last 5 minutes, so a short burst finishes before any pod is removed.
  - `cooldownPeriod: 90`: the list is empty as soon as the **last** job is *popped*, while that job still runs for up to 60 s. With a 30 s cooldown, KEDA would scale to 0 in the middle of it. So the cooldown must exceed the longest job, the same rule as `terminationGracePeriodSeconds`.
- A ScaledJob has none of this: each Job runs its one job to the end, and nothing is ever scaled *down*. A Job simply finishes.

What the ScaledObject does better: no pod start-up per job (a loop worker takes the next job immediately), and far fewer pods and Jobs for a long stream of short jobs.

## Why the existing files changed

- **`_helpers.tpl`**: the worker pod spec moved from `worker-deployment.yaml` into a `workerPodSpec` helper. Otherwise the Deployment and the ScaledJob would each carry the same ~40 lines (security context, Downward API, image, envFrom). They would drift apart the first time one was edited. The helper takes a dict (`ctx`, `workerMode`, `restartPolicy`), in the same style as the 3a label helpers.
- **`worker-deployment.yaml`**: wrapped in an `if` (no Deployment in `scaledjob` mode), and `replicas` only in `deployment` mode (see above). It's otherwise the same Deployment as in 3a. `helm template` in `deployment` mode renders the same pod as before, now with an explicit `restartPolicy: Always` (which was already the default).
- **`k3s.yaml`**: `replicas: 8` was removed, because `scaledjob` mode ignores it and leaving it would suggest it still does something.
- **`Chart.yaml` 0.2.0**: the templates changed. **Side effect you'll see on the first `make deploy`:** the `helm.sh/chart` label is in every pod template, so the chart version bump rolls the producer **and Redis** pods, and the Redis restart empties the queue (emptyDir, no persistence, a non-goal). Deploy when there are no jobs you care about.

## One-time setup

The 3a setup (kubeconfig, Tailscale grant, pull secret) is unchanged. Only KEDA is new:

```bash
make install-keda          # = deploy/scripts/install-keda.sh
kubectl -n keda get pods   # 3 pods Running (the operator may restart once while its certs are created)
kubectl get crd | grep keda.sh
kubectl api-resources --api-group=keda.sh
```

## Deploy

```bash
kubectl config set-context --current --namespace kubernetes-test-app   # (from 3a) the commands below skip -n
make deploy                # helm upgrade --install … -f deploy/helm/values/k3s.yaml  → ScaledJob mode
make watch                 # live: scaledjob, scaledobject, hpa, jobs, pods (Ctrl+C to leave)
make logs-worker           # in another terminal: every worker pod's log, new ones included
```

Extra flags go through `HELM_ARGS`, e.g. `make deploy HELM_ARGS="--set config.failRate=0.3"`. In `make watch`, "No resources found" for the kinds of the *other* mode is normal.

Open the page at `http://gcp-srv-02.beefalo-fort.ts.net/`, or use a port-forward on your Tailscale IP (see 3a). The curl commands below use the ingress:

```bash
P=http://gcp-srv-02.beefalo-fort.ts.net
jobs() { curl -s -X POST $P/api/jobs -H 'Content-Type: application/json' -d "{\"count\": $1, \"duration_seconds\": ${2:-30}}"; echo; }
status() { curl -s $P/api/status | jq '{queue: .queue_length, processing: (.processing|length), completed, failed, dead}'; }
```

## Experiments

Watch `make watch` during each experiment, and relate what you see to the Stage 1 scaler's `queue=7 running=3 max=5 → starting 2` lines.

### 1. Scale to zero

With nothing queued:

```bash
kubectl get scaledjob worker          # READY True, ACTIVE False
kubectl get pods -l app.kubernetes.io/component=worker
```

**Expect:** no running worker pods, and `ACTIVE False` (the trigger is below its activation threshold). Only the last ≤ 5 finished pods (`Completed`) from earlier runs are listed. Stage 1 equivalent: `queue=0 running=0 → nothing to do`.

### 2. Scale up

```bash
jobs 5 20
```

**Expect:** 5 Jobs (5 pods) within about 5–10 s (one `pollingInterval` plus pod start). All 5 run in parallel, complete after ~20 s, and 0 are running afterwards. `status` ends with `completed` +5 and `queue: 0`.

What the smoke test on this cluster actually showed (`kubectl -n keda logs deploy/keda-operator | grep scaleexecutor`):

```
19:47:51 Creating jobs  "Effective number of max jobs": 5     ← 5 waiting, 0 running
19:47:56 Scaling Jobs   "Number of running Jobs": 5
19:47:56 Creating jobs  "Effective number of max jobs": 2     ← the start-up race (see Concepts)
19:48:01 Scaling Jobs   "Number of running Jobs": 7
19:48:06 Scaling Jobs   "Number of running Jobs": 5           ← the 2 extras found nothing, exited 0
```

So you'll see 5 pods doing work and possibly 1–2 short-lived ones (`Completed` after a few seconds, log: `no job available`). There's no systematic under- or over-scaling: 5 waiting jobs got 5 workers, and nothing ran twice. Compare `kubectl get jobs`: the real workers have `DURATION` ~27 s, the extras ~7 s.

### 3. Maximum respected

```bash
jobs 30 20
```

**Expect:** never more than **10** worker pods Running at once (`maxReplicaCount`). As each Job finishes, the next poll starts a new one (`max − running`). All 30 complete in about 3 waves (~1.5–2 min). Stage 1 equivalent: `--max 5`.

Count while it runs: `kubectl get pods -l app.kubernetes.io/component=worker --field-selector=status.phase=Running --no-headers | wc -l`.

### 4. Spreading

During experiment 3:

```bash
kubectl get pods -l app.kubernetes.io/component=worker -o wide --field-selector=status.phase=Running
kubectl get pods -l app.kubernetes.io/component=worker -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort | uniq -c
```

**Expect:** workers on both agents (gcp-srv-03, gcp-srv-04), and probably on gcp-srv-02 as well (the k3s server is untainted). The web page groups processing jobs by host, and it shows the same thing via the Downward API `HOST_NAME`.

### 5. Failures

```bash
make deploy HELM_ARGS="--set config.failRate=0.3"
jobs 20 10
# ...wait until queue and processing are both 0...
status
```

**Expect:** `completed + dead == 20`, `failed` ≥ `dead`, and `queue: 0`, `processing: 0`. A failed attempt is requeued **by the worker**, and the next poll starts a new Job for it, so failures show up as *more Jobs*, not as failed Jobs: `kubectl get jobs` shows them all `Complete`, because the pod exited 0. Only jobs that fail 3 times end up in `jobs:dead` (`kubectl exec deploy/redis -- redis-cli llen jobs:dead`).

Because of `rollout: gradual`, the upgrade didn't touch Jobs that were running. Reset afterwards: `make deploy` (failRate back to 0.0 from the values file).

### 6. Capacity limit

```bash
make deploy-pending-demo      # k3s.yaml + pending-demo.yaml: cpu request "1", max 20
jobs 20 30
kubectl get pods -l app.kubernetes.io/component=worker -o wide
kubectl describe pod <a Pending one> | sed -n '/Events/,$p'
```

**Expect:** KEDA creates up to 20 Jobs (it doesn't know or care whether they fit), but only ~3 pods run: one per node, since each node has 2 CPUs and ~0.7–0.85 already requested (`kubectl describe node gcp-srv-03` → *Allocated resources*). The rest stay **Pending** with an event like:

```
Warning  FailedScheduling  … 0/3 nodes are available: 3 Insufficient cpu. preemption: …
```

As running workers finish, Pending pods get scheduled. The Pending pods are also why the `accurate` formula subtracts `pending`: they will take jobs, so they must not be counted as missing. On fixed VMs this is the ceiling: pods wait, and nothing adds a node. That's what Stage 4's cluster autoscaler on GKE changes. Go back with `make deploy`.

### 7. Interrupted worker

```bash
jobs 3 60
kubectl get pods -l app.kubernetes.io/component=worker        # pick a Running one
kubectl delete pod <pod>                                       # while its job runs
```

**Expect:**
- The pod logs `job … interrupted by shutdown signal, returned to queue` and exits within a second or two (`make logs-worker` shows it).
- The job goes back to **Waiting** on the page, and at the next poll KEDA starts a new Job that picks it up (it runs from the start again).

What happens to the *Job* object whose pod you deleted depends on the Job controller (to verify on your cluster with `kubectl get jobs` and `kubectl describe job <name>`). With `backoffLimit: 0` it's either marked Failed ("BackoffLimitExceeded"), or it counts as complete because the worker exited 0. Either way the work is safe, because the job lives in Redis, not in the Job. This is the same SIGTERM handling as 3a experiment 4. In 3a the *Deployment* replaced the pod. Here nobody replaces it: KEDA simply sees a waiting job again.

### 8. ScaledJob vs ScaledObject

Run experiment 3 in both modes, with `make watch` open.

```bash
make deploy                   # ScaledJob
jobs 30 20                    # note: pod count over time, total time, number of Jobs (kubectl get jobs)

make deploy-scaledobject      # k3s.yaml + scaledobject.yaml
kubectl get scaledobject,hpa  # KEDA created HPA keda-hpa-worker
jobs 30 20
```

Switching modes deletes the ScaledJob (and its finished Jobs) and creates Deployment `worker` + ScaledObject. The Deployment starts with Kubernetes' default of 1 replica, because the chart doesn't set any. KEDA scales it to 0 once the cooldown has passed with an empty list.

**Expect in ScaledObject mode:**
- 0 → 10 pods within a poll or two (KEDA activates 0 → 1, then the HPA goes to 10).
- Loop workers take the next job straight away. There's no pod start per job, so the total time can be a little shorter, and there are 10 pods instead of 30+ Jobs.
- When the queue is nearly drained, the HPA *wants* fewer pods, but the 300 s stabilization window holds 10 until well after all jobs are done. Then KEDA's 90 s cooldown takes it to 0. The scale-down is slow, but nothing is interrupted.

Now make the trade-off visible by removing the protection:

```bash
make deploy-scaledobject HELM_ARGS="--set worker.scaledObject.scaleDownStabilizationSeconds=0"
curl -s -X POST $P/api/jobs -H 'Content-Type: application/json' -d '{"count": 30, "duration_seconds": "random"}'; echo
```

**Expect:** as the list shrinks, the HPA removes pods **while they are working**. `make logs-worker` shows `interrupted by shutdown signal, returned to queue`, and those jobs start over on another pod. Nothing is lost (SIGTERM + grace period, Stage 2/3a), but work is wasted. A ScaledJob never has this problem.

| | ScaledJob | ScaledObject |
|---|---|---|
| unit | one Job per job | long-running Deployment pods |
| scale-down | none: a Job ends when its job ends | HPA deletes pods, busy or not → needs SIGTERM handling, a stabilization window and a long cooldown |
| per-job overhead | a pod start (~seconds) per job | none |
| objects created | many Jobs/pods (history kept: 5) | one HPA, ≤ 10 pods |
| good for | long or uneven jobs, where interrupting is expensive | many short jobs, steady streams |

Go back to the default with `make deploy`.

## Uninstall and cleanup

```bash
make undeploy                  # helm uninstall kubernetes-test-app (the namespace stays, as in 3a)
helm uninstall keda -n keda    # removes KEDA
kubectl get crd | grep keda.sh # ...the CRDs may remain, depending on the chart; remove only if no app uses them:
# kubectl delete crd scaledjobs.keda.sh scaledobjects.keda.sh triggerauthentications.keda.sh \
#   clustertriggerauthentications.keda.sh cloudeventsources.eventing.keda.sh clustercloudeventsources.eventing.keda.sh
kubectl delete namespace keda
```

Deleting a CRD deletes every object of that kind in the whole cluster, which is exactly why our app's chart never owns them. The cloud resources (Artifact Registry, `k3s-puller`) are listed in `docs/stage-3a.md` → *Cleanup*. Nothing in this stage creates billable resources.

## What carries forward

- **Stage 4 (GKE)** runs the same `install-keda.sh` and the same chart with a `gke.yaml` values file that also sets `worker.mode: scaledjob`. Experiment 6 is where GKE differs: Pending pods make the **cluster autoscaler** add nodes, and the nodes are removed after the queue drains.
- Every container still has CPU/memory requests. On GKE, requests are what the cluster autoscaler looks at (and on Autopilot, what you pay for).
