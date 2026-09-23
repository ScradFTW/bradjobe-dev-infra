# One trigger per deployable service, each scoped with included_files so
# a change to one Python backend in llm-testing-deploy (a shared repo for
# three of them) doesn't redeploy its siblings.
locals {
  app_triggers = {
    bradjobe-site = {
      repo_key       = "bradjobe.dev"
      filename       = "cloudbuild.yaml"
      included_files = null
    }
    ai-hub = {
      repo_key       = "demos-ui"
      filename       = "packages/ai-hub/cloudbuild.yaml"
      included_files = ["packages/ai-hub/**"]
    }
    ai-tools = {
      repo_key       = "demos-ui"
      filename       = "packages/ai-tools/cloudbuild.yaml"
      included_files = ["packages/ai-tools/**"]
    }
    genre-classifier = {
      repo_key       = "llm-testing-deploy"
      filename       = "genre-classifier/cloudbuild.yaml"
      included_files = ["genre-classifier/**"]
    }
    image-classifier = {
      repo_key       = "llm-testing-deploy"
      filename       = "image-classifier/cloudbuild.yaml"
      included_files = ["image-classifier/**"]
    }
    agent-orchestrator = {
      repo_key       = "llm-testing-deploy"
      filename       = "agent-orchestrator/cloudbuild.yaml"
      included_files = ["agent-orchestrator/**"]
    }
    pose-tracker = {
      repo_key       = "pose-tracker"
      filename       = "cloudbuild.yaml"
      included_files = null
    }
    ccaas = {
      repo_key       = "ccaas"
      filename       = "cloudbuild.yaml"
      included_files = null
    }
    qwen-llm-gke = {
      repo_key       = "qwen-llm-gke"
      filename       = "cloudbuild.yaml"
      included_files = null
    }
    electionmap = {
      repo_key       = "canelect"
      filename       = "cloudbuild.yaml"
      included_files = null
    }
  }
}

resource "google_cloudbuild_trigger" "app" {
  for_each = local.app_triggers

  project         = var.project_id
  location        = var.region
  name            = "${each.key}-deploy-on-main"
  service_account = "projects/${var.project_id}/serviceAccounts/${google_service_account.cloudbuild_app_deployer.email}"
  filename        = each.value.filename

  repository_event_config {
    repository = google_cloudbuildv2_repository.apps[each.value.repo_key].id
    push {
      branch = "^main$"
    }
  }

  included_files = each.value.included_files

  substitutions = {
    _REGION           = var.region
    _ARTIFACT_REGISTRY = "${var.region}-docker.pkg.dev/${var.project_id}/apps"
  }

  depends_on = [google_project_iam_member.cloudbuild_app_deployer_roles]
}

# --- Terraform self-deploy pipeline for THIS repo --------------------------
# Nobody runs `terraform apply` from a laptop. A PR gets a read-only plan
# posted as a Cloud Build check; merging to main is what actually changes
# infrastructure. See cloudbuild-terraform.yaml and README.md "Bootstrap".
resource "google_cloudbuild_trigger" "terraform_plan_on_pr" {
  project         = var.project_id
  location        = var.region
  name            = "terraform-plan-on-pr"
  service_account = "projects/${var.project_id}/serviceAccounts/${google_service_account.terraform_infra.email}"
  filename        = "cloudbuild-terraform.yaml"

  repository_event_config {
    repository = google_cloudbuildv2_repository.infra.id
    pull_request {
      branch = "^main$"
    }
  }

  substitutions = {
    _TF_COMMAND = "plan"
  }

  depends_on = [google_project_iam_member.terraform_infra_roles]
}

resource "google_cloudbuild_trigger" "terraform_apply_on_main" {
  project         = var.project_id
  location        = var.region
  name            = "terraform-apply-on-main"
  service_account = "projects/${var.project_id}/serviceAccounts/${google_service_account.terraform_infra.email}"
  filename        = "cloudbuild-terraform.yaml"

  repository_event_config {
    repository = google_cloudbuildv2_repository.infra.id
    push {
      branch = "^main$"
    }
  }

  substitutions = {
    _TF_COMMAND = "apply -auto-approve"
  }
}

# Created by hand during bootstrap (README.md step 5) — this exact
# trigger is what runs the very first terraform apply, so it can't be
# created BY that apply. Adopted here instead of recreated/duplicated.
import {
  to = google_cloudbuild_trigger.terraform_apply_on_main
  id = "projects/${var.project_id}/locations/${var.region}/triggers/4f3aa236-c0e7-4c60-98cf-4747c73c19dc"
}
