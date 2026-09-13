# One Docker repo for every image this project builds: the 7 Cloud Run
# services, the 3 ccaas images (backend/sandbox/egress-proxy), and the
# qwen-llm image. Splitting further isn't worth the extra IAM surface for a
# personal site.
resource "google_artifact_registry_repository" "apps" {
  location      = var.region
  repository_id = "apps"
  format        = "DOCKER"
  description   = "Container images for every bradjobe.dev service."

  depends_on = [google_project_service.apis]
}
