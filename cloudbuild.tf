# One GitHub connection for the whole account, one google_cloudbuildv2_repository
# per repo Cloud Build needs to react to. The connection's underlying GitHub
# App installation is a one-time manual step — see README.md "Bootstrap".
resource "google_cloudbuildv2_connection" "github" {
  project  = var.project_id
  location = var.region
  name     = "github-${lower(var.github_owner)}"

  github_config {
    app_installation_id = var.github_app_installation_id
    authorizer_credential {
      oauth_token_secret_version = "${google_secret_manager_secret.github_oauth_token.id}/versions/latest"
    }
  }

  depends_on = [
    google_project_service.apis,
    google_secret_manager_secret_iam_member.cloudbuild_sa_can_read_github_token,
  ]
}

resource "google_cloudbuildv2_repository" "apps" {
  for_each = var.app_repos

  project           = var.project_id
  location          = var.region
  name              = each.value
  parent_connection = google_cloudbuildv2_connection.github.name
  remote_uri        = "https://github.com/${var.github_owner}/${each.value}.git"
}

# Cloud Build's own repo — same connection, same resource type, listed
# separately in cloudbuild_triggers.tf since its triggers use a different
# service account (terraform_infra, not cloudbuild_app_deployer).
resource "google_cloudbuildv2_repository" "infra" {
  project           = var.project_id
  location          = var.region
  name              = "bradjobe-dev-infra"
  parent_connection = google_cloudbuildv2_connection.github.name
  remote_uri        = "https://github.com/${var.github_owner}/bradjobe-dev-infra.git"
}
