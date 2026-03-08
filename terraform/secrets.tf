# ---------------------------------------------------------------------------
# Secret Manager — secrets for OpenClaw credentials and bot tokens
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
#   # Telegram bot token (from @BotFather):
#   echo -n "YOUR_TELEGRAM_BOT_TOKEN" | \
#     gcloud secrets versions add openclaw-production-telegram-bot-token \
#     --data-file=-
#
#   # Discord bot token (from Discord Developer Portal):
#   echo -n "YOUR_DISCORD_BOT_TOKEN" | \
#     gcloud secrets versions add openclaw-production-discord-bot-token \
#     --data-file=-
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

resource "google_secret_manager_secret" "telegram_bot_token" {
  secret_id = "${local.name_prefix}-telegram-bot-token"
  project   = var.project_id

  labels = local.common_labels

  replication {
    auto {}
  }
}

resource "google_secret_manager_secret" "discord_bot_token" {
  secret_id = "${local.name_prefix}-discord-bot-token"
  project   = var.project_id

  labels = local.common_labels

  replication {
    auto {}
  }
}

# ---------------------------------------------------------------------------
# IAM — grant compute service account read access to secrets
#
# Bound at the secret level (not project level) following least-privilege:
# the compute SA can only read these specific secrets.
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

resource "google_secret_manager_secret_iam_member" "compute_reads_telegram_token" {
  secret_id = google_secret_manager_secret.telegram_bot_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.compute.email}"
  project   = var.project_id
}

resource "google_secret_manager_secret_iam_member" "compute_reads_discord_token" {
  secret_id = google_secret_manager_secret.discord_bot_token.id
  role      = "roles/secretmanager.secretAccessor"
  member    = "serviceAccount:${google_service_account.compute.email}"
  project   = var.project_id
}
