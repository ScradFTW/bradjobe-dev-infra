# Election Map (repo: canelect) — anonymous Canadian election prediction
# maps. A Next.js server on Cloud Run with a small Cloud SQL Postgres behind
# it, served at var.electionmap_subdomain through the main load balancer
# (lb.tf host rule).

# --- Database ---------------------------------------------------------------
# The first apply enables the Cloud SQL API and grants terraform-infra
# cloudsql.admin (iam.tf) in the same run. IAM grants take a minute or so to
# propagate, so creating the instance right away can fail with a 403.
resource "time_sleep" "electionmap_sql_prereqs" {
  create_duration = "60s"
  depends_on = [
    google_project_service.apis,
    google_project_iam_member.terraform_infra_roles,
  ]
}

# Smallest shared-core tier; the whole dataset is one table of small JSON
# maps. Only reachable through the Cloud SQL connector (IAM-authorized via
# the service's `roles/cloudsql.client`): public IP is on for the connector, but no
# authorized networks are listed, so nothing can connect to it directly.
resource "google_sql_database_instance" "electionmap" {
  project             = var.project_id
  name                = "electionmap-db"
  region              = var.region
  database_version    = "POSTGRES_16"
  deletion_protection = true

  settings {
    tier              = var.electionmap_db_tier
    edition           = "ENTERPRISE" # shared-core tiers aren't offered on Enterprise Plus
    availability_type = "ZONAL"
    disk_type         = "PD_SSD"
    disk_size         = 10
    disk_autoresize   = true

    # Public IP, but not publicly reachable: with no authorized_networks,
    # the only way in is the Cloud SQL connector (IAM cloudsql.client + TLS).
    # Private IP would need VPC peering plus VPC egress on the Cloud Run
    # service, and would stop the migration runbook's cloud-sql-proxy from
    # working off-network — not worth it for one small public dataset.
    ip_configuration {
      ipv4_enabled = true
      ssl_mode     = "ENCRYPTED_ONLY"
    }

    # Connection and activity logging for auditing (Cloud Logging)
    database_flags {
      name  = "log_connections"
      value = "on"
    }
    database_flags {
      name  = "log_disconnections"
      value = "on"
    }
    database_flags {
      name  = "log_checkpoints"
      value = "on"
    }
    database_flags {
      name  = "log_lock_waits"
      value = "on"
    }
    database_flags {
      name  = "log_temp_files"
      value = "0"
    }

    backup_configuration {
      enabled    = true
      start_time = "08:00" # ~3-4am Eastern
      backup_retention_settings {
        retained_backups = 7
      }
    }
  }

  depends_on = [time_sleep.electionmap_sql_prereqs]
}

resource "google_sql_database" "electionmap" {
  project  = var.project_id
  name     = "electionmap"
  instance = google_sql_database_instance.electionmap.name
}

# --- App user + DATABASE_URL -----------------------------------------------
# Terraform generates the password and hands it to Cloud SQL and Secret
# Manager through write-only arguments, so it's never written to state or
# plan output. The ephemeral password is regenerated on every run but only
# sent when the *_wo_version below changes. To rotate, bump
# local.electionmap_db_password_version: both resources then receive the
# same new password in one apply.
locals {
  electionmap_db_user             = "electionmap"
  electionmap_db_password_version = 1
}

ephemeral "random_password" "electionmap_db" {
  length  = 32
  special = false # keeps the connection string free of URL escaping
}

resource "google_sql_user" "electionmap" {
  project             = var.project_id
  instance            = google_sql_database_instance.electionmap.name
  name                = local.electionmap_db_user
  password_wo         = ephemeral.random_password.electionmap_db.result
  password_wo_version = local.electionmap_db_password_version
}

resource "google_secret_manager_secret" "electionmap_database_url" {
  project   = var.project_id
  secret_id = "electionmap-database-url"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_version" "electionmap_database_url" {
  secret                 = google_secret_manager_secret.electionmap_database_url.id
  secret_data_wo         = "postgresql://${local.electionmap_db_user}:${ephemeral.random_password.electionmap_db.result}@localhost/${google_sql_database.electionmap.name}?host=/cloudsql/${google_sql_database_instance.electionmap.connection_name}"
  secret_data_wo_version = local.electionmap_db_password_version

  # Only publish the URL once the user it names exists
  depends_on = [google_sql_user.electionmap]
}

# --- Service --------------------------------------------------------------------
module "electionmap" {
  source             = "./modules/cloud-run-service"
  project_id         = var.project_id
  region             = var.region
  name               = "electionmap"
  memory             = "512Mi" # Next.js server
  security_policy_id = google_compute_security_policy.default_rate_limit.id
  cloudsql_instances = [google_sql_database_instance.electionmap.connection_name]
  project_roles      = ["roles/cloudsql.client"]

  env = {
    # Google's LB appends "<client-ip>, <lb-ip>" to X-Forwarded-For; the app's
    # per-IP save limit reads the client IP from that position.
    TRUSTED_PROXY_HOPS = "2"
  }

  secret_env = {
    DATABASE_URL = google_secret_manager_secret.electionmap_database_url.secret_id
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_version.electionmap_database_url,
  ]
}

# --- Hostname -----------------------------------------------------------------
# Its own managed cert rather than adding the name to bradjobe-cert: changing
# a managed cert's domains replaces it, which would briefly take the main
# site's HTTPS down. The HTTPS proxy serves both by SNI (lb.tf).
resource "google_compute_managed_ssl_certificate" "electionmap" {
  name    = "electionmap-cert"
  project = var.project_id

  managed {
    domains = [var.electionmap_subdomain]
  }
}

resource "google_dns_record_set" "electionmap" {
  name         = "${var.electionmap_subdomain}."
  project      = var.project_id
  managed_zone = google_dns_managed_zone.main.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.main.address]
}
