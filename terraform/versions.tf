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
  }
}

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  # Increase default request timeout for long-running operations
  # (Cloud SQL, service networking, SSL cert provisioning)
  request_timeout = "30m"
}

provider "google-beta" {
  project = var.project_id
  region  = var.region
  zone    = var.zone

  request_timeout = "30m"
}
