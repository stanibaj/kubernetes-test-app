# Artifact Registry: our two images (producer, worker) since Stage 3a.
# Same region as the k3s VMs and the GKE cluster, so pulls are free.

resource "google_artifact_registry_repository" "images" {
  repository_id = "kubernetes-test-app"
  location      = var.region
  format        = "DOCKER"
  description   = "Stage 3+ images for kubernetes-test-app"

  depends_on = [google_project_service.this]
}

# Who may pull. `_iam_member` is NON-authoritative: it adds one member to
# one role and leaves every other member alone. Never use `_iam_binding` or
# `_iam_policy` in this shared project: those REPLACE the whole member list
# (or policy) with what Terraform knows, silently removing everyone else.
locals {
  image_pullers = {
    k3s = google_service_account.k3s_puller.member # k3s nodes, via a key in a Secret
    gke = google_service_account.gke_nodes.member  # GKE nodes, keyless
  }
}

resource "google_artifact_registry_repository_iam_member" "pullers" {
  for_each = local.image_pullers

  location   = google_artifact_registry_repository.images.location
  repository = google_artifact_registry_repository.images.name
  role       = "roles/artifactregistry.reader"
  member     = each.value
}
