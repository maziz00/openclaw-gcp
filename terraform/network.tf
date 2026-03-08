# ---------------------------------------------------------------------------
# VPC Network — custom mode so we control every subnet
# ---------------------------------------------------------------------------
resource "google_compute_network" "main" {
  name                    = local.network_name
  auto_create_subnetworks = false # custom mode; prevents unintended subnets
  description             = "OpenClaw ${var.environment} VPC"
  project                 = var.project_id
}

# ---------------------------------------------------------------------------
# Subnet — private Google access enabled so the instance can reach
# Google APIs (Secret Manager, Cloud Storage, etc.) without a public IP
# ---------------------------------------------------------------------------
resource "google_compute_subnetwork" "main" {
  name                     = local.subnetwork_name
  network                  = google_compute_network.main.id
  region                   = var.region
  ip_cidr_range            = "10.10.0.0/24"
  private_ip_google_access = true # allows Google API access without NAT
  project                  = var.project_id

  log_config {
    aggregation_interval = "INTERVAL_10_MIN"
    flow_sampling        = 0.5
    metadata             = "INCLUDE_ALL_METADATA"
  }
}

# ---------------------------------------------------------------------------
# Cloud Router — required by Cloud NAT for egress
# ---------------------------------------------------------------------------
resource "google_compute_router" "main" {
  name    = "${local.name_prefix}-router"
  network = google_compute_network.main.id
  region  = var.region
  project = var.project_id

  bgp {
    asn = 64514
  }
}

# ---------------------------------------------------------------------------
# Cloud NAT — provides outbound internet access for the private instance
# (e.g. pip install, pulling container images, Anthropic API calls)
# ---------------------------------------------------------------------------
resource "google_compute_router_nat" "main" {
  name                               = "${local.name_prefix}-nat"
  router                             = google_compute_router.main.name
  region                             = var.region
  project                            = var.project_id
  nat_ip_allocate_option             = "AUTO_ONLY"
  source_subnetwork_ip_ranges_to_nat = "ALL_SUBNETWORKS_ALL_IP_RANGES"

  log_config {
    enable = true
    filter = "ERRORS_ONLY"
  }
}

# ---------------------------------------------------------------------------
# Firewall Rules
# ---------------------------------------------------------------------------

# Allow direct SSH from operator CIDRs (optional — prefer IAP below)
resource "google_compute_firewall" "allow_ssh" {
  count = length(var.ssh_source_ranges) > 0 ? 1 : 0

  name        = "${local.name_prefix}-allow-ssh"
  network     = google_compute_network.main.id
  project     = var.project_id
  description = "Allow SSH from operator-specified CIDR ranges"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = var.ssh_source_ranges
  target_tags   = ["openclaw-app"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Allow SSH via Identity-Aware Proxy (IAP) tunnel — preferred zero-trust approach.
# IAP proxies the TCP tunnel through 35.235.240.0/20; no public IP required on instance.
resource "google_compute_firewall" "allow_iap" {
  name        = "${local.name_prefix}-allow-iap"
  network     = google_compute_network.main.id
  project     = var.project_id
  description = "Allow SSH via IAP tunnel (zero-trust; no public IP needed on instance)"
  direction   = "INGRESS"
  priority    = 1000

  source_ranges = ["35.235.240.0/20"]
  target_tags   = ["openclaw-app"]

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }
}

# Explicit deny-all ingress with lower priority than the allows above.
# Priority 65534 loses to anything <= 1000. Acts as a documented baseline.
resource "google_compute_firewall" "deny_all_ingress" {
  name        = "${local.name_prefix}-deny-all-ingress"
  network     = google_compute_network.main.id
  project     = var.project_id
  description = "Default deny all ingress — explicit baseline; specific allows above override this"
  direction   = "INGRESS"
  priority    = 65534

  source_ranges = ["0.0.0.0/0"]

  deny {
    protocol = "all"
  }
}
