# OpenClaw GCP Deployment -- Production-Grade AI Assistant Infrastructure

[![Terraform](https://img.shields.io/badge/Terraform-%3E%3D1.5-844FBA?logo=terraform)](https://www.terraform.io/)
[![Ansible](https://img.shields.io/badge/Ansible-%3E%3D2.15-EE0000?logo=ansible)](https://www.ansible.com/)
[![GCP](https://img.shields.io/badge/Google%20Cloud-4285F4?logo=googlecloud&logoColor=white)](https://cloud.google.com/)
[![AlmaLinux](https://img.shields.io/badge/AlmaLinux%209-0F4266?logo=almalinux&logoColor=white)](https://almalinux.org/)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

Fully automated, security-first deployment of [OpenClaw](https://openclaw.ai) personal AI assistant on Google Cloud Platform.

In my 12 years managing enterprise infrastructure across the UAE and Egypt, I have seen too many AI deployments treated as afterthoughts -- containers thrown onto a VM with no hardening, secrets in environment variables, and zero cost visibility. This project is how I deploy AI assistants for production: security-first, cost-aware, and fully automated.

---

## Architecture

```mermaid
graph TB
    Client["Client Browser"]

    subgraph GCP["Google Cloud Platform"]
        subgraph LB["HTTPS Load Balancer"]
            ManagedCert["Google-Managed<br/>SSL Certificate"]
            ForwardingRule["Global Forwarding Rule<br/>:443"]
        end

        subgraph VPC["VPC Network (10.10.0.0/24)"]
            subgraph Instance["AlmaLinux 9 (e2-standard-2)"]
                Nginx["Nginx<br/>Reverse Proxy :80"]
                OpenClaw["OpenClaw<br/>Docker Container :3000"]
                CostTracker["Cost Tracker<br/>systemd Service"]
            end
        end

        SecretMgr["GCP Secret Manager<br/>API Keys"]
        CloudNAT["Cloud NAT<br/>Egress Only"]
        Monitoring["Cloud Monitoring<br/>Budget Alerts"]
        IAP["Identity-Aware Proxy<br/>SSH Access"]
    end

    ClaudeAPI["Claude AI<br/>Vertex AI / Anthropic API"]

    Client -->|HTTPS :443| ForwardingRule
    ForwardingRule --> ManagedCert
    ManagedCert --> Nginx
    Nginx -->|Proxy :3000| OpenClaw
    OpenClaw -->|Fetch secrets| SecretMgr
    OpenClaw -->|via Cloud NAT| CloudNAT
    CloudNAT --> ClaudeAPI
    CostTracker --> Monitoring
    IAP -->|SSH Tunnel| Instance

    style GCP fill:#e8f0fe,stroke:#4285f4,stroke-width:2px
    style VPC fill:#fce8e6,stroke:#ea4335,stroke-width:1px
    style Instance fill:#fef7e0,stroke:#fbbc04,stroke-width:1px
    style LB fill:#e6f4ea,stroke:#34a853,stroke-width:1px
```

---

## Features

- **Security-first** -- SELinux enforcing, firewalld with default-drop zone, CIS-aligned sysctl hardening, Shielded VM with Secure Boot
- **Zero secrets in code** -- GCP Secret Manager with runtime fetching; API keys never touch disk or version control
- **Dual Claude AI provider support** -- Toggle between Anthropic direct API and Vertex AI with a single variable
- **Enterprise TLS** -- Google-managed SSL certificate via HTTPS Load Balancer; zero certificate renewal overhead
- **No public IP** -- Instance sits behind Cloud NAT for egress; SSH via Identity-Aware Proxy only
- **Claude API cost monitoring** -- Python systemd service pushes token usage to Cloud Monitoring with budget alerts
- **AlmaLinux 9** -- Red Hat ecosystem, binary-compatible with RHEL, enterprise-grade without the license cost
- **Fully automated** -- Single `deploy.sh` runs Terraform + Ansible end to end

---

## Project Structure

```
openclaw-gcp-deployment/
|-- README.md
|-- LICENSE
|-- deploy.sh
|-- terraform/
|   |-- versions.tf          # Provider versions and constraints
|   |-- backend.tf           # GCS remote state (optional)
|   |-- variables.tf         # All input variables with validation
|   |-- main.tf              # Locals, data sources
|   |-- network.tf           # VPC, subnet, Cloud NAT, firewall rules
|   |-- compute.tf           # GCE instance, instance group
|   |-- lb.tf                # HTTPS LB, managed SSL, health check
|   |-- iam.tf               # Service account, IAM bindings
|   |-- secrets.tf           # Secret Manager resources
|   |-- monitoring.tf        # Budget alerts, notification channels
|   |-- dns.tf               # Cloud DNS record (optional)
|   |-- outputs.tf           # Key outputs (LB IP, instance name, etc.)
|   `-- terraform.tfvars.example
|-- ansible/
|   |-- ansible.cfg
|   |-- site.yml
|   |-- inventory/
|   |   `-- gcp.yml           # Dynamic GCP inventory
|   |-- group_vars/
|   |   `-- all.yml
|   `-- roles/
|       |-- base-hardening/   # SELinux, firewalld, SSH, sysctl, CIS
|       |-- docker/           # Docker CE, Compose, SELinux integration
|       |-- secrets/          # GCP Secret Manager fetch
|       |-- openclaw/         # OpenClaw container deployment
|       |-- nginx/            # Reverse proxy configuration
|       `-- monitoring/       # Cost tracker, node exporter
|-- docs/
|   |-- architecture.md
|   |-- security.md
|   `-- cost-monitoring.md
`-- scripts/
    `-- deploy.sh
```

---

## Prerequisites

| Tool | Version | Purpose |
|------|---------|---------|
| Terraform | >= 1.5 | Infrastructure provisioning |
| Ansible | >= 2.15 | Configuration management |
| gcloud CLI | Latest | GCP authentication and project setup |
| GCP Project | -- | With billing enabled |
| Domain name | -- | For the managed SSL certificate |

You also need the following GCP APIs enabled:

```bash
gcloud services enable \
  compute.googleapis.com \
  secretmanager.googleapis.com \
  iap.googleapis.com \
  monitoring.googleapis.com \
  billingbudgets.googleapis.com \
  dns.googleapis.com
```

---

## Quick Start

**1. Clone the repository**

```bash
git clone https://github.com/maziz00/openclaw-gcp.git
cd openclaw-gcp
```

**2. Configure your deployment**

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
```

Edit `terraform/terraform.tfvars` with your values:

```hcl
project_id         = "my-gcp-project"
region             = "us-central1"
zone               = "us-central1-a"
domain_name        = "openclaw.example.com"
notification_email = "alerts@example.com"
claude_provider    = "anthropic_api"   # or "vertex_ai"
budget_amount      = 100
```

**3. Deploy**

```bash
chmod +x scripts/deploy.sh
./scripts/deploy.sh
```

The script runs Terraform to provision infrastructure, waits for the instance, then runs Ansible to configure the application. Total deployment takes roughly 8-12 minutes.

---

## Configuration

### Key Terraform Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `project_id` | -- (required) | GCP project ID |
| `region` | `us-central1` | GCP region |
| `zone` | -- (required) | GCP zone within region |
| `domain_name` | -- (required) | FQDN for SSL certificate |
| `instance_type` | `e2-standard-2` | GCE machine type (2 vCPU, 8 GB) |
| `claude_provider` | `anthropic_api` | `anthropic_api` or `vertex_ai` |
| `environment` | `production` | Environment label (production/staging/development) |
| `budget_amount` | `100` | Monthly budget alert threshold in USD |
| `notification_email` | -- (required) | Email for budget and monitoring alerts |
| `enable_dns` | `false` | Create Cloud DNS A record |
| `ssh_source_ranges` | `[]` | CIDR ranges for direct SSH (prefer IAP instead) |

### Key Ansible Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `claude_provider` | `anthropic_api` | Must match Terraform setting |
| `openclaw_version` | `latest` | OpenClaw Docker image tag |
| `openclaw_port` | `3000` | Application listen port |
| `domain_name` | `openclaw.example.com` | Domain for Nginx server_name |
| `cost_tracker_interval` | `300` | Seconds between cost metric pushes |

---

## Security

This deployment follows a defense-in-depth approach:

- **SELinux enforcing** with targeted policy and Docker container management
- **firewalld** with default-drop zone -- only HTTP, HTTPS, and SSH allowed
- **SSH hardened** -- no root login, no password auth, max 3 attempts
- **No public IP** on the instance -- egress via Cloud NAT, SSH via IAP tunnel
- **Shielded VM** -- Secure Boot, vTPM, and integrity monitoring enabled
- **GCP Secret Manager** -- API keys fetched at runtime, never stored on disk
- **CIS-aligned sysctl** -- ICMP broadcast ignore, SYN cookies, martian logging, ASLR

For the full security documentation, see [docs/security.md](docs/security.md).

---

## Cost Monitoring

A Python systemd service tracks Claude API token usage and pushes custom metrics to Cloud Monitoring. Budget alerts notify you before costs exceed your threshold.

- Custom metric: `custom.googleapis.com/openclaw/claude_api_cost`
- Default budget threshold: $100/month (configurable via `budget_amount`)
- Alert channels: email (expandable to Slack, PagerDuty)

For setup details and dashboard configuration, see [docs/cost-monitoring.md](docs/cost-monitoring.md).

---

## Why OpenClaw

[OpenClaw](https://openclaw.ai) is an open-source AI assistant that gives you full control over your AI interactions. Unlike hosted solutions, you own your data, control your costs, and can switch between AI providers without vendor lock-in. This deployment brings OpenClaw to production with the same infrastructure standards I apply to enterprise workloads in the MENA region.

---

## Documentation

- [Architecture](docs/architecture.md) -- Network topology, compute, load balancing, secrets flow
- [Security](docs/security.md) -- SELinux, firewalld, SSH, CIS alignment, Docker hardening
- [Cost Monitoring](docs/cost-monitoring.md) -- Claude API tracking, budget alerts, dashboards

---

## Author

**Mohamed AbdelAziz** -- Senior DevOps Engineer | 12 Years | Kubernetes GCP AWS

- [GitHub](https://github.com/maziz00)
- [LinkedIn](https://www.linkedin.com/in/maziz00/)
- [Medium](https://medium.com/@maziz00)
- [Upwork](https://www.upwork.com/freelancers/maziz00)

---

## License

This project is licensed under the MIT License. See [LICENSE](LICENSE) for details.
