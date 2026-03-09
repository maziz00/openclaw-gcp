terraform {
  required_version = ">= 1.5"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = ">= 5.0"
    }
    google-beta = {
      source  = "hashicorp/google-beta"
      version = ">= 5.0"
    }
    time = {
      source  = "hashicorp/time"
      version = ">= 0.9"
    }
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  # Required for billingbudgets.googleapis.com and other APIs that use
  # a quota project when authenticating with local ADC credentials.
  # Tells the provider to pass X-Goog-User-Project on all API calls.
  user_project_override = true
  billing_project       = var.project_id

  request_timeout = "30m"
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  user_project_override = true
  billing_project       = var.project_id

  request_timeout = "30m"
}
