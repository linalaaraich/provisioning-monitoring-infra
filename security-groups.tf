# =============================================================================
# Security Groups — shell resources (no inline rules)
# Rules defined below as aws_vpc_security_group_{ingress,egress}_rule resources
# per HashiCorp best practice.
# =============================================================================

# -----------------------------------------------------------------------------
# sg-monitoring — Prometheus, Grafana, Loki, Jaeger, OTel Collector
# -----------------------------------------------------------------------------
resource "aws_security_group" "monitoring" {
  name_prefix = "${var.project_name}-monitoring-"
  description = "Monitoring stack: Prometheus, Grafana, Loki, Jaeger, OTel Collector"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-sg-monitoring" }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# sg-backend — Spring Boot API
# -----------------------------------------------------------------------------
resource "aws_security_group" "backend" {
  name_prefix = "${var.project_name}-backend-"
  description = "Backend: Spring Boot API"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-sg-backend" }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# sg-network — Kong API Gateway
# -----------------------------------------------------------------------------
resource "aws_security_group" "network" {
  name_prefix = "${var.project_name}-network-"
  description = "Network: Kong API Gateway"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-sg-network" }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# sg-ai — Ollama, Triage Service, MCP Servers
# -----------------------------------------------------------------------------
resource "aws_security_group" "ai" {
  name_prefix = "${var.project_name}-ai-"
  description = "AI/LLM: Ollama, Triage Service, MCP Servers"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-sg-ai" }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# sg-rds — MySQL (backend access only)
# -----------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  description = "RDS MySQL: backend access only"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-sg-rds" }

  lifecycle {
    create_before_destroy = true
  }
}


# =============================================================================
# Ingress Rules — Monitoring SG
# =============================================================================

resource "aws_vpc_security_group_ingress_rule" "monitoring_ssh" {
  for_each = toset(var.allowed_ssh_cidrs)

  security_group_id = aws_security_group.monitoring.id
  description       = "SSH"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value

  tags = { Name = "${var.project_name}-monitoring-ssh" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_prometheus" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Prometheus"
  from_port         = 9090
  to_port           = 9090
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-monitoring-prometheus" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_grafana" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Grafana"
  from_port         = 3000
  to_port           = 3000
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-monitoring-grafana" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_loki" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Loki"
  from_port         = 3100
  to_port           = 3100
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-monitoring-loki" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_jaeger_ui" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Jaeger UI"
  from_port         = 16686
  to_port           = 16686
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-monitoring-jaeger-ui" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_jaeger_otlp_grpc" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Jaeger OTLP gRPC (remapped)"
  from_port         = 4327
  to_port           = 4327
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-monitoring-jaeger-otlp-grpc" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_jaeger_otlp_http" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Jaeger OTLP HTTP (remapped)"
  from_port         = 4328
  to_port           = 4328
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-monitoring-jaeger-otlp-http" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_otel_grpc" {
  security_group_id = aws_security_group.monitoring.id
  description       = "OTel Collector gRPC"
  from_port         = 4317
  to_port           = 4317
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-monitoring-otel-grpc" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_otel_http" {
  security_group_id = aws_security_group.monitoring.id
  description       = "OTel Collector HTTP"
  from_port         = 4318
  to_port           = 4318
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-monitoring-otel-http" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_otel_metrics" {
  security_group_id = aws_security_group.monitoring.id
  description       = "OTel Collector metrics"
  from_port         = 8888
  to_port           = 8888
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-monitoring-otel-metrics" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_node_exporter" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Node Exporter"
  from_port         = 9100
  to_port           = 9100
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-monitoring-node-exporter" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_cadvisor" {
  security_group_id = aws_security_group.monitoring.id
  description       = "cAdvisor"
  from_port         = 8081
  to_port           = 8081
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-monitoring-cadvisor" }
}


# =============================================================================
# Ingress Rules — Backend SG
# =============================================================================

resource "aws_vpc_security_group_ingress_rule" "backend_ssh" {
  for_each = toset(var.allowed_ssh_cidrs)

  security_group_id = aws_security_group.backend.id
  description       = "SSH"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value

  tags = { Name = "${var.project_name}-backend-ssh" }
}

resource "aws_vpc_security_group_ingress_rule" "backend_http_from_kong" {
  security_group_id            = aws_security_group.backend.id
  description                  = "HTTP from Kong"
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.network.id

  tags = { Name = "${var.project_name}-backend-http-from-kong" }
}

resource "aws_vpc_security_group_ingress_rule" "backend_spring_direct" {
  security_group_id = aws_security_group.backend.id
  description       = "Spring Boot direct (health checks)"
  from_port         = 8080
  to_port           = 8080
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-backend-spring-direct" }
}

resource "aws_vpc_security_group_ingress_rule" "backend_node_exporter" {
  security_group_id            = aws_security_group.backend.id
  description                  = "Node Exporter (Prometheus scrape)"
  from_port                    = 9100
  to_port                      = 9100
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id

  tags = { Name = "${var.project_name}-backend-node-exporter" }
}

resource "aws_vpc_security_group_ingress_rule" "backend_cadvisor" {
  security_group_id            = aws_security_group.backend.id
  description                  = "cAdvisor (Prometheus scrape)"
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id

  tags = { Name = "${var.project_name}-backend-cadvisor" }
}

resource "aws_vpc_security_group_ingress_rule" "backend_otel_grpc" {
  security_group_id = aws_security_group.backend.id
  description       = "OTel Collector gRPC"
  from_port         = 4317
  to_port           = 4317
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-backend-otel-grpc" }
}

resource "aws_vpc_security_group_ingress_rule" "backend_otel_http" {
  security_group_id = aws_security_group.backend.id
  description       = "OTel Collector HTTP"
  from_port         = 4318
  to_port           = 4318
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-backend-otel-http" }
}


# =============================================================================
# Ingress Rules — Network SG
# =============================================================================

resource "aws_vpc_security_group_ingress_rule" "network_ssh" {
  for_each = toset(var.allowed_ssh_cidrs)

  security_group_id = aws_security_group.network.id
  description       = "SSH"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value

  tags = { Name = "${var.project_name}-network-ssh" }
}

resource "aws_vpc_security_group_ingress_rule" "network_kong_proxy" {
  security_group_id = aws_security_group.network.id
  description       = "Kong Proxy"
  from_port         = 8000
  to_port           = 8000
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-network-kong-proxy" }
}

resource "aws_vpc_security_group_ingress_rule" "network_kong_admin" {
  security_group_id = aws_security_group.network.id
  description       = "Kong Admin"
  from_port         = 8001
  to_port           = 8001
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-network-kong-admin" }
}

resource "aws_vpc_security_group_ingress_rule" "network_node_exporter" {
  security_group_id            = aws_security_group.network.id
  description                  = "Node Exporter (Prometheus scrape)"
  from_port                    = 9100
  to_port                      = 9100
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id

  tags = { Name = "${var.project_name}-network-node-exporter" }
}

resource "aws_vpc_security_group_ingress_rule" "network_cadvisor" {
  security_group_id            = aws_security_group.network.id
  description                  = "cAdvisor (Prometheus scrape)"
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id

  tags = { Name = "${var.project_name}-network-cadvisor" }
}

resource "aws_vpc_security_group_ingress_rule" "network_otel_grpc" {
  security_group_id = aws_security_group.network.id
  description       = "OTel Collector gRPC"
  from_port         = 4317
  to_port           = 4317
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-network-otel-grpc" }
}

resource "aws_vpc_security_group_ingress_rule" "network_otel_http" {
  security_group_id = aws_security_group.network.id
  description       = "OTel Collector HTTP"
  from_port         = 4318
  to_port           = 4318
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-network-otel-http" }
}


# =============================================================================
# Ingress Rules — AI SG
# =============================================================================

resource "aws_vpc_security_group_ingress_rule" "ai_ssh" {
  for_each = toset(var.allowed_ssh_cidrs)

  security_group_id = aws_security_group.ai.id
  description       = "SSH"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value

  tags = { Name = "${var.project_name}-ai-ssh" }
}

resource "aws_vpc_security_group_ingress_rule" "ai_triage_webhook" {
  security_group_id            = aws_security_group.ai.id
  description                  = "Triage Service webhook (from Grafana)"
  from_port                    = 8090
  to_port                      = 8090
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id

  tags = { Name = "${var.project_name}-ai-triage-webhook" }
}

resource "aws_vpc_security_group_ingress_rule" "ai_ollama" {
  security_group_id = aws_security_group.ai.id
  description       = "Ollama API (internal)"
  from_port         = 11434
  to_port           = 11434
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-ai-ollama" }
}

resource "aws_vpc_security_group_ingress_rule" "ai_node_exporter" {
  security_group_id            = aws_security_group.ai.id
  description                  = "Node Exporter (Prometheus scrape)"
  from_port                    = 9100
  to_port                      = 9100
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id

  tags = { Name = "${var.project_name}-ai-node-exporter" }
}

resource "aws_vpc_security_group_ingress_rule" "ai_cadvisor" {
  security_group_id            = aws_security_group.ai.id
  description                  = "cAdvisor (Prometheus scrape)"
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id

  tags = { Name = "${var.project_name}-ai-cadvisor" }
}

resource "aws_vpc_security_group_ingress_rule" "ai_otel_grpc" {
  security_group_id = aws_security_group.ai.id
  description       = "OTel Collector gRPC"
  from_port         = 4317
  to_port           = 4317
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-ai-otel-grpc" }
}

resource "aws_vpc_security_group_ingress_rule" "ai_otel_http" {
  security_group_id = aws_security_group.ai.id
  description       = "OTel Collector HTTP"
  from_port         = 4318
  to_port           = 4318
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-ai-otel-http" }
}


# =============================================================================
# Ingress Rules — RDS SG
# =============================================================================

resource "aws_vpc_security_group_ingress_rule" "rds_mysql_from_backend" {
  security_group_id            = aws_security_group.rds.id
  description                  = "MySQL from backend"
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.backend.id

  tags = { Name = "${var.project_name}-rds-mysql-from-backend" }
}


# =============================================================================
# Egress Rules — All SGs allow all outbound
# =============================================================================

resource "aws_vpc_security_group_egress_rule" "monitoring_all_outbound" {
  security_group_id = aws_security_group.monitoring.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "${var.project_name}-monitoring-egress-all" }
}

resource "aws_vpc_security_group_egress_rule" "backend_all_outbound" {
  security_group_id = aws_security_group.backend.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "${var.project_name}-backend-egress-all" }
}

resource "aws_vpc_security_group_egress_rule" "network_all_outbound" {
  security_group_id = aws_security_group.network.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "${var.project_name}-network-egress-all" }
}

resource "aws_vpc_security_group_egress_rule" "ai_all_outbound" {
  security_group_id = aws_security_group.ai.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "${var.project_name}-ai-egress-all" }
}

resource "aws_vpc_security_group_egress_rule" "rds_all_outbound" {
  security_group_id = aws_security_group.rds.id
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "${var.project_name}-rds-egress-all" }
}
