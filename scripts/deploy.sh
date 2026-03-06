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
LB_IP=$(terraform output -raw load_balancer_ip 2>/dev/null || echo "")
PROJECT_ID=$(terraform output -raw project_id 2>/dev/null || echo "")

if [[ -n "${INSTANCE_ZONE}" ]]; then
    info "Instance: ${INSTANCE_NAME} (${INSTANCE_ZONE})"
fi
if [[ -n "${LB_IP}" ]]; then
    info "Load Balancer IP: ${LB_IP}"
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

# Export project ID for the dynamic inventory plugin
export GCP_PROJECT_ID="${PROJECT_ID}"

ansible-playbook site.yml \
    -e "gcp_project_id=${PROJECT_ID}" \
    -e "domain_name=$(cd "${TF_DIR}" && terraform output -raw domain_name 2>/dev/null || echo '')" \
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

if [[ -n "${LB_IP}" ]]; then
    DOMAIN_NAME=$(cd "${TF_DIR}" && terraform output -raw domain_name 2>/dev/null || echo "")
    echo -e "  Load Balancer IP:  ${BLUE}${LB_IP}${NC}"
    if [[ -n "${DOMAIN_NAME}" ]]; then
        echo -e "  Application URL:   ${BLUE}https://${DOMAIN_NAME}${NC}"
    fi
fi

echo -e "  Instance:          ${BLUE}${INSTANCE_NAME}${NC}"
if [[ -n "${INSTANCE_ZONE}" ]]; then
    echo -e "  Zone:              ${BLUE}${INSTANCE_ZONE}${NC}"
fi

echo ""
echo -e "  SSH via IAP:"
echo -e "    ${YELLOW}gcloud compute ssh ${INSTANCE_NAME} --zone=${INSTANCE_ZONE} --tunnel-through-iap${NC}"
echo ""

if [[ -n "${DOMAIN_NAME}" ]]; then
    echo -e "  ${YELLOW}Note:${NC} The Google-managed SSL certificate may take 15-60 minutes"
    echo -e "  to provision. HTTPS will not work until the certificate is active."
    echo -e "  Check status: gcloud compute ssl-certificates list"
fi

echo ""
