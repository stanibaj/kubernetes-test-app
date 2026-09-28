# Safety net: delete the GKE cluster every night, so a forgotten cluster
# costs at most one day. Cloud Scheduler calls the GKE REST API directly
# (DELETE .../clusters/kta-gke), with a token for an SA that may do nothing
# else. No code to deploy, and it works even if vps-01 is off.
#
# The cluster itself belongs to ../gke. After a nightly delete, the next
# `make gke-up` (terraform apply in ../gke) notices it's gone and creates it
# again. On nights without a cluster the call gets 404 and the job logs a
# failure; that is expected and harmless.

# Least privilege: only what deleting a cluster needs.
resource "google_project_iam_custom_role" "gke_cluster_deleter" {
  role_id     = "gkeClusterDeleter"
  title       = "GKE cluster deleter"
  description = "Used by the kta-gke-nightly-delete Cloud Scheduler job."
  permissions = [
    "container.clusters.get",
    "container.clusters.delete",
    "container.operations.get",
  ]
}

resource "google_service_account" "gke_reaper" {
  account_id   = "gke-reaper"
  display_name = "Deletes GKE clusters at night"
}

resource "google_project_iam_member" "gke_reaper" {
  project = var.project_id
  role    = google_project_iam_custom_role.gke_cluster_deleter.id
  member  = google_service_account.gke_reaper.member
}

resource "google_cloud_scheduler_job" "gke_nightly_delete" {
  name        = "${var.gke_cluster_name}-nightly-delete"
  region      = var.region
  description = "Safety net: delete the Stage 4 GKE cluster every night"
  schedule    = var.nightly_delete_schedule
  time_zone   = var.nightly_delete_time_zone

  # The API answers at once with an operation; the deletion itself runs
  # for ~5 minutes afterwards.
  attempt_deadline = "60s"

  # No retry_config: the default is 0 retries, which is what we want (a 404,
  # no cluster tonight, would just fail again). Writing retry_count = 0
  # explicitly makes every plan show a change: the API doesn't return a
  # block that only holds defaults, so Terraform thinks it's missing.

  http_target {
    http_method = "DELETE"
    uri         = "https://container.googleapis.com/v1/projects/${var.project_id}/locations/${var.zone}/clusters/${var.gke_cluster_name}"

    oauth_token {
      service_account_email = google_service_account.gke_reaper.email
      scope                 = "https://www.googleapis.com/auth/cloud-platform"
    }
  }

  depends_on = [
    google_project_service.this,
    google_project_iam_member.gke_reaper,
  ]
}
