# --- GKE node identity ---------------------------------------------------
# Minimal roles a GKE node needs to pull images and ship logs/metrics —
# never the sweeping default compute service account.
resource "google_service_account" "gke_node" {
  project      = var.project_id
  account_id   = "sa-gke-node"
  display_name = "GKE node identity (bradjobe-llm-cluster)"
}

resource "google_project_iam_member" "gke_node_roles" {
  for_each = toset([
    "roles/artifactregistry.reader",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.gke_node.email}"
}

# --- ccaas VM identity -----------------------------------------------------
resource "google_service_account" "ccaas_vm" {
  project      = var.project_id
  account_id   = "sa-ccaas-vm"
  display_name = "ccaas GCE VM identity"
}

resource "google_project_iam_member" "ccaas_vm_roles" {
  for_each = toset([
    "roles/artifactregistry.reader",
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/secretmanager.secretAccessor",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.ccaas_vm.email}"
}

# --- Cloud Build: app deploy identity --------------------------------------
# Used by the 9 app-service triggers (cloudbuild_triggers.tf). Deliberately
# narrower than terraform-infra below: it can deploy/build/redeploy the
# things CI is supposed to touch, nothing about IAM policy or networking.
resource "google_service_account" "cloudbuild_app_deployer" {
  project      = var.project_id
  account_id   = "cloudbuild-app-deployer"
  display_name = "Cloud Build — app service deploys"
}

resource "google_project_iam_member" "cloudbuild_app_deployer_roles" {
  for_each = toset([
    "roles/run.developer",
    "roles/artifactregistry.writer",
    "roles/container.developer",   # kubectl apply against bradjobe-llm-cluster
    "roles/compute.instanceAdmin.v1", # restart/query the ccaas VM
    "roles/iap.tunnelResourceAccessor", # SSH to the ccaas VM via IAP, no public port
    "roles/compute.osAdminLogin",  # OS Login + sudo for that SSH session (rsync + systemctl restart)
    "roles/logging.logWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.cloudbuild_app_deployer.email}"
}

# Deploying a Cloud Run revision `--service-account <runtime-sa>` requires
# actAs on that exact SA — grant it per-service rather than a blanket
# project-wide serviceAccountUser.
resource "google_service_account_iam_member" "cloudbuild_can_act_as_runtime_sa" {
  for_each = {
    bradjobe-site       = module.bradjobe_site.runtime_service_account_email
    ai-hub              = module.ai_hub.runtime_service_account_email
    ai-tools            = module.ai_tools.runtime_service_account_email
    pose-tracker        = module.pose_tracker.runtime_service_account_email
    genre-classifier    = module.genre_classifier.runtime_service_account_email
    image-classifier    = module.image_classifier.runtime_service_account_email
    agent-orchestrator  = module.agent_orchestrator.runtime_service_account_email
  }
  service_account_id = "projects/${var.project_id}/serviceAccounts/${each.value}"
  role                = "roles/iam.serviceAccountUser"
  member              = "serviceAccount:${google_service_account.cloudbuild_app_deployer.email}"
}

# --- Cloud Build: Terraform self-deploy identity ---------------------------
# The ONLY identity ever allowed to change this project's infrastructure.
# Used exclusively by the two triggers in cloudbuild_triggers.tf that run
# `terraform plan` (on PRs) / `terraform apply` (on push to main) against
# THIS repo. Nobody applies this configuration from a laptop — see
# README.md "Bootstrap" and versions.tf.
resource "google_service_account" "terraform_infra" {
  project      = var.project_id
  account_id   = "terraform-infra"
  display_name = "Cloud Build — terraform apply for bradjobe-dev-infra"
}

resource "google_project_iam_member" "terraform_infra_roles" {
  for_each = toset([
    "roles/run.admin",
    "roles/container.admin",
    "roles/compute.admin",
    "roles/artifactregistry.admin",
    "roles/dns.admin",
    "roles/secretmanager.admin",
    "roles/iam.serviceAccountAdmin",
    "roles/iam.serviceAccountUser",
    "roles/resourcemanager.projectIamAdmin",
    "roles/storage.admin",
    "roles/serviceusage.serviceUsageAdmin",
    "roles/cloudbuild.builds.editor",
    "roles/cloudbuild.connectionAdmin",
    "roles/logging.logWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.terraform_infra.email}"
}
