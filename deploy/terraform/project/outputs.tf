output "registry" {
  description = "image.registry for the Helm values files."
  value       = "${google_artifact_registry_repository.images.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.images.repository_id}"
}

output "gke_nodes_service_account" {
  description = "Service account of the GKE nodes (used by ../gke)."
  value       = google_service_account.gke_nodes.email
}

output "nightly_delete_job" {
  description = "The Cloud Scheduler job that deletes the GKE cluster."
  value       = google_cloud_scheduler_job.gke_nightly_delete.name
}
