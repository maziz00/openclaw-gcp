# Cost Monitoring

This document covers the Claude API cost tracking and GCP budget alert system deployed with OpenClaw. After managing cloud budgets for enterprise teams in the UAE, I have learned that cost surprises kill projects faster than technical debt. This monitoring setup gives you visibility before the bill arrives.

---

## Overview

The cost monitoring system has two layers:

1. **Claude API cost tracker** -- A Python systemd service running on the instance that estimates token usage and pushes custom metrics to Cloud Monitoring
2. **GCP budget alerts** -- Native billing budget with threshold-based email notifications

Together, these give you both real-time application-level cost visibility and account-level spending guardrails.

---

## Claude API Cost Tracking

### How It Works

The cost tracker is a Python service deployed by the Ansible `monitoring` role. It runs as a systemd unit that:

1. Reads OpenClaw application logs to extract Claude API request/response data
2. Estimates token counts from the logged payloads
3. Calculates estimated cost based on the current Claude model pricing
4. Pushes a custom metric to Cloud Monitoring every 5 minutes (configurable)

### Custom Metric

| Property | Value |
|----------|-------|
| Metric type | `custom.googleapis.com/openclaw/claude_api_cost` |
| Metric kind | Gauge |
| Value type | Double |
| Unit | USD |
| Labels | `provider` (anthropic_api or vertex_ai), `model`, `environment` |

### Configuration

The tracking interval is configurable in Ansible:

```yaml
# ansible/group_vars/all.yml
cost_tracker_interval: 300  # seconds (5 minutes)
```

### Token Estimation

The tracker estimates tokens using the following approximation:

| Direction | Method |
|-----------|--------|
| Input tokens | Character count / 4 (conservative estimate for English text) |
| Output tokens | Character count / 4 |

This is an approximation. Actual token counts from the API may differ by 10-15%, but the goal is directional cost awareness, not accounting-grade precision. For exact numbers, use the Anthropic usage dashboard or Vertex AI billing reports.

### Pricing Reference

Current Claude model pricing used for estimation (update these values in the cost tracker config if pricing changes):

| Model | Input (per 1M tokens) | Output (per 1M tokens) |
|-------|----------------------|------------------------|
| Claude Opus 4 | $15.00 | $75.00 |
| Claude Sonnet 4 | $3.00 | $15.00 |
| Claude Haiku 3.5 | $0.80 | $4.00 |

---

## Cloud Monitoring Dashboard

### Viewing Metrics in GCP Console

1. Navigate to **Cloud Monitoring** > **Metrics Explorer**
2. Select metric type: `custom.googleapis.com/openclaw/claude_api_cost`
3. Set aggregation to **Sum** with alignment period **1 hour** or **1 day**
4. Filter by label `environment = production`

### Creating a Dashboard

To create a persistent dashboard:

1. Go to **Cloud Monitoring** > **Dashboards** > **Create Dashboard**
2. Add a **Line Chart** widget:
   - Metric: `custom.googleapis.com/openclaw/claude_api_cost`
   - Aggregation: Sum, aligned per hour
   - Group by: `model`
3. Add a **Scorecard** widget for daily total:
   - Same metric, aggregation Sum, aligned per day
4. Add a **Threshold** line at your daily budget target (e.g., $3.33/day for a $100/month budget)

### Sample MQL Query

For advanced users, this Monitoring Query Language (MQL) query shows daily cost by model:

```
fetch custom.googleapis.com/openclaw/claude_api_cost
| align delta(1d)
| group_by [metric.model], [value_claude_api_cost_aggregate: aggregate(value.claude_api_cost)]
```

---

## Budget Alerts

### Terraform Configuration

Budget alerts are provisioned by Terraform in `monitoring.tf`:

| Setting | Value |
|---------|-------|
| Budget amount | `var.budget_amount` (default: $100/month) |
| Alert thresholds | 50%, 80%, 100% of budget |
| Notification channel | Email to `var.notification_email` |
| Scope | Entire GCP project |

### How Alerts Work

GCP billing budgets evaluate spend against thresholds. When actual or forecasted spend crosses a threshold, an email notification is sent:

