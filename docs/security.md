# Security

This document covers the security controls implemented in the OpenClaw GCP deployment. The approach follows defense-in-depth: multiple overlapping layers so that no single failure compromises the system.

In my experience hardening infrastructure for enterprise clients in the UAE, the most common gaps are not exotic vulnerabilities -- they are SELinux set to permissive, SSH with password auth still enabled, and API keys sitting in plaintext environment files. This deployment addresses all of those by default.

---

## SELinux Enforcing Mode

SELinux runs in **enforcing** mode with the **targeted** policy. This is the default on AlmaLinux 9 and we keep it that way -- unlike many deployment guides that tell you to `setenforce 0` as step one.

### Configuration

```yaml
# ansible/roles/base-hardening/defaults/main.yml
selinux_state: enforcing
selinux_policy: targeted
```

### Docker Integration

The `container_manage_cgroup` SELinux boolean is enabled, which allows Docker containers to manage cgroups under SELinux enforcement. The Docker daemon is configured with `selinux-enabled: true` so containers receive proper SELinux labels automatically.

```yaml
# ansible/roles/docker/defaults/main.yml
docker_daemon_config:
  selinux-enabled: true
```

What this means in practice:
- Container processes cannot access host files unless explicitly labeled
- A compromised container cannot escalate to host-level access
- Docker volumes get appropriate SELinux contexts (`container_file_t`)

### Why This Matters

Most "production-ready" Docker deployments disable SELinux because it causes permission errors during initial setup. That trades 30 minutes of configuration time for a permanent reduction in security posture. The Ansible roles in this project handle the SELinux configuration so you do not have to fight it manually.

---

## firewalld Configuration

### Default Drop Zone

The Ansible `base-hardening` role sets the default firewalld zone to **drop**, which silently discards all traffic that does not match an explicit allow rule.

```yaml
# Allowed services only — no HTTP/HTTPS because there is nothing to serve inbound
firewalld_services:
  - ssh
```

With no inbound web traffic to accept, the firewall allows only the SSH service. This is a significantly smaller attack surface than a typical web-facing VM. The `ssh` service is used exclusively by the IAP tunnel.

### Combined with GCP Firewall

The host-level firewalld works alongside the GCP VPC firewall rules:

| Layer | Rules | Purpose |
|-------|-------|---------|
| GCP VPC Firewall | Allow IAP on TCP 22, deny-all at priority 65534 | Network-level filtering before traffic reaches the instance |
| firewalld (host) | Default drop zone, allow SSH only | Defense in depth -- if GCP rules are misconfigured, host firewall still blocks |

Both layers must be bypassed to reach the instance. In practice this means an attacker would need to compromise Google's IAP infrastructure and then break through the host firewall.

### Disabled Services

Services that have no business running on an AI assistant server are explicitly stopped and disabled:

```yaml
disabled_services:
  - postfix      # No email needed
  - rpcbind      # NFS/RPC attack surface
  - avahi-daemon  # mDNS not needed in cloud
```

---

## SSH Hardening

SSH is hardened beyond the AlmaLinux 9 defaults:

| Setting | Value | Default | Why |
|---------|-------|---------|----|
| `PermitRootLogin` | `no` | `yes` | Force named user accounts for audit trail |
| `PasswordAuthentication` | `no` | `yes` | Key-based auth only; no brute-force surface |
| `MaxAuthTries` | `3` | `6` | Faster lockout on failed attempts |
| `X11Forwarding` | `no` | `yes` | No GUI forwarding needed on a headless server |
| `AllowAgentForwarding` | `no` | `yes` | Prevents SSH agent hijacking |
| `ClientAliveInterval` | `300` | `0` | Drop idle sessions after 5 minutes |
| `ClientAliveCountMax` | `2` | `3` | Two missed keepalives = disconnect |

### OS Login

GCP OS Login is enabled via instance metadata (`enable-oslogin: TRUE`). This means:

- SSH public keys are managed centrally through GCP IAM, not per-instance `authorized_keys` files
- SSH access is tied to GCP IAM roles (`roles/compute.osLogin` or `roles/compute.osAdminLogin`)
- Two-factor authentication can be enforced at the GCP organization level
- Login events are logged in Cloud Audit Logs

### Preferred Access: IAP Tunnel

The recommended SSH access path is through Identity-Aware Proxy:

```bash
gcloud compute ssh openclaw-production-instance \
  --zone us-central1-a \
  --tunnel-through-iap
```

IAP verifies the user's GCP identity before establishing the tunnel. No SSH port is exposed to the internet. The firewall rule allows TCP 22 only from IAP's range (`35.235.240.0/20`).

---

## GCP Secret Manager

### Zero Secrets in Code

The deployment follows a strict policy: **no secrets in version control, no secrets on disk, no secrets in metadata**.

### What Is Stored

Four secrets are managed in Secret Manager:

| Secret | Contents | Who Reads It |
|--------|---------|--------------|
| `openclaw-production-anthropic-api-key` | Anthropic API key | OpenClaw container (via env var) |
| `openclaw-production-vertex-ai-credentials` | Vertex AI SA key (JSON) | OpenClaw container (via env var) |
| `openclaw-production-telegram-bot-token` | Telegram bot token | OpenClaw container (via env var) |
| `openclaw-production-discord-bot-token` | Discord bot token | OpenClaw container (via env var) |

### How Secrets Flow

1. **Terraform** creates Secret Manager secret *resources* (the container, not the value)
2. **Operator** manually adds the secret *value* via GCP Console or CLI:
   ```bash
   echo -n "YOUR_TELEGRAM_BOT_TOKEN" | \
     gcloud secrets versions add openclaw-production-telegram-bot-token --data-file=-
   ```
