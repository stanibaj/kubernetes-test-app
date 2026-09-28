# Command cheat sheet: kubectl + Helm for this project

This sheet is organized by the **question you want answered**. Use it to check an assumption *before* and *after* you change something. Every command here only reads, unless it's marked ✏️ (changes the cluster).

## Before you start

```bash
# Work in the app's namespace by default (kubectl AND helm follow the context's namespace)
kubectl config set-context --current --namespace kubernetes-test-app
kubectl config view --minify -o jsonpath='{..namespace}'; echo    # which namespace am I in?

# Shorthand for the chart + values used by every helm command below
C=deploy/helm/kubernetes-test-app
V="-f deploy/helm/values/k3s.yaml"
R=kubernetes-test-app            # release name
```

If a command says `not found` although the thing exists, you're probably in the wrong namespace. Add `-n kubernetes-test-app`, or use `-A` for all namespaces.

---

## 1. Is the cluster healthy?

```bash
kubectl get nodes -o wide                    # Ready? versions, internal (Tailscale) IPs
kubectl top nodes                            # actual CPU/memory use per node (metrics-server)
kubectl describe node gcp-srv-04             # capacity, allocatable, what's reserved ("Allocated resources")
kubectl get pods -A                          # everything on the cluster, incl. kube-system (Traefik, CoreDNS, ...)
kubectl events -A --types=Warning            # recent problems anywhere
```

**Check an assumption:** "a node has room for another 250m pod". `describe node` → *Allocated resources* shows the reserved requests, not the actual usage. The scheduler decides based on **requests**; `top` shows real usage. These two are different numbers.

---

## 2. What is running, and where?

```bash
kubectl get all                                       # deployments, replicasets, pods, services
kubectl get pods -o wide                              # node + pod IP of each pod
kubectl get pods -L app.kubernetes.io/component       # add a label as a column
kubectl get pods --show-labels                        # all labels
kubectl get pods -l app.kubernetes.io/component=worker          # filter by label (what selectors do)
kubectl get pods -o custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,IMAGE:.spec.containers[0].image,PHASE:.status.phase
kubectl get pods -w                                   # watch changes live (Ctrl+C to stop)
```

The object chain Deployment → ReplicaSet → Pod:

```bash
kubectl get deploy,rs,pods -l app.kubernetes.io/component=worker
kubectl get pod <pod> -o jsonpath='{.metadata.ownerReferences[0].kind}/{.metadata.ownerReferences[0].name}'; echo
```

---

## 3. What does an object actually say? (desired vs actual)

```bash
kubectl get deploy worker -o yaml                           # the full object: spec (desired) + status (actual)
kubectl get deploy worker -o jsonpath='{.spec.replicas}'; echo          # desired count
kubectl get deploy worker -o jsonpath='{.status.readyReplicas}'; echo   # how many are ready
kubectl describe deploy worker                              # human-readable summary + events
kubectl get cm app-config -o yaml                           # the config the pods get
kubectl exec deploy/worker -- env | sort                    # the env vars INSIDE a running container
```

**Check an assumption:** "my change reached the pod". Compare three places: the value in your files (`helm template`, section 5), the object in the API (`get -o yaml`), and the running container (`exec … env`).

---

## 4. Why is something broken?

```bash
kubectl describe pod <pod>                   # scroll to "Last State", "Exit Code" and "Events" at the bottom
kubectl logs <pod>                           # current container's log
kubectl logs <pod> --previous                # the log of the container that CRASHED (most useful for CrashLoopBackOff)
kubectl logs deploy/worker -f                # follow one pod of a deployment
kubectl logs -l app.kubernetes.io/component=worker --prefix -f    # all workers at once, each line prefixed
kubectl events --for pod/<pod>               # events for just one object
kubectl events --types=Warning               # e.g. failed probes, image pull errors, back-offs
```

| You see | Usually means | Look at |
|---|---|---|
| `Pending` | can't be scheduled (no room, no matching node) | `describe pod` → Events ("Insufficient cpu") |
| `ErrImagePull` / `ImagePullBackOff` | wrong image name/tag, or no pull credentials | `describe pod` → Events |
| `CrashLoopBackOff` | the process keeps exiting; kubelet waits longer each time | `logs --previous`, `describe` → Exit Code |
| `0/1 Running` | container runs but readiness probe fails | `describe pod` → Readiness, Events |
| `OOMKilled` | exceeded its memory limit | `describe pod` → Last State |

