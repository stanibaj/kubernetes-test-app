# Stage 3a manual: every file, what it does, and why it exists

[`stage-3a.md`](stage-3a.md) is the *how-to* (setup, install, experiments). This manual is the *what and why*. It walks through every file created in Stage 3a, one at a time. For each file you get:

- **Why it exists**, meaning what would break or be missing without it.
- **What it does**, section by section.
- **What it becomes in the cluster**, and the command to see that live object.

Read the first two sections once. After that, the file sections can be read in any order.

---

## 1. The big picture: from files to running pods

You never send `values.yaml` or `producer.yaml` to Kubernetes directly. There are two separate machines at work.

**Helm** runs on vps-01. It is a text generator plus a record keeper:

```
Chart.yaml ─┐
values.yaml ─┼─▶ merge ─▶ values ─┐
k3s.yaml ───┘   (-f, --set)       ├─▶ render the Go templates ─▶ plain Kubernetes YAML
templates/*.yaml, _helpers.tpl ───┘                                  │
                                                                     ▼
                                    send each object to the Kubernetes API server
                                    + save "revision N" as a Secret in the namespace
```

**Kubernetes** runs on the cluster. It is a set of *controllers*: loops that keep comparing "what the objects ask for" (desired state) with "what exists" (actual state), and fix the difference:

```
Deployment "worker" (replicas: 1)
   │  Deployment controller: "I need a ReplicaSet for this pod template"
   ▼
ReplicaSet "worker-d54cb6d9b" (replicas: 1)
   │  ReplicaSet controller: "I need 1 pod; there are 0 → create one"
   ▼
Pod "worker-d54cb6d9b-z499v"
   │  Scheduler: "gcp-srv-04 has 250m CPU / 64Mi free → put it there"
   ▼
kubelet on gcp-srv-04: pull the image (with the pull secret), start the container,
                       restart it if it exits, report status back
```

So a template file → an object in the API → controllers that create more objects → a container on a node. Helm is only involved in the first step. Once the objects exist, Kubernetes keeps things running on its own. If you turned vps-01 off, the app would keep running.

What this stage created, file by file, and what each file became in the cluster:

| File in the repo | Becomes in the cluster | See it with |
|---|---|---|
| `Chart.yaml` | the `helm.sh/chart` label, the release's chart version | `helm list` |
| `values.yaml` + `values/k3s.yaml` | nothing by themselves: they fill in the templates | `helm get values kubernetes-test-app --all` |
| `templates/_helpers.tpl` | nothing by itself: snippets used by the others | — |
| `templates/configmap.yaml` | ConfigMap `app-config` | `kubectl get cm app-config -o yaml` |
| `templates/redis.yaml` | Deployment + Service `redis` | `kubectl get deploy,svc redis` |
| `templates/producer.yaml` | Deployment + Service + Ingress `producer` | `kubectl get deploy,svc,ingress producer` |
| `templates/worker-deployment.yaml` | Deployment `worker` | `kubectl get deploy worker` |
| `templates/NOTES.txt` | text printed after install/upgrade | `helm get notes kubernetes-test-app` |
| `.helmignore` | nothing (only matters for `helm package`) | — |
| *(Helm itself)* | Secret `sh.helm.release.v1.kubernetes-test-app.v1` | `kubectl get secret -l owner=helm` |

The commands below assume the default namespace is set: `kubectl config set-context --current --namespace kubernetes-test-app`.

---

## 2. A 5-minute primer on Helm template syntax

Everything inside `{{ … }}` is a Go template expression. Everything outside is copied to the output as-is. That's why templates look like YAML with holes in them.

