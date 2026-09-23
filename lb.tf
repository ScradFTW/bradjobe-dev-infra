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
    # full_path_match + path_prefix_rewrite, not prefix_match: tried
    # prefix_match first (matching the original nginx's blanket prefix
    # strip), and confirmed for real — via the actual Cloud Run request
    # logs, which showed the backend receiving the UNREWRITTEN path —
    # that combination silently doesn't rewrite anything for a Serverless
    # NEG backend. full_path_match does (already proven by the
    # /status/api/* rules below, which use exactly this combination).
    # Each frontend tab only ever calls one specific endpoint (checked
    # demos-ui's tab components directly), so an explicit rule per
    # endpoint is no less correct than a blanket prefix strip would have
    # been, just less flexible for hypothetical endpoints nothing calls.
    route_rules {
      priority = 1
      match_rules {
        full_path_match = "/genre-classifier/api/predict"
      }
      service = module.genre_classifier.backend_service_id
      route_action {
        url_rewrite {
          path_prefix_rewrite = "/predict"
        }
      }
    }
    route_rules {
      priority = 2
      match_rules {
        full_path_match = "/image-classifier/api/predict"
      }
      service = module.image_classifier.backend_service_id
      route_action {
        url_rewrite {
          path_prefix_rewrite = "/predict"
        }
      }
    }
    route_rules {
      priority = 3
      match_rules {
        full_path_match = "/agent-demo/api/chat"
      }
      service = module.agent_orchestrator.backend_service_id
      route_action {
        url_rewrite {
          path_prefix_rewrite = "/chat"
        }
      }
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
    # pose-tracker's large binary assets (onnxruntime-web's WASM runtime,
    # the ~61MB trained model) go to a GCS backend bucket instead of the
    # Cloud Run container — Cloud Run enforces a 32MB response size limit,
    # confirmed for real (nginx served the file fine; Cloud Run's own
    # proxy cut it short). Priority (and declaration order — GCP requires
    # both to agree; a priority=9 rule declared AFTER a priority=10 rule
    # was rejected outright, confirmed for real) must put this ahead of
    # priority 11's general /pose-tracker/ rule below, which would
    # otherwise shadow it.
    route_rules {
      priority = 9
      match_rules {
        prefix_match = "/pose-tracker/vendor/"
      }
      service = google_compute_backend_bucket.pose_tracker_vendor.id
    }
    route_rules {
      priority = 10
      match_rules {
        prefix_match = "/ai/"
      }
      service = module.ai_hub.backend_service_id
    }

    # No route_action here: prefix_match + path_prefix_rewrite doesn't
    # actually rewrite anything for a Serverless NEG backend (confirmed
    # for real via Cloud Run's own request logs — see the API rules
    # above, which hit the exact same thing and switched to
    # full_path_match instead). Pose-tracker serves many files, not one
    # endpoint, so full_path_match per file isn't practical either — the
    # container itself now serves everything under /pose-tracker/
    # (Dockerfile in that repo), matching ai-hub/ai-tools' already-proven
    # approach of physically mirroring the URL prefix inside the image.
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

    # Bare demo paths (no trailing slash) redirect, same as the current
    # nginx `location = /genre-classifier { return 301 /genre-classifier/; }`
    # style rules — every prefix-matched route above only matches WITH the
    # trailing slash, so without this a bare path would silently fall
    # through to bradjobe-site and 404. Written as 7 literal blocks, not a
    # `dynamic` over a map, deliberately: GCP requires each route_rule's
    # priority to be strictly higher than the previous one IN DECLARATION
    # ORDER, and a `dynamic` block over a map iterates in sorted-key order
    # (alphabetical by path here), not the order the map was written in —
    # that would silently reorder these to 32, 35, 31, 33, 30, 36, 34 and
    # fail the same validation this is fixing.
    route_rules {
      priority = 30
      match_rules {
        full_path_match = "/llm-testing"
      }
      url_redirect {
        path_redirect          = "/llm-testing/"
        redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
        strip_query             = false
      }
    }
    route_rules {
      priority = 31
      match_rules {
        full_path_match = "/genre-classifier"
      }
      url_redirect {
        path_redirect          = "/genre-classifier/"
        redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
        strip_query             = false
      }
    }
    route_rules {
      priority = 32
      match_rules {
        full_path_match = "/agent-demo"
      }
      url_redirect {
        path_redirect          = "/agent-demo/"
        redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
        strip_query             = false
      }
    }
    route_rules {
      priority = 33
      match_rules {
        full_path_match = "/image-classifier"
      }
      url_redirect {
        path_redirect          = "/image-classifier/"
        redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
        strip_query             = false
      }
    }
    route_rules {
      priority = 34
      match_rules {
        full_path_match = "/status"
      }
      url_redirect {
        path_redirect          = "/status/"
        redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
        strip_query             = false
      }
    }
    route_rules {
      priority = 35
      match_rules {
        full_path_match = "/ai"
      }
      url_redirect {
        path_redirect          = "/ai/"
        redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
        strip_query             = false
      }
    }
    route_rules {
      priority = 36
      match_rules {
        full_path_match = "/pose-tracker"
      }
      url_redirect {
        path_redirect          = "/pose-tracker/"
        redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
        strip_query             = false
      }
    }
  }

  # Election Map is a whole Next.js app on its own hostname — no path
  # routing, every request goes to its one backend (electionmap.tf).
  # Declared after "main" on purpose: path_matcher is an ordered list, and
  # inserting ahead of it makes the plan diff every existing route.
  host_rule {
    hosts        = [var.electionmap_subdomain]
    path_matcher = "electionmap"
  }

  path_matcher {
    name            = "electionmap"
    default_service = module.electionmap.backend_service_id
  }
}

resource "google_compute_target_https_proxy" "main" {
  name    = "bradjobe-https-proxy"
  project = var.project_id
  url_map = google_compute_url_map.main.id
  ssl_certificates = [
    google_compute_managed_ssl_certificate.main.id,
    google_compute_managed_ssl_certificate.electionmap.id,
  ]
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
