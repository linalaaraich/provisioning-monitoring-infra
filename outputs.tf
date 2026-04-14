# -----------------------------------------------------------------------------
# EC2 Private IPs (used by Ansible inventory)
# -----------------------------------------------------------------------------
output "monitoring_private_ip" {
  description = "Monitoring VM private IP"
  value       = aws_instance.monitoring.private_ip
}

output "k3s_private_ip" {
  description = "k3s cluster VM private IP"
  value       = aws_instance.k3s.private_ip
}

output "gpu_private_ip" {
  description = "GPU VM private IP"
  value       = aws_instance.gpu.private_ip
}

# -----------------------------------------------------------------------------
# Elastic IPs (for SSH access)
# -----------------------------------------------------------------------------
output "monitoring_public_ip" {
  description = "Monitoring VM Elastic IP"
  value       = aws_eip.monitoring.public_ip
}

output "k3s_public_ip" {
  description = "k3s cluster VM Elastic IP"
  value       = aws_eip.k3s.public_ip
}

output "gpu_public_ip" {
  description = "GPU VM Elastic IP"
  value       = aws_eip.gpu.public_ip
}

# -----------------------------------------------------------------------------
# RDS
# -----------------------------------------------------------------------------
output "rds_endpoint" {
  description = "RDS MySQL endpoint (hostname:port)"
  value       = aws_db_instance.mysql.endpoint
}

output "rds_hostname" {
  description = "RDS MySQL hostname only"
  value       = aws_db_instance.mysql.address
}

output "rds_port" {
  description = "RDS MySQL port"
  value       = aws_db_instance.mysql.port
}

# -----------------------------------------------------------------------------
# S3 / CloudFront
# -----------------------------------------------------------------------------
output "s3_bucket_name" {
  description = "S3 bucket name for frontend and Drain3 snapshots"
  value       = aws_s3_bucket.frontend.id
}

output "cloudfront_domain" {
  description = "CloudFront distribution domain name"
  value       = aws_cloudfront_distribution.frontend.domain_name
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID (for cache invalidation)"
  value       = aws_cloudfront_distribution.frontend.id
}

# -----------------------------------------------------------------------------
# Network IDs
# -----------------------------------------------------------------------------
output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "private_subnet_id" {
  description = "Private subnet ID"
  value       = aws_subnet.private.id
}

output "public_subnet_id" {
  description = "Public subnet ID"
  value       = aws_subnet.public.id
}
