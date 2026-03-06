# ---------------------------------------------------------------------------
# Secret Manager — secrets for OpenClaw credentials
#
# IMPORTANT: Secret *versions* (the actual values) are NOT created here.
# You must add the secret values manually after `terraform apply`:
#
#   # Anthropic API key:
#   echo -n "sk-ant-YOUR_KEY_HERE" | \
#     gcloud secrets versions add openclaw-production-anthropic-api-key \
#     --data-file=-
#
#   # Vertex AI service account credentials (JSON key file):
#   gcloud secrets versions add openclaw-production-vertex-ai-credentials \
#     --data-file=/path/to/vertex-sa-key.json
#
# Never commit secret values to this repository.
# ---------------------------------------------------------------------------

resource "google_secret_manager_secret" "anthropic_api_key" {
  secret_id = "${local.name_prefix}-anthropic-api-key"
  project   = var.project_id

  labels = local.common_labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "vertex_ai_credentials" {
  secret_id = "${local.name_prefix}-vertex-ai-credentials"
  project   = var.project_id

  labels = local.common_labels

  replication {
    auto {}
  }
}

# ---------------------------------------------------------------------------
# IAM — grant compute service account read access to secrets
#
# We bind at the secret level (not project level) following least-privilege:
# the compute SA can only read these two specific secrets.
# ---------------------------------------------------------------------------

resource "google_secret_manager_secret_iam_member" "compute_reads_anthropic_key" {
  secret_id = google_secret_manager_secret.anthropic_api_key.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.compute.email}"
  project   = var.project_id
}

resource "google_secret_manager_secret_iam_member" "compute_reads_vertex_creds" {
  secret_id = google_secret_manager_secret.vertex_ai_credentials.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.compute.email}"
  project   = var.project_id
}
