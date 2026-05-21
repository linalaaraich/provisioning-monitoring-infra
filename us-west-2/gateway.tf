# =============================================================================
# Lambda autoshutoff gateway (Phase 3 of the GPU migration).
#
# Fronts the g5.xlarge defined in main.tf with:
#   - API Gateway HTTP API  (Grafana webhook entry point)
#   - Lambda triage-gateway-router       (in VPC, forwards or queues+starts)
#   - Lambda triage-idle-checker         (out of VPC, EventBridge cron)
#   - SQS triage-cold-start-queue        (buffers webhooks during boot)
#   - DDB triage-gateway-state           (singleton row, lock + traffic stamp)
#   - VPC interface endpoints for ec2 / sqs / dynamodb (no NAT egress needed
#     for AWS-API traffic from the in-VPC router Lambda)
#   - CloudWatch billing alarm + SNS email subscription
#
# Contract with main.tf (resolved against the sibling-agent's actual names):
#   - aws_instance.gpu        — the g5.xlarge
#   - aws_subnet.private      — Lambda + interface endpoints land here
#   - aws_vpc.main            — owns both
#   - aws_security_group.gpu  — already has a VPC-CIDR :8090 ingress rule
#                               (see main.tf "fastapi_intra_vpc"), so no extra
#                               cross-SG rule is needed from this file.
# =============================================================================

locals {
  # ---- contract with main.tf ------------------------------------------------
  gpu_instance_id    = aws_instance.gpu.id
  gpu_private_ip     = aws_instance.gpu.private_ip
  gpu_vpc_id         = aws_vpc.main.id
  gpu_private_subnet = aws_subnet.private.id
  gpu_instance_sg_id = aws_security_group.gpu.id
  # ---------------------------------------------------------------------------

  ddb_table_name = "triage-gateway-state"
  sqs_queue_name = "triage-cold-start-queue"
}

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}

# -----------------------------------------------------------------------------
# DynamoDB — singleton state row (id="singleton")
# -----------------------------------------------------------------------------
resource "aws_dynamodb_table" "gateway_state" {
  name         = local.ddb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  point_in_time_recovery {
    enabled = false # singleton row, no recovery story needed
  }

  tags = { Name = local.ddb_table_name }
}

# -----------------------------------------------------------------------------
# SQS — cold-start buffer. 1h retention because Grafana retries on its own
# after that; anything older is staler than the live alarm itself.
# Visibility timeout 90s = enough headroom for the instance to boot + the
# triage service to accept the replay.
# -----------------------------------------------------------------------------
resource "aws_sqs_queue" "cold_start" {
  name                       = local.sqs_queue_name
  visibility_timeout_seconds = 90
  message_retention_seconds  = 3600
  receive_wait_time_seconds  = 20 # default long-poll for drain_queue.py

  tags = { Name = local.sqs_queue_name }
}

# -----------------------------------------------------------------------------
# Security group for the in-VPC router Lambda.
# Outbound only — nothing reaches the Lambda inbound.
# Used as the SOURCE on the ingress rule we add to gpu_triage SG below.
# -----------------------------------------------------------------------------
resource "aws_security_group" "triage_lambda" {
  name        = "triage-lambda-sg"
  description = "Egress-only SG for triage-gateway-router Lambda"
  vpc_id      = local.gpu_vpc_id

  tags = { Name = "triage-lambda-sg" }
}

resource "aws_vpc_security_group_egress_rule" "triage_lambda_all" {
  security_group_id = aws_security_group.triage_lambda.id
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"
  description       = "Outbound to instance + interface endpoints"
}

# NOTE: main.tf's aws_vpc_security_group_ingress_rule.fastapi_intra_vpc already
# opens :8090 to the entire VPC CIDR, which covers Lambda traffic from the
# private subnet. No extra cross-SG ingress rule needed here. If the sibling
# tightens that rule to be SG-scoped, uncomment the block below:
#
# resource "aws_vpc_security_group_ingress_rule" "instance_from_lambda" {
#   security_group_id            = local.gpu_instance_sg_id
#   referenced_security_group_id = aws_security_group.triage_lambda.id
#   ip_protocol                  = "tcp"
#   from_port                    = 8090
#   to_port                      = 8090
#   description                  = "Triage webhook from Lambda gateway"
# }

