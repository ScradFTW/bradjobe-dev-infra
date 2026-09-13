# ccaas needs a real Docker daemon (dockerode spawns/execs sibling
# containers per user session, and the egress-proxy/sandbox images are
# pulled and run directly against it) plus nginx for its dynamic
# `/sites/<slug>/` publishing feature (writes a config fragment + sudo-
# scoped reload — see ccaas/apps/backend/src/sites.js). Neither fits
# Cloud Run's sandboxed runtime, so this one service gets a VM instead.
resource "google_compute_instance" "ccaas" {
  name         = "ccaas-vm"
  project      = var.project_id
  zone         = var.zone
  machine_type = var.ccaas_machine_type

  boot_disk {
    initialize_params {
      image = "projects/ubuntu-os-cloud/global/images/family/ubuntu-2404-lts-amd64"
      size  = 30
    }
  }

  network_interface {
    subnetwork = google_compute_subnetwork.main.id
    # No explicit network_ip: a reserved static internal address here
    # actively broke create_before_destroy — the replacement instance
    # would try to claim the same IP the still-live original was using.
    # Nothing else in this repo references this VM by IP (the LB reaches
    # it through the instance group, gce_ccaas.tf below), so there's no
    # reason to pin it.
    #
    # No access_config block: no public IP. Reached only via the load
    # balancer (lb.tf) and administered only via IAP SSH tunneling
    # (network.tf's allow-iap-ssh rule), matching the "everything behind
    # one HTTPS entrypoint" shape of the rest of this migration.
  }

  service_account {
    email  = google_service_account.ccaas_vm.email
    scopes = ["cloud-platform"]
  }

  tags = ["ccaas-vm"]

  # OS Login, not metadata SSH keys, was the original plan here — but OS
  # Login for a SERVICE ACCOUNT identity (as opposed to a human user; the
  # cloudbuild-app-deployer SA correctly resolved to POSIX user
  # sa_<uniqueId>, confirmed against a human login that worked fine on
  # the same VM) consistently hit "Permission denied (publickey)" even
  # after retries, with no further diagnosis possible without dropping
  # into Google support. This is the same dedicated-keypair-via-metadata
  # pattern Google's own Cloud Build + Compute Engine deploy guides use,
  # specifically because CI-service-account OS Login has exactly this
  # kind of friction. Public key only — the private half lives in Secret
  # Manager (ccaas-deploy-ssh-private-key, created out of band, not by
  # Terraform, so it never touches state) and cloudbuild.yaml pulls it at
  # deploy time.
  # startup-script lives in this plain metadata map, not the dedicated
  # metadata_startup_script argument: that argument is ForceNew in this
  # provider (any edit recreates the instance) and already collided once
  # with create_before_destroy below — a same-zone/same-name replacement
  # tries to create the replacement before destroying the original,
  # which fails on a duplicate name. metadata is a plain updatable map,
  # so edits here just update the running instance in place instead.
  metadata = {
    enable-oslogin = "FALSE"
    ssh-keys       = "clouddeploy:ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGcrkJTdSN/fZkOCAH0humHOgP+n1GbsCFOep91r1q+k clouddeploy"
    startup-script = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail

    # Idempotent: Cloud Build reruns nothing here, but a VM recreate should
    # still converge to the same base state.
    if ! command -v docker >/dev/null; then
      apt-get update
      apt-get install -y ca-certificates curl gnupg nginx
      install -m 0755 -d /etc/apt/keyrings
      curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
      chmod a+r /etc/apt/keyrings/docker.asc
      echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo $VERSION_CODENAME) stable" \
        > /etc/apt/sources.list.d/docker.list
      apt-get update
      apt-get install -y docker-ce docker-ce-cli containerd.io docker-compose-plugin
      systemctl enable --now docker
    fi

    # The ccaas backend itself runs directly on the host (systemd + node),
    # not containerized — only its sandbox/egress-proxy children are
    # Docker images. Node 22 to match those images' base and the
    # package.json engines expectation.
    if ! command -v npm >/dev/null; then
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
      apt-get install -y nodejs
    fi

    useradd -r -m -d /srv/ccaas -s /usr/sbin/nologin ccaas 2>/dev/null || true
    usermod -aG docker ccaas
    mkdir -p /srv/ccaas/data /srv/ccaas/squid-acl /etc/nginx/ccaas-sites
    chown -R ccaas:ccaas /srv/ccaas /etc/nginx/ccaas-sites

    # `gcloud auth configure-docker` equivalent for the VM's Docker daemon,
    # so it can pull from Artifact Registry using its own service account.
    mkdir -p /root/.docker
    docker-credential-gcr configure-docker --registries=${var.region}-docker.pkg.dev 2>/dev/null || \
      gcloud auth configure-docker ${var.region}-docker.pkg.dev --quiet || true

    # nginx is fully wired up here — not left as a manual post-boot step —
    # so the LB health check (google_compute_health_check.ccaas below)
    # passes even before the first Cloud Build deploy has run. ccaas.conf
    # starts as a 503 stub; the first deploy (ccaas/infra/gcp-deploy.sh)
    # overwrites it with the real proxy_pass to the backend.
    # Written with printf, not nested heredocs: this whole script is
    # itself the body of a Terraform <<-EOT heredoc, and mixing that
    # dedent behavior with bash's own heredoc indentation rules is a
    # well-known footgun that's easy to get subtly wrong and impossible
    # to test without a real apply.
    mkdir -p /etc/nginx/snippets
    if [ ! -f /etc/nginx/snippets/ccaas.conf ]; then
      printf 'location /ccaas/ {\n    return 503 "ccaas not deployed yet";\n}\n' \
        > /etc/nginx/snippets/ccaas.conf
    fi

    printf 'map $http_upgrade $connection_upgrade {\n    default upgrade;\n    '"''"' close;\n}\n' \
      > /etc/nginx/conf.d/upgrade-map.conf

    printf 'server {\n    listen 80 default_server;\n    listen [::]:80 default_server;\n    server_name _;\n\n    include snippets/ccaas.conf;\n    include /etc/nginx/ccaas-sites/*.conf;\n\n    location / {\n        return 404;\n    }\n}\n' \
      > /etc/nginx/sites-available/default
    ln -sf /etc/nginx/sites-available/default /etc/nginx/sites-enabled/default
    nginx -t && systemctl reload nginx || systemctl restart nginx

    echo "base image ready — application deploy happens via Cloud Build (see ccaas/cloudbuild.yaml)"
  EOT
  }

  # No create_before_destroy here (on purpose, and it already burned once):
  # this instance and google_compute_instance_group.ccaas below share the
  # name "ccaas-vm"/"ccaas-vm-group" within the same zone, so create-first
  # collides with the still-live original on a duplicate-name 409 unless
  # they're also changing zone. The original create_before_destroy was
  # added for exactly that cross-zone case (the northamerica-northeast1-a
  # -> -c move) and isn't needed now that both are settled in -c — a
  # same-zone replacement destroys the old one first, freeing the name,
  # with no conflict since the instance group's `instances` list update
  # doesn't require the old instance to still exist.
}

