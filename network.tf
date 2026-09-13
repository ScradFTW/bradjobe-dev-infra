# Custom VPC (not `default`) so firewall rules stay intentional. Sized for
# a personal-site workload: one subnet, two secondary ranges for the
# VPC-native GKE cluster's pod/service IPs.
resource "google_compute_network" "main" {
  name                    = "bradjobe-vpc"
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

resource "google_compute_subnetwork" "main" {
  name          = "bradjobe-subnet"
  network       = google_compute_network.main.id
  region        = var.region
  ip_cidr_range = "10.10.0.0/20"

  secondary_ip_range {
    range_name    = "gke-pods"
    ip_cidr_range = "10.16.0.0/16"
  }
  secondary_ip_range {
    range_name    = "gke-services"
    ip_cidr_range = "10.24.0.0/20"
  }
}

# Google's health-check and GFE ranges, used by both the classic external LB
# (ccaas backend, GKE Ingress) and container-native NEGs.
resource "google_compute_firewall" "allow_lb_health_checks" {
  name    = "allow-lb-health-checks"
  network = google_compute_network.main.id

  direction     = "INGRESS"
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  allow {
    protocol = "tcp"
  }
}

# IAP's TCP forwarding range — lets `gcloud compute ssh --tunnel-through-iap`
# reach the ccaas VM and GKE nodes without either needing a public SSH port.
resource "google_compute_firewall" "allow_iap_ssh" {
  name    = "allow-iap-ssh"
  network = google_compute_network.main.id

  direction     = "INGRESS"
  source_ranges = ["35.235.240.0/20"]
  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# The ccaas VM has no public IP (gce_ccaas.tf), but still needs real
# internet egress: its startup script installs Docker/nginx from the
# public internet, and dockerode pulls/runs images that themselves need
# egress (gated per-user by the Squid egress-proxy container it manages —
# that's a policy control at the container level, not a substitute for the
# VM having a path out at all). GKE nodes route through the same NAT for
# anything not reachable via Private Google Access.
resource "google_compute_router" "main" {
  name    = "bradjobe-router"
  project = var.project_id
  region  = var.region
  network = google_compute_network.main.id
}

resource "google_compute_router_nat" "main" {
  name    = "bradjobe-nat"
  project = var.project_id
  region  = var.region
  router  = google_compute_router.main.name

  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"
}

resource "google_compute_firewall" "allow_internal" {
  name    = "allow-internal"
  network = google_compute_network.main.id

  direction     = "INGRESS"
  source_ranges = [
    google_compute_subnetwork.main.ip_cidr_range,
    "10.16.0.0/16",
    "10.24.0.0/20",
  ]
  allow {
    protocol = "tcp"
  }
  allow {
    protocol = "udp"
  }
  allow {
    protocol = "icmp"
  }
}
