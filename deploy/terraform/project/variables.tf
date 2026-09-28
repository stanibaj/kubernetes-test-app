# Defaults are this project's real values, so no .tfvars file is needed.

variable "project_id" {
  description = "The GCP project. Shared with other work (dns-chatbot), so nothing here may be authoritative over project-wide settings."
  type        = string
  default     = "dns-chatbot-sb"
}

variable "region" {
  description = "Region for the registry, the VM schedule and Cloud Scheduler."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zone of the k3s VMs and of the GKE cluster."
  type        = string
  default     = "us-central1-a"
}

variable "gke_cluster_name" {
  description = "Name of the GKE cluster (created by ../gke) that the nightly job deletes."
  type        = string
  default     = "kta-gke"
}

variable "gke_node_tag" {
  description = "Network tag on the GKE nodes (set in ../gke), used by the firewall rule."
  type        = string
  default     = "kta-gke-node"
}

variable "nightly_delete_schedule" {
  description = "Cron schedule (in nightly_delete_time_zone) for deleting the GKE cluster."
  type        = string
  default     = "0 1 * * *"
}

variable "nightly_delete_time_zone" {
  description = "Time zone of nightly_delete_schedule."
  type        = string
  default     = "Europe/Berlin"
}
