# Stage 3a: k3s with a Helm chart, manual scaling

In Stage 2 the app ran as containers under Compose on one machine. In this stage the **same images** run on a real Kubernetes cluster: self-managed k3s on three GCP VMs. The app is packaged as a **Helm chart**. Scaling is still manual: you pick the number of workers. Stage 3b hands that job to KEDA.

> **New to these files?** [`stage-3a-manual.md`](stage-3a-manual.md) walks through every file of this stage: what it does, why it exists, and what it becomes in the cluster.

Stage 2 already made the app container-ready (env config, stdout logs, SIGTERM as PID 1, health endpoints, no disk writes, numeric non-root UID), and this stage builds on that. **One fix to the Stage 1 worker was still needed.** The first deploy exposed a timing bug that a single machine could never show; see [Change to the Stage 1 worker, and why](#change-to-the-stage-1-worker-and-why).

## What was built

```
 vps-01 (kubectl, helm)                              k3s cluster (GCP dns-chatbot-sb, us-central1-a)
 ─────────────────────                               ────────────────────────────────────────────────
 kubectl/helm ──tailnet──▶ gcp-srv-02:6443 (API)     namespace kubernetes-test-app
 browser ─────tailnet──▶ any node :80 (Traefik) ───▶   Ingress producer ─▶ Service producer ─▶ producer pod
          (or port-forward through the API)                                                      │
                                                        worker pods (N) ──▶ Service redis ──▶ redis pod
                                                        spread over gcp-srv-03 / gcp-srv-04 / gcp-srv-02

 GCP firewall "deny-ingress-tailscale-only" (priority 100) drops everything to the nodes' public IPs.
 Images come from Artifact Registry us-central1-docker.pkg.dev/dns-chatbot-sb/kubernetes-test-app.
```

| File | What it is |
|---|---|
| `deploy/helm/kubernetes-test-app/Chart.yaml` | Chart name, chart `version` (0.1.0), `appVersion`. |
| `deploy/helm/kubernetes-test-app/values.yaml` | The defaults for every setting, each one commented. |
| `deploy/helm/kubernetes-test-app/templates/_helpers.tpl` | Named snippets: labels, selector labels, image name, security contexts, config checksum. |
| `templates/configmap.yaml` | `app-config`: `REDIS_HOST`, `REDIS_PORT`, `QUEUE_NAME`, `FAIL_RATE`, `MAX_ATTEMPTS`. |
| `templates/redis.yaml` | Redis Deployment (emptyDir, `Recreate`) + ClusterIP Service `redis`. |
| `templates/producer.yaml` | Producer Deployment with probes + ClusterIP Service + optional Ingress. |
| `templates/worker-deployment.yaml` | Worker Deployment, `WORKER_MODE=loop`, replicas from values, Downward API. |
| `templates/NOTES.txt` | Printed after every install/upgrade: how to open the page, useful commands. |
| `deploy/helm/kubernetes-test-app/.helmignore` | Files kept out of a packaged chart (standard). |
| `deploy/helm/values/k3s.yaml` | This cluster: registry + tag, pull secret, Traefik ingress on the tailnet name. |
| `.gitignore` (changed) | `*key*.json`, so a service-account key can never be committed by accident. |

Tool versions: **Helm v4.3.0**, **kubectl v1.36.5** (installed in `~/.local/bin` on vps-01), and k3s **v1.36.4+k3s1** on the cluster. kubectl may be at most one minor version away from the server, so 1.36 matches.

## One-time setup

Some of this was already done while building the stage. Each step is listed so you can redo it anywhere.

### 1. Tools on vps-01 (done)

```bash
# kubectl, same minor version as the cluster
KV=$(curl -fsSL https://dl.k8s.io/release/stable-1.36.txt)
curl -fsSLO https://dl.k8s.io/release/$KV/bin/linux/amd64/kubectl
echo "$(curl -fsSL https://dl.k8s.io/release/$KV/bin/linux/amd64/kubectl.sha256)  kubectl" | sha256sum -c
install -m 755 kubectl ~/.local/bin/

# helm 4
curl -fsSLO https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz
curl -fsSL https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz.sha256sum | sha256sum -c
tar xzf helm-v4.3.0-linux-amd64.tar.gz && install -m 755 linux-amd64/helm ~/.local/bin/
```

### 2. kubeconfig (done)

k3s writes an admin kubeconfig on the server at `/etc/rancher/k3s/k3s.yaml`, pointing at `127.0.0.1`. It was copied to `~/.kube/config` (mode 600), with the server address changed to gcp-srv-02's **Tailscale IP**:

```bash
mkdir -p ~/.kube && chmod 700 ~/.kube
ssh gcp-srv-02 'sudo cat /etc/rancher/k3s/k3s.yaml' \
  | sed 's#https://127.0.0.1:6443#https://100.112.126.75:6443#' > ~/.kube/config
chmod 600 ~/.kube/config
```

The API server's TLS certificate already lists `100.112.126.75` among its names (check: `ssh gcp-srv-02 sudo openssl x509 -in /var/lib/rancher/k3s/server/tls/serving-kube-apiserver.crt -noout -ext subjectAltName`), so no `tls-san` change was needed. This file holds **cluster-admin** credentials, so treat it like a password.

### 3. Tailscale policy: let vps-01 reach the cluster (your TODO)

`ssh gcp-srv-02` works, but `kubectl get nodes` times out. The nodes' own firewall accepts everything that arrives on `tailscale0`, so the block is in the **tailnet policy**: vps-01 is allowed to SSH to `tag:k3s` machines, but not to reach 6443 (the API) or 80/443 (Traefik). Add a grant in the Tailscale admin console, or wherever your policy file is managed (the `iac-*` tags suggest it may be in an IaC repo):

```jsonc
"grants": [
  // vps-01 → k3s nodes: Kubernetes API and the Traefik ingress
  { "src": ["100.110.243.10"], "dst": ["tag:k3s"], "ip": ["tcp:6443", "tcp:80", "tcp:443"] },
]
```

You can use a tag instead of vps-01's IP as `src` if you prefer, for example one only vps-01 has. To reach the page from your laptop too, add it (or `autogroup:member`) with `tcp:80`. Then check it:

```bash
kubectl get nodes -o wide     # gcp-srv-02 (control-plane), gcp-srv-03, gcp-srv-04: Ready
```

### 4. Artifact Registry + pull credentials (done)

> **Since Stage 4** the repository, `k3s-puller` and its reader permission are managed by Terraform (`deploy/terraform/project/`, imported, see `docs/stage-4.md`). The commands below are how they were first created. Don't re-run them; change the Terraform code instead. The key (last command) stays outside Terraform, because a key created by Terraform would be stored in its state.

```bash
P=dns-chatbot-sb; R=us-central1; SA=k3s-puller@$P.iam.gserviceaccount.com
gcloud artifacts repositories create kubernetes-test-app --repository-format=docker \
  --location=$R --project=$P --description="Stage 3+ images for kubernetes-test-app"
gcloud iam service-accounts create k3s-puller --project=$P --display-name="k3s image puller"
gcloud artifacts repositories add-iam-policy-binding kubernetes-test-app --location=$R --project=$P \
  --member=serviceAccount:$SA --role=roles/artifactregistry.reader
( umask 077; gcloud iam service-accounts keys create ~/.config/kubernetes-test-app/k3s-puller-key.json \
  --iam-account=$SA --project=$P )
```

- **Same region as the VMs** (`us-central1`), so pulls to the nodes cost no network egress. The images are about 275 MB, which fits in Artifact Registry's 0.5 GB of free storage.
- **Least privilege.** The service account can only *read*, and only *this* repository. The binding is on the repo, not the project.
- **The key is a long-lived secret.** It lives outside the repo (mode 600) and `*key*.json` is git-ignored. Rotate it by creating a new key, updating the Secret, and deleting the old key (`gcloud iam service-accounts keys list/delete`).

Push the images (the tag is the git SHA; Stage 2 explains why unique tags matter):

```bash
gcloud auth print-access-token | podman login -u oauth2accesstoken --password-stdin us-central1-docker.pkg.dev
make build push REGISTRY=us-central1-docker.pkg.dev/dns-chatbot-sb/kubernetes-test-app TAG=$(git rev-parse --short HEAD)
gcloud artifacts docker images list us-central1-docker.pkg.dev/dns-chatbot-sb/kubernetes-test-app --include-tags
```

Two tags are pushed. `1f98a56` was the first deploy. `0.2.0` has the worker fix below, and `k3s.yaml` uses it. `0.2.0` is a version rather than a SHA because the fix was built before it was committed. Any unique tag that is never reused works. After changing app code, push a new tag and update `image.tag` in `k3s.yaml` (or pass `--set image.tag=…`).

### 5. The pull secret in the namespace (your TODO, needs step 3)

```bash
kubectl create namespace kubernetes-test-app
kubectl -n kubernetes-test-app create secret docker-registry artifact-registry \
  --docker-server=us-central1-docker.pkg.dev \
  --docker-username=_json_key \
  --docker-password="$(cat ~/.config/kubernetes-test-app/k3s-puller-key.json)"
```

`_json_key` is the special user name Artifact Registry accepts for "the password is a service-account key file". The chart adds `imagePullSecrets: [{name: artifact-registry}]` to the producer and worker pods (from `k3s.yaml`). The kubelet then passes these credentials to containerd when it pulls. Redis comes from Docker Hub and needs no secret.

**Why doesn't k3s just use the VM's service account?** On GKE, the node's container runtime is set up to get tokens from the GCE metadata server. Plain k3s's containerd knows nothing about GCP, so it has to be given credentials. The options are:

| Option | How | Trade-off |
|---|---|---|
| **imagePullSecret** (used here) | A `docker-registry` Secret in the namespace, referenced by the pods | Per namespace and visible in Kubernetes. The chart stays in control. |
| **k3s `registries.yaml`** | `/etc/rancher/k3s/registries.yaml` on **every** node, with `configs."us-central1-docker.pkg.dev".auth` `{username: _json_key, password: <key json>}`, then restart k3s/k3s-agent | Cluster-wide with no Secret needed, but it's node configuration outside Kubernetes, and each new node needs it. |
| **Public registry** | Push to a public repo (for example `ghcr.io/<you>` set to public, or Docker Hub) and set `image.registry` to it with `imagePullSecrets: []` | No credentials at all, but anyone can pull your images. |
| Short-lived token | `print-access-token` as the password | Expires in about an hour, so not suitable for a cluster. |

The chart supports all of these, because only the values change.

## Only reachable over Tailscale

This cluster must never serve the app to the public internet. Several layers make sure of that:

1. **GCP firewall.** The VMs have public IPs (for example gcp-srv-02 has `34.58.195.228`), but the rule `deny-ingress-tailscale-only` (priority **100**, *deny all* from `0.0.0.0/0`, target tag `tailscale-only` on gcp-srv-02/03/04) overrides the default allow rules (priority 65534). Nothing reaches the public IPs: not SSH, not 6443, and not Traefik's 80/443. Tailscale still works because it connects *outbound* (and via DERP relays).
2. **The chart only creates `ClusterIP` Services.** A ClusterIP is a virtual IP that exists only inside the cluster. The chart never creates `NodePort` (which opens a port on every node) or `LoadBalancer` Services. Redis in particular is reachable only by pods.
3. **The Ingress goes through Traefik.** k3s runs Traefik as a `LoadBalancer` Service, implemented by k3s's ServiceLB, which listens on ports 80/443 of **every** node on all interfaces. So "who can reach the page" comes down to "who can reach node port 80": over the tailnet that's whoever the Tailscale policy allows, and from the internet it's nobody (layer 1).
4. **The Ingress `host` is not a security boundary.** `host: gcp-srv-02.beefalo-fort.ts.net` only tells Traefik which requests to route here, based on the HTTP `Host` header, which any client can set. The protection comes from layer 1 and the Tailscale policy.

Check it yourself:

```bash
curl -s --max-time 5 http://34.58.195.228/ || echo "public IP: blocked (good)"
curl -s http://gcp-srv-02.beefalo-fort.ts.net/healthz      # {"status":"ok"} over the tailnet
```

If you ever remove the firewall rule, or add a node without the `tailscale-only` tag, Traefik would become public. Stronger setups bind k3s/ServiceLB to the Tailscale interface only, or use the Tailscale Kubernetes operator. Both are out of scope here.

## Change to the Stage 1 worker, and why

**The symptom.** After the first `helm upgrade --install`, the producer and Redis were `Running`, but the worker showed `0/1 CrashLoopBackOff` with dozens of restarts:

```bash
kubectl get pods -o wide                     # worker-…  0/1  CrashLoopBackOff  71  gcp-srv-04
kubectl describe pod -l app.kubernetes.io/component=worker   # Last State: Terminated, Exit Code: 1
kubectl logs deploy/worker --previous        # log of the crashed container, not the new one
# [worker-…] waiting for jobs on jobs:queue
# ...
# redis.exceptions.TimeoutError: Timeout reading from socket
```

**Ruling out the cluster.** `kubectl get endpointslices` showed Redis behind its Service. From the gcp-srv-04 node, a `PING` to the Redis pod IP and to the Service IP both answered `+PONG`. So DNS, the Service and the cross-node pod network all worked.

**The cause: two clocks set to the same 5 seconds.**
- The worker asks Redis `BLPOP jobs:queue 5`: "give me a job, or wait up to 5 s".
- redis-py 8 *also* stops waiting for **any** reply after 5 s by default (`socket_timeout=5`). The Stage 1 code never set it.

With an empty queue, Redis replies "no job" only **after** its 5 s are up, and the reply then has to travel back. Timing that reply from gcp-srv-04 gave **5.02–5.07 s every time**: the Redis pod is on gcp-srv-03, and pod traffic between nodes goes through flannel's VXLAN tunnel over Tailscale. The client had already given up at 5.00 s. redis-py retried, timed out again, and finally raised `TimeoutError`. The worker only caught `ConnectionError`, so it died with exit 1 about once a minute, and the kubelet kept restarting it (`CrashLoopBackOff`). In Stages 1 and 2 everything ran on one machine with microsecond round trips, so the reply almost always won the race.

The same failure was reproduced locally before the fix: Redis on 127.0.0.1 plus a small proxy adding 50 ms to every reply. The old worker crashed after about a minute with the same traceback, and the fixed one kept running.

**The fix** in `app/worker/worker.py`:

```python
BLPOP_TIMEOUT = 5
SOCKET_TIMEOUT = BLPOP_TIMEOUT + 5     # always longer than the BLPOP wait

def connect(cfg):
    return redis.Redis(..., socket_timeout=SOCKET_TIMEOUT)
...
except (redis.ConnectionError, redis.TimeoutError) as exc:   # was: ConnectionError only
    log(cfg, f"cannot reach Redis ...")
    return 1
```

- The client now waits 10 s for a reply to a command that takes 5 s by design, which leaves plenty of room for network delay.
- A Redis that really doesn't answer is still a *real error*: one log line and exit 1, as agreed in Stage 1. Before, it was an unhandled traceback.
- Two new tests pin this down: `test_socket_timeout_is_longer_than_blpop_timeout` and `test_main_returns_1_when_redis_times_out`.

The producer didn't need a change. It never blocks, and Stage 2 already gave it explicit 2 s timeouts for fast failure.

**The lesson.** A cluster adds real network latency between components that used to share a machine. Every timeout that waits on a remote answer must be longer than the time the remote side is *allowed* to take, plus the network. Looking at the **previous** container's log (`--previous`) is usually the fastest way to find out why a pod keeps restarting.

**Rolling out the fix:** build and push a new tag (`0.2.0`), set it in `k3s.yaml`, then `helm upgrade --install $H`. The new image tag changes the pod template, so the Deployment starts a new ReplicaSet. `kubectl get pods -w` shows the new worker becoming `1/1 Running` and the crash-looping pod going away. The producer rolls too, because both images share `image.tag`. Its image content is identical, since its code didn't change.

## Helm concepts

**Chart, values, release.**
- A **chart** is a package of templated Kubernetes YAML (`deploy/helm/kubernetes-test-app/`).
- **Values** are the inputs: `values.yaml` holds the defaults, and you override them with `-f file.yaml` and `--set key=value`.
- A **release** is one installation of a chart into a namespace, with a name (`kubernetes-test-app`) and numbered **revisions**. Every `upgrade` or `rollback` adds a revision. Helm stores each revision as a Secret in the release's namespace (`kubectl -n kubernetes-test-app get secrets -l owner=helm`), which is how `helm history` and `rollback` work.

**How values flow into templates.** Templates are Go templates. `{{ .Values.worker.replicas }}` inserts a value, and `.Chart`, `.Release` (name, namespace, revision) and `.Template` are also available. When Helm renders, it merges in this order, and later entries win:

```
values.yaml (chart defaults)  →  -f deploy/helm/values/k3s.yaml  →  -f more.yaml  →  --set a.b=c
```

That's why `k3s.yaml` is short: it contains only what differs on this cluster. Stage 3b and 4 add more files layered on top (`-f k3s.yaml -f pending-demo.yaml`).

**Watch out:** `--set` isn't remembered. The next `helm upgrade` without that `--set` goes back to what the files say. (`--reuse-values` exists, but it hides what's really deployed; prefer editing a values file for lasting changes.)

