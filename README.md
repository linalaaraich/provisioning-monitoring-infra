# provisioning-monitoring-infra

Terraform configuration for the CIRES Technologies observability platform AWS demo environment (Sprint 2).

## Infrastructure

Provisions a production-like demo environment in `us-east-1`:

| Resource | Type | Purpose |
|----------|------|---------|
| VPC | 10.0.0.0/16 | Public + private subnets, NAT Gateway |
| Monitoring EC2 | t3.large | Prometheus, Grafana, Loki, Jaeger, OTel Collector |
| Backend EC2 | t3.small | Spring Boot API |
| Network EC2 | t3.small | Kong API Gateway |
| AI/LLM EC2 | g4dn.xlarge | Ollama, Triage Service, 5 MCP servers |
| RDS MySQL | db.t3.micro | Managed database (single-AZ) |
| S3 + CloudFront | Standard | React frontend static hosting |

## Usage

```bash
# Configure
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your SSH key path, DB passwords, etc.

# Deploy
terraform init
terraform plan
terraform apply

# Generate Ansible inventory from Terraform outputs
./generate-inventory.sh

# Tear down (removes ALL resources)
terraform destroy
```

## Outputs

After `terraform apply`, outputs feed directly into the Ansible inventory:
- EC2 private IPs and Elastic IPs
- RDS endpoint
- S3 bucket name
- CloudFront domain

## Related

- [monitoring-project](https://github.com/linalaaraich/monitoring-project) — Ansible playbooks and roles
- [monitoring-docs](https://github.com/linalaaraich/monitoring-docs) — Documentation and sprint guides
