# ---------------------------------------------------------------------------
# Cloud DNS A Record — conditional on var.enable_dns
#
# Prerequisites (must be done manually before enabling):
#   1. A Cloud DNS managed zone must exist in this project.
#   2. Your domain registrar's NS records must point to GCP's nameservers.
#
# To find your zone's nameservers:
#   gcloud dns managed-zones describe YOUR_ZONE_NAME --format="value(nameServers)"
# ---------------------------------------------------------------------------

resource "google_dns_record_set" "openclaw" {
  count = var.enable_dns ? 1 : 0

  name         = "${var.domain_name}." # trailing dot required by Cloud DNS
  type         = "A"
  ttl          = 300
  managed_zone = var.dns_zone_name
  project      = var.project_id

  rrdatas = [google_compute_global_address.lb.address]

  # The LB IP must exist before we can create the DNS record
  depends_on = [google_compute_global_address.lb]
}
