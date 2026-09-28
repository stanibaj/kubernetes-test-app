# deploy/terraform

GCP infrastructure for this project (project `dns-chatbot-sb`), in three stacks. The full explanation is in [`docs/stage-4.md`](../../docs/stage-4.md#provisioning-with-terraform).

| Stack | What | State |
|---|---|---|
| `bootstrap/` | the state bucket `gs://dns-chatbot-sb-tfstate` | local (gitignored) |
| `project/` | APIs, Artifact Registry + IAM, service accounts, firewall rules, k3s VMs + stop schedule (imported), nightly GKE delete job | GCS `kubernetes-test-app/project` |
| `gke/` | the `kta-gke` cluster and its autoscaling node pool | GCS `kubernetes-test-app/gke` |

Order (every apply prints the plan and asks for `yes`):

```bash
gcloud auth application-default login   # once: credentials for Terraform
make tf-bootstrap                        # once: the state bucket
make tf-plan && make tf-apply            # imports existing resources + creates the new ones
make gke-up                              # each session (the cluster is deleted every night at 01:00)
make gke-down                            # when done
```

Rules: never `terraform destroy` the `project/` stack; imported resources must plan with 0 changes; IAM is non-authoritative (`*_iam_member` only); no secrets are created here, because they would land in the state.
