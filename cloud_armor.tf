# Replicates the per-IP nginx `limit_req_zone` rates measured on the
# current VPS (/etc/nginx/conf.d/*.conf) as Cloud Armor throttle rules —
# the closest equivalent to limit_req's soft per-IP cap. Ban-style actions
# were deliberately not used here since nginx's `nodelay` behavior is a
# throttle, not a ban.

resource "google_compute_security_policy" "default_rate_limit" {
  name    = "default-rate-limit"
  project = var.project_id

  # matches nginx's global_req zone: 15r/s per IP, applied to every static
  # app that doesn't have its own tighter limit below.
  rule {
    action   = "throttle"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 900 # 15r/s
        interval_sec = 60
      }
    }
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "default rule"
  }
}

resource "google_compute_security_policy" "demo_api_rate_limit" {
  name    = "demo-api-rate-limit"
  project = var.project_id

  # matches nginx's genre_classifier_zone, shared today by
  # /genre-classifier/api/, /agent-demo/api/, and /image-classifier/api/:
  # 12r/m per IP.
  rule {
    action   = "throttle"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 12
        interval_sec = 60
      }
    }
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "default rule"
  }
}

# Matches nginx's llm_testing_zone: 6r/m per IP. Not attached to a Cloud
# Run backend service — this policy's name/id is consumed by a
# BackendConfig in qwen-llm-gke/k8s/backendconfig.yaml, since the GKE
# Ingress's backend service is created by Kubernetes, not Terraform.
resource "google_compute_security_policy" "llm_rate_limit" {
  name    = "llm-rate-limit"
  project = var.project_id

  rule {
    action   = "throttle"
    priority = 1000
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    rate_limit_options {
      conform_action = "allow"
      exceed_action  = "deny(429)"
      enforce_on_key = "IP"
      rate_limit_threshold {
        count        = 6
        interval_sec = 60
      }
    }
  }

  rule {
    action   = "allow"
    priority = 2147483647
    match {
      versioned_expr = "SRC_IPS_V1"
      config {
        src_ip_ranges = ["*"]
      }
    }
    description = "default rule"
  }
}
