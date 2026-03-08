#!/bin/bash
# setup-tf-backend.sh — Create GCS bucket + update backend.tf automatically
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TFVARS="${PROJECT_ROOT}/terraform/terraform.tfvars"
BACKEND_TF="${PROJECT_ROOT}/terraform/backend.tf"

if [[ ! -f "$TFVARS" ]]; then
  echo "ERROR: terraform.tfvars not found at $TFVARS"
  exit 1
fi

PROJECT_ID=$(grep '^project_id' "$TFVARS" | sed 's/.*"\(.*\)".*/\1/')
REGION=$(grep '^region' "$TFVARS" | sed 's/.*"\(.*\)".*/\1/' || echo "us-central1")
BUCKET="${PROJECT_ID}-openclaw-tfstate"

echo "Project:  $PROJECT_ID"
echo "Region:   $REGION"
echo "Bucket:   gs://$BUCKET"
echo ""

# --- Step 1: Create GCS bucket ---
if gcloud storage buckets describe "gs://$BUCKET" --project="$PROJECT_ID" &>/dev/null; then
  echo "Bucket gs://$BUCKET already exists. Skipping creation."
else
  echo "Creating bucket..."
  gcloud storage buckets create "gs://$BUCKET" \
    --project="$PROJECT_ID" \
    --location="$REGION" \
    --uniform-bucket-level-access \
    --public-access-prevention

  echo "Enabling versioning..."
  gcloud storage buckets update "gs://$BUCKET" --versioning

  echo "Bucket created."
fi

# --- Step 2: Update backend.tf ---
echo ""
echo "Updating backend.tf..."

cat > "$BACKEND_TF" << EOF
# Remote state backend — GCS
# Bucket created by: scripts/setup-tf-backend.sh

terraform {
  backend "gcs" {
    bucket = "${BUCKET}"
    prefix = "openclaw/prod"
  }
}
EOF

echo "backend.tf updated with bucket: $BUCKET"
echo ""
echo "Done. Next: run deploy.sh"
