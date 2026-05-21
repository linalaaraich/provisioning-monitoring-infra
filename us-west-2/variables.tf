# -----------------------------------------------------------------------------
# Tailscale — sensitive, never put a default value here.
# Pass at apply time via:  export TF_VAR_tailscale_auth_key="$(cat ~/.tailscale-key)"
# -----------------------------------------------------------------------------
variable "tailscale_auth_key" {
  description = "Ephemeral + reusable Tailscale auth key used by user-data to enroll the GPU host into the tailnet on first boot."
  type        = string
  sensitive   = true
}

# -----------------------------------------------------------------------------
# SSH access — same convention as the us-east-1 root module.
# Tailnet traffic bypasses the AWS security group (arrives on tailscale0
# inside the OS), so this list only gates *public-internet* SSH.
# -----------------------------------------------------------------------------
variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed public-internet SSH access to the GPU instance. Keep scoped tight — Tailscale is the primary access path."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

# -----------------------------------------------------------------------------
# Instance shape
# -----------------------------------------------------------------------------
variable "instance_type" {
  description = "EC2 instance type for the GPU host. g5.xlarge = A10G 24 GB VRAM, 4 vCPU, 16 GB RAM."
  type        = string
  default     = "g5.xlarge"
}

variable "key_pair_name" {
  description = "OPTIONAL name of an existing AWS key pair in us-west-2. Leave null (default) to launch without an AWS key pair — admin access then goes through Tailscale SSH, which is enabled by `tailscale up --ssh` in userdata.sh.tpl. Set this only if you want an AWS-keyfile fallback in addition to Tailscale."
  type        = string
  default     = null
}

# -----------------------------------------------------------------------------
# Cost protection — CloudWatch billing alarm threshold.
# The alarm itself is created by the Phase 3 Lambda Terraform; this var is
# declared here so the value can be set once via -var-file and referenced
# from either module.
# -----------------------------------------------------------------------------
variable "billing_alert_threshold_usd" {
  description = "USD threshold for the monthly CloudWatch billing alarm. Lina's default proposal: 50 USD soft alert, 200 USD hard concern."
  type        = number
  default     = 50
}

# -----------------------------------------------------------------------------
# Phase 3 gateway — added by gateway.tf
# -----------------------------------------------------------------------------
variable "alarm_email_to" {
  description = "Email address that receives CloudWatch billing alarm notifications via SNS. Must be confirmed once by clicking the link in the first SNS email after apply."
  type        = string
}

variable "idle_threshold_min" {
  description = "Minutes of no Grafana traffic before triage-idle-checker calls ec2:StopInstances. The EventBridge cron itself fires every 5 min, so actual stop latency is threshold + up to 5 min."
  type        = number
  default     = 20
}

variable "allowed_webhook_source_ips" {
  description = "List of source IPs (no CIDR — single IPs) that the Lambda router will accept webhook POSTs from. Anyone else gets 403. Lock this down to your Grafana host + any manual-test machines."
  type        = list(string)
  default     = []
}