---

## 5. Helm: what WOULD be deployed? (nothing touches the cluster)

```bash
helm lint $C $V                                  # errors and warnings in the chart
helm show values $C                              # the chart's defaults, with comments
helm template $R $C $V                           # the complete YAML Helm would send
helm template $R $C $V -s templates/<file>.yaml  # just one template's output
helm template $R $C $V --set <key>=<value>       # try a value without editing any file
helm template $R $C $V | grep -n '<something>'   # quick check that a value landed where you think
helm template $R $C $V --debug                   # show more detail when a template fails to render
```

**Compare what Helm would send with what's live** (no helm-diff plugin needed):

```bash
helm template $R $C $V | kubectl diff -f -       # lines with -/+ = what would change; exit code 1 = there are differences
helm upgrade --install $R $C $V --dry-run=server # like a real upgrade, validated by the API server, but applies nothing
```

---

## 6. Helm: what IS deployed?

```bash
helm list                                   # releases in this namespace (-A: all namespaces)
helm status $R                              # state, revision, notes
helm get values $R                          # only the values YOU supplied (files + --set)
helm get values $R --all                    # everything merged: what the templates actually used
helm get manifest $R                        # the YAML Helm sent for the current revision
helm get notes $R                           # the NOTES.txt output again
helm history $R                             # every revision: when, status, description
helm get values $R --revision 1             # values of an older revision
kubectl get secrets -l owner=helm           # where Helm keeps those revisions
```

**Check an assumption:** "Helm used the value I think". `helm get values $R --all` shows the merged values, and `helm get manifest $R | grep …` shows where the value ended up.

---

## 7. Changing things ✏️

```bash
helm upgrade --install $R $C $V                         # ✏️ deploy what's in the files (idempotent)
helm upgrade --install $R $C $V --set <key>=<value>     # ✏️ one-off override (NOT remembered next time)
helm upgrade --install $R $C $V --force-conflicts       # ✏️ Helm 4: take back fields changed by kubectl
helm rollback $R <revision>                             # ✏️ go back; creates a NEW revision
helm uninstall $R                                       # ✏️ remove the release (namespace + hand-made secrets stay)

kubectl scale deployment worker --replicas=<n>          # ✏️ manual change, outside Helm = drift
kubectl delete pod <pod>                                # ✏️ the Deployment replaces it (self-healing)
kubectl rollout restart deployment/worker               # ✏️ new pods with the same spec
```

---

## 8. Rollouts: what changed and did it finish?

```bash
kubectl rollout status deployment/worker        # waits until the rollout is done (or failed)
kubectl rollout history deployment/worker       # the Deployment's own revisions (one per ReplicaSet)
kubectl get rs -l app.kubernetes.io/component=worker     # old ReplicaSets are kept at 0 replicas
kubectl get pod <pod> -o jsonpath='{.metadata.annotations}'; echo    # e.g. checksum/config
kubectl get deploy <name> -o jsonpath='{.spec.template.metadata.labels}'; echo
```

**Check an assumption:** "this change will (or won't) restart pods". Pods are replaced **only when the pod template changes** (`spec.template`: image, env, labels, annotations, …). Changing `spec.replicas` doesn't create new pods from a new template; it adds or removes pods of the same one. Render before and after with `helm template` and compare the `template:` sections.

---

## 9. Who owns a field? (Helm 4 server-side apply)

```bash
kubectl get deploy worker -o yaml --show-managed-fields | less    # look for "manager:" entries
```

The manager is `helm` for fields Helm sets, `kubectl` (subresource `scale`) after a `kubectl scale`, and `k3s`/`kube-controller-manager` for status. When two managers set the same field, the next `helm upgrade` reports a conflict.

---

## 10. Networking: can A reach B?

```bash
kubectl get svc                                   # ClusterIPs and ports
kubectl get endpointslices                        # which pod IPs are behind each Service right now
kubectl describe svc producer                     # selector + endpoints
kubectl get ingress; kubectl describe ingress producer
kubectl -n kube-system get svc traefik            # the ingress controller's addresses (nodes' Tailscale IPs)

# From vps-01 (host rule: bind only to the Tailscale IP)
kubectl port-forward --address "$(tailscale ip -4)" svc/producer 8080:8000
curl -s http://gcp-srv-02.beefalo-fort.ts.net/readyz; echo

# From inside the cluster
kubectl exec deploy/producer -- python -c "import socket; print(socket.gethostbyname('redis'))"   # DNS → ClusterIP
kubectl exec deploy/redis -- redis-cli ping
```