**`_helpers.tpl` and named templates.** Files starting with `_` produce no output. They define snippets with `{{ define "name" }}`, which other templates insert with `{{ include "name" arg | nindent 4 }}` (`nindent` = newline + indent, so the YAML lines up). Ours:

- `kubernetes-test-app.selectorLabels`: `app.kubernetes.io/name`, `instance`, `component`. These are the labels a Deployment uses to find its pods and a Service uses to find endpoints. **A Deployment's `selector` is immutable**: if it ever changed, `helm upgrade` would fail and the Deployment would have to be deleted. So only labels that never change are used here.
- `kubernetes-test-app.labels`: the selector labels plus `part-of`, `version`, `managed-by: Helm` and `helm.sh/chart`. These may change between releases, so they go on resources and pod templates but never into selectors.
- `kubernetes-test-app.image`: builds `<registry>/<repository>:<tag>`, with the tag defaulting to `appVersion`.
- `podSecurityContext` / `containerSecurityContext`: the same hardening for every pod.
- `configChecksum`: see below.

**Deliberately simple templates.** The only logic is `if producer.ingress.enabled`, a few `with` blocks (render something only when a value is set) and `default` for the image tag. Worker `replicas` is rendered **without** `default`, because `default` treats `0` as empty, and `worker.replicas=0` must really mean zero.

