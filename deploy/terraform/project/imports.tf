# Resources that existed before Terraform (made with gcloud or the console
# in Stages 3a/3b). An import block tells Terraform "this resource in the
# code IS that existing object": the plan shows it as "will be imported"
# instead of "will be created", and the apply only records it in the state
# (it changes nothing in GCP by itself).
#
# Before applying, the plan must show 0 to change and 0 to destroy for
# everything imported: any difference means the code doesn't describe the
# real resource yet, and applying would CHANGE the real resource to match
# the code. After a successful apply these blocks do nothing and could be
# deleted; they are kept as a record of what was adopted.

locals {
  preexisting_services = toset([
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
  ])
}

import {
  for_each = local.preexisting_services
  to       = google_project_service.this[each.value]
  id       = "${var.project_id}/${each.value}"
}

import {
  to = google_artifact_registry_repository.images
  id = "projects/${var.project_id}/locations/${var.region}/repositories/kubernetes-test-app"
}

import {
  to = google_service_account.k3s_puller
  id = "projects/${var.project_id}/serviceAccounts/k3s-puller@${var.project_id}.iam.gserviceaccount.com"
}

import {
  to = google_artifact_registry_repository_iam_member.pullers["k3s"]
  id = "projects/${var.project_id}/locations/${var.region}/repositories/kubernetes-test-app roles/artifactregistry.reader serviceAccount:k3s-puller@${var.project_id}.iam.gserviceaccount.com"
}

import {
  to = google_compute_firewall.deny_ingress_tailscale_only
  id = "projects/${var.project_id}/global/firewalls/deny-ingress-tailscale-only"
}

import {
  to = google_compute_resource_policy.k3s_lab_schedule
  id = "projects/${var.project_id}/regions/${var.region}/resourcePolicies/k3s-lab-schedule"
}

import {
  for_each = local.k3s_nodes
  to       = google_compute_instance.k3s[each.key]
  id       = "projects/${var.project_id}/zones/${var.zone}/instances/${each.key}"
}
