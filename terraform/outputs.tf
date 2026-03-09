output "project_id" {
  description = "GCP project ID where all resources are deployed."
  value       = var.project_id
}

output "instance_ip" {
  description = "Internal (private) IP address of the OpenClaw GCE instance. The instance has no public IP — access via IAP tunnel only."
  value       = google_compute_instance.openclaw.network_interface[0].network_ip
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
  description = "Map of secret names to their full Secret Manager resource IDs. Operator must populate values via gcloud CLI after terraform apply."
  value = {
    anthropic_api_key     = google_secret_manager_secret.anthropic_api_key.id
    vertex_ai_credentials = google_secret_manager_secret.vertex_ai_credentials.id
    telegram_bot_token    = google_secret_manager_secret.telegram_bot_token.id
    discord_bot_token     = google_secret_manager_secret.discord_bot_token.id
  }
}

output "iap_ssh_command" {
  description = "Command to SSH into the instance via IAP tunnel (no public IP required)."
  value       = "gcloud compute ssh ${google_compute_instance.openclaw.name} --zone=${var.zone} --project=${var.project_id} --tunnel-through-iap"
}

output "iap_tunnel_command" {
  description = "Command to forward the OpenClaw UI to your local browser via IAP SSH tunnel. Run this, then open http://localhost:3000."
  value       = "gcloud compute ssh ${google_compute_instance.openclaw.name} --zone=${var.zone} --project=${var.project_id} --tunnel-through-iap -- -L 3000:localhost:3000"
}

output "log_sink_bucket" {
  description = "Name of the GCS bucket receiving OpenClaw application log exports."
  value       = google_storage_bucket.log_sink.name
}