**The `checksum/config` pattern.** Pods read environment variables from a ConfigMap **only when a container starts**. If you change `FAIL_RATE` and `helm upgrade`, the ConfigMap changes, but running pods keep the old value, and the Deployment doesn't notice because its pod template didn't change. The fix: the pod template carries the annotation `checksum/config: <sha256 of the rendered configmap.yaml>`. A different config gives a different hash, which is a different pod template, so the Deployment rolls out new pods. Redis deliberately does **not** have this annotation: it doesn't read the ConfigMap, and restarting it would wipe the queue.

**Why the namespace is not a chart template.** The chart deploys *into* a namespace. It doesn't own one.
1. Helm stores the release records *in* the namespace, so a chart that creates its own namespace has a chicken-and-egg problem.
2. `helm uninstall` would delete the namespace and with it **everything inside**, including things Helm didn't create, like our `artifact-registry` Secret.
3. The same chart can be installed in any namespace with `-n`.

`--create-namespace` creates it if it's missing. Here we already created it for the pull secret, so the flag is a harmless no-op, but it keeps the install command self-contained.

**Resource names.** Resources are named after their component (`redis`, `producer`, `worker`, `app-config`) instead of the Helm habit `<release>-<component>`. That keeps commands short (`kubectl scale deployment worker`) and keeps `REDIS_HOST=redis` identical to Compose. The trade-off is **one release per namespace**. A second release in the same namespace would collide, so use another namespace for that.

