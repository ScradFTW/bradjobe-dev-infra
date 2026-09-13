# --- Static / no-backend services -------------------------------------
# Main portfolio site. Repo: bradjobe.dev.
module "bradjobe_site" {
  source              = "./modules/cloud-run-service"
  project_id          = var.project_id
  region              = var.region
  name                = "bradjobe-site"
  memory              = "256Mi"
  security_policy_id  = google_compute_security_policy.default_rate_limit.id
  depends_on          = [google_project_service.apis]
}

# Landing page tying the demos together. Repo: demos-ui, package ai-hub.
module "ai_hub" {
  source             = "./modules/cloud-run-service"
  project_id         = var.project_id
  region             = var.region
  name               = "ai-hub"
  memory             = "256Mi"
  security_policy_id = google_compute_security_policy.default_rate_limit.id
  depends_on         = [google_project_service.apis]
}

# One shared SPA build served at /agent-demo/, /genre-classifier/,
# /image-classifier/, /llm-testing/, /status/ (see lb.tf path rules).
# Repo: demos-ui, package ai-tools.
module "ai_tools" {
  source             = "./modules/cloud-run-service"
  project_id         = var.project_id
  region             = var.region
  name               = "ai-tools"
  memory             = "256Mi"
  security_policy_id = google_compute_security_policy.default_rate_limit.id
  depends_on         = [google_project_service.apis]
}

# Browser-only pose tracking (ONNX runtime + wasm) — this service only ever
# serves static files. Repo: pose-tracker.
module "pose_tracker" {
  source             = "./modules/cloud-run-service"
  project_id         = var.project_id
  region             = var.region
  name               = "pose-tracker"
  memory             = "256Mi"
  security_policy_id = google_compute_security_policy.default_rate_limit.id
  depends_on         = [google_project_service.apis]
}

# --- Python/Flask backends (repo: llm-testing-deploy) -------------------

# Called directly by the browser at /genre-classifier/api/*, and
# server-to-server by agent-orchestrator (see the run.invoker grant below).
module "genre_classifier" {
  source             = "./modules/cloud-run-service"
  project_id         = var.project_id
  region             = var.region
  name               = "genre-classifier"
  memory             = "512Mi" # scikit-learn pipeline
  security_policy_id = google_compute_security_policy.demo_api_rate_limit.id
  depends_on         = [google_project_service.apis]
}

module "image_classifier" {
  source             = "./modules/cloud-run-service"
  project_id         = var.project_id
  region             = var.region
  name               = "image-classifier"
  memory             = "512Mi" # onnxruntime
  security_policy_id = google_compute_security_policy.demo_api_rate_limit.id
  depends_on         = [google_project_service.apis]
}

# Calls the Qwen LLM (its own public subdomain, gke.tf/dns.tf) and
# genre-classifier (service-to-service, ID-token authenticated) as a tool.
module "agent_orchestrator" {
  source             = "./modules/cloud-run-service"
  project_id         = var.project_id
  region             = var.region
  name               = "agent-orchestrator"
  memory             = "256Mi"
  security_policy_id = google_compute_security_policy.demo_api_rate_limit.id
  env = {
    LLAMA_URL = "https://${var.llm_subdomain}/v1/chat/completions"
    GENRE_URL = "${module.genre_classifier.service_uri}/predict"
  }
  depends_on = [google_project_service.apis]
}

# agent-orchestrator authenticates to genre-classifier with a Google ID
# token (see llm-testing-deploy/agent-orchestrator's app.py change in its
# PR) instead of relying on network-path trust.
resource "google_cloud_run_v2_service_iam_member" "agent_orchestrator_calls_genre_classifier" {
  project  = var.project_id
  location = var.region
  name     = module.genre_classifier.service_name
  role     = "roles/run.invoker"
  member   = "serviceAccount:${module.agent_orchestrator.runtime_service_account_email}"
}
