# One runtime identity per service — least privilege, and it's what lets
# `iam.tf` grant agent-orchestrator run.invoker on exactly genre-classifier
# instead of every service trusting every other service.
resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = "sa-${var.name}"
  display_name = "Runtime identity for Cloud Run service ${var.name}"
}

# Terraform owns the service's existence, scaling, and IAM. It deliberately
# does NOT own the deployed image: Cloud Build deploys new revisions on every
# push to main (see the app repo's cloudbuild.yaml), and re-running
# `terraform apply` must never roll that back to this placeholder.
resource "google_cloud_run_v2_service" "this" {
  project  = var.project_id
  name     = var.name
  location = var.region

  # Only reachable through the shared load balancer (lb.tf) or from other
  # Cloud Run services in this project — never directly via the *.run.app
  # URL. Public access below is scoped to the LB path, not the raw URL.
  ingress = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"

  template {
    service_account = google_service_account.runtime.email

    scaling {
      min_instance_count = 0
      max_instance_count = var.max_instance_count
    }

    containers {
      # Placeholder — immediately replaced by the first Cloud Build deploy.
      # See the ignore_changes lifecycle rule below.
      image = "us-docker.pkg.dev/cloudrun/container/hello"

      resources {
        limits = {
          cpu    = var.cpu
          memory = var.memory
        }
      }

      dynamic "env" {
        for_each = var.env
        content {
          name  = env.key
          value = env.value
        }
      }
    }
  }

  lifecycle {
    ignore_changes = [
      # Cloud Build owns the deployed image tag from here on — Terraform
      # must never roll a revision back to the `hello` placeholder above.
      # `env` is NOT ignored: Terraform stays authoritative for config
      # (e.g. agent-orchestrator's LLAMA_URL/GENRE_URL), since the app
      # repos' cloudbuild.yaml only ever deploys a new image, not new env
      # vars.
      template[0].containers[0].image,
      # `gcloud run deploy` stamps these on every revision; without
      # ignoring them, every `terraform plan` after a CI deploy shows a
      # spurious diff.
      client,
      client_version,
    ]
  }
}

resource "google_cloud_run_v2_service_iam_member" "public" {
  project  = var.project_id
  location = var.region
  name     = google_cloud_run_v2_service.this.name
  role     = "roles/run.invoker"
  member   = "allUsers"
}

resource "google_compute_region_network_endpoint_group" "this" {
  project               = var.project_id
  name                  = "${var.name}-neg"
  region                = var.region
  network_endpoint_type = "SERVERLESS"
  cloud_run {
    service = google_cloud_run_v2_service.this.name
  }
}

resource "google_compute_backend_service" "this" {
  project         = var.project_id
  name            = "${var.name}-backend"
  security_policy = var.security_policy_id

  backend {
    group = google_compute_region_network_endpoint_group.this.id
  }

  log_config {
    enable = true
  }
}
