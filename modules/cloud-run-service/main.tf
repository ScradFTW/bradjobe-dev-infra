# One runtime identity per service — least privilege, and it's what lets
# `iam.tf` grant agent-orchestrator run.invoker on exactly genre-classifier
# instead of every service trusting every other service.
resource "google_service_account" "runtime" {
  project      = var.project_id
  account_id   = "sa-${var.name}"
  display_name = "Runtime identity for Cloud Run service ${var.name}"
}

# Granted before the service exists: a revision that can't read its secrets
# fails to start, which would fail the apply.
resource "google_secret_manager_secret_iam_member" "runtime_reads_secret" {
  for_each  = var.secret_env
  project   = var.project_id
  secret_id = each.value
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.runtime.email}"
}

resource "google_project_iam_member" "runtime_roles" {
  for_each = var.project_roles
  project  = var.project_id
  role     = each.value
  member   = "serviceAccount:${google_service_account.runtime.email}"
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
        # CPU only allocated while handling a request, not for the life of
        # the instance — the right default for these low-traffic services
        # (cheaper: idle instances aren't billed for CPU) and required by
        # Cloud Run below 512Mi: "always allocated" CPU rejects memory
        # under 512Mi outright.
        cpu_idle = true
      }

      dynamic "env" {
        for_each = var.env
        content {
          name  = env.key
          value = env.value
        }
      }

      dynamic "env" {
        for_each = var.secret_env
        content {
          name = env.key
          value_source {
            secret_key_ref {
              secret  = env.value
              version = "latest"
            }
          }
        }
      }

      dynamic "volume_mounts" {
        for_each = length(var.cloudsql_instances) > 0 ? [1] : []
        content {
          name       = "cloudsql"
          mount_path = "/cloudsql"
        }
      }
    }

    dynamic "volumes" {
      for_each = length(var.cloudsql_instances) > 0 ? [1] : []
      content {
        name = "cloudsql"
        cloud_sql_instance {
          instances = var.cloudsql_instances
        }
      }
    }
  }

  depends_on = [
    google_secret_manager_secret_iam_member.runtime_reads_secret,
    google_project_iam_member.runtime_roles,
  ]

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
