# Single-zone cluster dedicated to the Qwen LLM demo. Zonal (not regional)
# both because a personal demo doesn't need a multi-zone control plane and
# because most billing accounts get one zonal cluster's management fee
# waived — see README.md "Cost estimate".
resource "google_container_cluster" "llm" {
  name     = "bradjobe-llm-cluster"
  location = var.zone
  project  = var.project_id

  network    = google_compute_network.main.id
  subnetwork = google_compute_subnetwork.main.id

  networking_mode = "VPC_NATIVE"
  ip_allocation_policy {
    cluster_secondary_range_name  = "gke-pods"
    services_secondary_range_name = "gke-services"
  }

  # The GPU pool below is the only node pool this cluster runs — no
  # separate "system" pool. Deleting the auto-created default pool means
  # every node (and every dollar) here is one we actually asked for.
  remove_default_node_pool = true
  initial_node_count       = 1

  deletion_protection = false

  release_channel {
    channel = "REGULAR"
  }

  depends_on = [google_project_service.apis]
}

resource "google_container_node_pool" "llm_gpu" {
  name     = "llm-gpu-pool"
  cluster  = google_container_cluster.llm.id
  location = var.zone
  project  = var.project_id

  node_count = var.llm_gpu_node_count

  node_config {
    machine_type    = var.llm_gpu_machine_type
    spot            = true
    service_account = google_service_account.gke_node.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    guest_accelerator {
      type  = var.llm_gpu_type
      count = 1

      gpu_driver_installation_config {
        gpu_driver_version = "LATEST"
      }
    }

    labels = {
      workload = "qwen-llm"
    }

    # Spot nodes can be reclaimed at any time; keeping the taint means only
    # workloads that explicitly tolerate it (the qwen-llm Deployment, see
    # qwen-llm-gke/k8s/deployment.yaml) ever land here.
    taint {
      key    = "cloud.google.com/gke-spot"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }

  # Fixed size, no autoscaler: "at least two nodes" is a floor for the demo,
  # not a workload that needs to grow, and a fixed Spot pool keeps the
  # monthly cost predictable. Bump llm_gpu_node_count if that changes.
}
