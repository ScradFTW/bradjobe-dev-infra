output "load_balancer_ip" {
  description = "Point bradjobe.dev / www.bradjobe.dev at this (already done automatically via Cloud DNS — see name_servers below)."
  value       = google_compute_global_address.main.address
}

output "llm_ingress_ip" {
  description = "IP the GKE Ingress for llm.bradjobe.dev must claim by name (kubernetes.io/ingress.global-static-ip-name: llm-ingress-ip)."
  value       = google_compute_global_address.llm_ingress.address
}

output "name_servers" {
  description = "Set these as bradjobe.dev's nameservers at the registrar to complete the DNS cutover."
  value       = google_dns_managed_zone.main.name_servers
}

output "artifact_registry" {
  value = "${var.region}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.apps.repository_id}"
}

output "gke_cluster_name" {
  value = google_container_cluster.llm.name
}

output "ccaas_vm_internal_ip" {
  value = google_compute_instance.ccaas.network_interface[0].network_ip
}

output "cloud_run_urls" {
  description = "Direct *.run.app URLs — for debugging only; ingress is locked to the load balancer so these 403 from the open internet."
  value = {
    bradjobe-site      = module.bradjobe_site.service_uri
    ai-hub             = module.ai_hub.service_uri
    ai-tools           = module.ai_tools.service_uri
    pose-tracker       = module.pose_tracker.service_uri
    genre-classifier   = module.genre_classifier.service_uri
    image-classifier   = module.image_classifier.service_uri
    agent-orchestrator = module.agent_orchestrator.service_uri
    electionmap        = module.electionmap.service_uri
  }
}

output "electionmap_db_connection_name" {
  description = "Cloud SQL connection name for Election Map's DATABASE_URL (host=/cloudsql/<this>) and for cloud-sql-proxy."
  value       = google_sql_database_instance.electionmap.connection_name
}
