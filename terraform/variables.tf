variable "project_id" {
  description = "The GCP project ID where all resources will be created."
  type        = string

  validation {
    condition     = length(var.project_id) > 0
    error_message = "project_id must not be empty."
  }
}

variable "region" {
  description = "GCP region for regional resources (VPC subnet, Cloud NAT, etc.)."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "GCP zone for the GCE instance. Must be within var.region."
  type        = string

  validation {
    condition     = length(var.zone) > 0
    error_message = "zone must not be empty."
  }
}

variable "instance_type" {
  description = "GCE machine type for the OpenClaw application instance."
  type        = string
  default     = "e2-standard-2"
}

variable "claude_provider" {
  description = "Which Claude API provider to use. 'anthropic_api' uses the Anthropic direct API (requires anthropic_api_key secret). 'vertex_ai' uses Vertex AI (requires vertex_ai_credentials secret and aiplatform.user IAM role)."
  type        = string
  default     = "anthropic_api"

  validation {
    condition     = contains(["anthropic_api", "vertex_ai"], var.claude_provider)
    error_message = "claude_provider must be either 'anthropic_api' or 'vertex_ai'."
  }
}

variable "environment" {
  description = "Deployment environment label applied to all resources as a label (e.g. production, staging)."
  type        = string
  default     = "production"

  validation {
    condition     = contains(["production", "staging", "development"], var.environment)
    error_message = "environment must be one of: production, staging, development."
  }
}

variable "budget_amount" {
  description = "Monthly budget alert threshold in USD. An alert fires when actual spend exceeds this amount."
  type        = number
  default     = 100

  validation {
    condition     = var.budget_amount > 0
    error_message = "budget_amount must be a positive number."
  }
}

variable "notification_email" {
  description = "Email address to receive budget alerts and monitoring notifications."
  type        = string

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.notification_email))
    error_message = "notification_email must be a valid email address."
  }
}

variable "ssh_source_ranges" {
  description = "List of CIDR ranges allowed to SSH to the instance directly. Prefer using IAP (Identity-Aware Proxy) instead — set this to [] if IAP tunnel is your only SSH path."
  type        = list(string)
  default     = []

  validation {
    condition = alltrue([
      for cidr in var.ssh_source_ranges :
      can(cidrnetmask(cidr))
    ])
    error_message = "All entries in ssh_source_ranges must be valid CIDR ranges (e.g. 203.0.113.0/24)."
  }
}

