#!/bin/bash
# =============================================================================
# observability-rca-gpu first-boot bootstrap
#
# Runs ONCE on the very first boot of the g5.xlarge. Idempotent enough that
# re-running won't break anything, but day-2 changes should go through Ansible
# (../playbooks/) not by editing this file — Terraform ignores user_data
# changes on the instance after creation.
# =============================================================================
set -euxo pipefail

# -----------------------------------------------------------------------------
# Tailscale — install + join tailnet
# -----------------------------------------------------------------------------
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up \
  --authkey='${tailscale_auth_key}' \
  --hostname='${tailscale_hostname}' \
  --accept-routes \
  --ssh

# -----------------------------------------------------------------------------
# Docker — the DL AMI usually has it preinstalled, but guard against drift.
# -----------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update -y
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  systemctl enable --now docker
else
  # Make sure the compose plugin exists even when docker itself is preinstalled.
  apt-get update -y
  apt-get install -y docker-compose-plugin || true
fi

# -----------------------------------------------------------------------------
# AWS CLI — needed by the SQS-drain script that Phase 3 ships.
# -----------------------------------------------------------------------------
if ! command -v aws >/dev/null 2>&1; then
  apt-get install -y unzip
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp/
  /tmp/aws/install
  rm -rf /tmp/aws /tmp/awscliv2.zip
fi

# -----------------------------------------------------------------------------
# Ollama — installed on the HOST (not in a container) so the systemd unit
# can attach to the GPU directly via nvidia-container-runtime. The triage
# compose reaches it at host.docker.internal:11434 via the docker0 gateway.
#
# CRITICAL drop-in: the stock ollama.service binds 127.0.0.1:11434, which
# blocks containers (or any external caller) from reaching it. We override
# OLLAMA_HOST to 0.0.0.0:11434 so the docker0 gateway and the VPC SG (which
# already opens 11434) actually work. Without this drop-in, the triage
# container hits "connection refused" on every Ollama call.
#
# Added to IaC 2026-06-02 after the real-induction agent had to add the
# drop-in by hand on the live GPU host — see runbook MIGRATION_RESTORE.md.
# -----------------------------------------------------------------------------
if ! command -v ollama >/dev/null 2>&1; then
  curl -fsSL https://ollama.com/install.sh | sh
fi
mkdir -p /etc/systemd/system/ollama.service.d
cat >/etc/systemd/system/ollama.service.d/override.conf <<'OLLAMA_OVERRIDE'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
OLLAMA_OVERRIDE
systemctl daemon-reload
systemctl restart ollama || true
systemctl enable ollama || true

# Pre-pull the production models so Phase 2 doesn't pay the ~10 GB download
# on first request. `:14b` is the primary; `:7b` is the fallback used when
# the circuit breaker trips on the 14b. Ollama's canonical tags are bare
# `:14b` + `:7b` — the `-instruct` suffix is NOT a valid tag for qwen2.5
# (caught by the real-induction agent 2026-06-02 with a 404 on /api/generate).
sudo -u ubuntu ollama pull qwen2.5:14b || echo "WARN: qwen2.5:14b pre-pull failed."
sudo -u ubuntu ollama pull qwen2.5:7b  || echo "WARN: qwen2.5:7b pre-pull failed."

# -----------------------------------------------------------------------------
# Triage stack scaffolding — directories + image pre-pull.
# The actual docker-compose.gpu.yml file is scp'd in during Phase 2;
# user-data only primes the host so Phase 2 is fast.
# -----------------------------------------------------------------------------
mkdir -p /opt/triage/config /opt/triage/state /opt/triage/models
chown -R ubuntu:ubuntu /opt/triage

docker pull ghcr.io/linalaaraich/monitoring-triage-service:main || \
  echo "WARN: triage image pre-pull failed — Phase 2 will retry."

# -----------------------------------------------------------------------------
# systemd unit — installed but NOT enabled. Phase 2 enables it after
# /opt/triage/docker-compose.gpu.yml is in place.
# -----------------------------------------------------------------------------
cat >/etc/systemd/system/triage-stack.service <<'UNIT'
[Unit]
Description=Triage stack (FastAPI + MCP + Drain3 + Ollama) — GPU host
Requires=docker.service
After=docker.service network-online.target
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
WorkingDirectory=/opt/triage
ExecStart=/usr/bin/docker compose -f /opt/triage/docker-compose.gpu.yml up -d
ExecStop=/usr/bin/docker compose -f /opt/triage/docker-compose.gpu.yml down
TimeoutStartSec=600

[Install]
WantedBy=multi-user.target
UNIT

# -----------------------------------------------------------------------------
# retention-cleanup.{service,timer} — daily systemd timer that prunes
# rca_history.db rows older than 90 days (except quality='actionable',
# which are the exemplar pool and never expire). Persistent=true so if the
# instance was Lambda-autoshutoff during the scheduled run, it catches up
# on next boot. The Python script + units are scp'd in by Phase 2 deploy
# from /root/provisioning-monitoring-infra/us-west-2/retention/ — until
# the files land, the timer just won't fire.
# -----------------------------------------------------------------------------

# -----------------------------------------------------------------------------
# drain-queue.service — picks webhooks out of SQS during cold-start recovery.
# The actual Python (drain_queue.py) is scp'd in by Phase 2 along with the
# compose file. Until then this unit is installed but DISABLED.
#
# The env file at /opt/triage/drain-queue.env carries SQS_QUEUE_URL and
# AWS_DEFAULT_REGION; Phase 2 generates it from `terraform output` and
# scp's it in. Until that file exists the service will refuse to start.
# -----------------------------------------------------------------------------
cat >/etc/systemd/system/drain-queue.service <<'UNIT'
[Unit]
Description=Triage cold-start queue drainer (SQS → localhost:8090/webhook/grafana)
After=triage-stack.service network-online.target
Wants=triage-stack.service network-online.target

[Service]
Type=simple
EnvironmentFile=/opt/triage/drain-queue.env
ExecStart=/usr/bin/python3 /opt/triage/drain_queue.py
Restart=on-failure
RestartSec=10s
User=ubuntu

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
# Intentionally NOT enabling triage-stack.service or drain-queue.service
# here — Phase 2 runs:
#   sudo systemctl enable --now triage-stack.service
#   sudo systemctl enable --now drain-queue.service
# after the compose file + drain_queue.py + drain-queue.env are delivered.

echo "user-data bootstrap complete — host is ready for Phase 2 compose drop"
