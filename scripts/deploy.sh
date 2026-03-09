#!/usr/bin/env bash
# deploy.sh -- Automated deployment of OpenClaw on GCP
# Usage: ./scripts/deploy.sh
# chmod +x scripts/deploy.sh
set -euo pipefail

# ---------------------------------------------------------------------------
# Colors
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TF_DIR="${PROJECT_ROOT}/terraform"
ANSIBLE_DIR="${PROJECT_ROOT}/ansible"
TFVARS_FILE="${TF_DIR}/terraform.tfvars"

# ---------------------------------------------------------------------------
# Step 0: Check prerequisites
# ---------------------------------------------------------------------------
info "Checking prerequisites..."

command -v terraform >/dev/null 2>&1 || error "terraform is not installed. Install from https://www.terraform.io/downloads"
command -v ansible-playbook >/dev/null 2>&1 || error "ansible is not installed. Install with: pip install ansible"
command -v gcloud >/dev/null 2>&1 || error "gcloud CLI is not installed. Install from https://cloud.google.com/sdk/docs/install"

# google-auth is required by the GCP dynamic inventory plugin
python3 -c "import google.auth" 2>/dev/null || error "Missing Python library 'google-auth'. Install with: pip3 install google-auth requests"

# google.cloud Ansible collection is required for the GCP inventory plugin
ansible-galaxy collection list google.cloud 2>/dev/null | grep -q "google.cloud" || {
    warn "google.cloud Ansible collection not found. Installing..."
    ansible-galaxy collection install google.cloud
}

TERRAFORM_VERSION=$(terraform version -json 2>/dev/null | python3 -c "import sys,json; print(json.load(sys.stdin)['terraform_version'])" 2>/dev/null || terraform version | head -1 | grep -oP '\d+\.\d+\.\d+')
info "Terraform version: ${TERRAFORM_VERSION}"

ANSIBLE_VERSION=$(ansible-playbook --version | head -1 | grep -oP '\d+\.\d+\.\d+')
info "Ansible version: ${ANSIBLE_VERSION}"

# Verify gcloud auth
GCLOUD_ACCOUNT=$(gcloud config get-value account 2>/dev/null || true)
if [[ -z "${GCLOUD_ACCOUNT}" ]]; then
    error "gcloud is not authenticated. Run: gcloud auth login"
fi
info "GCP account: ${GCLOUD_ACCOUNT}"

success "All prerequisites met."
echo ""

# ---------------------------------------------------------------------------
# Step 1: Validate configuration
# ---------------------------------------------------------------------------
info "Validating configuration..."

if [[ ! -f "${TFVARS_FILE}" ]]; then
    error "terraform.tfvars not found at ${TFVARS_FILE}. Copy terraform.tfvars.example and fill in your values."
fi

success "Configuration file found."
echo ""

# ---------------------------------------------------------------------------
# Step 2: Terraform init and apply
# ---------------------------------------------------------------------------
info "Initializing Terraform..."
cd "${TF_DIR}"
terraform init -input=false

info "Validating Terraform configuration..."
terraform validate

info "Planning infrastructure changes..."
terraform plan -var-file="${TFVARS_FILE}" -out=tfplan

echo ""
echo -e "${YELLOW}Review the plan above. This will create/modify GCP resources.${NC}"
echo ""
read -rp "Apply this plan? (yes/no): " CONFIRM

if [[ "${CONFIRM}" != "yes" ]]; then
    info "Deployment cancelled."
    rm -f tfplan
    exit 0
fi

info "Applying Terraform configuration..."
terraform apply tfplan
rm -f tfplan

success "Infrastructure provisioned."
echo ""

# ---------------------------------------------------------------------------
# Step 3: Extract outputs
# ---------------------------------------------------------------------------
info "Extracting Terraform outputs..."

INSTANCE_NAME=$(terraform output -raw instance_name 2>/dev/null || echo "openclaw-production-instance")
INSTANCE_ZONE=$(terraform output -raw instance_zone 2>/dev/null || echo "")
PROJECT_ID=$(terraform output -raw project_id 2>/dev/null || grep '^project_id' "${TFVARS_FILE}" | head -1 | sed 's/.*=\s*"\(.*\)"/\1/')

