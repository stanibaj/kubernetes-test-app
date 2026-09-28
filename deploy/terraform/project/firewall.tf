# Firewall rules on the "default" VPC network.

# k3s VMs (tag tailscale-only): drop ALL inbound traffic arriving over the
# VPC, public and internal alike. The k3s nodes talk to each other and to
# you over Tailscale, which this rule doesn't see. Imported (existed before).
# Never put this tag on GKE nodes: GKE nodes, pods and the control plane
# talk over the VPC, so this would break the cluster.
resource "google_compute_firewall" "deny_ingress_tailscale_only" {
  name        = "deny-ingress-tailscale-only"
  network     = "default"
  description = "Block all inbound (incl. VPC-internal) to tailscale-only VMs; access only via Tailscale"
  direction   = "INGRESS"
  priority    = 100

  deny {
    protocol = "all"
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = ["tailscale-only"]
}

# GKE nodes: close SSH and RDP from anywhere. The project-wide
# default-allow-ssh/rdp rules (priority 65534) would otherwise open them on
# the nodes' ephemeral public IPs; this deny at priority 100 wins. Nothing
# of the app listens on the nodes (the page is served only over Tailscale).
resource "google_compute_firewall" "gke_deny_public_admin" {
  name        = "kta-gke-deny-public-admin"
  network     = "default"
  description = "kta-gke nodes: no SSH/RDP from anywhere (the app is reachable only over Tailscale)"
  direction   = "INGRESS"
  priority    = 100

  deny {
    protocol = "tcp"
    ports    = ["22", "3389"]
  }

  source_ranges = ["0.0.0.0/0"]
  target_tags   = [var.gke_node_tag]
}
