output "instance_ip" {
  description = "Internal (private) IP address of the OpenClaw GCE instance. Use IAP tunnel or LB to reach the app; the instance has no public IP."
  value       = google_compute_instance.openclaw.network_interface[0].network_ip
}

output "lb_ip_address" {
  description = "Global static IP address assigned to the HTTPS load balancer. Point your DNS A record here."
  value       = google_compute_global_address.lb.address
}

output "lb_url" {
  description = "Public HTTPS URL for the OpenClaw application. The SSL cert may take up to 60 minutes to provision after DNS propagation."
  value       = "https://${var.domain_name}"
}

output "instance_name" {
  description = "Name of the GCE instance. Use this with gcloud commands (e.g. gcloud compute ssh, gcloud compute instances describe)."
  value       = google_compute_instance.openclaw.name
}

output "instance_zone" {
  description = "GCP zone where the instance is deployed."
  value       = google_compute_instance.openclaw.zone
}

output "service_account_email" {
  description = "Email of the compute service account attached to the GCE instance."
  value       = google_service_account.compute.email
}

output "vertex_ai_service_account_email" {
  description = "Email of the Vertex AI service account. Only populated when claude_provider = 'vertex_ai'."
  value       = var.claude_provider == "vertex_ai" ? google_service_account.vertex_ai[0].email : null
}

output "secret_ids" {
  description = "Map of secret names to their full Secret Manager resource IDs. Use these IDs when referencing secrets from other Terraform configurations or scripts."
  value = {
    anthropic_api_key    = google_secret_manager_secret.anthropic_api_key.id
    vertex_ai_credentials = google_secret_manager_secret.vertex_ai_credentials.id
  }
}

output "iap_ssh_command" {
  description = "Convenience command to SSH into the instance via IAP tunnel (no public IP required). Run this from a machine with gcloud CLI and IAP permissions."
  value       = "gcloud compute ssh ${google_compute_instance.openclaw.name} --zone=${var.zone} --project=${var.project_id} --tunnel-through-iap"
}

output "log_sink_bucket" {
  description = "Name of the GCS bucket receiving OpenClaw application log exports."
  value       = google_storage_bucket.log_sink.name
}
