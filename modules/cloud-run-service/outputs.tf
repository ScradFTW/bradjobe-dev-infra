output "service_name" {
  value = google_cloud_run_v2_service.this.name
}

output "service_uri" {
  value = google_cloud_run_v2_service.this.uri
}

output "runtime_service_account_email" {
  value = google_service_account.runtime.email
}

output "backend_service_id" {
  value = google_compute_backend_service.this.id
}

output "backend_service_name" {
  value = google_compute_backend_service.this.name
}
