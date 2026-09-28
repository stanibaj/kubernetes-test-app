# The k3s lab (Stage 3): three VMs plus the schedule that stops them every
# night. All of this existed before Terraform; it is IMPORTED (imports.tf),
# and the code below was written to match the real VMs exactly, so the plan
# shows no changes for them.
#
# Safety first, because a VM that Terraform decides to "replace" is a
# deleted k3s node:
#   - prevent_destroy: any plan that would delete or replace a VM fails.
#   - ignore_changes on metadata: the startup script (it contains a secret)
#     is never written in code. NOTE: once imported, it IS in the state file
#     (the state bucket is private, see ../bootstrap).
#   - ignore_changes on boot_disk initialize_params: those only matter when
#     a disk is CREATED (image, size); a newer image must never mean
#     "recreate the VM".
#   - no allow_stopping_for_update: a change that needs a stopped VM makes
#     the apply fail instead of stopping the node.
#   - no desired_status: starting and stopping belongs to the schedule
#     (and to you), not to Terraform.

# Stops the VMs every night at 23:00 Prague time. There is no start
# schedule: start them yourself with
#   gcloud compute instances start gcp-srv-02 gcp-srv-03 gcp-srv-04 --zone us-central1-a
resource "google_compute_resource_policy" "k3s_lab_schedule" {
  name        = "k3s-lab-schedule"
  region      = var.region
  description = "Nightly stop of k3s lab VMs (gcp-srv-02..04)"

  instance_schedule_policy {
    time_zone = "Europe/Prague"
    vm_stop_schedule {
      schedule = "0 23 * * *"
    }
  }
}

locals {
  # The server is a regular VM; the two agents are Spot VMs (cheap, may be
  # reclaimed by Google, and then just stop).
  k3s_nodes = {
    "gcp-srv-02" = { machine_type = "e2-medium", role = "k3s-server", spot = false }
    "gcp-srv-03" = { machine_type = "e2-small", role = "k3s-worker", spot = true }
    "gcp-srv-04" = { machine_type = "e2-small", role = "k3s-worker", spot = true }
  }
}

data "google_compute_default_service_account" "default" {}

resource "google_compute_instance" "k3s" {
  for_each = local.k3s_nodes

  name         = each.key
  zone         = var.zone
  machine_type = each.value.machine_type

  # Matches the deny-ingress-tailscale-only firewall rule.
  tags = ["tailscale-only"]

  labels = {
    purpose = "k8s-learning"
    role    = each.value.role
  }

  boot_disk {
    auto_delete = true
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-minimal-2604-resolute-amd64-v20260918"
      size  = 30
      type  = "pd-balanced"
    }
  }

  network_interface {
    network    = "default"
    subnetwork = "default"
    # An ephemeral public IP, used only for outbound traffic (the firewall
    # drops everything inbound).
    access_config {}
  }

  scheduling {
    provisioning_model          = each.value.spot ? "SPOT" : "STANDARD"
    preemptible                 = each.value.spot
    automatic_restart           = !each.value.spot
    on_host_maintenance         = each.value.spot ? "TERMINATE" : "MIGRATE"
    instance_termination_action = each.value.spot ? "STOP" : null
  }

  # The Compute Engine default SA with the default scopes, as created.
  service_account {
    email = data.google_compute_default_service_account.default.email
    scopes = [
      "https://www.googleapis.com/auth/devstorage.read_only",
      "https://www.googleapis.com/auth/logging.write",
      "https://www.googleapis.com/auth/monitoring.write",
      "https://www.googleapis.com/auth/pubsub",
      "https://www.googleapis.com/auth/service.management.readonly",
      "https://www.googleapis.com/auth/servicecontrol",
      "https://www.googleapis.com/auth/trace.append",
    ]
  }

  shielded_instance_config {
    enable_secure_boot          = false
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  resource_policies = [google_compute_resource_policy.k3s_lab_schedule.self_link]

  lifecycle {
    prevent_destroy = true
    ignore_changes = [
      metadata,
      metadata_startup_script,
      boot_disk[0].initialize_params,
    ]
  }
}
