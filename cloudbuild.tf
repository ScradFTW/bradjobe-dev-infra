# The connection itself (GitHub App installation + its OAuth token secret)
# was created by the Cloud Build console's "Connect Repository" flow
# during bootstrap, not by this resource block — that flow's GitHub OAuth
# consent step is inherently interactive and can't be scripted. (There is
# no data source for this resource type in the google provider, only
# `resource` — so importing it, with config matching its actual live
# values, is the only way to reference it from Terraform at all.) The
# import block below adopts it; Terraform owns its lifecycle from here on
# the same as anything else in this repo, it just didn't create it.
resource "google_cloudbuildv2_connection" "github" {
  project  = var.project_id
  location = var.region
  name     = "scradftw-github"

  github_config {
    app_installation_id = "161463108"
    authorizer_credential {
      oauth_token_secret_version = "projects/${var.project_id}/secrets/scradftw-github-github-oauthtoken-3446ca/versions/latest"
    }
  }
}

import {
  to = google_cloudbuildv2_connection.github
  id = "projects/${var.project_id}/locations/${var.region}/connections/scradftw-github"
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
