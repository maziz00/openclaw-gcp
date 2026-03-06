locals {
  # Consistent naming prefix for all resources
  name_prefix = "openclaw-${var.environment}"

  # Common labels applied to every resource that supports them
  common_labels = {
    app         = "openclaw"
    environment = var.environment
    managed_by  = "terraform"
  }

  # Derived network names
  network_name    = "${local.name_prefix}-vpc"
  subnetwork_name = "${local.name_prefix}-subnet"

  # The compute service account email — built from the SA resource in iam.tf
  compute_sa_email = google_service_account.compute.email
}

# Look up the GCP project to get the project number, used for IAM bindings
# and billing budget (billing budgets reference project numbers, not IDs)
data "google_project" "this" {
  project_id = var.project_id
}
