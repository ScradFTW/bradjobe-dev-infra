# Spending cap for the LLM demo: once bradjobe-llm-cluster's spend for the
# calendar month reaches var.llm_monthly_budget, every node pool is scaled
# to 0. The cluster and its config are kept, so restoring is one resize.
#
#   billing budget ──(every update)──▶ Pub/Sub ──▶ Cloud Function
#                                                  (functions/llm-budget-guard)
#                                                  costAmount >= budgetAmount
#                                                  → set_node_pool_size(0)
#
# The budget filters on the goog-k8s-cluster-name label that GKE puts on
# every node VM, so it counts the node compute + disks (the bulk of the
# cost). It does NOT count the llm.bradjobe.dev Ingress load balancer,
# which has no such label.
#
# Billing data lags actual usage by a few hours, so the pools shut off a
# few hours after the cap is really crossed, not at the exact moment.
#
# To bring the demo back before the month rolls over, raise
# llm_monthly_budget first (otherwise the next notification re-zeroes it),
# then: gcloud container clusters resize bradjobe-llm-cluster \
#   --zone=northamerica-northeast1-c --node-pool=llm-cpu-pool --num-nodes=4

data "google_project" "this" {
  project_id = var.project_id
}

resource "google_pubsub_topic" "llm_budget_alerts" {
  name    = "llm-budget-alerts"
  project = var.project_id

  depends_on = [google_project_service.apis]
}

# The Billing Budgets service publishes as this Google-managed account.
resource "google_pubsub_topic_iam_member" "billing_can_publish" {
  project = var.project_id
  topic   = google_pubsub_topic.llm_budget_alerts.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:billing-budget-alert@system.gserviceaccount.com"
}

resource "google_billing_budget" "llm" {
  billing_account = var.billing_account_id
  display_name    = "bradjobe-llm-cluster monthly cap"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
    labels = {
      "goog-k8s-cluster-name" = google_container_cluster.llm.name
    }
    calendar_period = "MONTH"
    # Gross cost, before credits: free-tier/promo credits shouldn't let the
    # cluster run past the cap unnoticed and then bill once they run out.
    credit_types_treatment = "EXCLUDE_ALL_CREDITS"
  }

  amount {
    specified_amount {
      # Must match the billing account's currency (CAD).
      currency_code = "CAD"
      units         = tostring(var.llm_monthly_budget)
    }
  }

  # Emails to the billing account admins on the way up, as a heads-up
  # before the guard trips at 100%.
  threshold_rules {
    threshold_percent = 0.5
  }
  threshold_rules {
    threshold_percent = 0.9
  }
  threshold_rules {
    threshold_percent = 1.0
  }

  all_updates_rule {
    pubsub_topic   = google_pubsub_topic.llm_budget_alerts.id
    schema_version = "1.0"
  }

  depends_on = [google_pubsub_topic_iam_member.billing_can_publish]
}

# --- The guard function -----------------------------------------------------

resource "google_service_account" "llm_budget_guard" {
  project      = var.project_id
  account_id   = "llm-budget-guard"
  display_name = "Scales bradjobe-llm-cluster to 0 when its budget is spent"
}

resource "google_project_iam_member" "llm_budget_guard_roles" {
  for_each = toset([
    "roles/container.clusterAdmin", # set_node_pool_size
    "roles/run.invoker",            # Eventarc → the function's Cloud Run service
    "roles/eventarc.eventReceiver",
    "roles/logging.logWriter",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.llm_budget_guard.email}"
}

# Builds the function's container. Given its own account instead of the
# project's default compute SA so it has exactly these roles and no more.
resource "google_service_account" "functions_builder" {
  project      = var.project_id
  account_id   = "functions-builder"
  display_name = "Cloud Build — builds Cloud Functions source"
}

resource "google_project_iam_member" "functions_builder_roles" {
  for_each = toset([
    "roles/logging.logWriter",
    "roles/artifactregistry.writer",
    "roles/storage.objectViewer",
  ])
  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.functions_builder.email}"
}

resource "google_storage_bucket" "functions_source" {
  name                        = "${var.project_id}-functions-source"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true

  depends_on = [google_project_service.apis]
}

data "archive_file" "llm_budget_guard" {
  type        = "zip"
  source_dir  = "${path.module}/functions/llm-budget-guard"
  output_path = "${path.module}/.build/llm-budget-guard.zip"
}

# Named by content hash so any change to the source redeploys the function.
resource "google_storage_bucket_object" "llm_budget_guard" {
  bucket = google_storage_bucket.functions_source.name
  name   = "llm-budget-guard-${data.archive_file.llm_budget_guard.output_md5}.zip"
  source = data.archive_file.llm_budget_guard.output_path
}

resource "google_cloudfunctions2_function" "llm_budget_guard" {
  name     = "llm-budget-guard"
  project  = var.project_id
  location = var.region

  build_config {
    runtime         = "python312"
    entry_point     = "handle_budget_notification"
    service_account = google_service_account.functions_builder.id
    source {
      storage_source {
        bucket = google_storage_bucket.functions_source.name
        object = google_storage_bucket_object.llm_budget_guard.name
      }
    }
  }

  service_config {
    available_memory      = "256M"
    max_instance_count    = 1
    ingress_settings      = "ALLOW_INTERNAL_ONLY"
    service_account_email = google_service_account.llm_budget_guard.email
    environment_variables = {
      PROJECT_ID       = var.project_id
      CLUSTER_LOCATION = google_container_cluster.llm.location
      CLUSTER_NAME     = google_container_cluster.llm.name
    }
  }

  event_trigger {
    trigger_region        = var.region
    event_type            = "google.cloud.pubsub.topic.v1.messagePublished"
    pubsub_topic          = google_pubsub_topic.llm_budget_alerts.id
    retry_policy          = "RETRY_POLICY_DO_NOT_RETRY" # the next budget update is the retry
    service_account_email = google_service_account.llm_budget_guard.email
  }

  depends_on = [
    google_project_iam_member.llm_budget_guard_roles,
    google_project_iam_member.functions_builder_roles,
  ]
}