3. **Ansible** fetches the secret value at deploy time using the instance's service account
4. **Docker** receives the secret as a runtime environment variable
5. **No persistence** -- the secret exists only in the container's memory space

### Service Account Permissions

The compute service account has the minimum IAM roles needed:

| Role | Purpose |
|------|---------|
| `roles/secretmanager.secretAccessor` | Read secret values at deploy time |
| `roles/monitoring.metricWriter` | Push cost tracking metrics |
| `roles/logging.logWriter` | Write application logs |

The service account does **not** have:
- `roles/secretmanager.admin` (cannot create or delete secrets)
- `roles/compute.admin` (cannot modify its own instance)
- `roles/iam.serviceAccountAdmin` (cannot escalate permissions)

---

## Network Security

### No Public IP, No Inbound Traffic

The GCE instance has no external IP address and accepts zero inbound connections from the internet. This eliminates the entire class of direct-to-instance attacks, including port scans, brute force, and vulnerability exploitation.

| Traffic Direction | Path |
|-------------------|------|
| Inbound (SSH only) | Operator --> IAP Tunnel --> Instance |
| Outbound (bot polling) | Instance --> Cloud NAT --> Telegram / Discord APIs |
| Outbound (Claude API) | Instance --> Cloud NAT --> Anthropic / Vertex AI |
| Outbound (GCP APIs) | Instance --> Private Google Access (no NAT needed) |

### Cloud NAT

Cloud NAT provides outbound internet access for:
- OpenClaw polling Telegram and Discord APIs
- Pulling Docker images from Docker Hub / GCR
- Calling the Anthropic API (when using `anthropic_api` provider)
- System package updates (`dnf update`)

NAT logs are enabled (errors only) for troubleshooting egress issues.

### VPC Flow Logs

Subnet flow logs are enabled with:
- 10-minute aggregation interval
- 50% flow sampling
- All metadata included

These logs feed into Cloud Logging for network forensics and anomaly detection.

---

## CIS Benchmark Alignment

The sysctl hardening parameters align with CIS AlmaLinux 9 Benchmark recommendations:

| Parameter | Value | CIS Reference |
|-----------|-------|---------------|
| `net.ipv4.conf.all.send_redirects` | `0` | 3.1.2 |
| `net.ipv4.conf.all.accept_redirects` | `0` | 3.2.2 |
| `net.ipv4.conf.all.accept_source_route` | `0` | 3.2.1 |
| `net.ipv4.conf.all.log_martians` | `1` | 3.2.4 |
| `net.ipv4.icmp_echo_ignore_broadcasts` | `1` | 3.2.5 |
| `net.ipv4.tcp_syncookies` | `1` | 3.2.7 |
| `kernel.randomize_va_space` | `2` | 1.5.3 |
| `fs.suid_dumpable` | `0` | 1.5.1 |
| `net.ipv4.ip_forward` | `1` | Exception: required for Docker networking |

The `ip_forward` setting is intentionally set to `1` because Docker requires IP forwarding for container networking. This is an accepted deviation from the CIS benchmark, documented here for audit purposes.

### Additional CIS Controls

| Control | Implementation |
|---------|---------------|
| Time synchronization | chronyd enabled and running |
| Audit logging | auditd enabled and running |
| File integrity | AIDE installed (manual baseline required) |
| Unnecessary services | postfix, rpcbind, avahi-daemon disabled |

---

## Docker Security

### Daemon Configuration

```json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2",
  "selinux-enabled": true
}
```

### Container Security Practices

- **No `--privileged` flag** -- containers run with default Linux capabilities
- **SELinux labels applied** -- Docker's SELinux integration assigns `container_t` type to container processes
- **Log rotation enforced** -- prevents disk exhaustion from runaway logs (10 MB x 3 files per container)
- **Overlay2 storage driver** -- production-grade, no deprecated drivers
- **Legacy packages removed** -- podman, buildah, and old Docker packages are purged to prevent conflicts
- **Localhost binding** -- OpenClaw binds to `127.0.0.1:3000` only; no container port is accessible from the network

### Shielded VM

The GCE instance runs as a Shielded VM with:

| Feature | Purpose |
|---------|---------|
| Secure Boot | Ensures only verified bootloader and kernel code runs |
| vTPM | Hardware-backed key storage and attestation |
| Integrity Monitoring | Detects boot-level rootkits and tampering |

---

## Security Checklist

Use this checklist after deployment to verify security controls:

```bash
# Verify SELinux is enforcing
getenforce
# Expected: Enforcing

# Verify firewalld default zone
firewall-cmd --get-default-zone
# Expected: drop

# Verify only SSH is allowed (no http/https)
firewall-cmd --list-services
# Expected: ssh

# Verify SSH hardening
sshd -T | grep -E 'permitrootlogin|passwordauthentication|maxauthtries'
# Expected: permitrootlogin no, passwordauthentication no, maxauthtries 3

# Verify Docker SELinux
docker info | grep "Security Options"
# Expected: selinux

# Verify no public IP (outbound via Cloud NAT)
curl -s ifconfig.me
# Expected: Cloud NAT IP, not instance IP (verify in GCP Console)

# Verify OpenClaw binds to localhost only
ss -tlnp | grep 3000
# Expected: 127.0.0.1:3000

# Verify disabled services
systemctl is-active postfix rpcbind avahi-daemon
# Expected: inactive for all
```
