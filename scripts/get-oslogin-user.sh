#!/usr/bin/env bash
# get-oslogin-user.sh — detect the OS Login username and write it to group_vars/all.yml
# Usage: ./scripts/get-oslogin-user.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TFVARS="${SCRIPT_DIR}/../terraform/terraform.tfvars"
ALL_YML="${SCRIPT_DIR}/../ansible/group_vars/all.yml"

PROJECT_ID=$(grep '^project_id' "${TFVARS}" | head -1 | sed 's/.*=\s*"\(.*\)"/\1/')
ZONE=$(grep '^zone' "${TFVARS}" | head -1 | sed 's/.*=\s*"\(.*\)"/\1/')
INSTANCE="openclaw-production-instance"

echo "Detecting OS Login username via IAP tunnel..."

USERNAME=$(gcloud compute ssh "${INSTANCE}" \
  --zone="${ZONE}" \
  --project="${PROJECT_ID}" \
  --tunnel-through-iap \
  --command="whoami" \
  --quiet 2>/dev/null || echo "")

if [[ -z "${USERNAME}" ]]; then
  echo "ERROR: Could not retrieve username. Ensure the instance is RUNNING and IAP is enabled."
  exit 1
fi

echo "Detected: ${USERNAME}"

# Write or update ansible_user in group_vars/all.yml
if grep -q '^ansible_user:' "${ALL_YML}"; then
  sed -i "s|^ansible_user:.*|ansible_user: \"${USERNAME}\"|" "${ALL_YML}"
elif grep -q '^# ansible_user:' "${ALL_YML}"; then
  sed -i "s|^# ansible_user:.*|ansible_user: \"${USERNAME}\"|" "${ALL_YML}"
else
  echo "ansible_user: \"${USERNAME}\"" >> "${ALL_YML}"
fi

echo "Written to ansible/group_vars/all.yml"