**Inspect before installing.** `helm lint` checks the chart for errors. `helm template` renders the YAML locally without touching the cluster. `helm upgrade --install … --dry-run=server` also asks the API server to validate. `helm get manifest`/`helm get values` show what a release actually contains.

**Helm 4 and server-side apply (SSA).** Helm 3 computed patches on the client (a "three-way merge"). **Helm 4 uses Kubernetes server-side apply for new releases**: it sends the full desired object, and the API server tracks which *field manager* owns each field (`kubectl get deploy worker -o yaml --show-managed-fields`). If another manager (for example `kubectl scale`) changed a field Helm sets, Helm 4 **refuses with a conflict** instead of silently overwriting it, unless you pass `--force-conflicts`. Experiment 3 shows this. `--server-side=auto` (the default) keeps whichever mode the release was first installed with.

## Kubernetes concepts in the chart

- **Deployment → ReplicaSet → Pods.** A Deployment declares "N pods like this template". It creates a ReplicaSet that keeps exactly N running, replacing any that die or get deleted (self-healing, experiment 4). Changing the template (new image, new checksum) creates a new ReplicaSet and shifts pods over gradually (a rolling update).
- **Redis uses `strategy: Recreate`.** A rolling update would briefly run the old *and* the new Redis behind one Service, which would split the queue between two independent databases. Recreate stops the old pod first. With `emptyDir` storage, any Redis restart starts empty. Persistence is a non-goal of this project.
- **ConfigMap + `envFrom`.** Every key becomes an env var. The app code reads the same variables it read locally and in Compose.
- **Downward API.** `WORKER_ID` comes from `metadata.name` (the pod name, e.g. `worker-7d9c…-x2k4p`) and `HOST_NAME` from `spec.nodeName` (e.g. `gcp-srv-03`). The status page's host column now shows **which node** ran each job. In Compose it showed the container ID.
- **Probes.**
  - Producer readiness `/readyz`: the pod is removed from the Service while Redis is down.
  - Producer liveness `/healthz`: the container is restarted only if the process hangs.
  - Redis: `redis-cli ping` exec probes.
  - Workers have none, because they serve no HTTP. A crash (exit 1 when Redis is unreachable) is restarted by the kubelet, with growing delays (`CrashLoopBackOff`).
