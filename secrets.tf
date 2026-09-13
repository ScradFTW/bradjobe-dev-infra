# Terraform creates the secret shells only. Real values are added out of
# band with `gcloud secrets versions add <name> --data-file=-` — never
# through a .tfvars file or a terraform variable, so nothing sensitive ever
# passes through state or this repo. See README.md "Secrets".
resource "google_secret_manager_secret" "ccaas" {
  for_each = toset([
    "ccaas-google-oauth-client-id",
    "ccaas-google-oauth-client-secret",
    "ccaas-session-secret",
    "ccaas-allowed-emails",
  ])

  project   = var.project_id
  secret_id = each.value

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_iam_member" "ccaas_vm_can_read" {
  for_each  = google_secret_manager_secret.ccaas
  project   = var.project_id
  secret_id = each.value.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.ccaas_vm.email}"
}

# GitHub App OAuth token backing the Cloud Build v2 GitHub connection
# (cloudbuild.tf). Created empty here; the real value is a personal access
# token / GitHub App token added once by hand during bootstrap — see
# README.md "Bootstrap", step 4.
resource "google_secret_manager_secret" "github_oauth_token" {
  project   = var.project_id
  secret_id = "github-oauth-token"

  replication {
    auto {}
  }

  depends_on = [google_project_service.apis]
}

resource "google_secret_manager_secret_iam_member" "cloudbuild_sa_can_read_github_token" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.github_oauth_token.secret_id
  role      = "roles/secretmanager.secretAccessor"
  # Cloud Build v2's own service agent reads this to authenticate to GitHub
  # on Terraform's behalf — not either of the deploy identities above.
  member = "serviceAccount:service-${data.google_project.this.number}@gcp-sa-cloudbuild.iam.gserviceaccount.com"
}

data "google_project" "this" {
  project_id = var.project_id
}
