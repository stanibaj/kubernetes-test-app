# Bootstrap: the GCS bucket that holds the Terraform state of the other two
# stacks (project/ and gke/). See docs/stage-4.md "Provisioning with Terraform".
#
# Chicken and egg: a backend "gcs" block needs the bucket to exist BEFORE
# `terraform init`, so this one stack keeps its own (tiny) state locally in
# terraform.tfstate here (gitignored). If that file is ever lost, nothing
# breaks: re-adopt the bucket with
#   terraform -chdir=deploy/terraform/bootstrap import google_storage_bucket.tfstate dns-chatbot-sb-tfstate
#
#   make tf-bootstrap      (= terraform -chdir=deploy/terraform/bootstrap init && ... apply)

terraform {
  required_version = ">= 1.16.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 8.4"
    }
  }
}

variable "project_id" {
  description = "GCP project that owns the state bucket."
  type        = string
  default     = "dns-chatbot-sb"
}

variable "region" {
  description = "Region of the bucket (same as everything else in this project)."
  type        = string
  default     = "us-central1"
}

provider "google" {
  project = var.project_id
  region  = var.region
}

resource "google_storage_bucket" "tfstate" {
  # Bucket names are global across all of GCS, hence the project prefix.
  name     = "${var.project_id}-tfstate"
  location = var.region

  # Every state write keeps the previous version: a broken apply or a bad
  # manual edit can be rolled back by restoring an older object version.
  versioning {
    enabled = true
  }

  # IAM only (no per-object ACLs), and never public: the state contains
  # every attribute of every resource, sometimes secrets.
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Refuse to delete a bucket that still has objects in it.
  force_destroy = false

  labels = {
    purpose = "terraform-state"
    project = "kubernetes-test-app"
  }

  # `terraform destroy` here would lose all other stacks' state.
  lifecycle {
    prevent_destroy = true
  }
}

output "bucket" {
  description = "Put this in the backend \"gcs\" blocks of the other stacks."
  value       = google_storage_bucket.tfstate.name
}
