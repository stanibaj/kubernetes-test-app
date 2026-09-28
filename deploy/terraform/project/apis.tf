# APIs this project needs. The first four were already enabled (imported in
# imports.tf); Cloud Scheduler is new.
#
# disable_on_destroy = false on ALL of them: the project is shared, and
# disabling e.g. compute.googleapis.com because a resource left this config
# would take down everything else in the project. Terraform only ever turns
# these on.

locals {
  services = toset([
    "artifactregistry.googleapis.com",
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "cloudscheduler.googleapis.com",
  ])
}

resource "google_project_service" "this" {
  for_each = local.services

  service            = each.value
  disable_on_destroy = false
}