| Syntax | Meaning | Example from our chart |
|---|---|---|
| `{{ .Values.x.y }}` | insert a value from the merged values | `replicas: {{ .Values.worker.replicas }}` → `replicas: 1` |
| `.Release`, `.Chart`, `.Template` | built-in objects: release name/namespace/revision, Chart.yaml fields, the current template's path | `{{ .Release.Name }}` → `kubernetes-test-app` |
| `\|` (pipe) | pass the left side as the **last** argument to the function on the right | `{{ .Values.config.failRate \| quote }}` → `"0.0"` |
| `quote` | wrap in double quotes (forces a YAML string) | ConfigMap values must be strings |
| `default X` | use X if the value is empty (`""`, `0`, `false`, null) | `.Values.image.tag \| default .Chart.AppVersion` |
| `toYaml` | turn a values subtree into YAML text | `{{ toYaml .Values.worker.resources }}` |
| `nindent N` | newline, then indent every line by N spaces | makes inserted YAML line up at the right depth |
| `{{-` and `-}}` | trim the whitespace (including newlines) before / after the tag | stops template tags from leaving blank lines |
| `{{ if … }} … {{ end }}` | render the block only if the condition is true | the Ingress, only when `producer.ingress.enabled` |
| `{{ with X }} … {{ end }}` | render the block only if X is non-empty, and inside it `.` **is** X | `imagePullSecrets` only when the list isn't empty |
| `{{ define "name" }}` | declare a named snippet (only in `_helpers.tpl`) | `kubernetes-test-app.labels` |
| `{{ include "name" ARG }}` | render a named snippet with ARG as its `.` | `include "kubernetes-test-app.labels" (dict …)` |
| `dict "k1" v1 "k2" v2` | build a small map, to pass several arguments to a snippet | `(dict "ctx" $ "component" "worker")` |
| `.` vs `$` | `.` is "the current thing" (changes inside `with`); `$` always means the top level | we pass `$` as `ctx` so snippets can reach `.Values` |

The best way to learn it is to change something and render:

```bash
helm template kubernetes-test-app deploy/helm/kubernetes-test-app -f deploy/helm/values/k3s.yaml \
  -s templates/worker-deployment.yaml --set worker.replicas=7
```

`-s` shows just one template. Nothing is sent to the cluster.

---

## 3. `deploy/helm/kubernetes-test-app/Chart.yaml`

**Why it exists.** It is the one file that makes a directory a Helm chart. Without it, `helm` refuses the directory.

**What it does.**

```yaml
apiVersion: v2          # chart format for Helm 3 and 4 (v1 was Helm 2)
name: kubernetes-test-app
type: application       # vs "library": a chart of only helpers, which installs nothing
version: 0.1.0          # version of the CHART, i.e. of these templates
appVersion: "dev"       # version of the APP inside
```

There are two versions, and they mean different things:
- **`version`** is the packaging version. Bump it when you change templates. It appears as `CHART kubernetes-test-app-0.1.0` in `helm list` and in the `helm.sh/chart` label.
- **`appVersion`** is informational, plus our templates use it as the **fallback image tag** when `image.tag` is empty. `helm list` shows `APP VERSION dev` because `k3s.yaml` sets `image.tag` directly and doesn't change `appVersion`.

**Try it.** `helm show chart deploy/helm/kubernetes-test-app`.

---

## 4. `deploy/helm/kubernetes-test-app/values.yaml`

**Why it exists.** Templates must never hard-code anything that differs between environments: the registry, the image tag, how many workers, whether there's an Ingress. Those become *values*. `values.yaml` is the chart's **complete list of knobs with safe defaults**. It is also the chart's documentation: every key is commented, so you can learn what the chart can do just by reading this file.

**What it does.** Each top-level key groups the settings for one part:

| Key | Used by | What it controls |
|---|---|---|
| `image.registry`, `image.tag`, `image.pullPolicy` | producer + worker | where our images come from. The default `localhost` matches Stage 2's local Podman builds. |
| `imagePullSecrets` | producer + worker pods | registry credentials to use (empty by default) |
| `config.*` | `configmap.yaml` | app settings: `QUEUE_NAME`, `FAIL_RATE`, `MAX_ATTEMPTS` |
| `redis.image`, `redis.resources` | `redis.yaml` | the Redis image (from Docker Hub, so a full reference) and its CPU/memory |
| `producer.*` | `producer.yaml` | replicas, Service port, Ingress on/off/class/host, resources |
| `worker.*` | `worker-deployment.yaml` | replicas, grace period, resources |

