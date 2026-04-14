#!/usr/bin/env bash
# Generate Ansible inventory and group_vars from Terraform outputs
# Usage: ./generate-inventory.sh [ANSIBLE_PROJECT_DIR]
#
# Reads Terraform outputs and writes:
#   - inventory/production.yml  (host IPs)
#   - inventory/group_vars/all.yml updates (VM IPs, RDS, CloudFront)

set -euo pipefail

ANSIBLE_DIR="${1:-../monitoring-project}"

echo "Reading Terraform outputs..."
MONITORING_IP=$(terraform output -raw monitoring_private_ip)
K3S_IP=$(terraform output -raw k3s_private_ip)
GPU_IP=$(terraform output -raw gpu_private_ip)
RDS_ENDPOINT=$(terraform output -raw rds_hostname)
RDS_PORT=$(terraform output -raw rds_port)
CLOUDFRONT_DOMAIN=$(terraform output -raw cloudfront_domain)

echo ""
echo "=== Terraform Outputs ==="
echo "Monitoring VM: $MONITORING_IP"
echo "k3s VM:        $K3S_IP"
echo "GPU VM:        $GPU_IP"
echo "RDS Endpoint:  $RDS_ENDPOINT:$RDS_PORT"
echo "CloudFront:    $CLOUDFRONT_DOMAIN"
echo ""

# Update group_vars/all.yml
ALL_VARS="$ANSIBLE_DIR/inventory/group_vars/all.yml"
if [ -f "$ALL_VARS" ]; then
  echo "Updating $ALL_VARS ..."
  sed -i "s|^monitoring_vm_ip:.*|monitoring_vm_ip: \"$MONITORING_IP\"|" "$ALL_VARS"
  sed -i "s|^k3s_host_ip:.*|k3s_host_ip: \"$K3S_IP\"|" "$ALL_VARS"
  sed -i "s|^gpu_host_ip:.*|gpu_host_ip: \"$GPU_IP\"|" "$ALL_VARS"
  sed -i "s|^rds_endpoint:.*|rds_endpoint: \"$RDS_ENDPOINT\"|" "$ALL_VARS"
  sed -i "s|^rds_port:.*|rds_port: $RDS_PORT|" "$ALL_VARS"
  sed -i "s|^cloudfront_domain:.*|cloudfront_domain: \"$CLOUDFRONT_DOMAIN\"|" "$ALL_VARS"
  echo "  Done."
else
  echo "WARNING: $ALL_VARS not found. Skipping."
fi

# Update inventory/production.yml
INVENTORY="$ANSIBLE_DIR/inventory/production.yml"
if [ -f "$INVENTORY" ]; then
  echo "Updating $INVENTORY ..."
  sed -i "s|ansible_host: .*# monitoring|ansible_host: $MONITORING_IP  # monitoring|" "$INVENTORY"
  # Use Python for more reliable YAML updates
  python3 - "$INVENTORY" "$MONITORING_IP" "$K3S_IP" "$GPU_IP" <<'PYEOF'
import sys, re

path, mon, k3s, gpu = sys.argv[1:5]
with open(path) as f:
    content = f.read()

# Update each host's ansible_host
updates = {
    'monitoring-vm': mon,
    'k3s-vm': k3s,
    'gpu-vm': gpu,
}

for host, ip in updates.items():
    pattern = rf'({host}:\s*\n\s*ansible_host:\s*)(\S+)'
    content = re.sub(pattern, rf'\g<1>{ip}', content)

with open(path, 'w') as f:
    f.write(content)
PYEOF
  echo "  Done."
else
  echo "WARNING: $INVENTORY not found. Skipping."
fi

echo ""
echo "Inventory updated. Run: ansible-playbook playbooks/site.yml"
