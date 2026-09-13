# One Global External HTTPS Load Balancer in front of every Cloud Run
# service and the ccaas VM, path-routed under a single domain — the same
# shape the current single nginx vhost gives bradjobe.dev today. The GKE
# LLM demo deliberately is NOT behind this LB; see gke.tf / dns.tf for why
# it gets its own subdomain + GKE-native Ingress instead.

resource "google_compute_global_address" "main" {
  name    = "bradjobe-lb-ip"
  project = var.project_id
}

resource "google_compute_managed_ssl_certificate" "main" {
  name    = "bradjobe-cert"
  project = var.project_id

  managed {
    domains = [var.domain, "www.${var.domain}"]
  }
}

resource "google_compute_url_map" "main" {
  name            = "bradjobe-url-map"
  project         = var.project_id
  default_service = module.bradjobe_site.backend_service_id

  host_rule {
    hosts        = [var.domain, "www.${var.domain}"]
    path_matcher = "main"
  }

  path_matcher {
    name            = "main"
    default_service = module.bradjobe_site.backend_service_id

    # --- most specific: API subpaths (checked ahead of the SPA prefixes
    # below since a request can only match one route_rule) ---
    route_rules {
      priority = 1
      match_rules {
        prefix_match = "/genre-classifier/api/"
      }
      service = module.genre_classifier.backend_service_id
    }
    route_rules {
      priority = 2
      match_rules {
        prefix_match = "/image-classifier/api/"
      }
      service = module.image_classifier.backend_service_id
    }
    route_rules {
      priority = 3
      match_rules {
        prefix_match = "/agent-demo/api/"
      }
      service = module.agent_orchestrator.backend_service_id
    }

    # /status/api/* fans out to three backends' own /stats endpoint —
    # nginx did this today with three explicit proxy_pass rewrites.
    route_rules {
      priority = 4
      match_rules {
        full_path_match = "/status/api/agent-stats"
      }
      service = module.agent_orchestrator.backend_service_id
      route_action {
        url_rewrite {
          path_prefix_rewrite = "/stats"
        }
      }
    }
    route_rules {
      priority = 5
      match_rules {
        full_path_match = "/status/api/genre-stats"
      }
      service = module.genre_classifier.backend_service_id
      route_action {
        url_rewrite {
          path_prefix_rewrite = "/stats"
        }
      }
    }
    route_rules {
      priority = 6
      match_rules {
        full_path_match = "/status/api/image-stats"
      }
      service = module.image_classifier.backend_service_id
      route_action {
        url_rewrite {
          path_prefix_rewrite = "/stats"
        }
      }
    }

    # --- single-purpose static apps ---
    route_rules {
      priority = 10
      match_rules {
        prefix_match = "/ai/"
      }
      service = module.ai_hub.backend_service_id
    }
    route_rules {
      priority = 11
      match_rules {
        prefix_match = "/pose-tracker/"
      }
      service = module.pose_tracker.backend_service_id
    }

    # --- ccaas: whole subtree (frontend, API, and the /ws/chat upgrade
    # path) is one Node process behind nginx on the VM, same as today.
    # /sites/<slug>/ is ccaas's own dynamically-published user sites
    # (see ccaas/apps/backend/src/sites.js) — same backend, different
    # top-level prefix.
    route_rules {
      priority = 12
      match_rules {
        prefix_match = "/ccaas/"
      }
      service = google_compute_backend_service.ccaas.id
    }
    route_rules {
      priority = 13
      match_rules {
        prefix_match = "/sites/"
      }
      service = google_compute_backend_service.ccaas.id
    }

    # --- shared ai-tools SPA bundle, deployed once and served at five
    # historical paths (see demos-ui/packages/ai-tools/vite.config.js) ---
    route_rules {
      priority = 20
      match_rules {
        prefix_match = "/agent-demo/"
      }
      match_rules {
        prefix_match = "/genre-classifier/"
      }
      match_rules {
        prefix_match = "/image-classifier/"
      }
      match_rules {
        prefix_match = "/llm-testing/"
      }
      match_rules {
        prefix_match = "/status/"
      }
      service = module.ai_tools.backend_service_id
    }
  }
}

resource "google_compute_target_https_proxy" "main" {
  name             = "bradjobe-https-proxy"
  project          = var.project_id
  url_map          = google_compute_url_map.main.id
  ssl_certificates = [google_compute_managed_ssl_certificate.main.id]
}

resource "google_compute_global_forwarding_rule" "https" {
  name       = "bradjobe-https-fr"
  project    = var.project_id
  target     = google_compute_target_https_proxy.main.id
  port_range = "443"
  ip_address = google_compute_global_address.main.id
}

# Plain-HTTP requests get redirected, never served — this is a public
# personal site, not a mixed-content demo.
resource "google_compute_url_map" "http_redirect" {
  name    = "bradjobe-http-redirect"
  project = var.project_id

  default_url_redirect {
    https_redirect = true
    strip_query    = false
  }
}

resource "google_compute_target_http_proxy" "redirect" {
  name    = "bradjobe-http-proxy"
  project = var.project_id
  url_map = google_compute_url_map.http_redirect.id
}

resource "google_compute_global_forwarding_rule" "http" {
  name       = "bradjobe-http-fr"
  project    = var.project_id
  target     = google_compute_target_http_proxy.redirect.id
  port_range = "80"
  ip_address = google_compute_global_address.main.id
}

# --- Reserved for the GKE Ingress (gke.tf / dns.tf) -------------------
# A plain global address, claimed by name from the k8s Ingress manifest
# (`kubernetes.io/ingress.global-static-ip-name: llm-ingress-ip`) in
# qwen-llm-gke/k8s/ingress.yaml — Terraform never creates the Ingress
# itself, only reserves the IP DNS needs to point at ahead of time.
resource "google_compute_global_address" "llm_ingress" {
  name    = "llm-ingress-ip"
  project = var.project_id
}