The defaults are chosen so that `helm template` works with **no** extra files. That's how you can inspect the chart before any environment exists.

**How it combines with other files.** Helm merges maps key by key, and later sources win:

```
values.yaml  ◀── overridden by ── -f values/k3s.yaml  ◀── overridden by ── --set worker.replicas=4
```

`k3s.yaml` sets `image.tag`, but `image.pullPolicy` still comes from `values.yaml`, because the merge is per key, not per section. Lists are the exception: a list in a later file **replaces** the whole list.

**Try it.** `helm get values kubernetes-test-app` shows only what you supplied (k3s.yaml plus any `--set`). Add `--all` to see the fully merged result that the templates actually used.

---

## 5. `deploy/helm/values/k3s.yaml`

**Why it exists.** It holds everything that is true **only for this cluster**, so that the chart itself stays usable anywhere. Stage 4 adds a `gke.yaml` next to it, and the templates don't change.

**What it does.** It overrides exactly four things:

| Setting | Value here | Why this cluster needs it |
|---|---|---|
| `image.registry` | `us-central1-docker.pkg.dev/dns-chatbot-sb/kubernetes-test-app` | the nodes can't see vps-01's local `localhost/...` images. They pull from Artifact Registry, in the same region as the VMs, so pulls are free. |
| `image.tag` | `0.2.0` | a unique, never-reused tag for the pushed images (`1f98a56` was the first deploy). A unique tag guarantees every node runs the same code. |
| `imagePullSecrets` | `[{name: artifact-registry}]` | the registry is private, and k3s's containerd has no GCP credentials of its own |
| `producer.ingress` | enabled, `className: traefik`, host `gcp-srv-02.beefalo-fort.ts.net` | k3s ships Traefik as its ingress controller, and the host is the server's **tailnet** name, reachable only over Tailscale |

Stage 3b will layer more files on top: `-f k3s.yaml -f pending-demo.yaml`.

---

## 6. `templates/_helpers.tpl`

**Why it exists.** Four templates need the same labels, image naming and security settings. Without helpers, you'd copy those blocks four times, and sooner or later one copy would drift from the others. For labels, drift is a real bug: a Service whose selector doesn't match its pods' labels silently routes to nothing.

The file name starts with `_`, so Helm renders **nothing** from it directly. It only defines named snippets.

**What each snippet does.**

**`kubernetes-test-app.chart`** gives `kubernetes-test-app-0.1.0`, the value of the `helm.sh/chart` label. The `replace "+" "_"` and `trunc 63` are there because label values may not contain `+` and are limited to 63 characters.

**`kubernetes-test-app.selectorLabels`**: the three labels that *identify* a component:

```yaml
app.kubernetes.io/name: worker
app.kubernetes.io/instance: kubernetes-test-app   # the release name
app.kubernetes.io/component: worker
```

Two kinds of objects use these to *find* pods:
- A **Deployment's `spec.selector`**: "the pods I own are the ones with these labels". This field is **immutable**. If a later chart version changed it, `helm upgrade` would fail, and you'd have to delete and recreate the Deployment.
- A **Service's `spec.selector`**: "send traffic to pods with these labels".

That's why only labels that **never change** belong here. A version label in a selector would break the next upgrade.

**`kubernetes-test-app.labels`**: the selector labels **plus** descriptive ones:

```yaml
app.kubernetes.io/part-of: kubernetes-test-app   # which bigger system this belongs to
app.kubernetes.io/version: "0.2.0"             # changes every release: fine here, never in a selector
app.kubernetes.io/managed-by: Helm               # who manages this object
helm.sh/chart: kubernetes-test-app-0.1.0
```

