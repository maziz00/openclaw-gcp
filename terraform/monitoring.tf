# ---------------------------------------------------------------------------
# Monitoring Notification Channel — email alerts
# ---------------------------------------------------------------------------
resource "google_monitoring_notification_channel" "email" {
  display_name = "OpenClaw ${var.environment} Email Alerts"
  type         = "email"
  project      = var.project_id

  labels = {
    email_address = var.notification_email
  }

  enabled = true
}

# ---------------------------------------------------------------------------
# Budget Alert
#
# Fires when the project's monthly spend exceeds var.budget_amount USD.
# Thresholds at 50%, 90%, and 100% give early warning before overage.
#
# Note: Billing budgets are tied to the billing account, not the project.
# The budget filters by this project's number so costs are isolated.
# Requires the billing account ID to be known — we derive it from the project.
# ---------------------------------------------------------------------------
data "google_billing_account" "acct" {
  display_name = "My Billing Account"
  open         = true
}

resource "google_billing_budget" "openclaw" {
  billing_account = data.google_billing_account.acct.id

  display_name = "OpenClaw ${var.environment} Monthly Budget"

  budget_filter {
    projects = ["projects/${data.google_project.this.number}"]
    # Filter by OpenClaw services; Claude API calls via Anthropic go to
    # "Cloud AI" or custom Anthropic billing — adjust services list as needed
  }

  amount {
    specified_amount {
      currency_code = "USD"
      units         = tostring(var.budget_amount)
    }
  }

  # Alert at 50%, 90%, and 100% of budget
  threshold_rules {
    threshold_percent = 0.5
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 0.9
    spend_basis       = "CURRENT_SPEND"
  }

  threshold_rules {
    threshold_percent = 1.0
    spend_basis       = "CURRENT_SPEND"
  }

  all_updates_rule {
    monitoring_notification_channels = [google_monitoring_notification_channel.email.id]
    # disable_default_iam_recipients = false keeps GCP billing contacts notified too
    disable_default_iam_recipients = false
  }
}

# ---------------------------------------------------------------------------
# Custom Metric Descriptor — Claude API token usage
#
# The OpenClaw application should emit this metric via the Cloud Monitoring
# custom metrics API after each inference call. Tracking token consumption
# is essential for cost attribution and rate-limit monitoring.
#
# Metric name: custom.googleapis.com/openclaw/claude_api_tokens_used
# Dimensions: model (e.g. claude-3-opus), request_type (input/output)
# ---------------------------------------------------------------------------
resource "google_monitoring_metric_descriptor" "claude_api_tokens" {
  description  = "Number of Claude API tokens consumed per request. Emitted by the OpenClaw application."
  display_name = "OpenClaw Claude API Tokens Used"
  type         = "custom.googleapis.com/openclaw/claude_api_tokens_used"
  metric_kind  = "CUMULATIVE"  # ever-increasing token counter; GCP custom metrics do not support DELTA
  value_type   = "INT64"
  unit         = "{tokens}"
  project      = var.project_id

  labels {
    key         = "model"
    value_type  = "STRING"
    description = "Claude model name (e.g. claude-3-opus-20240229, claude-3-5-sonnet)"
  }

  labels {
    key         = "request_type"
    value_type  = "STRING"
    description = "Token type: 'input' or 'output'"
  }

  labels {
    key         = "environment"
    value_type  = "STRING"
    description = "Deployment environment (production, staging)"
  }
}

# ---------------------------------------------------------------------------
# Propagation wait — GCP custom metrics are eventually consistent.
# The metric descriptor API returns 200 immediately, but the metric takes
# 60-120 seconds to become queryable by the Alert Policy API.
# Without this wait, Terraform fires the alert policy creation instantly
# and gets a 404 ("metric not found").
# ---------------------------------------------------------------------------
resource "time_sleep" "wait_for_metric_propagation" {
  depends_on      = [google_monitoring_metric_descriptor.claude_api_tokens]
  create_duration = "90s"
}

# ---------------------------------------------------------------------------
# Alert Policy — high Claude API token usage
#
# Fires when the rolling 1-hour sum of tokens exceeds 1,000,000.
# Tune the threshold based on your expected usage and cost sensitivity.
# ---------------------------------------------------------------------------
resource "google_monitoring_alert_policy" "high_token_usage" {
  display_name = "OpenClaw — High Claude API Token Usage"
  project      = var.project_id
  combiner     = "OR"
  enabled      = true

  depends_on = [time_sleep.wait_for_metric_propagation]

  conditions {
    display_name = "Claude token usage > 1M tokens/hr"

    condition_threshold {
      filter          = "metric.type=\"custom.googleapis.com/openclaw/claude_api_tokens_used\" AND resource.type=\"global\""
      duration        = "0s"
      comparison      = "COMPARISON_GT"
      threshold_value = 1000000

      aggregations {
        alignment_period     = "3600s" # 1-hour window
        per_series_aligner   = "ALIGN_RATE"  # rate of change for CUMULATIVE metrics
        cross_series_reducer = "REDUCE_SUM"
      }
    }
  }

  notification_channels = [google_monitoring_notification_channel.email.id]

  alert_strategy {
    auto_close = "604800s" # auto-close after 7 days if not manually resolved
  }

  documentation {
    content   = "Claude API token usage has exceeded 1 million tokens in the last hour. Check the OpenClaw application logs and consider rate-limiting or caching to reduce costs."
    mime_type = "text/markdown"
  }
}

# ---------------------------------------------------------------------------
# Log Sink — OpenClaw application container/process logs
#
# Exports openclaw-tagged log entries to a dedicated GCS bucket for
# long-term retention and offline analysis. The sink SA is granted
# storage.objectCreator on the bucket.
# ---------------------------------------------------------------------------
resource "google_storage_bucket" "log_sink" {
  name          = "${var.project_id}-${local.name_prefix}-logs"
  location      = var.region
  project       = var.project_id
  force_destroy = false # prevent accidental log loss

  labels = local.common_labels

  uniform_bucket_level_access = true

  lifecycle_rule {
    action {
      type = "Delete"
    }
    condition {
      age = 90 # retain logs for 90 days; adjust for compliance requirements
    }
  }

  versioning {
    enabled = false # logs are immutable; versioning adds cost without benefit
  }
}

resource "google_logging_project_sink" "openclaw_logs" {
  name        = "${local.name_prefix}-log-sink"
  project     = var.project_id
  destination = "storage.googleapis.com/${google_storage_bucket.log_sink.name}"

  # Filter: capture all log entries tagged with the openclaw app label
  filter = "resource.type=\"gce_instance\" AND labels.\"app\"=\"openclaw\""

  unique_writer_identity = true # creates a dedicated SA for the sink
}

# Grant the sink's writer identity permission to write to the log bucket
resource "google_storage_bucket_iam_member" "log_sink_writer" {
  bucket = google_storage_bucket.log_sink.name
  role   = "roles/storage.objectCreator"
  member = google_logging_project_sink.openclaw_logs.writer_identity
}
