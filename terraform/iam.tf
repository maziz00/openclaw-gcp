# ---------------------------------------------------------------------------
# Service Account — Compute Instance
#
# This SA is attached to the GCE instance. Roles are bound at project level
# for monitoring/logging (required by Cloud Ops agents) and at resource level
# for Secret Manager (see secrets.tf for those bindings).
# ---------------------------------------------------------------------------
resource "google_service_account" "compute" {
  account_id   = "${local.name_prefix}-compute-sa"
  display_name = "OpenClaw ${var.environment} Compute Instance SA"
  description  = "Service account for the OpenClaw GCE instance. Least-privilege: secretAccessor bound per-secret in secrets.tf."
  project      = var.project_id
}

# Write custom metrics (Claude token usage, etc.) to Cloud Monitoring
resource "google_project_iam_member" "compute_metric_writer" {
  project = var.project_id
  role    = "roles/monitoring.metricWriter"
  member  = "serviceAccount:${google_service_account.compute.email}"
}

# Write application logs to Cloud Logging
resource "google_project_iam_member" "compute_log_writer" {
  project = var.project_id
  role    = "roles/logging.logWriter"
  member  = "serviceAccount:${google_service_account.compute.email}"
}

# ---------------------------------------------------------------------------
# Service Account — Vertex AI (conditional)
#
# Only created when claude_provider = "vertex_ai". Allows calling
# Vertex AI Gemini/Claude endpoints from outside the GCE instance
# (e.g. from a CI job or a separate service), or can be used by the
# compute instance via Workload Identity or key-based auth.
#
# Note: if the compute SA itself needs Vertex AI access, bind
# roles/aiplatform.user to google_service_account.compute instead.
# ---------------------------------------------------------------------------
resource "google_service_account" "vertex_ai" {
  count = var.claude_provider == "vertex_ai" ? 1 : 0

  account_id   = "${local.name_prefix}-vertex-sa"
  display_name = "OpenClaw ${var.environment} Vertex AI SA"
  description  = "Service account for Vertex AI Claude/Gemini API calls. Only created when claude_provider = 'vertex_ai'."
  project      = var.project_id
}

# Grant Vertex AI user role — allows calling prediction endpoints
resource "google_project_iam_member" "vertex_ai_user" {
  count = var.claude_provider == "vertex_ai" ? 1 : 0

  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.vertex_ai[0].email}"
}

# When using Vertex AI, the compute instance also needs to call the API.
# Grant the compute SA aiplatform.user as well so it can make inference requests.
resource "google_project_iam_member" "compute_vertex_ai_user" {
  count = var.claude_provider == "vertex_ai" ? 1 : 0

  project = var.project_id
  role    = "roles/aiplatform.user"
  member  = "serviceAccount:${google_service_account.compute.email}"
}