if [[ -z "${PROJECT_ID}" ]]; then
    error "Could not determine project ID from Terraform outputs or terraform.tfvars."
fi

if [[ -n "${INSTANCE_ZONE}" ]]; then
    info "Instance: ${INSTANCE_NAME} (${INSTANCE_ZONE})"
fi

echo ""

# ---------------------------------------------------------------------------
# Step 4: Wait for instance to be ready
# ---------------------------------------------------------------------------
info "Waiting for instance to be ready..."

MAX_ATTEMPTS=30
ATTEMPT=0

while [[ ${ATTEMPT} -lt ${MAX_ATTEMPTS} ]]; do
    ATTEMPT=$((ATTEMPT + 1))

    STATUS=$(gcloud compute instances describe "${INSTANCE_NAME}" \
        --zone="${INSTANCE_ZONE}" \
        --project="${PROJECT_ID}" \
        --format="value(status)" 2>/dev/null || echo "UNKNOWN")

    if [[ "${STATUS}" == "RUNNING" ]]; then
        success "Instance is running."
        break
    fi

    if [[ ${ATTEMPT} -eq ${MAX_ATTEMPTS} ]]; then
        error "Instance did not reach RUNNING state after ${MAX_ATTEMPTS} attempts. Current status: ${STATUS}"
    fi

    info "Instance status: ${STATUS}. Waiting... (${ATTEMPT}/${MAX_ATTEMPTS})"
    sleep 10
done

# Give the startup script time to complete
info "Waiting 30 seconds for startup script to finish bootstrapping..."
sleep 30

echo ""

# ---------------------------------------------------------------------------
# Step 5: Run Ansible playbook
# ---------------------------------------------------------------------------
info "Running Ansible playbook..."
cd "${ANSIBLE_DIR}"

# Required env vars for dynamic inventory plugin and IAP ProxyCommand in ansible.cfg
export GCP_PROJECT_ID="${PROJECT_ID}"
export GCP_ZONE="${INSTANCE_ZONE}"

# Detect OS Login username — GCP derives it from the Google account POSIX profile.
# Ansible needs this to SSH in when OS Login is enabled on the instance.
OSLOGIN_USER=$(gcloud compute os-login describe-profile \
    --format='value(loginProfile.posixAccounts[0].username)' 2>/dev/null || echo "")

if [[ -z "${OSLOGIN_USER}" ]]; then
    warn "Could not detect OS Login username. Ansible will attempt connection without an explicit user."
    warn "If it fails, run: gcloud compute os-login describe-profile"
else
    info "OS Login username: ${OSLOGIN_USER}"
fi

ansible-playbook site.yml \
    -e "gcp_project_id=${PROJECT_ID}" \
    ${OSLOGIN_USER:+-e "ansible_user=${OSLOGIN_USER}"} \
    -v

success "Application deployed."
echo ""

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${GREEN}========================================${NC}"
echo -e "${GREEN}  OpenClaw Deployment Complete${NC}"
echo -e "${GREEN}========================================${NC}"
echo ""
echo -e "  Instance:    ${BLUE}${INSTANCE_NAME}${NC}"
echo -e "  Zone:        ${BLUE}${INSTANCE_ZONE}${NC}"
echo ""
echo -e "  SSH access (IAP tunnel):"
echo -e "    ${YELLOW}gcloud compute ssh ${INSTANCE_NAME} --zone=${INSTANCE_ZONE} --tunnel-through-iap${NC}"
echo ""
echo -e "  Browser access (SSH port-forward to OpenClaw UI):"
echo -e "    ${YELLOW}gcloud compute ssh ${INSTANCE_NAME} --zone=${INSTANCE_ZONE} --tunnel-through-iap -- -L 3000:localhost:3000${NC}"
echo -e "  Then open: ${BLUE}http://localhost:3000${NC}"
echo ""
echo -e "  ${YELLOW}Next step:${NC} Populate bot tokens in Secret Manager if not done yet."
echo -e "  See terraform/secrets.tf for the gcloud commands."
echo ""
