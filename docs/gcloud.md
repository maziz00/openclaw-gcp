# GCP / Terraform Known Issues

Errors encountered during `terraform apply` and their root causes and fixes.

---

## Error 1 — billingbudgets API 403: Quota Project Not Set

### Symptoms

```
Error: Error creating Budget: googleapi: Error 403:
Your application is authenticating by using local Application Default Credentials.
The billingbudgets.googleapis.com API requires a quota project, which is not set by default.
```

### Root Cause

When you authenticate with `gcloud auth application-default login`, Terraform uses your **user credentials** (ADC — Application Default Credentials), not a service account. Some GCP APIs (including `billingbudgets.googleapis.com`) require a **quota project** to be declared — this tells GCP which project to bill API quota against. User credentials have no default quota project, so the call is rejected.

The error message mentions project `764086051850` — that is Google's own internal project (`cloudsdktool`), which appears when no quota project is set. GCP refuses to use it.

### Fix (code-side — permanent)

Add `user_project_override` and `billing_project` to the Google provider in `terraform/versions.tf`:

```hcl
provider "google" {
  project               = var.project_id
  region                = var.region
  zone                  = var.zone
  user_project_override = true
  billing_project       = var.project_id
}
```

`user_project_override = true` instructs the provider to attach the `X-Goog-User-Project` header to every API request. This header tells GCP to use `billing_project` as the quota project. Since both point to your actual project, the API call is authorised.

**This fix is already applied in `terraform/versions.tf`.**

### Fix (user-side — one-time, alternative)

If you prefer not to touch the provider block, run this once:

```bash
gcloud auth application-default set-quota-project claude-code-00
```

This writes the quota project into `~/.config/gcloud/application_default_credentials.json`. It persists across Terraform runs but is machine-specific — anyone else cloning the repo must run it too. The code-side fix is more portable.

### Fix (for gcloud CLI calls, separate from Terraform)

```bash
gcloud config set billing/quota_project claude-code-00
```

---

## Error 2 — MetricDescriptor 400: DELTA Metric Kind Not Supported

### Symptoms

```
Error: Error creating MetricDescriptor: googleapi: Error 400:
Field metricDescriptor.metricKind had an invalid value of "DELTA":
When creating metric custom.googleapis.com/openclaw/claude_api_tokens_used:
the DELTA metric kind is not supported for custom metrics.
```

### Root Cause

GCP custom metrics only support two metric kinds:

| Kind | Meaning | Use When |
|------|---------|----------|
| `GAUGE` | Snapshot value at a point in time | CPU %, memory used, temperature |
| `CUMULATIVE` | Monotonically increasing counter from a start time | Total requests, total tokens |

`DELTA` (change over an interval) is used internally by GCP built-in metrics but is **not available for user-defined custom metrics**. The Terraform resource had `metric_kind = "DELTA"` — GCP rejected it.

### Fix

Change `metric_kind` to `CUMULATIVE` in `terraform/monitoring.tf`:

```hcl
resource "google_monitoring_metric_descriptor" "claude_api_tokens" {
  metric_kind = "CUMULATIVE"  # was DELTA — not supported for custom metrics
  ...
}
```

`CUMULATIVE` is correct for token counting: the Python cost tracker reports an ever-increasing total tokens-consumed counter. Each data point includes a `start_time` (when the counter began) and an `end_time` (the current timestamp). Cloud Monitoring can then compute rates and deltas itself.

Also update the alert policy aligner — `ALIGN_SUM` is wrong for `CUMULATIVE` metrics:

```hcl
aggregations {
  alignment_period   = "3600s"
  per_series_aligner = "ALIGN_RATE"   # was ALIGN_SUM; rate is correct for CUMULATIVE
}
```

`ALIGN_RATE` converts a `CUMULATIVE` metric to a per-second rate. At a 3600s alignment period, this gives tokens/second over the last hour. Multiply by 3600 to get hourly token count.

**Both fixes are already applied in `terraform/monitoring.tf`.**

---

## Error 3 — AlertPolicy 404: Metric Not Found (Cascade)

### Symptoms

```
Error: Error creating AlertPolicy: googleapi: Error 404:
Cannot find metric(s) that match type = "custom.googleapis.com/openclaw/claude_api_tokens_used".
```

### Root Cause

This is a **cascade error** from Error 2. Because the `MetricDescriptor` resource failed to create (DELTA not supported), the `AlertPolicy` that references the same metric type found nothing to attach to.

### Fix

No independent fix needed. Fixing Error 2 (changing DELTA → CUMULATIVE) allows the MetricDescriptor to be created successfully. On the next `terraform apply`, the AlertPolicy creation will succeed automatically because the metric now exists.

---

## Re-running After Fixes

After applying the code fixes above, run:

```bash
cd terraform
terraform apply -var-file=terraform.tfvars
```

The three resources that failed will be created in this order (Terraform handles dependencies):
1. `google_monitoring_metric_descriptor.claude_api_tokens` — CUMULATIVE, created successfully
2. `google_monitoring_alert_policy.high_token_usage` — metric now exists, created successfully
3. `google_billing_budget.openclaw` — quota project now set via provider, created successfully

---

---

## Error 4 — google_billing_budget: "billing_account" Required / No Definition Found

### Symptoms

```
Error: Missing required argument
  with google_billing_budget.openclaw,
  on monitoring.tf line 28, in resource "google_billing_budget" "openclaw":
  28:   billing_account = data.google_project.this.billing_account
The argument "billing_account" is required, but no definition was found.
```

### Root Cause

The `google_project` data source does **not** expose `billing_account` as an output attribute. The GCP Terraform provider only returns project metadata (number, name, labels, etc.) — the billing account linkage is not part of the project resource model. Referencing `data.google_project.this.billing_account` returns `null`, which Terraform treats as "no definition found" for a required argument.

### Fix

Add a `billing_account_id` input variable and pass it directly to the budget resource.

**`terraform/variables.tf`** — add the variable:
```hcl
variable "billing_account_id" {
  description = "GCP billing account ID. Format: XXXXXX-XXXXXX-XXXXXX. Find with: gcloud billing accounts list"
  type        = string
}
```

**`terraform/monitoring.tf`** — reference the variable:
```hcl
resource "google_billing_budget" "openclaw" {
  billing_account = var.billing_account_id
  ...
}
```

**`terraform/terraform.tfvars`** — add your actual value:
```hcl
billing_account_id = "XXXXXX-XXXXXX-XXXXXX"
```

Find your billing account ID:
```bash
gcloud billing accounts list
# Output example:
# ACCOUNT_ID            NAME                OPEN  MASTER_ACCOUNT_ID
# 01AB23-456789-CDEF01  My Billing Account  True
```

**This fix is already applied.**

---

## Prevention

| Issue | Prevention |
|-------|-----------|
| ADC quota project | Always set `user_project_override = true` in the provider when using ADC. Standard practice for any Terraform project that uses billing/budget APIs. |
| DELTA metric kind | Custom metrics only support `GAUGE` or `CUMULATIVE`. Check the [metric kind docs](https://cloud.google.com/monitoring/api/ref_v3/rest/v3/projects.metricDescriptors#MetricKind) before choosing. |
| Alert policy cascade | Always check if the metric descriptor was successfully created before adding alert policies that reference it. `terraform plan` won't catch this — it only appears at apply time. |
| billing_account on google_project | The `google_project` data source does not return billing account. Always pass `billing_account_id` as an explicit variable. |
