# The long-lived part of dns-chatbot-sb that this project uses: APIs, the
# image registry, service accounts, firewall rules, the k3s VMs and the
# nightly GKE delete job. Most of it existed before Terraform and is adopted
# with the import blocks in imports.tf. See docs/stage-4.md.
#
#   make tf-plan / make tf-apply

terraform {
  required_version = ">= 1.16.0"

  # State lives in the bucket made by ../bootstrap. Backend blocks can't use
  # variables, hence the literal names.
  backend "gcs" {
    bucket = "dns-chatbot-sb-tfstate"
    prefix = "kubernetes-test-app/project"
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.4"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}
