output "instance_id" {
  description = "EC2 instance ID for the GPU host"
  value       = aws_instance.gpu.id
}

output "public_ip" {
  description = "Elastic IP attached to the GPU host (stable public address)"
  value       = aws_eip.gpu.public_ip
}

output "private_ip" {
  description = "Private IP of the GPU host inside the VPC — Lambda gateway calls this, NOT the EIP"
  value       = aws_instance.gpu.private_ip
}

output "instance_profile_arn" {
  description = "IAM instance profile ARN — referenced by the Phase 3 Lambda when granting STS access patterns"
  value       = aws_iam_instance_profile.gpu.arn
}

output "instance_role_arn" {
  description = "IAM role ARN used by the GPU instance profile"
  value       = aws_iam_role.gpu.arn
}

output "vpc_id" {
  description = "VPC ID — Phase 3 Lambda Terraform attaches Lambda + interface endpoints to this VPC"
  value       = aws_vpc.main.id
}

output "private_subnet_id" {
  description = "Private subnet ID — Phase 3 Lambda runs here"
  value       = aws_subnet.private.id
}

output "public_subnet_id" {
  description = "Public subnet ID — GPU instance lives here"
  value       = aws_subnet.public.id
}

output "security_group_id" {
  description = "Security group ID for the GPU host — Phase 3 Lambda's SG opens 8090 to this"
  value       = aws_security_group.gpu.id
}

# -----------------------------------------------------------------------------
# Phase 3 gateway outputs (from gateway.tf)
# -----------------------------------------------------------------------------
output "api_gateway_invoke_url" {
  description = "Full URL Grafana should POST webhooks to. Pattern: https://<api-id>.execute-api.us-west-2.amazonaws.com/webhook/grafana"
  value       = "${aws_apigatewayv2_api.gateway.api_endpoint}/webhook/grafana"
}

output "api_gateway_id" {
  description = "API Gateway HTTP API ID — useful for console links and CLI debugging."
  value       = aws_apigatewayv2_api.gateway.id
}

output "sqs_cold_start_queue_url" {
  description = "URL of the cold-start SQS queue (consumed by drain_queue.py on the instance)."
  value       = aws_sqs_queue.cold_start.url
}

output "ddb_state_table" {
  description = "DynamoDB table name holding the singleton gateway state row."
  value       = aws_dynamodb_table.gateway_state.name
}

output "billing_sns_topic_arn" {
  description = "SNS topic for the CloudWatch billing alarm. After first apply, confirm the subscription email."
  value       = aws_sns_topic.billing_alerts.arn
}
