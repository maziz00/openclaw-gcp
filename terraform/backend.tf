# Remote state backend configuration using GCS
#
# Before enabling: create the GCS bucket manually (chicken-and-egg problem):
#   gsutil mb -p YOUR_PROJECT_ID -l us-central1 gs://YOUR_PROJECT_ID-openclaw-tfstate
#   gsutil versioning set on gs://YOUR_PROJECT_ID-openclaw-tfstate
#
# Then uncomment this block and run:
#   terraform init -migrate-state
#
# terraform {
#   backend "gcs" {
#     bucket = "YOUR_PROJECT_ID-openclaw-tfstate"
#     prefix = "openclaw/production"
#   }
# }
#
# Terraform will prompt for the bucket name when running init if left unconfigured,
# or you can pass it with: terraform init -backend-config="bucket=YOUR_BUCKET_NAME"
