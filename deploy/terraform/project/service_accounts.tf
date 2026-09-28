# Identities. None of them gets a key from Terraform: a key created here
# would be stored in the state. The one key that exists (k3s-puller's, for
# the k3s imagePullSecret) was made by hand in Stage 3a and stays outside
# Terraform.

# k3s nodes pull images as this SA (Stage 3a; imported).
resource "google_service_account" "k3s_puller" {
  account_id   = "k3s-puller"
  display_name = "k3s image puller"
}

# GKE nodes run as this SA (Stage 4): the kubelet pulls images with its
# token, so GKE needs no pull secret.
resource "google_service_account" "gke_nodes" {
  account_id   = "gke-nodes"
  display_name = "GKE nodes (kta-gke)"
}

# The minimum a GKE node needs (writing logs and metrics). Non-authoritative,
# like all IAM here (see registry.tf).
resource "google_project_iam_member" "gke_nodes_default" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = google_service_account.gke_nodes.member
}