# -----------------------------------------------------------------------------
# VPC interface endpoints — required because the router Lambda runs in a
# private subnet with no NAT path. (us-east-1 has a NAT GW; us-west-2 does
# not, to save ~$32/mo — interface endpoints are ~$7/mo each.)
# -----------------------------------------------------------------------------
resource "aws_security_group" "vpc_endpoints" {
  name        = "triage-vpce-sg"
  description = "Allow HTTPS from triage-lambda-sg to VPC interface endpoints"
  vpc_id      = local.gpu_vpc_id

  tags = { Name = "triage-vpce-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "vpce_https_from_lambda" {
  security_group_id            = aws_security_group.vpc_endpoints.id
  referenced_security_group_id = aws_security_group.triage_lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
  description                  = "HTTPS to AWS API endpoints"
}

resource "aws_vpc_endpoint" "ec2" {
  vpc_id              = local.gpu_vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.ec2"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [local.gpu_private_subnet]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "triage-vpce-ec2" }
}

resource "aws_vpc_endpoint" "sqs" {
  vpc_id              = local.gpu_vpc_id
  service_name        = "com.amazonaws.${data.aws_region.current.name}.sqs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [local.gpu_private_subnet]
  security_group_ids  = [aws_security_group.vpc_endpoints.id]
  private_dns_enabled = true

  tags = { Name = "triage-vpce-sqs" }
}

# DynamoDB has both gateway and interface endpoint variants. We pick the
# Gateway variant: it's free (vs ~$7/mo for the interface), and DynamoDB's
# interface endpoint refuses private DNS so the Lambda would have to use a
# non-default endpoint URL anyway. Gateway attaches to the route table so
# anything in the private subnet hits DDB over private routing transparently.
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = local.gpu_vpc_id
  service_name      = "com.amazonaws.${data.aws_region.current.name}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]

  tags = { Name = "triage-vpce-dynamodb" }
}