| Threshold | When You Receive It | What It Means |
|-----------|-------------------|---------------|
| 50% ($50) | Mid-month typically | On track, normal usage |
| 80% ($80) | Usually week 3 | Review usage, consider reducing if ahead of plan |
| 100% ($100) | Approaching limit | Take action: reduce usage or increase budget |

**Important:** GCP budget alerts are notifications only -- they do not automatically stop services or block API calls. If you need hard spending limits, configure them at the Anthropic API level or use Vertex AI quotas.

### Changing the Budget

To update the budget threshold:

```hcl
# terraform/terraform.tfvars
budget_amount = 200  # increase to $200/month
```

Then run:

```bash
cd terraform && terraform apply
```

---

## Setting Up Slack Notifications

To receive budget alerts in Slack instead of (or in addition to) email:

### Step 1: Create a Slack Webhook

1. Go to your Slack workspace settings
2. Create an incoming webhook for your target channel
3. Copy the webhook URL

### Step 2: Create a Cloud Monitoring Notification Channel

```bash
gcloud beta monitoring channels create \
  --display-name="OpenClaw Budget Alerts" \
  --type=slack \
  --channel-labels=channel_name="#devops-alerts" \
  --channel-labels=auth_token="xoxb-your-slack-token"
```

### Step 3: Link to Budget

Add the notification channel ID to the budget alert in `monitoring.tf`, or manually link it in the GCP Console under **Billing** > **Budgets & Alerts**.

---

## Setting Up PagerDuty Notifications

For on-call escalation when spend exceeds critical thresholds:

1. Create a PagerDuty service with a GCP integration
2. Add a Cloud Monitoring notification channel of type `pagerduty`
3. Link the channel to the budget alert
4. Configure PagerDuty escalation policies as needed

---

## Node Exporter

The Ansible `monitoring` role also installs Prometheus Node Exporter for system-level metrics:

| Metric Category | Examples |
|-----------------|----------|
| CPU | Usage, load average, context switches |
| Memory | Used, available, swap usage |
| Disk | Space used, I/O throughput, inode usage |
| Network | Bytes in/out, errors, drops |

Node Exporter runs on port 9100 and is accessible only within the VPC (no firewall rule exposes it externally). These metrics complement the Claude API cost data to give a complete picture of resource utilization.

### Node Exporter Version

```yaml
# ansible/group_vars/all.yml
node_exporter_version: "1.7.0"
```

---

## Cost Optimization Tips

Based on running AI workloads in production:

1. **Use Claude Haiku for simple tasks** -- Route classification, summarization, and formatting tasks to Haiku at $0.80/M input tokens instead of Opus at $15/M
2. **Cache common prompts** -- If OpenClaw supports prompt caching, enable it to reduce redundant API calls
3. **Set Vertex AI quotas** -- If using Vertex AI, set request-per-minute quotas to prevent runaway costs from bugs or abuse
4. **Review the daily dashboard** -- A 5-minute daily check catches anomalies before they become $500 surprises
5. **Right-size the instance** -- `e2-standard-2` (2 vCPU, 8 GB) is generous for a single-user AI assistant running OpenClaw + monitoring; `e2-small` may suffice for light usage

---

## Troubleshooting

### Cost tracker not reporting metrics

```bash
# Check service status
sudo systemctl status openclaw-cost-tracker

# View recent logs
sudo journalctl -u openclaw-cost-tracker --since "1 hour ago"

# Verify the service account has monitoring.metricWriter role
gcloud projects get-iam-policy YOUR_PROJECT_ID \
  --flatten="bindings[].members" \
  --filter="bindings.role:roles/monitoring.metricWriter"
```

### Budget alerts not firing

1. Verify the notification channel is active: **Cloud Monitoring** > **Alerting** > **Notification Channels**
2. Check the budget in **Billing** > **Budgets & Alerts** -- ensure the correct project is scoped
3. Budget alerts can take up to 24 hours to reflect recent spend -- GCP billing data is not real-time

### Metric not appearing in Metrics Explorer

Custom metrics take up to 2-3 minutes to appear after first write. If the metric still does not appear:

1. Confirm the cost tracker service is running (`systemctl status openclaw-cost-tracker`)
2. Check that the service account has the `roles/monitoring.metricWriter` IAM role
3. Verify the metric descriptor was created: `gcloud monitoring metric-descriptors list --filter="type=custom.googleapis.com/openclaw/claude_api_cost"`