# A freshly-created instance's URL is sometimes rejected by the instance
# group API ("invalid instance URLs") for a few seconds after
# google_compute_instance reports creation complete — an eventual-
# consistency gap between Compute Engine and the instance-group service,
# observed directly (the group update failed immediately after the
# instance's own "Creation complete" log line, on a plain create with no
# replacement involved). A short wait bridges it.
resource "time_sleep" "wait_for_ccaas_instance" {
  create_duration = "30s"
  depends_on      = [google_compute_instance.ccaas]
}

# Unmanaged instance group so this single VM can be an External HTTPS LB
# backend (lb.tf) — Terraform-managed, no autoscaling since ccaas is
# stateful (SQLite + per-user Docker state) and was never designed to run
# as more than one instance.
resource "google_compute_instance_group" "ccaas" {
  name    = "ccaas-vm-group"
  project = var.project_id
  zone    = var.zone

  instances = [google_compute_instance.ccaas.id]

  depends_on = [time_sleep.wait_for_ccaas_instance]

  named_port {
    name = "http"
    port = 80
  }

  # A zone change (or any other forced replacement of the instance/group)
  # must create the replacement before destroying the original: the old
  # group can't be deleted while gce_ccaas.tf's backend_service still
  # points at it, and Terraform won't repoint the backend_service to a
  # group that doesn't exist yet. Names are zone-scoped, so the old and
  # new resources coexisting briefly under the same name in different
  # zones is not a conflict.
  lifecycle {
    create_before_destroy = true
  }
}

resource "google_compute_firewall" "allow_lb_to_ccaas" {
  name    = "allow-lb-to-ccaas-vm"
  network = google_compute_network.main.id

  direction     = "INGRESS"
  target_tags   = ["ccaas-vm"]
  source_ranges = ["130.211.0.0/22", "35.191.0.0/16"]
  allow {
    protocol = "tcp"
    ports    = ["80"]
  }
}

resource "google_compute_health_check" "ccaas" {
  name    = "ccaas-http-health-check"
  project = var.project_id

  http_health_check {
    port         = 80
    # Added to server.js in the ccaas PR, unauthenticated, matching the
    # /health convention the Python backends already use.
    request_path = "/ccaas/health"
  }
}

resource "google_compute_backend_service" "ccaas" {
  name        = "ccaas-backend"
  project     = var.project_id
  protocol    = "HTTP"
  port_name   = "http"
  timeout_sec = 3600 # long-lived /ws/chat WebSocket connections

  backend {
    group = google_compute_instance_group.ccaas.id
  }

  health_checks = [google_compute_health_check.ccaas.id]

  log_config {
    enable = true
  }
}