# -----------------------------------------------------------------------------
# IAM — separate roles per Lambda so the blast radius of each policy is
# the lambda that needs it. (Idle checker should never be able to SendMessage,
# router should never be able to StopInstances.)
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ---- router role ------------------------------------------------------------
resource "aws_iam_role" "router" {
  name               = "triage-gateway-router-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "router_inline" {
  statement {
    sid       = "EC2DescribeAndStart"
    actions   = ["ec2:DescribeInstances", "ec2:StartInstances"]
    resources = ["*"] # DescribeInstances is wildcard-only; StartInstances we tighten in a Condition
  }
  statement {
    sid       = "SQSWrite"
    actions   = ["sqs:SendMessage", "sqs:GetQueueAttributes"]
    resources = [aws_sqs_queue.cold_start.arn]
  }
  statement {
    sid     = "DDBStateRW"
    actions = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
    resources = [
      aws_dynamodb_table.gateway_state.arn,
    ]
  }
  statement {
    sid     = "VPCNetworking"
    actions = ["ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DeleteNetworkInterface"]
    # Lambda VPC attachment requires these — AWS-managed, can't be scoped.
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "router_inline" {
  name   = "triage-gateway-router-inline"
  role   = aws_iam_role.router.id
  policy = data.aws_iam_policy_document.router_inline.json
}

resource "aws_iam_role_policy_attachment" "router_logs" {
  role       = aws_iam_role.router.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ---- idle-checker role ------------------------------------------------------
resource "aws_iam_role" "idle_checker" {
  name               = "triage-idle-checker-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
}

data "aws_iam_policy_document" "idle_checker_inline" {
  statement {
    sid       = "EC2DescribeAndStop"
    actions   = ["ec2:DescribeInstances", "ec2:StopInstances"]
    resources = ["*"]
  }
  statement {
    sid       = "DDBStateRead"
    actions   = ["dynamodb:GetItem", "dynamodb:UpdateItem"]
    resources = [aws_dynamodb_table.gateway_state.arn]
  }
}

resource "aws_iam_role_policy" "idle_checker_inline" {
  name   = "triage-idle-checker-inline"
  role   = aws_iam_role.idle_checker.id
  policy = data.aws_iam_policy_document.idle_checker_inline.json
}

resource "aws_iam_role_policy_attachment" "idle_checker_logs" {
  role       = aws_iam_role.idle_checker.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# -----------------------------------------------------------------------------
# Lambda code archive — single zip, two entry points.
# -----------------------------------------------------------------------------
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/handler.py"
  output_path = "${path.module}/lambda/handler.zip"
}

# -----------------------------------------------------------------------------
# CloudWatch log groups (created explicitly so retention is enforced from
# day 1 — otherwise Lambda auto-creates with "never expire").
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "router" {
  name              = "/aws/lambda/triage-gateway-router"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "idle_checker" {
  name              = "/aws/lambda/triage-idle-checker"
  retention_in_days = 14
}

# -----------------------------------------------------------------------------
# Lambda: triage-gateway-router (in VPC)
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "router" {
  function_name    = "triage-gateway-router"
  role             = aws_iam_role.router.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler_router"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  memory_size      = 256
  timeout          = 30

  vpc_config {
    subnet_ids         = [local.gpu_private_subnet]
    security_group_ids = [aws_security_group.triage_lambda.id]
  }

  environment {
    variables = {
      INSTANCE_ID         = local.gpu_instance_id
      INSTANCE_PRIVATE_IP = local.gpu_private_ip
      SQS_QUEUE_URL       = aws_sqs_queue.cold_start.url
      DDB_TABLE           = aws_dynamodb_table.gateway_state.name
      IDLE_THRESHOLD_MIN  = tostring(var.idle_threshold_min)
      ALLOWED_SOURCE_IPS  = join(",", var.allowed_webhook_source_ips)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.router,
    aws_vpc_endpoint.ec2,
    aws_vpc_endpoint.sqs,
    aws_vpc_endpoint.dynamodb,
  ]

  tags = { Name = "triage-gateway-router" }
}

# -----------------------------------------------------------------------------
# Lambda: triage-idle-checker (NOT in VPC — only needs EC2 + DDB public APIs)
# -----------------------------------------------------------------------------
resource "aws_lambda_function" "idle_checker" {
  function_name    = "triage-idle-checker"
  role             = aws_iam_role.idle_checker.arn
  runtime          = "python3.12"
  handler          = "handler.lambda_handler_idle_check"
  filename         = data.archive_file.lambda_zip.output_path
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  memory_size      = 128
  timeout          = 15

  environment {
    variables = {
      # Reuses the same handler.py, so it needs the same env contract even
      # though it doesn't actually use SQS_QUEUE_URL / INSTANCE_PRIVATE_IP.
      INSTANCE_ID         = local.gpu_instance_id
      INSTANCE_PRIVATE_IP = local.gpu_private_ip
      SQS_QUEUE_URL       = aws_sqs_queue.cold_start.url
      DDB_TABLE           = aws_dynamodb_table.gateway_state.name
      IDLE_THRESHOLD_MIN  = tostring(var.idle_threshold_min)
    }
  }

  depends_on = [aws_cloudwatch_log_group.idle_checker]

  tags = { Name = "triage-idle-checker" }
}

# -----------------------------------------------------------------------------
# EventBridge — rate(5 minutes) -> idle checker
# -----------------------------------------------------------------------------
resource "aws_cloudwatch_event_rule" "idle_check" {
  name                = "triage-idle-check"
  description         = "Fires the triage-idle-checker every 5 min"
  schedule_expression = "rate(5 minutes)"
}

resource "aws_cloudwatch_event_target" "idle_check" {
  rule      = aws_cloudwatch_event_rule.idle_check.name
  target_id = "triage-idle-checker"
  arn       = aws_lambda_function.idle_checker.arn
}

resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.idle_checker.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.idle_check.arn
}

# -----------------------------------------------------------------------------
# API Gateway HTTP API — cheaper than REST API, simpler integration story.
# -----------------------------------------------------------------------------
resource "aws_apigatewayv2_api" "gateway" {
  name          = "triage-gateway"
  protocol_type = "HTTP"
  description   = "Grafana -> Lambda router for the GPU triage service"
}

resource "aws_apigatewayv2_integration" "router" {
  api_id                 = aws_apigatewayv2_api.gateway.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.router.invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000 # API GW max is 30s; router Lambda is 30s
}

resource "aws_apigatewayv2_route" "webhook" {
  api_id    = aws_apigatewayv2_api.gateway.id
  route_key = "POST /webhook/grafana"
  target    = "integrations/${aws_apigatewayv2_integration.router.id}"
}

resource "aws_apigatewayv2_route" "proxy" {
  api_id    = aws_apigatewayv2_api.gateway.id
  route_key = "ANY /{proxy+}"
  target    = "integrations/${aws_apigatewayv2_integration.router.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.gateway.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "allow_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.router.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.gateway.execution_arn}/*/*"
}

# -----------------------------------------------------------------------------
# Billing alarm — SNS topic + email subscription + the alarm itself.
# AWS billing metrics (AWS/Billing namespace) are published ONLY in us-east-1,
# so all three resources use the `aws.us_east_1` aliased provider declared in
# provider.tf. The SNS topic and email subscription live in us-east-1 too so
# the alarm action ARN stays in the same region as the metric.
# -----------------------------------------------------------------------------
resource "aws_sns_topic" "billing_alerts" {
  provider = aws.us_east_1
  name     = "triage-billing-alerts"
}

resource "aws_sns_topic_subscription" "billing_email" {
  provider  = aws.us_east_1
  topic_arn = aws_sns_topic.billing_alerts.arn
  protocol  = "email"
  endpoint  = var.alarm_email_to
}

resource "aws_cloudwatch_metric_alarm" "billing" {
  provider            = aws.us_east_1
  alarm_name          = "triage-monthly-spend-over-${var.billing_alert_threshold_usd}usd"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "EstimatedCharges"
  namespace           = "AWS/Billing"
  period              = 21600 # 6h — billing metrics only update every ~6h
  statistic           = "Maximum"
  threshold           = var.billing_alert_threshold_usd
  alarm_description   = "Month-to-date estimated AWS spend exceeded ${var.billing_alert_threshold_usd} USD"
  alarm_actions       = [aws_sns_topic.billing_alerts.arn]

  dimensions = {
    Currency = "USD"
  }
}
