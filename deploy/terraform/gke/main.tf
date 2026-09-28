# Stage 4: the GKE Standard cluster kta-gke, and nothing else. It is a
# separate stack because its lifetime is different: it is created for an
# experiment session (make gke-up), deleted at night by the Cloud Scheduler
# job in ../project, and created again by the next apply. Keeping it apart
# means that a `terraform destroy` here can never reach the k3s VMs.
#
# After the nightly delete, `terraform plan` refreshes the state, gets "404
# not found" for the cluster and node pool, drops them from the state, and
# plans to create them again. That's intended: the cluster holds nothing
# that must survive (Redis has no persistence, the app is redeployed with
# Helm).
#
#   make gke-up     (apply + get-credentials)      make gke-down   (destroy)

terraform {
  required_version = ">= 1.16.0"

  backend "gcs" {
    bucket = "dns-chatbot-sb-tfstate"
    prefix = "kubernetes-test-app/gke"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.4"
    }
  }
}

variable "project_id" {
  type    = string
  default = "dns-chatbot-sb"
}

variable "zone" {
  description = "A ZONAL cluster: one control-plane zone, covered by the GKE free tier credit (a regional one isn't)."
  type        = string
  default     = "us-central1-a"
}

variable "cluster_name" {
  description = "Must match gke_cluster_name in ../project (the nightly delete job)."
  type        = string
  default     = "kta-gke"
}

variable "node_tag" {
  description = "Network tag of the nodes; ../project's firewall rule kta-gke-deny-public-admin targets it."
  type        = string
  default     = "kta-gke-node"
}

variable "min_nodes" {
  type    = number
  default = 1
}

variable "max_nodes" {
  description = "Upper limit for the cluster autoscaler (Stage 4 experiment 2)."
  type        = number
  default     = 4
}

provider "google" {
  project = var.project_id
}

locals {
  # Created in ../project (service_accounts.tf). Built from its name rather
  # than read from the other stack's state, to keep the stacks independent.
  node_service_account = "gke-nodes@${var.project_id}.iam.gserviceaccount.com"
}

resource "google_container_cluster" "this" {
  name     = var.cluster_name
  location = var.zone

  # GKE picks and upgrades the version within the REGULAR channel.
  release_channel {
    channel = "REGULAR"
  }

  # A cluster can't be created without a node pool, so GKE makes a default
  # one and Terraform deletes it right away. Our pool is the separate
  # resource below, which can then be changed without touching the cluster.
  remove_default_node_pool = true
  initial_node_count       = 1

  # A Terraform-only guard (the API ignores it). With `true`, `terraform
  # destroy` refuses to run. The cluster is disposable, so off.
  deletion_protection = false

  # Turn off GKE's built-in Ingress controller (ingress-gce). We never use
  # it: our Ingress is ingressClassName "tailscale". Left on, it runs the
  # NodePort Service kube-system/default-http-backend, and any Ingress of
  # class "gce" would create a PUBLIC HTTP load balancer. Off = that can't
  # happen in this cluster, even by mistake.
  addons_config {
    http_load_balancing {
      disabled = true
    }
  }

  # No metrics stack (a spec non-goal): skip Google Managed Prometheus.
  monitoring_config {
    enable_components = ["SYSTEM_COMPONENTS"]
    managed_prometheus {
      enabled = false
    }
  }
}

resource "google_container_node_pool" "default" {
  name     = "default-pool"
  cluster  = google_container_cluster.this.id
  location = var.zone

  # The cluster autoscaler for this pool: adds nodes when pods are Pending
  # and would fit on a new node, removes idle ones (after ~10 min).
  initial_node_count = var.min_nodes
  autoscaling {
    min_node_count = var.min_nodes
    max_node_count = var.max_nodes
  }

  node_config {
    machine_type = "e2-standard-2" # 2 vCPU / 8 GB, like the k3s VMs' 2 CPUs
    # Spot: much cheaper, may be reclaimed by Google at any time. Workers
    # requeue their job on SIGTERM; Redis's queue would be lost (a demo).
    spot = true

    # The GKE default is 100 GB pd-balanced (~$10/month per node).
    disk_type    = "pd-standard"
    disk_size_gb = 30

    # Nodes run as gke-nodes: they pull our images from Artifact Registry
    # with its token, no pull secret. What the SA may do is limited by its
    # IAM roles, so the scope is the broad "cloud-platform" (recommended).
    service_account = local.node_service_account
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    tags = [var.node_tag]

    labels = {
      purpose = "k8s-learning"
    }
  }

  # The autoscaler changes the node count; Terraform must not reset it.
  lifecycle {
    ignore_changes = [initial_node_count]
  }
}

output "get_credentials" {
  description = "Adds the cluster to ~/.kube/config (and makes it the current context)."
  value       = "gcloud container clusters get-credentials ${google_container_cluster.this.name} --zone ${var.zone} --project ${var.project_id}"
}

output "kube_context" {
  description = "The kubeconfig context name, as used by the Makefile's GKE_CONTEXT."
  value       = "gke_${var.project_id}_${var.zone}_${google_container_cluster.this.name}"
}
