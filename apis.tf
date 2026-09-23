# Every API a resource in this repo touches. Re-enabling an already-enabled
# API is a no-op, so this list is intentionally generous.
locals {
  required_apis = [
    "run.googleapis.com",
    "container.googleapis.com",
    "compute.googleapis.com",
    "cloudbuild.googleapis.com",
    "artifactregistry.googleapis.com",
    "dns.googleapis.com",
    "secretmanager.googleapis.com",
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
    "cloudresourcemanager.googleapis.com",
    "storage.googleapis.com",
    "serviceusage.googleapis.com",
    "sts.googleapis.com",
    "billingbudgets.googleapis.com",
    "pubsub.googleapis.com",
    "cloudfunctions.googleapis.com",
    "eventarc.googleapis.com",
    "sqladmin.googleapis.com",
  ]
}

resource "google_project_service" "apis" {
  for_each = toset(local.required_apis)

  project            = var.project_id
  service            = each.value
  disable_on_destroy = false
}
