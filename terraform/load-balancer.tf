# ---------------------------------------------------------------------------
# Global External IP — static IP for the HTTPS load balancer.
# Cloud DNS A record (dns.tf) points the domain to this address.
# ---------------------------------------------------------------------------
resource "google_compute_global_address" "lb" {
  name        = "${local.name_prefix}-lb-ip"
  description = "Static global IP for OpenClaw HTTPS load balancer"
  project     = var.project_id
  ip_version  = "IPV4"
}

# ---------------------------------------------------------------------------
# Google-managed SSL Certificate
# GCP automatically provisions and rotates the certificate via ACME.
# DNS must already point to the LB IP before the cert will be issued.
# Cert provisioning typically takes 10-60 minutes after DNS propagation.
# ---------------------------------------------------------------------------
resource "google_compute_managed_ssl_certificate" "openclaw" {
  name    = "${local.name_prefix}-ssl-cert"
  project = var.project_id

  managed {
    domains = [var.domain_name]
  }

  lifecycle {
    # Prevent replacement during cert rotation; GCP handles renewal automatically
    create_before_destroy = true
  }
}

# ---------------------------------------------------------------------------
# Health Check — HTTP probe to /health on port 80.
# OpenClaw app must expose GET /health returning 200 for the backend to
# be considered healthy.
# ---------------------------------------------------------------------------
resource "google_compute_health_check" "openclaw" {
  name               = "${local.name_prefix}-health-check"
  project            = var.project_id
  description        = "HTTP health check for OpenClaw application"
  check_interval_sec = 10
  timeout_sec        = 5
  healthy_threshold  = 2
  unhealthy_threshold = 3

  http_health_check {
    port         = 80
    request_path = "/health"
  }
}

# ---------------------------------------------------------------------------
# Backend Service — connects the LB to the instance group.
# CDN is disabled; OpenClaw responses are dynamic AI outputs.
# ---------------------------------------------------------------------------
resource "google_compute_backend_service" "openclaw" {
  name                  = "${local.name_prefix}-backend"
  project               = var.project_id
  description           = "OpenClaw backend service"
  protocol              = "HTTP"
  port_name             = "http" # matches named_port in instance group
  timeout_sec           = 120    # generous timeout for LLM inference calls
  enable_cdn            = false
  load_balancing_scheme = "EXTERNAL"
  health_checks         = [google_compute_health_check.openclaw.id]

  backend {
    group           = google_compute_instance_group.openclaw.id
    balancing_mode  = "UTILIZATION"
    max_utilization = 0.8
    capacity_scaler = 1.0
  }

  log_config {
    enable      = true
    sample_rate = 1.0 # log all requests for cost debugging and audit
  }
}

# ---------------------------------------------------------------------------
# URL Map — routes all requests to the backend service.
# Can be extended with path matchers later (e.g. /api/* → different backend).
# ---------------------------------------------------------------------------
resource "google_compute_url_map" "openclaw" {
  name            = "${local.name_prefix}-url-map"
  project         = var.project_id
  description     = "URL map for OpenClaw HTTPS load balancer"
  default_service = google_compute_backend_service.openclaw.id
}

# HTTP→HTTPS redirect URL map — no backend, just a 301
resource "google_compute_url_map" "http_redirect" {
  name    = "${local.name_prefix}-http-redirect"
  project = var.project_id

  default_url_redirect {
    https_redirect         = true
    redirect_response_code = "MOVED_PERMANENTLY_DEFAULT"
    strip_query            = false
  }
}

# ---------------------------------------------------------------------------
# Target HTTPS Proxy — attaches SSL cert to the URL map
# ---------------------------------------------------------------------------
resource "google_compute_target_https_proxy" "openclaw" {
  name             = "${local.name_prefix}-https-proxy"
  project          = var.project_id
  url_map          = google_compute_url_map.openclaw.id
  ssl_certificates = [google_compute_managed_ssl_certificate.openclaw.id]
}

# Target HTTP Proxy for the redirect
resource "google_compute_target_http_proxy" "redirect" {
  name    = "${local.name_prefix}-http-redirect-proxy"
  project = var.project_id
  url_map = google_compute_url_map.http_redirect.id
}

# ---------------------------------------------------------------------------
# Forwarding Rules — bind global IP to the proxies on ports 443 and 80
# ---------------------------------------------------------------------------
resource "google_compute_global_forwarding_rule" "https" {
  name                  = "${local.name_prefix}-https-fw-rule"
  project               = var.project_id
  description           = "HTTPS forwarding rule for OpenClaw"
  ip_address            = google_compute_global_address.lb.id
  ip_protocol           = "TCP"
  port_range            = "443"
  target                = google_compute_target_https_proxy.openclaw.id
  load_balancing_scheme = "EXTERNAL"
}

resource "google_compute_global_forwarding_rule" "http_redirect" {
  name                  = "${local.name_prefix}-http-fw-rule"
  project               = var.project_id
  description           = "HTTP→HTTPS redirect forwarding rule for OpenClaw"
  ip_address            = google_compute_global_address.lb.id
  ip_protocol           = "TCP"
  port_range            = "80"
  target                = google_compute_target_http_proxy.redirect.id
  load_balancing_scheme = "EXTERNAL"
}
