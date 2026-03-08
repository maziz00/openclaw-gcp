# Remote state backend — GCS
# Bucket created by: scripts/setup-tf-backend.sh

terraform {
  backend "gcs" {
    bucket = "claude-code-00-openclaw-tfstate"
    prefix = "openclaw/prod"
  }
}
