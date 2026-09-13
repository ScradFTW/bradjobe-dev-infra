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

# No github-oauth-token secret here: the Cloud Console's "Connect
# Repository" flow creates its own secret (and grants Cloud Build's
# service agent access to it) as part of installing the GitHub App during
# bootstrap. cloudbuild.tf's data.google_cloudbuildv2_connection just
# references that connection by name — Terraform never owns this secret.
