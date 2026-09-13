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