These are the standard [recommended labels](https://kubernetes.io/docs/concepts/overview/working-with-objects/common-labels/). Tools and humans use them to filter, for example `kubectl get pods -l app.kubernetes.io/part-of=kubernetes-test-app`.

**Why the `dict "ctx" $ "component" "worker"` argument?** A snippet gets exactly **one** argument. These snippets need two things: the top-level context (for `.Release.Name` and `.Values`) and a component name. So the caller packs both into a small map, and the snippet reads `.ctx.Release.Name` and `.component`.

**`kubernetes-test-app.image`** builds `<registry>/<repository>:<tag>` in one place, falling back to `appVersion` when the tag is empty.

**`kubernetes-test-app.podSecurityContext`** takes a user ID (10001 for our images, 999 for Redis):

```yaml
runAsNonRoot: true        # the kubelet refuses to start the container if it would run as UID 0
runAsUser: 10001          # run as this numeric user...
runAsGroup: 10001         # ...and group
fsGroup: 10001            # mounted volumes (Redis's /data) become writable by this group
seccompProfile:
  type: RuntimeDefault    # the container runtime's default syscall filter blocks rarely-needed, risky syscalls
```

**`kubernetes-test-app.containerSecurityContext`**:

```yaml
allowPrivilegeEscalation: false  # a process can't gain more privileges than it started with (e.g. via setuid)
readOnlyRootFilesystem: true     # the container's filesystem is read-only: an attacker can't drop files
privileged: false                # no access to the host's devices
capabilities:
  drop: ["ALL"]                  # none of Linux's root "superpowers" (binding low ports, changing file owners, ...)
```

Together these mean that even if someone exploited the app, they'd be a nobody user in a read-only box. It all works only because Stage 2 made the images run as a numeric non-root user and write nothing to disk.

**`kubernetes-test-app.configChecksum`**:

```yaml
checksum/config: {{ include (print .Template.BasePath "/configmap.yaml") . | sha256sum }}
```

It renders `configmap.yaml` again and hashes the result. The problem this solves: env vars from a ConfigMap are read **only when a container starts**. If `FAIL_RATE` changes, the ConfigMap object updates, but the running pods keep the old value, and the Deployment has no reason to replace them, because its pod template didn't change. With the hash in the pod template as an annotation, a config change **is** a template change, so the Deployment rolls out new pods. See experiment 6.

---

## 7. `templates/configmap.yaml` → ConfigMap `app-config`

**Why it exists.** The app reads everything from environment variables (Stage 1's rule). A **ConfigMap** is Kubernetes' object for non-secret configuration. Keeping the settings in one object, instead of repeating `env:` entries in each Deployment, means the producer and the workers can't disagree about, say, the queue name.

**What it does.**

```yaml
data:
  REDIS_HOST: "redis"      # the Redis Service's DNS name (section 8)
  REDIS_PORT: "6379"
  QUEUE_NAME: {{ .Values.config.queueName | quote }}
  FAIL_RATE: {{ .Values.config.failRate | quote }}
  MAX_ATTEMPTS: {{ .Values.config.maxAttempts | quote }}
```

The keys are exactly the env var names the Python code reads. The pods use `envFrom: configMapRef: app-config`, which turns every key into an env var. ConfigMap values must be strings, hence `quote`: without it, `MAX_ATTEMPTS: 3` would be a YAML number and the API server would reject the object.

`REDIS_HOST: "redis"` is hard-coded rather than a value because it is the name of a Service **this chart** creates. It isn't an environment choice.

**Live:** `kubectl get cm app-config -o yaml`, and `kubectl exec deploy/producer -- env | grep -E 'REDIS|QUEUE|FAIL'` to see it arrive inside a container.

---

## 8. `templates/redis.yaml` → Deployment + Service `redis`

**Why it exists.** The queue needs a Redis server inside the cluster. In Compose that was a service with `image: redis:7`. In Kubernetes it takes **two objects**: a Deployment that *runs* it and a Service that makes it *findable*.

### The Deployment

```yaml
spec:
  replicas: 1
  strategy:
    type: Recreate
```

**Why `Recreate`?** The default strategy is `RollingUpdate`: start the new pod, wait until it's ready, then stop the old one. That's right for stateless apps, but for our Redis it would briefly mean **two separate Redis databases** behind one Service: the old one full of jobs and the new one empty. The Service would split connections between them. `Recreate` stops the old pod first. There's a short gap, but the queue is never split.

```yaml
  selector:
    matchLabels: {name: redis, instance: kubernetes-test-app, component: redis}
  template:
    metadata:
      labels: {…same three, plus the descriptive ones…}
```

The **selector** must match the **template's labels**. This is how the Deployment (through its ReplicaSet) recognizes "my pods". The Deployment controller also adds a `pod-template-hash` label to each ReplicaSet and its pods, which is where names like `redis-b4f4577cd-j4lfk` come from.

```yaml
    spec:
      enableServiceLinks: false
```

By default Kubernetes injects variables for every Service in the namespace into every container: `REDIS_SERVICE_HOST`, `REDIS_PORT=tcp://10.43.209.189:6379`, and so on. That last one collides with the name our app uses for the port number. The ConfigMap's value would win, but turning links off removes the trap entirely. We use DNS names instead, which is the modern way.

```yaml
      securityContext: {runAsUser: 999, …}
```

999 is the `redis` user inside the official image. The image's startup script normally starts as root, `chown`s `/data`, and then switches to `redis`. Starting directly as 999 skips that root-only step, so `runAsNonRoot` can be on for Redis too.

```yaml
      containers:
        - name: redis
          image: docker.io/library/redis:7
          args: ["redis-server", "--save", "", "--appendonly", "no"]
```

`args` replaces the image's default command arguments. `--save ""` turns off snapshots and `--appendonly no` turns off the write log, so Redis never tries to write to disk. Persistence is a non-goal.

```yaml
          readinessProbe:  { exec: { command: ["redis-cli", "ping"] }, periodSeconds: 5 }
          livenessProbe:   { exec: { command: ["redis-cli", "ping"] }, periodSeconds: 10, failureThreshold: 3 }
```

Probes are questions the kubelet asks the container over and over:
- **Readiness** asks "should this pod receive traffic?" If it says no, the pod is removed from the Service's endpoints until it recovers.
- **Liveness** asks "is it stuck?" After 3 failures in a row, the kubelet restarts the container.

Redis has no HTTP endpoint, so these run `redis-cli ping` inside the container and treat exit code 0 as success.

```yaml
          resources: {requests: {cpu: 50m, memory: 64Mi}, limits: {cpu: 250m, memory: 128Mi}}
```

- **Requests** are what the **scheduler** reserves for the pod on a node. A pod only goes to a node with that much unreserved room. `50m` = 50 millicores = 5% of one CPU.
- **Limits** are the ceiling while running. Above the CPU limit the container is slowed down (throttled). Above the memory limit it is killed (`OOMKilled`) and restarted.

```yaml
          volumeMounts: [{name: data, mountPath: /data}]
      volumes: [{name: data, emptyDir: {}}]
```

An **emptyDir** is a scratch directory created when the pod starts and **deleted when the pod goes away**. Redis's working directory must be writable, and the root filesystem is read-only, so this gives it one writable place. It also makes the non-persistence explicit: a new Redis pod starts empty.

### The Service

```yaml
kind: Service
metadata: {name: redis}
spec:
  type: ClusterIP
  selector: {name: redis, instance: kubernetes-test-app, component: redis}
  ports: [{name: redis, port: 6379, targetPort: redis}]
```

Pods come and go, and each new one gets a new IP (`10.42.x.y`). A **Service** gives a group of pods a **stable virtual IP** (`10.43.209.189`) and a **DNS name** (`redis`, or in full `redis.kubernetes-test-app.svc.cluster.local`). It is how `REDIS_HOST=redis` works, just like the Compose service name did.
- `selector` decides which pods are behind it. Kubernetes keeps an **EndpointSlice** listing their IPs (`kubectl get endpointslices`).
- `port: 6379` is the port on the Service IP. `targetPort: redis` is the container port with that *name*, so the numbers are defined in one place.
- `type: ClusterIP` means the IP exists **only inside the cluster**. Nothing outside, not even the nodes' Tailscale IPs, can reach Redis.

**Live:**

```bash
kubectl get deploy,rs,pods,svc,endpointslices -l app.kubernetes.io/component=redis -o wide
kubectl exec deploy/redis -- redis-cli llen jobs:queue
```

---

## 9. `templates/producer.yaml` → Deployment + Service + Ingress `producer`

**Why it exists.** It runs the web page and API, gives it a stable in-cluster address, and optionally exposes it to browsers.

### The Deployment

The new parts compared with Redis:

```yaml
  template:
    metadata:
      annotations:
        checksum/config: fba2ac55…     # from _helpers.tpl: config change → new pods
    spec:
      imagePullSecrets: [{name: artifact-registry}]
```

`imagePullSecrets` points the kubelet at the Secret holding the Artifact Registry credentials (the service-account key). The kubelet hands them to containerd when it pulls the image. The template uses `with`, so if the values list is empty, this whole block disappears.

```yaml
      containers:
        - name: producer
          image: us-central1-docker.pkg.dev/.../kubernetes-test-app-producer:0.2.0
          imagePullPolicy: IfNotPresent
          envFrom: [{configMapRef: {name: app-config}}]
          ports: [{name: http, containerPort: 8000}]
```

- `IfNotPresent` means pull only if the node doesn't already have this exact tag. That's safe *because* tags are unique commit SHAs.
- `envFrom` gives the container all ConfigMap keys as env vars.
- `HOST=0.0.0.0` isn't here: it's baked into the image (Stage 2). It means all interfaces **of the pod**, which is required so the Service can reach it. It has nothing to do with vps-01's host rule.

```yaml
          readinessProbe: {httpGet: {path: /readyz, port: http}, periodSeconds: 5, timeoutSeconds: 3}
          livenessProbe:  {httpGet: {path: /healthz, port: http}, periodSeconds: 10, failureThreshold: 3}
```

These are the two endpoints Stage 2 added, now actually used:
- `/readyz` fails when Redis is unreachable, and the pod is taken out of the Service. The Ingress then answers 503 instead of sending you to a broken page.
- `/healthz` only fails if the Python process itself hangs, which leads to a restart.

`timeoutSeconds: 3` is there because the producer's Redis client gives up after about 2 s. The probe must wait a little longer than that, or it would count "Redis slow" as "producer dead".

### The Service

It's the same idea as Redis's: a ClusterIP `10.43.75.32` and DNS name `producer`, on port 8000. **Both the Ingress and `kubectl port-forward` go through it.**

### The Ingress (only if `producer.ingress.enabled`)

```yaml
{{- if .Values.producer.ingress.enabled }}
kind: Ingress
spec:
  ingressClassName: traefik
  rules:
    - host: "gcp-srv-02.beefalo-fort.ts.net"
      http:
        paths:
          - path: /
            pathType: Prefix
            backend: {service: {name: producer, port: {name: http}}}
{{- end }}
```

An **Ingress** is a *routing rule for HTTP*: "requests for this host and path go to this Service". By itself it does nothing. An **ingress controller** reads Ingress objects and does the actual routing. On k3s that's **Traefik** (namespace `kube-system`), which is what `ingressClassName: traefik` picks.

How a request reaches the page:

```
browser (on the tailnet)
  → gcp-srv-02.beefalo-fort.ts.net:80   (a node's Tailscale IP)
  → Traefik's LoadBalancer Service, implemented by k3s ServiceLB on every node
     (kubectl -n kube-system get svc traefik: EXTERNAL-IP = the 3 nodes' Tailscale IPs)
  → a Traefik pod: "Host gcp-srv-02… path / → Service producer"
  → Service producer (10.43.75.32:8000)
  → a ready producer pod (10.42.1.4:8000)
```

The Ingress's `ADDRESS` column (`kubectl get ingress`) shows those same three node IPs.

Why only standard Ingress fields and no Traefik-specific `IngressRoute` objects? So that the same template works on GKE in Stage 4, where only `className` and `host` change, in `gke.yaml`.

**Live:**

```bash
kubectl get deploy,svc,ingress producer -o wide
kubectl describe ingress producer             # rules and backend endpoints
curl http://gcp-srv-02.beefalo-fort.ts.net/readyz
```

---

## 10. `templates/worker-deployment.yaml` → Deployment `worker`

**Why it exists.** It runs the workers. This is the file the whole project is about. In 3a, *you* set the replica count. In 3b, KEDA will.

**What's special compared with the others:**

```yaml
spec:
  replicas: {{ .Values.worker.replicas }}     # deliberately no "| default 1"
```

`default` treats `0` as empty, so `--set worker.replicas=0` would silently turn into 1. Without `default`, 0 really means 0 (experiment 5).

```yaml
      terminationGracePeriodSeconds: 90
```

What happens when a pod is deleted, scaled down, or replaced during a rollout:
1. The pod is marked *Terminating* and removed from any Service.
2. The kubelet sends **SIGTERM** to the container's PID 1 (our Python worker).
3. It waits up to **90 s**.
4. If the process is still running, it sends **SIGKILL**, which can't be caught.

Our worker handles SIGTERM by pushing its job back to the queue and exiting at once, so it never needs the full 90 s. The spec requires the grace period to be longer than the longest job (60 s) anyway, for safety.

```yaml
          env:
            - name: WORKER_MODE
              value: loop
            - name: WORKER_ID
              valueFrom: {fieldRef: {fieldPath: metadata.name}}     # e.g. worker-d54cb6d9b-z499v
            - name: HOST_NAME
              valueFrom: {fieldRef: {fieldPath: spec.nodeName}}     # e.g. gcp-srv-04
```

- `WORKER_MODE=loop` is set here, not in the ConfigMap, because it's a property of *how this Deployment runs the worker*. 3b's ScaledJob will run the same image with `once`.
- The other two use the **Downward API**: the pod asks Kubernetes about *itself*. The pod name is only known once the pod is created, and the node only once the scheduler has placed it, so you couldn't write these into a values file. That's why the dashboard's host column shows node names now, where Compose showed container IDs.

There are **no probes** on the worker. It serves no HTTP, and "alive" is already expressed by the process running. If it exits with an error, the kubelet restarts it with growing pauses (10 s, 20 s, 40 s … up to 5 min). That is **`CrashLoopBackOff`**: not a special failure, just "it keeps exiting, so I'm waiting longer between restarts".

```yaml
          resources: {requests: {cpu: 250m, memory: 64Mi}, limits: {cpu: 250m, memory: 64Mi}}
```

Requests equal limits, so each worker costs **exactly** a quarter of a CPU on its node. That makes capacity easy to calculate: in 3b's capacity experiment, you'll fill the nodes on purpose.

**Live:**

```bash
kubectl get deploy,rs,pods -l app.kubernetes.io/component=worker -o wide
kubectl logs -f deploy/worker
kubectl describe pod -l app.kubernetes.io/component=worker   # Events at the bottom explain restarts
```

---

## 11. `templates/NOTES.txt`

**Why it exists.** It is the chart's "what now?" message. Helm renders it like a template and prints it after every `install`/`upgrade`, so you don't have to remember how to open the app.

**What it does.** It prints:
- the release, namespace and revision, and the exact image references (a quick check that the right tag was deployed);
- the Ingress URL (only when enabled);
- the port-forward command with `--address "$(tailscale ip -4)"`, per the host rule;
- a few everyday commands.

Nothing in it is sent to the cluster. **Try it:** `helm get notes kubernetes-test-app`.

---

## 12. `deploy/helm/kubernetes-test-app/.helmignore`

**Why it exists.** `helm package` turns a chart directory into a `.tgz` to share or publish. `.helmignore` lists files to leave out: editor backups, `.git`, IDE folders. It's the chart's version of `.dockerignore`. It's the standard file that `helm create` generates. It doesn't affect `helm install` from a directory in any visible way here, but a well-formed chart has one.

---

## 13. Changed files: `.gitignore`, `README.md`, `CLAUDE.md`

- **`.gitignore`** now has `*key*.json`, so a service-account key can never be committed by accident, even if someone copies it into the repo. The real key lives in `~/.config/kubernetes-test-app/`, outside the repo.
- **`README.md`** has the 3a row in the stage table, a 3a quick start, and `helm/` in the layout description.
- **`CLAUDE.md`** records the new facts for future sessions: the stage status, the tool versions, the cluster and registry names, and the Tailscale-only rule.

---

## 14. Things that are *not* in the repo (and why)

Some of this stage lives outside git on purpose: it is either **secret** or **belongs to the environment**, not the app.

| Thing | Where | Why it's not in the repo |
|---|---|---|
| kubeconfig | `~/.kube/config` on vps-01 | cluster-admin credentials |
| service-account key | `~/.config/kubernetes-test-app/k3s-puller-key.json` | a long-lived credential |
| Secret `artifact-registry` | the namespace (created with `kubectl create secret`) | contains the key. A values file would put credentials into git and into Helm's release history. |
| namespace `kubernetes-test-app` | the cluster (`kubectl create namespace` / `--create-namespace`) | Helm stores the release *inside* it, and `helm uninstall` must not delete things Helm didn't create (like the Secret) |
| Artifact Registry repo, `k3s-puller` service account | GCP project `dns-chatbot-sb` | cloud infrastructure, created once with `gcloud` (commands in stage-3a.md) |
| Helm release records | Secrets `sh.helm.release.v1.kubernetes-test-app.vN` | Helm's own bookkeeping: `helm history`/`rollback` read them |
| Tailscale grant, GCP firewall rule | the tailnet policy / GCP | network policy for the whole environment, not this app |

### How kubectl on vps-01 reaches the cluster

`~/.kube/config` has three parts:

```yaml
clusters:   # WHERE:  server: https://100.112.126.75:6443  + the cluster CA, to verify the server's certificate
users:      # WHO:    a client certificate + key signed by the cluster CA → cluster-admin
contexts:   # a name for "this cluster as this user"; current-context picks which one kubectl uses
```

It is a copy of the k3s server's `/etc/rancher/k3s/k3s.yaml`, with `127.0.0.1` replaced by gcp-srv-02's Tailscale IP. kubectl opens a TLS connection to port 6443 over the tailnet and authenticates with the client certificate. There is no ssh and no tunnel. `helm` uses the same file.

---

## 15. Reading a live problem with these files in mind

The first deploy of this stage is a good worked example. `kubectl get pods` showed:

```
producer-84c5887f8c-gbmfc   1/1   Running            0     gcp-srv-03
redis-b4f4577cd-j4lfk       1/1   Running            0     gcp-srv-03
worker-d54cb6d9b-z499v      0/1   CrashLoopBackOff   71    gcp-srv-04
```

Each file we walked through tells you where to look:
- **worker-deployment.yaml** has no probes, so `0/1` plus restarts means the *process* keeps exiting, and `CrashLoopBackOff` is the kubelet's growing restart delay.
- `kubectl describe pod` → *Last State: Terminated, Exit Code: 1*. Exit code 1 is the worker's "real error" code (Stage 1), so this isn't a Kubernetes failure.
- `kubectl logs deploy/worker --previous` (the log of the *previous*, crashed container) → `redis.exceptions.TimeoutError: Timeout reading from socket`.
- **redis.yaml** / the Service: `kubectl get endpointslices` shows Redis has an endpoint, and a `PING` from the gcp-srv-04 node to the Redis pod and Service IPs gets `+PONG`. So DNS, the Service and the cross-node network all work.

The cause is in the app, not the chart. redis-py 8's default socket read timeout is 5 s, the same as the worker's `BLPOP` timeout. With an empty queue, Redis answers "nothing yet" at exactly 5 s. Through the pod network, which here runs over Tailscale between nodes, that reply arrives a few milliseconds too late. On localhost (Stages 1 and 2) it always won the race. The fix, now applied in image `0.2.0`, is in `app/worker/worker.py`: the client's read timeout (10 s) is longer than the BLPOP timeout (5 s), and a Redis timeout is handled as a real error (exit 1 with one log line). The full story is in [stage-3a.md → Change to the Stage 1 worker](stage-3a.md#change-to-the-stage-1-worker-and-why).