- **`terminationGracePeriodSeconds: 90`.** On delete or scale-down, Kubernetes sends SIGTERM, waits up to 90 s, then sends SIGKILL. That is longer than the longest job (60 s), but our worker doesn't need it: it requeues the job and exits at once (Stage 1/2).
- **Resources.**
  - *Requests* are what the scheduler reserves on a node. A pod only lands where its requests fit.
  - *Limits* are the ceiling: CPU is throttled and memory over the limit is OOM-killed.
  - Worker: 250m CPU / 64Mi for both, so each worker costs exactly a quarter of a CPU. That makes capacity easy to reason about in 3b.
  - Producer: 50m/96Mi requests, 500m/192Mi limits. Redis: 50m/64Mi requests, 250m/128Mi limits.
- **Security context** (every pod):
  - `runAsNonRoot` + a numeric `runAsUser` (10001 for our images, 999 for Redis's own user). Starting Redis as 999 makes its entrypoint skip the root-only `chown` + `gosu` step.
  - `allowPrivilegeEscalation: false`, `capabilities.drop: [ALL]`, `privileged: false`, `seccompProfile: RuntimeDefault`.
  - `readOnlyRootFilesystem: true`. Our apps write nothing, and Redis writes only to its `/data` emptyDir. All three images were tested locally with `podman run --read-only --cap-drop ALL --security-opt no-new-privileges --user …`.
- **`enableServiceLinks: false`.** By default Kubernetes injects Docker-link-style variables for every Service in the namespace. For our Service `redis` that includes **`REDIS_PORT=tcp://10.43.x.y:6379`**, exactly the name our app reads as a port number. The ConfigMap's value would win anyway, but turning links off removes the trap and the clutter.
- **Service DNS.** Inside the namespace, `redis` resolves to the Redis Service's ClusterIP (the full name is `redis.kubernetes-test-app.svc.cluster.local`). As noted in Stage 2, the name keeps resolving even while no Redis pod is ready, and connections simply fail fast.

## Install

```bash
cd ~/kubernetes-learning/kubernetes-test-app
helm upgrade --install kubernetes-test-app deploy/helm/kubernetes-test-app \
  -n kubernetes-test-app --create-namespace -f deploy/helm/values/k3s.yaml
kubectl -n kubernetes-test-app get pods -o wide -w
```

`upgrade --install` is idempotent: it installs the first time and upgrades after that, so you can always run the same command.

**Open the page** (either works; both are tailnet-only):

- Ingress: `http://gcp-srv-02.beefalo-fort.ts.net/` (needs the tcp:80 grant from setup step 3).
- Port-forward, the simplest way and one that needs no Ingress at all:

  ```bash
  kubectl -n kubernetes-test-app port-forward --address $(tailscale ip -4) svc/producer 8080:8000
  # → http://100.110.243.10:8080/     (ss -ltn shows 100.110.243.10:8080, never 0.0.0.0)
  ```

  kubectl opens a tunnel through the API server to the pod. The host rule applies: always pass `--address $(tailscale ip -4)`. Without it, kubectl binds 127.0.0.1, which is also safe but only usable on vps-01 itself.

Tip: set a default namespace so you can drop `-n`: `kubectl config set-context --current --namespace kubernetes-test-app`. The commands below assume you did, and use `H` for the helm arguments:

```bash
H="kubernetes-test-app deploy/helm/kubernetes-test-app -n kubernetes-test-app -f deploy/helm/values/k3s.yaml"
```

**If pods don't start:** `kubectl describe pod <name>` → *Events*. `ErrImagePull`/`ImagePullBackOff` with `403`/`unauthorized` means the pull secret is missing or wrong (setup step 5). `manifest unknown` means the tag isn't pushed.

## Experiments

### 1. Inspect before installing

```bash
helm lint deploy/helm/kubernetes-test-app -f deploy/helm/values/k3s.yaml
helm template $H | less                                   # the exact YAML that would be applied
helm template $H -s templates/worker-deployment.yaml      # just one template
helm template $H --set worker.replicas=4 -s templates/worker-deployment.yaml | grep replicas
helm template $H --set config.failRate=0.3 | grep -E 'FAIL_RATE|checksum'
helm template $H --set producer.ingress.enabled=false | grep -c 'kind: Ingress'   # 0
```

**Expect:**
- lint: `1 chart(s) linted, 0 chart(s) failed`. The only message is `[INFO] icon is recommended`, which is informational, not a warning.
- `replicas: 4` in the rendered worker.
- A different `checksum/config` hash when `failRate` changes.
- No Ingress when it's disabled.

Nothing has touched the cluster yet: `helm template` runs entirely locally.

### 2. Deploy

```bash
helm upgrade --install $H --create-namespace   # prints NOTES.txt
helm list                                      # release, revision 1, status deployed
helm status kubernetes-test-app                # same, plus the notes again
kubectl get all                                # deployments, replicasets, pods, services
kubectl get pods -o wide                        # which node each pod is on
```

Open the page and submit 5 jobs of 10 s. **Expect:** with 1 worker they run one after another. The host column shows a node name like `gcp-srv-03`, and the worker is shown by its pod name. `kubectl logs -f deploy/worker` shows the same lines as in Stage 1.

### 3. Manual scaling and drift

```bash
kubectl scale deployment worker --replicas=4
kubectl get pods -o wide -l app.kubernetes.io/component=worker
```

Submit 12 jobs of 20 s. **Expect:**
- 4 jobs processing at a time, on different hosts.
- The scheduler spreads the pods over the nodes (it prefers nodes with more free room). Workers may also land on gcp-srv-02, because k3s's server node accepts normal pods unless it is tainted.

Now run the normal upgrade, with the values file still saying `replicas: 1`:

```bash
helm upgrade --install $H
```

**Expect (Helm 4, server-side apply), to verify on your cluster:** the upgrade **fails with a conflict**, approximately:

```
Error: UPGRADE FAILED: ... Apply failed with 1 conflict: conflict with "kubectl" with subresource "scale" using apps/v1: .spec.replicas
```

`kubectl scale` made the `kubectl` field manager the owner of `.spec.replicas` (check with `kubectl get deploy worker -o yaml --show-managed-fields | grep -B2 -A8 scale`). Helm 4 won't take it back silently. You now have two choices:

```bash
helm upgrade --install $H --force-conflicts                  # Helm takes ownership: back to 1 worker
helm upgrade --install $H --set worker.replicas=4            # or make the desired state say 4
```

With Helm 3, the same `helm upgrade` silently snapped replicas back to 1. Either way, the lesson is the same:
- **Helm owns the desired state**, and a hand edit with kubectl is *drift* that the next deploy either overwrites or trips over.
- The lasting way to scale is the values: edit `worker.replicas` in a values file (or use `--set`, remembering it isn't sticky).
- This is also why, in 3b, the **autoscaler** must own the replica count and the chart must *not* set `replicas` at all. Otherwise every deploy would fight KEDA.

### 4. Self-healing

With a few workers running (`--set worker.replicas=3`), submit 3 jobs of 60 s. While they run:

```bash
kubectl get pods -l app.kubernetes.io/component=worker
kubectl delete pod <one-worker-pod>
kubectl logs <that-pod>              # in another terminal, before it disappears (or use -f)
kubectl get pods -l app.kubernetes.io/component=worker -w
```

**Expect:**
- The deleted pod logs `job … interrupted by shutdown signal, returned to queue` and `received SIGTERM, exiting`, and it terminates within a second or two, not the full 90 s.
- The dashboard shows the job back in **Waiting**.
- The ReplicaSet immediately creates a replacement pod (a new name, maybe on another node), which picks the job up again.

Nobody asked for the replacement: the Deployment only knows "3 should exist". A deleted pod is a lost replica, and it gets replaced.

### 5. Scale to zero

```bash
helm upgrade --install $H --set worker.replicas=0
```

Submit 5 jobs. **Expect:** no worker pods and the jobs stay in **Waiting**. Nothing is lost, because the queue lives in Redis. Bring workers back (`--set worker.replicas=2`) and the jobs drain. In 3b, KEDA does exactly this on its own: 0 workers while the queue is empty, more when jobs arrive.

### 6. Release history and rollback

```bash
helm upgrade --install $H --set config.failRate=0.3
kubectl get pods -w                  # producer + worker pods are replaced; redis is NOT
kubectl get configmap app-config -o yaml | grep FAIL_RATE
helm history kubernetes-test-app
```

**Expect:**
- The producer and worker pods roll: a new ReplicaSet with a new `checksum/config`. Compare `kubectl get pod <worker> -o yaml | grep checksum` before and after.
- Redis keeps running, and the counters survive.
- Submit 20 jobs of 5 s. Completed + Dead-lettered ends at 20.
- `helm history` lists every revision with its description.

Roll back to the revision before the failure-rate change:

```bash
helm rollback kubernetes-test-app <REVISION>
helm history kubernetes-test-app    # a NEW revision "Rollback to N"; history is never rewritten
helm get values kubernetes-test-app # the user-supplied values of the current revision
```

The pods roll again, because the checksum changed back, and `FAIL_RATE` is `0.0`.

### 7. Uninstall

```bash
helm uninstall kubernetes-test-app -n kubernetes-test-app
kubectl get all,configmap,ingress,secret -n kubernetes-test-app
kubectl get namespace kubernetes-test-app
```

**Expect:**
- **Removed:** everything the chart rendered (Deployments and their pods, Services, Ingress, ConfigMap) and the release history (the `sh.helm.release.v1.*` Secrets). The Redis data goes with its pod.
- **Kept:** the **namespace** (Helm didn't create it as part of the chart) and the **`artifact-registry` Secret** (created by hand, so Helm never knew about it). The images stay in Artifact Registry.

A reinstall with the same command works right away. To remove everything, including the Secret: `kubectl delete namespace kubernetes-test-app`.

## Cleanup (cloud resources)

The Artifact Registry repo is used again in 3b and 4, so keep it until you're done with the project. At the end:

```bash
P=dns-chatbot-sb
gcloud iam service-accounts keys list --iam-account=k3s-puller@$P.iam.gserviceaccount.com
gcloud iam service-accounts delete k3s-puller@$P.iam.gserviceaccount.com --project=$P   # also invalidates its keys
gcloud artifacts repositories delete kubernetes-test-app --location=us-central1 --project=$P
rm ~/.config/kubernetes-test-app/k3s-puller-key.json
```

## What carries forward

- **Stage 3b** adds `worker.mode` (`deployment` / `scaledjob` / `scaledobject`) to this chart, plus KEDA templates that render only when selected. In `scaledobject` mode the worker Deployment must stop setting `replicas`, for the reason shown in experiment 3.
- The worker's 250m CPU request becomes the unit that fills the nodes up in 3b's capacity experiment (`pending-demo.yaml`).
- **Stage 4** reuses the templates unchanged with a `gke.yaml` values file: a different registry path, no pull secret (GKE nodes authenticate to Artifact Registry themselves), and a different ingress class.
