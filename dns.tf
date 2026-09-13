# DNS hosting moves from the registrar to Cloud DNS. Terraform manages the
# zone and every record; the one step it cannot do for you is pointing the
# registrar's nameservers at `google_dns_managed_zone.main.name_servers`
# (output below) — a registrar-side change, done once, see README.md
# "Bootstrap"/"Cutover".
resource "google_dns_managed_zone" "main" {
  name        = "bradjobe-dev-zone"
  project     = var.project_id
  dns_name    = "${var.domain}."
  description = "bradjobe.dev — migrated from registrar DNS to Cloud DNS."

  depends_on = [google_project_service.apis]
}

resource "google_dns_record_set" "apex" {
  name         = google_dns_managed_zone.main.dns_name
  project      = var.project_id
  managed_zone = google_dns_managed_zone.main.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.main.address]
}

resource "google_dns_record_set" "www" {
  name         = "www.${google_dns_managed_zone.main.dns_name}"
  project      = var.project_id
  managed_zone = google_dns_managed_zone.main.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.main.address]
}

resource "google_dns_record_set" "llm" {
  name         = "${var.llm_subdomain}."
  project      = var.project_id
  managed_zone = google_dns_managed_zone.main.name
  type         = "A"
  ttl          = 300
  rrdatas      = [google_compute_global_address.llm_ingress.address]
}
