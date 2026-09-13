# The connection itself (GitHub App installation + its OAuth token secret)
# is created by the Cloud Console's "Connect Repository" flow during
# bootstrap, not by Terraform — that flow's GitHub OAuth consent step is
# inherently interactive and can't be scripted. This is a data source, not
# a resource, precisely because Terraform doesn't own its lifecycle; it
# only needs to reference it to attach repositories. See README.md
# "Bootstrap".
data "google_cloudbuildv2_connection" "github" {
  project  = var.project_id
  location = var.region
  name     = "scradftw-github"
}

resource "google_cloudbuildv2_repository" "apps" {
  for_each = var.app_repos

  project           = var.project_id
  location          = var.region
  name              = each.value
  parent_connection = data.google_cloudbuildv2_connection.github.name
  remote_uri        = "https://github.com/${var.github_owner}/${each.value}.git"
}

# Cloud Build's own repo — same connection, same resource type, listed
# separately in cloudbuild_triggers.tf since its triggers use a different
# service account (terraform_infra, not cloudbuild_app_deployer).
resource "google_cloudbuildv2_repository" "infra" {
  project           = var.project_id
  location          = var.region
  name              = "bradjobe-dev-infra"
  parent_connection = data.google_cloudbuildv2_connection.github.name
  remote_uri        = "https://github.com/${var.github_owner}/bradjobe-dev-infra.git"
}

# This one had to be created by hand during bootstrap (`gcloud builds
# repositories create bradjobe-dev-infra ...`): the bootstrap trigger
# needs it to exist before the first `terraform apply` can ever run, so
# it can't be the thing that first apply creates. This import block makes
# that same first apply reconcile onto the existing resource instead of
# failing with "already exists" — no separate `terraform import` command
# needed (there's nowhere to run one from — see versions.tf).
import {
  to = google_cloudbuildv2_repository.infra
  id = "projects/${var.project_id}/locations/${var.region}/connections/scradftw-github/repositories/bradjobe-dev-infra"
}
