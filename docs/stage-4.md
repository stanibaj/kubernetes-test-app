# Stage 4: GKE, reachable only over Tailscale

> **⚠️ Cost warning: this stage costs real money while the cluster exists.**
> All GCP resources are Terraform code under `deploy/terraform/`, and **you** run every `terraform apply` (the plan is printed first and needs a `yes`). Delete the cluster when you're done ([Teardown](#teardown)). There is also a [nightly safety net](#safety-net-the-nightly-delete) that deletes it at 01:00.
> Rough prices for `us-central1` (check <https://cloud.google.com/kubernetes-engine/pricing> and <https://cloud.google.com/compute/vm-instance-pricing>):
>
> | What | Price | Notes |
> |---|---|---|
> | GKE cluster management fee | $0.10/hour | The GKE free tier credit ($74.40/month per billing account) covers **one zonal** cluster, which is why we create a zonal one (`--zone`, not `--region`). |
> | Nodes: e2-standard-2 **Spot** | about $0.02–0.03/hour each (on-demand is about $0.067) | 1 node most of the time, up to 4 during the autoscaling experiment. |
> | Node boot disks: 30 GB pd-standard | about $1.20/month each (prorated per hour) | The GKE default is 100 GB pd-balanced, about $10/month per node, so we set it smaller. |
> | Artifact Registry | free under 0.5 GB | Same images as Stage 3, same region: pulls cost nothing. |
> | Cloud Scheduler (the nightly delete) | free | 3 jobs per billing account are free. |
> | Terraform state bucket | a few cents/month at most | A few small, versioned JSON objects. |
>
> An afternoon of experiments costs well under $1. Forgetting a 4-node cluster for a month would cost about $60–90.

Stage 3 ran on three VMs you manage yourself, with a fixed number of nodes. In the capacity experiment (3b #6), workers stayed **Pending** because nothing could add a node. On GKE, Google runs the control plane, and the **cluster autoscaler** adds nodes when pods don't fit and removes them when they are idle. That is the main thing to see in this stage.

The second requirement: **the app must be reachable only over Tailscale, never from the internet.** On k3s that came from a GCP firewall rule in front of Traefik. On GKE we use the **Tailscale Kubernetes operator**.

**No application code changed. The chart changed a little** (see [Why the existing files changed](#why-the-existing-files-changed)). The images are still `0.2.0`.

## What was built

```
 your devices on the tailnet                              GKE cluster kta-gke (us-central1-a)
 (vps-01, laptop)                     ┌──────────────────────────────────────────────────────────────┐
        │                              │ namespace tailscale                                          │
        │  https://kubernetes-test-app │   operator (tag:k8s-operator) ── watches Ingresses           │
        │  .<tailnet>.ts.net           │   ts-producer-xxxxx-0 (proxy pod, tag:k8s) ─┐                  │
        └───── WireGuard (tailnet) ────┼──▶ a tailnet device, no public IP          │ HTTP             │
                                       │                                            ▼                  │
  internet ──╳ (nothing listens:       │ namespace kubernetes-test-app   Service producer (ClusterIP) │
   no load balancer, no NodePort,      │   producer ─▶ redis ◀─ worker Jobs (KEDA ScaledJob)          │
   no external IP)                     │ namespace keda: keda-operator (same as k3s)                  │
                                       └──────────────────────────────────────────────────────────────┘
                                          nodes: e2-standard-2 Spot, autoscaling 1..4
```

| File | What it is |
|---|---|
| `deploy/helm/values/gke.yaml` | **New.** Values for GKE, used *instead of* `k3s.yaml`. |
| `deploy/scripts/install-tailscale-operator.sh` | **New.** Installs the Tailscale operator **1.102.4** with its official Helm chart into namespace `tailscale`. Idempotent. |
| `templates/producer.yaml`, `values.yaml` | **Changed.** New `producer.ingress.tls` (standard Ingress TLS, empty by default). |
| `templates/redis.yaml` | **Changed.** Pod annotation `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"`. |
| `templates/NOTES.txt` | **Changed.** Prints the `https://….ts.net/` address for a Tailscale Ingress. |
| `Chart.yaml` | **Changed.** Chart version 0.2.0 → 0.3.0. |
| `deploy/scripts/install-keda.sh`, `logs-worker.sh` | **Changed.** They accept an optional `KUBE_CONTEXT`. |
| `Makefile` | **Changed.** Every k8s target names its cluster (`--kube-context`). New `-gke` targets, and the Terraform targets `tf-bootstrap`, `tf-plan`, `tf-apply`, `gke-plan`, `gke-up`, `gke-down`. |
| `deploy/terraform/bootstrap/` | **New.** The Terraform state bucket. |
| `deploy/terraform/project/` | **New.** All long-lived GCP resources of this project, including the ones from Stage 3 (imported). |
| `deploy/terraform/gke/` | **New.** The GKE cluster and its autoscaling node pool. |

Versions: GKE `REGULAR` channel (default 1.35.8 today; KEDA 2.21 supports 1.34–1.36), KEDA 2.21.0, Tailscale operator 1.102.4, Helm v4.3.0, Terraform 1.16.4 with the google provider `~> 8.4`.

## Concepts

### Why not GKE's own Ingress (or the Gateway API)?

The spec asks for "GKE's ingress class or the Gateway API". Both are built on Google Cloud Load Balancing:

- `ingressClassName: gce` and the Gateway class `gke-l7-global-external-managed` create an **external** HTTP(S) load balancer with a **public IP**. That breaks the Tailscale-only requirement.
- `gce-internal` and `gke-l7-rilb` create an **internal** load balancer, which is reachable only inside the VPC. To reach it from the tailnet you would also need a Tailscale subnet router in the VPC, a proxy-only subnet, and a forwarding rule (about $18/month).

The Tailscale operator is simpler, free, and never public. That is why this stage deviates from the spec here.

### How the Tailscale operator works

The operator is a controller, like KEDA. It runs in its own namespace, watches resources, and creates others. It logs into your tailnet with an **OAuth client** you create, tagged `tag:k8s-operator`. When it sees an Ingress with `ingressClassName: tailscale`, it:

1. creates a StatefulSet with one proxy pod (`ts-producer-…-0`, namespace `tailscale`),
2. registers that pod as a new **device** on your tailnet, tagged `tag:k8s`, named after `spec.tls[0].hosts[0]` → `kubernetes-test-app`,
3. gets a Let's Encrypt certificate for `kubernetes-test-app.<tailnet>.ts.net` and serves HTTPS on it (Tailscale Serve),
4. forwards each request to the `producer` Service's ClusterIP. That traffic stays inside the cluster.

Traffic reaches the proxy only through WireGuard from other tailnet devices, and only those your tailnet policy allows. The proxy has no public listener, and GKE never creates a load balancer for a `tailscale`-class Ingress. It is the same standard `Ingress` template as on k3s. Only the class and the TLS host differ.

Two details of this operator shaped `gke.yaml`:

- **The name comes from `tls`, not `host`.** The operator ignores every rule whose `host` differs from the TLS host (it logs the event `rule with host "…" ignored, unsupported`). So `producer.ingress.host` stays empty, and the name goes in `producer.ingress.tls[0].hosts[0]`. That's why the chart got a `tls` value.
- **No `secretName`.** Other controllers expect a Secret holding the certificate. Tailscale makes the certificate itself.

**What would make it public: Tailscale Funnel.** The annotation `tailscale.com/funnel: "true"` on the Ingress exposes it to the internet through Tailscale's relays. Never add it. The chart has no way to set Ingress annotations. Your tailnet policy also gives the `funnel` nodeAttr only to `autogroup:member` (your own devices) and two specific IPs, not to `tag:k8s`, so the proxies couldn't use Funnel even with the annotation.

### Is anything else public?

- **Services:** `producer` and `redis` are `ClusterIP`, reachable only inside the cluster. No `LoadBalancer` and no `NodePort` Service exists, so GCP creates no forwarding rule.
- **Nodes:** GKE Standard nodes get ephemeral public IPs by default. They are used for **outbound** traffic: pulling `docker.io/library/redis:7`, and Tailscale's connection to its coordination server. The only inbound rules that apply to them are the project-wide `default-allow-ssh`, `default-allow-rdp` and `default-allow-icmp` from `0.0.0.0/0`. Nothing of the app listens on those ports. The one-time setup adds a deny rule for SSH and RDP on the GKE nodes anyway (step 4).

  Why not reuse `deny-ingress-tailscale-only`? It denies **all** protocols from `0.0.0.0/0`, internal VPC traffic included. The k3s nodes survive it because they talk to each other over Tailscale. GKE nodes, pods and the control plane talk over the VPC, so that tag would break the cluster.

  Fully private nodes (`--enable-private-nodes`) would remove the public IPs, but then you need Cloud NAT (about $32/month) for the outbound traffic.
- **The Kubernetes API** (the control plane) has a public endpoint protected by Google authentication, like every GKE cluster. Optional hardening: a `master_authorized_networks_config` block in `gke/main.tf` that allows only vps-01's public IP.

### Image pulls without key files

On k3s the nodes had no Google identity, so we made a key for `k3s-puller` and stored it in a Secret. On GKE **every node runs as a Google service account**. The kubelet asks the metadata server for a token and pulls from Artifact Registry with it. We create a dedicated, minimal node service account `gke-nodes` with:

- `roles/container.defaultNodeServiceAccount`: what a node needs (writing logs and metrics).
- `roles/artifactregistry.reader` **on the `kubernetes-test-app` repository only**.

That's why `gke.yaml` has `imagePullSecrets: []`, and no key file exists anywhere. The node SA gives the nodes an identity. The per-pod equivalent is **Workload Identity Federation for GKE**, where each Kubernetes ServiceAccount maps to its own Google identity, for pods that call Google APIs. Our pods call no Google API, so we don't need it.

### The cluster autoscaler

KEDA decides how many **pods** run. The cluster autoscaler decides how many **nodes** exist. They are separate controllers that never talk to each other:

1. KEDA creates 20 Jobs. The scheduler places the pods that fit and leaves the rest **Pending** with `Insufficient cpu`, exactly as on k3s.
2. **Scale-up:** the autoscaler notices that some Pending pods *would fit* on a new node of the pool. It raises the node pool size (event `TriggeredScaleUp`), and a VM boots and joins in about 1–2 minutes. The pods get scheduled there. The autoscaler never goes above `--max-nodes 4`.
3. **Scale-down:** a node that has been underused for about **10 minutes**, and whose pods can all run elsewhere, is drained and deleted. The autoscaler never goes below `--min-nodes 1`.

It works only from **resource requests**, never from actual usage. A pod without requests "fits" anywhere, so it never triggers a scale-up. This is why every container in the chart has requests.

**Why Redis says `safe-to-evict: "false"`.** Scale-down drains a node, which moves its pods. For most pods that's fine. For Redis it would mean losing the whole queue, because it lives in an `emptyDir`. The annotation tells the autoscaler never to remove the node Redis runs on. On k3s nothing reads it, so it's harmless. It doesn't protect against **Spot preemption**: when Google reclaims a Spot VM, everything on it stops. For workers that's fine (the worker requeues its job on SIGTERM). For Redis the queue is lost, which is acceptable for a demo without persistence (a non-goal).

### Autopilot, the alternative

**GKE Autopilot** has no node pools. You deploy pods, and Google provisions (and bills) capacity **per pod, from its resource requests**. Requests on every container matter even more there: they are literally the bill, and Autopilot adds default requests to containers that have none. KEDA works on Autopilot too. We use **Standard** because the point of this stage is to *watch nodes come and go*, which Autopilot hides.

## Why the existing files changed

- **`producer.ingress.tls` (chart):** the Tailscale operator takes its device name only from `spec.tls`. It's a standard Ingress field, rendered only when set, so k3s output is unchanged. `helm template` with `k3s.yaml` differs only in the chart label, the Redis annotation, and `checksum/config`.
- **Why `checksum/config` changed on k3s:** the ConfigMap carries the `helm.sh/chart` label, which now says `0.3.0`. So the next `make deploy` on k3s rolls the producer once. With `rollout: gradual`, running ScaledJob workers are left alone. This is harmless and expected after a chart bump.
- **Redis annotation:** see [The cluster autoscaler](#the-cluster-autoscaler).
- **`--kube-context` everywhere (Makefile, scripts):** `gcloud container clusters get-credentials` adds the GKE cluster to `~/.kube/config` **and makes it the current context**. From then on a plain `make deploy` would send `k3s.yaml` (Traefik, a pull secret) to GKE. Now every target names its cluster: `K3S_CONTEXT=default` and `GKE_CONTEXT=gke_dns-chatbot-sb_us-central1-a_kta-gke`, both overridable. The scripts use `KUBE_CONTEXT` if it's set and the current context otherwise, as before.

- **Terraform instead of `gcloud` commands:** the first version of this stage listed `gcloud` commands for you to type, following the spec's original "no automated cloud provisioning". With a cluster, three service accounts, a custom role, two firewall rules and a scheduler job, hand-typed commands drift and can't be reviewed. So all of it, and the Stage 3 resources, are now Terraform code (see [Provisioning with Terraform](#provisioning-with-terraform)). `spec.md` was updated to match.

Nothing k3s-specific was hidden in the templates. Everything that differs was already a value.

## `k3s.yaml` vs `gke.yaml`

| Setting | `k3s.yaml` | `gke.yaml` | Why |
|---|---|---|---|
| `image.registry` / `image.tag` | AR `us-central1`, `0.2.0` | same | Same project and region. Free pulls, nothing to rebuild. |
| `imagePullSecrets` | `[artifact-registry]` (SA key) | `[]` | GKE nodes authenticate as their node SA. |
| `producer.ingress.className` | `traefik` (bundled with k3s) | `tailscale` (operator) | `gce` would create a public load balancer. |
| `producer.ingress.host` | `gcp-srv-02.beefalo-fort.ts.net` | `""` | Tailscale takes the name from `tls`. |
| `producer.ingress.tls` | none (default `[]`) | `hosts: [kubernetes-test-app]` | Device name; Tailscale makes the certificate. |
| What keeps it tailnet-only | GCP firewall `deny-ingress-tailscale-only` on the node IPs | no public listener at all | |
| URL | `http://gcp-srv-02.beefalo-fort.ts.net/` | `https://kubernetes-test-app.beefalo-fort.ts.net/` | |
| `worker.mode` | `scaledjob` | `scaledjob` | Same KEDA setup. |

Not in the values but also different: KEDA runs on both (same script), the Tailscale operator only on GKE, and node autoscaling only on GKE.

## Provisioning with Terraform

Everything in GCP that this project uses is described in Terraform under `deploy/terraform/`: the k3s VMs from Stage 3, the registry, the service accounts, the firewall rules, the nightly delete job, and the GKE cluster. Nothing is created by hand-typed `gcloud` commands any more.

**Why.** A list of `gcloud` commands records what someone *once did*. Terraform code records what *should exist*. `terraform plan` compares the code with what really exists, and prints the difference before anything changes. You review a plan like a diff, re-running it is safe (it's idempotent), and `git log` shows every change to your infrastructure. It's the same idea as Helm for what runs inside the cluster, one level down.

**Who runs what.** Claude writes the code and runs only `fmt`, `validate` and `plan`, which read. **You run every `apply`.** The Makefile targets never pass `-auto-approve`, so each apply prints the plan and waits for `yes`.

### Three stacks

A *stack* is one directory with its own state. They are split by **lifetime** and **blast radius**:

| Stack | What | State | Lifetime |
|---|---|---|---|
| `bootstrap/` | The state bucket `gs://dns-chatbot-sb-tfstate` (versioned, private) | local file (gitignored) | forever (`prevent_destroy`) |
| `project/` | APIs, Artifact Registry + who may pull, SAs `k3s-puller`, `gke-nodes`, `gke-reaper`, firewall rules, the k3s VMs + their stop schedule, the nightly delete job | GCS, prefix `kubernetes-test-app/project` | long-lived |
| `gke/` | The cluster `kta-gke` and its node pool, nothing else | GCS, prefix `kubernetes-test-app/gke` | one session: `make gke-up`, deleted at night |

- **Why `bootstrap` is separate, and local:** a `backend "gcs"` block needs its bucket to exist *before* `terraform init`, so the bucket's own stack can't be stored in it. If `bootstrap/terraform.tfstate` is ever lost, nothing breaks: one `terraform import` re-adopts the bucket (see the comment in `bootstrap/main.tf`).
- **Why `gke` is separate:** it is destroyed and recreated all the time. With its own state, a `terraform destroy` there, or a mistake in its code, can't touch the k3s VMs.
- **What state is:** Terraform's record of which real object each resource in the code is, with its last-known attributes. Losing it doesn't delete anything, but Terraform "forgets" and would try to create duplicates. That's why it lives in a versioned bucket.

### Adopting what already existed: `import` blocks

Stages 3a and 3b created some resources by hand:

- the registry
- `k3s-puller` and its pull permission
- the firewall rule `deny-ingress-tailscale-only`
- the VMs and their stop schedule
- the enabled APIs

`project/imports.tf` has an **`import` block** for each. It says "this resource in the code *is* that existing object". The plan then shows it as

```
  # google_compute_instance.k3s["gcp-srv-02"] will be imported
```

instead of `will be created`. Applying an import only writes the state; it doesn't change the object.

**The rule for reading that plan:** every imported resource must show *no* changes (`0 to change, 0 to destroy`). A difference means the code doesn't describe the real object yet, and applying would *change the real object* to match the code. The code in `project/` was written from the real attributes (`gcloud … describe`), and the plan was checked for this before you apply. What that check showed (2026-09-28): **12 to import, 9 to add, 3 to change, 0 to destroy.**

- **The one expected change, on each VM:** `labels` and `terraform_labels` show `+ "purpose"` and `+ "role"`. Since google provider v5, `labels` in Terraform is *non-authoritative*: an import records the labels GCP already has (in `effective_labels`) but leaves the `labels` field that Terraform manages empty. So the plan "adds" labels that are already there. `effective_labels`, the labels actually on the VM, is **unchanged**. The apply writes the same two labels again, which changes nothing, and the next plan shows no changes for the VMs.
- **The first plan prints the VMs' startup script.** For an imported resource, the plan shows every attribute, and `metadata` isn't marked sensitive by the provider. Don't paste that plan output anywhere, and don't save it to a file you share. After the import, later plans only show differences, so the script no longer appears.

**The k3s VMs get extra protection** (`k3s.tf`), because a VM that Terraform decides to "replace" is a deleted k3s node:

- `prevent_destroy = true`: any plan that would delete or replace a VM fails with an error.
- `ignore_changes` on `metadata`: the startup script contains a secret, so it is never written in code, and Terraform never touches it. Once imported, it *is* in the state, and that's one reason the bucket is private.
- `ignore_changes` on the boot disk's `initialize_params` (image, size): these only matter when a disk is created. A newer Ubuntu image must never mean "recreate the VM".
- No `allow_stopping_for_update`: a change that needs a stopped VM makes the apply fail, instead of stopping the node.
- No `desired_status`: the `k3s-lab-schedule` policy (stop at 23:00 Prague) keeps owning start and stop.

**IAM is non-authoritative everywhere.** The project is shared with dns-chatbot. `google_project_iam_member` and the other `…_iam_member` resources add *one* member to *one* role and leave everyone else alone. The authoritative `_iam_binding` and `_iam_policy` would replace the whole list with what Terraform knows, and silently remove other people's access. For the same reason, every `google_project_service` has `disable_on_destroy = false`: Terraform only turns APIs on, never off.

### The nightly delete and Terraform

The Cloud Scheduler job (`project/scheduler.tf`) deletes the cluster at 01:00 Europe/Berlin, behind Terraform's back. That's fine here. The next `terraform plan` in `gke/` refreshes, gets `404` for the cluster and node pool, removes them from the state, and plans to create them again. So "bring it back tomorrow" is just `make gke-up`.

## One-time setup

### 1. Tailscale: policy, HTTPS, OAuth client

The tailnet policy is managed as code in `~/homelab-iac/tailscale/policy.hujson`, applied by that repo's CI. The Stage 4 change is committed (not pushed) on branch `feat/kubernetes-test-app-gke`, in the worktree `~/homelab-iac-worktrees/kubernetes-test-app-gke`, together with a test in `tests/test_tailscale_policy.py`. Review it, push it, and merge the PR. It adds:

```jsonc
"tagOwners": {
  "tag:k8s-operator": ["<you>"],              // the operator's OAuth client carries this tag
  "tag:k8s":          ["tag:k8s-operator"],   // the operator may tag its proxies
},
"grants": [
  // vps-01 → the GKE ingress proxies, HTTPS only
  { "src": ["tag:vps-01"], "dst": ["tag:k8s"], "ip": ["tcp:443"] },
],
```

Your own (untagged) devices already reach everything through the policy's first grant. The new grant is for vps-01, which is a tagged device.

**`tag:k8s` must be owned by `tag:k8s-operator`, not by your user.** The operator logs in *as* `tag:k8s-operator`, and a tagged identity can only put tags on devices if it owns those tags. With the wrong owner, the Ingress never gets an ADDRESS, no `ts-producer-…-0` pod appears, and the operator logs `failed to create or get API key secret: requested tags [tag:k8s] are invalid or not permitted (400)` (`kubectl $G -n tailscale logs deploy/operator`). The operator keeps retrying, so once the policy is fixed it recovers by itself within a few minutes.

In the [admin console](https://login.tailscale.com/admin):

- **DNS** page: MagicDNS on, and **HTTPS Certificates** enabled. This is needed for the `*.ts.net` certificate.
- **Settings → OAuth clients → Generate**: scopes **Devices › Core** (write), **Keys › Auth Keys** (write), **General › Services** (write), with tag `tag:k8s-operator`. This stays manual on purpose: creating it with Terraform would store its secret in the state. Keep it outside the repo:

```bash
( umask 077; cat > ~/.config/kubernetes-test-app/tailscale-oauth.env <<'EOF'
TS_OAUTH_CLIENT_ID=...
TS_OAUTH_CLIENT_SECRET=tskey-client-...
EOF
)
```

### 2. Tools and credentials on vps-01

```bash
terraform version                                         # 1.16.4, in ~/.local/bin
sudo apt install google-cloud-cli-gke-gcloud-auth-plugin  # kubectl's GKE login helper (gcloud is from apt here)
gcloud auth application-default login                     # credentials for Terraform (a browser login, once)
```

### 3. State bucket, then the project stack

```bash
make tf-bootstrap     # plan: 1 to add (the bucket). Type yes.
make tf-plan          # read it: N to import, M to add, 0 to change, 0 to destroy
make tf-apply         # the same plan again; yes
```

`tf-apply` does three things:

- imports the existing resources, without changing them
- enables the Cloud Scheduler API
- creates `gke-nodes` (with the node role and the registry reader role), the firewall rule `kta-gke-deny-public-admin`, and the nightly delete job with its `gke-reaper` SA and custom role

After this, the safety net exists before any cluster does.

The registry and the `0.2.0` images already exist from Stage 3a. If you ever start from scratch, `make tf-apply` creates the registry and `make build push …` fills it (see `docs/stage-3a.md`).

## Each session

### 4. Create the cluster 💰

```bash
make gke-plan         # 2 to add: google_container_cluster.this, google_container_node_pool.default
make gke-up           # apply (yes), then get-credentials, set its namespace, switch back to k3s as current
```

What `deploy/terraform/gke/main.tf` sets, and why:

- `location = us-central1-a`: a **zonal** cluster, with one control-plane zone, covered by the free tier credit.
- A separate `google_container_node_pool` (with `remove_default_node_pool`), so the pool can change without touching the cluster.
- `autoscaling { min 1, max 4 }`: the cluster autoscaler for this pool. The node count belongs to the autoscaler, so Terraform ignores it (`ignore_changes`).
- `spot = true`: cheap VMs that Google may reclaim at any time. That's fine for a demo (see Redis above).
- `pd-standard`, 30 GB, instead of the default 100 GB pd-balanced.
- `service_account = gke-nodes`: nodes pull images as `gke-nodes`, without keys.
- `tags = ["kta-gke-node"]`: the target of the firewall rule that closes SSH and RDP from the internet.
- `http_load_balancing { disabled = true }`: turns off GKE's built-in Ingress controller. We never use it, and while it's on it runs a NodePort Service (`kube-system/default-http-backend`), and any Ingress of class `gce` would create a **public** load balancer. With it off, that can't happen even by mistake.
- `managed_prometheus { enabled = false }`: no metrics stack (a non-goal).
- `deletion_protection = false`: a Terraform-only guard. With `true`, `make gke-down` would refuse to run.

Creating the cluster takes about 5–8 minutes. Then:

```bash
kubectl config get-contexts             # default (k3s) and gke_dns-chatbot-sb_us-central1-a_kta-gke
G="--context gke_dns-chatbot-sb_us-central1-a_kta-gke"      # used below: kubectl $G …
kubectl $G get nodes -o wide            # 1 node, Ready
```

### 5. Add-ons: KEDA and the Tailscale operator

```bash
make install-keda-gke              # same script and version as on k3s, KUBE_CONTEXT=<gke>
make install-tailscale-operator    # reads ~/.config/kubernetes-test-app/tailscale-oauth.env
kubectl $G -n tailscale get pods   # operator Running
kubectl $G get ingressclass        # "tailscale"
```

In the admin console, a new device `tailscale-operator` (tag:k8s-operator) appears. These add-ons live *inside* the cluster, so they are Helm's job, not Terraform's. They disappear with each nightly delete and come back with these two commands.

## Deploy

```bash
helm lint deploy/helm/kubernetes-test-app -f deploy/helm/values/gke.yaml
helm template kubernetes-test-app deploy/helm/kubernetes-test-app -f deploy/helm/values/gke.yaml -s templates/producer.yaml
make deploy-gke                   # helm upgrade --install --kube-context <gke> -f gke.yaml
make watch-gke                    # other terminals: make watch-nodes-gke, make logs-worker-gke
kubectl $G get ingress producer   # ADDRESS: kubernetes-test-app.beefalo-fort.ts.net (may take ~1 min)
```

Nodes pull images with no pull secret. If a pod shows `ImagePullBackOff` with `403`, the `artifactregistry.reader` member for `gke-nodes` is missing (`make tf-plan` would show it).

### Check that it is tailnet-only

```bash
curl -sI https://kubernetes-test-app.beefalo-fort.ts.net/ | head -1                # from vps-01: HTTP/2 200
tailscale status | grep kubernetes-test-app                                       # the proxy is a tailnet device
kubectl $G get svc -A | grep -E 'LoadBalancer|NodePort' || echo "no public Services"
kubectl $G get svc -A -o jsonpath='{range .items[*]}{.status.loadBalancer.ingress}{end}'; echo   # empty
gcloud compute forwarding-rules list --project=$P                                 # Listed 0 items: no load balancer
gcloud compute addresses list --project=$P                                        # no reserved IPs for the app
```

Also try from a machine that is **not** on your tailnet (e.g. a phone with Tailscale off): the name doesn't lead anywhere. Only MagicDNS resolves it, to a `100.x` tailnet address, and that address can't be reached from the internet. The node IPs serve nothing. One thing *is* public: the certificate. Let's Encrypt certificates go into public Certificate Transparency logs, so the **name** `kubernetes-test-app.beefalo-fort.ts.net` can be seen, but not reached.

Helpers for the experiments (the same as 3b, only the URL differs):

```bash
P=https://kubernetes-test-app.beefalo-fort.ts.net
jobs() { curl -s -X POST $P/api/jobs -H 'Content-Type: application/json' -d "{\"count\": $1, \"duration_seconds\": ${2:-30}}"; echo; }
status() { curl -s $P/api/status | jq '{queue: .queue_length, processing: (.processing|length), completed, failed, dead}'; }
```

(`P` is the page's URL here, as in 3b.)

## Experiments

### 1. Stage 3b experiments 1–5 on GKE

Run them exactly as in [`stage-3b.md`](stage-3b.md#experiments), with `kubectl $G` and the `-gke` make targets (`make deploy-gke HELM_ARGS="--set config.failRate=0.3"` for #5).

- **Scale to zero, scale up, maximum:** these should look identical. KEDA doesn't care which cloud it's on.
- **Spreading (#4):** with one node, all workers run on it. Ten 250m workers fit on one e2-standard-2 only partly (it has about 1.9 CPU allocatable minus system pods), so the autoscaler may add a node during #3 already. Watch `make watch-nodes-gke`.
- **Failures (#5):** `completed + dead == 20`, none lost.

### 2. Capacity limit → the cluster autoscaler adds nodes

```bash
make deploy-gke-pending-demo           # gke.yaml + pending-demo.yaml: 1 CPU per worker, max 20
jobs 20 120                            # long jobs, so there's time to watch the scale-up
kubectl $G get nodes -w                # terminal 2
kubectl $G get events -A -w --field-selector reason=TriggeredScaleUp   # terminal 3
```

**Expect:**

1. As on k3s, KEDA creates 20 Jobs, and most pods are **Pending** (`FailedScheduling … Insufficient cpu`).
2. Within about 30 s, `TriggeredScaleUp` appears on those pods: `pod triggered scale-up: [{…default-pool… 1->4 (max: 4)}]`.
3. After about 1–2 min, new nodes appear in `get nodes -w` (`NotReady` → `Ready`), and Pending pods start on them. One 1-CPU worker fits per node, so about 3–4 workers run at once and the rest wait. **4 is the ceiling now**, instead of 3 fixed VMs.
4. `kubectl $G describe pod <pending pod>` also shows `NotTriggerScaleUp … max node group size reached` once the pool is at 4.

**Scale-down:** when the queue drains, the extra nodes are idle, and after about **10 minutes** the autoscaler drains and deletes them, back to 1 node.

```bash
kubectl $G get events -A -w --field-selector reason=ScaleDown          # "node removed by cluster autoscaler"
kubectl $G get nodes -w
```

If a node refuses to go away, `kubectl $G get events -A | grep -i -E 'scale ?down|NoScaleDown'`, and the "Autoscaler logs" in the console (Kubernetes Engine → cluster → Logs) tell you which pod is blocking it. One blocker is **by design**: the node running Redis (`safe-to-evict: "false"`). That's usually node 1, which is also the minimum.

Go back with `make deploy-gke`.

### 3. Tear down

See below. Compare `helm uninstall` (removes the app; the operator removes its tailnet device) with deleting the cluster (removes everything in GCP, but not the tailnet devices).

## Teardown

```bash
make undeploy-gke        # first: the operator deletes the kubernetes-test-app tailnet device
helm --kube-context gke_dns-chatbot-sb_us-central1-a_kta-gke -n tailscale uninstall tailscale-operator
make gke-down            # 💰 terraform destroy of the gke stack: stops all node and cluster charges
```

`make gke-down` leaves the `project/` stack alone. `gke-nodes`, the firewall rules, the registry and the nightly job stay, so the next `make gke-up` works right away. They cost nothing while no cluster exists. To check that no cluster is left: `gcloud container clusters list --project=dns-chatbot-sb`.

**Tailnet devices:** `make undeploy-gke` makes the operator delete the proxy's device. The operator's own `tailscale-operator` device stays behind offline. When the cluster is deleted directly (for example by the nightly job), **both** devices stay behind. Remove them in the admin console (Machines) **before** the next deploy. Otherwise the new proxy is named `kubernetes-test-app-1` and the URL changes.

**Completely done with Stage 4?** Remove these from `project/`: `kta-gke-deny-public-admin`, `gke-nodes` and its IAM members, and the scheduler job with its role and SA. Then `make tf-plan` lists exactly those as "destroy", and `make tf-apply` removes them. Never run `terraform destroy` on `project/`: it would try to delete the k3s VMs (which `prevent_destroy` blocks) and the registry.

## Safety net: the nightly delete

A forgotten cluster is the main cost risk, so the Cloud Scheduler job `kta-gke-nightly-delete` (`deploy/terraform/project/scheduler.tf`) deletes `kta-gke` every night at 01:00 Europe/Berlin.

- **How:** Cloud Scheduler calls the GKE REST API itself (`DELETE …/clusters/kta-gke`), with a token for the SA `gke-reaper`. There's nothing to deploy, and it runs in Google Cloud, so it works even when vps-01 is off.
- **Least privilege:** `gke-reaper` has only the custom role `gkeClusterDeleter` (`container.clusters.get`, `container.clusters.delete`, `container.operations.get`).
- **Timing:** the job only **starts** the deletion (the API returns an operation). The cluster is gone about 5 minutes later.
- **No cluster that night:** the call gets `404 NOT_FOUND` and the job logs a failure. That's expected. There are no retries, because a retry would just fail the same way.
- **Changing it:** the schedule and time zone are variables in `project/variables.tf` (`nightly_delete_schedule`, `nightly_delete_time_zone`). Change them there, then `make tf-apply`.

Check and manage it:

```bash
R="--location=us-central1 --project=dns-chatbot-sb"
gcloud scheduler jobs describe kta-gke-nightly-delete $R    # schedule, state, last attempt
gcloud scheduler jobs run kta-gke-nightly-delete $R         # ⚠️ deletes the cluster NOW (a test)
gcloud scheduler jobs pause  kta-gke-nightly-delete $R      # keep the cluster tonight
gcloud scheduler jobs resume kta-gke-nightly-delete $R
gcloud logging read 'resource.type="cloud_scheduler_job" AND resource.labels.job_id="kta-gke-nightly-delete"' \
  --project=dns-chatbot-sb --limit=5 --format='value(timestamp,jsonPayload.status,httpRequest.status)'
```

`pause` and `resume` change the job outside Terraform, so the next `make tf-plan` shows a change to its `paused` state. That's a small example of *drift*. To fix it, resume the job, or apply to put it back to what the code says.

## What carries forward

The same chart ran on two very different clusters, and only the values file changed. The differences were exactly the environment-specific things: how the nodes authenticate to the registry, which ingress controller exists, and how the app is kept private. Everything about the app itself (config, probes, security context, KEDA scaling) was identical. The layering of pod scaling (KEDA) and node scaling (the cluster autoscaler), both driven by resource requests, is how most real queue-worker systems on Kubernetes run.
