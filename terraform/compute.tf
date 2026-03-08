# ---------------------------------------------------------------------------
# AlmaLinux 9 image — Red Hat-compatible, enterprise-grade, free.
# Image family "almalinux-9" from project "almalinux-cloud" ensures we
# always use the latest patched AlmaLinux 9 image on creation.
# ---------------------------------------------------------------------------
data "google_compute_image" "almalinux9" {
  family  = "almalinux-9"
  project = "almalinux-cloud"
}

# ---------------------------------------------------------------------------
# GCE Instance — no public IP; no inbound web traffic.
# OpenClaw connects outbound to Telegram/Discord/WhatsApp APIs via Cloud NAT.
# SSH access via IAP tunnel only.
# ---------------------------------------------------------------------------
resource "google_compute_instance" "openclaw" {
  name         = "${local.name_prefix}-instance"
  machine_type = var.instance_type
  zone         = var.zone
  project      = var.project_id
  description  = "OpenClaw AI application server (AlmaLinux 9, ${var.environment})"

  tags = ["openclaw-app"] # matches firewall target_tags

  labels = local.common_labels

  boot_disk {
    initialize_params {
      image = data.google_compute_image.almalinux9.self_link
      size  = 30   # GB — SSD for snappy Python startup times
      type  = "pd-ssd"
    }
    # auto_delete = true (default) so disk is reclaimed on instance deletion
  }

  network_interface {
    network    = google_compute_network.main.id
    subnetwork = google_compute_subnetwork.main.id
    # No access_config block = no public IP (all egress goes via Cloud NAT)
  }

  service_account {
    email  = google_service_account.compute.email
    scopes = ["cloud-platform"] # broad scope; IAM policies on SA restrict actual permissions
  }

  metadata = {
    # Enable OS Login so GCP controls SSH key management (no per-instance SSH keys)
    enable-oslogin = "TRUE"

    # Ansible-compatible: set the Python interpreter explicitly for AlmaLinux 9
    ansible-python-interpreter = "/usr/bin/python3"

    # Startup script — bootstraps Python, pip, and Ansible then signals readiness.
    # OpenClaw application is deployed via Ansible (see ../ansible/).
    startup-script = <<-EOT
      #!/bin/bash
      set -euo pipefail

      # --- System update and base packages ---
      dnf update -y --quiet
      dnf install -y --quiet \
        python3 \
        python3-pip \
        python3-devel \
        git \
        curl \
        wget \
        openssl \
        ca-certificates

      # --- Install Ansible and required collections ---
      pip3 install --quiet ansible ansible-core

      # Ansible Galaxy collections used by the OpenClaw playbooks
      ansible-galaxy collection install \
        community.general \
        ansible.posix \
        --quiet 2>/dev/null || true

      # --- Signal readiness ---
      # OpenClaw app is deployed by Ansible after this script runs.
      echo "Bootstrap complete: $(date)" >> /var/log/openclaw-startup.log
    EOT
  }

  scheduling {
    # Standard VM — no spot/preemptible to avoid unexpected restarts
    preemptible       = false
    on_host_maintenance = "MIGRATE"
    automatic_restart   = true
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }

  lifecycle {
    # Allow Ansible to update app without Terraform recreating the instance
    ignore_changes = [metadata["startup-script"]]
  }
}

