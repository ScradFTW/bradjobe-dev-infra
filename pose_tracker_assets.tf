# pose-tracker's vendor/ assets (onnxruntime-web's WASM runtime + the
# trained pose_net.onnx model, ~61MB) can't be served through Cloud Run
# at all: Cloud Run enforces a 32MB response size limit, confirmed for
# real — nginx itself served the file fine (200, full byte count in its
# own access log), but Cloud Run's own proxy cut the response short and
# the client saw a 500. GCS backend buckets have no such limit and are
# the standard way to serve large static files behind this same load
# balancer, so vendor/ is routed here instead (lb.tf), bypassing
# pose-tracker's Cloud Run container entirely for these paths.
resource "google_storage_bucket" "pose_tracker_vendor" {
  name                        = "${var.project_id}-pose-tracker-vendor"
  project                     = var.project_id
  location                    = var.region
  uniform_bucket_level_access = true

  depends_on = [google_project_service.apis]
}

resource "google_storage_bucket_iam_member" "pose_tracker_vendor_public_read" {
  bucket = google_storage_bucket.pose_tracker_vendor.name
  role   = "roles/storage.objectViewer"
  member = "allUsers"
}

# pose-tracker's own Cloud Build pipeline uploads the actual objects
# (fetch-vendor.sh's output + the committed pose_net.onnx) on every
# deploy — Terraform only owns the bucket's existence, not its contents.
resource "google_storage_bucket_iam_member" "pose_tracker_vendor_writable_by_cicd" {
  bucket = google_storage_bucket.pose_tracker_vendor.name
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.cloudbuild_app_deployer.email}"
}

resource "google_compute_backend_bucket" "pose_tracker_vendor" {
  name        = "pose-tracker-vendor-backend"
  project     = var.project_id
  bucket_name = google_storage_bucket.pose_tracker_vendor.name
  enable_cdn  = true # immutable, content-hashed-in-spirit static assets — exactly what CDN caching is for
}