---

## 11. The app's data in Redis

```bash
kubectl exec deploy/redis -- redis-cli llen jobs:queue          # waiting jobs
kubectl exec deploy/redis -- redis-cli hgetall jobs:processing  # who is working on what, on which node
kubectl exec deploy/redis -- redis-cli mget jobs:completed jobs:failed
kubectl exec deploy/redis -- redis-cli llen jobs:dead
kubectl exec deploy/redis -- redis-cli lrange jobs:history 0 4  # last 5 finished jobs
```

Submit jobs without the web page:

```bash
curl -s -X POST http://gcp-srv-02.beefalo-fort.ts.net/api/jobs \
  -H 'Content-Type: application/json' -d '{"count": 6, "duration_seconds": 20}'; echo
curl -s http://gcp-srv-02.beefalo-fort.ts.net/api/status | python3 -m json.tool
```

---

## 11b. KEDA: what is it deciding, and why? (Stage 3b)

```bash
kubectl get scaledjob,scaledobject,hpa,jobs,pods -o wide     # everything KEDA owns or creates (= make watch)
kubectl describe scaledjob worker                            # READY/ACTIVE conditions, events
kubectl get hpa keda-hpa-worker -o yaml                      # ScaledObject mode: current metric vs target
kubectl -n keda logs deploy/keda-operator | grep scaleexecutor | tail   # "Creating jobs ... Number of jobs: N"
kubectl -n keda get pods                                     # is KEDA itself healthy?
kubectl get jobs --sort-by=.metadata.creationTimestamp       # DURATION: real workers vs "no job available" extras
```

**Check an assumption:** "KEDA sees the same queue length I do". Compare `kubectl exec deploy/redis -- redis-cli llen jobs:queue` with the numbers in the operator log for the same poll.

---

## 11c. Two clusters, and nodes that come and go (Stage 4)

```bash
kubectl config get-contexts                       # * = the current one; default = k3s, gke_… = GKE
kubectl config current-context                    # check BEFORE any command without --context
G="--context gke_dns-chatbot-sb_us-central1-a_kta-gke"
kubectl $G get nodes -w                           # nodes being added/removed by the cluster autoscaler
kubectl $G get events -A -w --field-selector reason=TriggeredScaleUp    # "pod triggered scale-up"
kubectl $G get events -A | grep -i -E 'scale ?down|NoScaleDown|NotTriggerScaleUp'
kubectl $G describe node <node> | sed -n '/Allocated resources/,/Events/p'   # requests vs allocatable
kubectl $G get ingress producer                   # ADDRESS = the tailnet name (Tailscale operator)
kubectl $G -n tailscale get pods                  # operator + one ts-producer-… proxy pod
kubectl $G get svc -A | grep -E 'LoadBalancer|NodePort' || echo "nothing public"
```

**Check an assumption:** "the autoscaler adds a node because the node is busy". It doesn't. It adds one only when a pod is **Pending** and would fit on a new node, based on **requests**. Compare `describe node` → *Allocated resources* with `kubectl top node` (actual use).

---

## 12. Learning the API itself

```bash
kubectl explain deployment.spec                     # what fields exist, with descriptions
kubectl explain deployment.spec.strategy --recursive
kubectl explain pod.spec.containers.readinessProbe
kubectl api-resources                               # every object kind the cluster knows
kubectl get <kind> <name> -o yaml                   # then compare with the template that produced it
```

---

## A habit worth building

For every change, go through these steps:

1. **Predict** what should happen.
2. **Render:** `helm template … | kubectl diff -f -`
3. **Apply:** `helm upgrade --install …`
4. **Watch:** `kubectl get pods -w` and `kubectl rollout status …`
5. **Verify** in all three places:
   - the files (`helm get values --all`)
   - the API (`kubectl get … -o yaml`)
   - the container (`kubectl exec … env`, logs)

If step 5 surprises you, that's the most useful moment of the exercise.
