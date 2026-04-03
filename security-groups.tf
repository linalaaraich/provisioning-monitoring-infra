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
# Shared ingress rules — SSH, OTel, Node Exporter, cAdvisor
# These patterns repeat across all (or most) non-RDS security groups.
# =============================================================================

locals {
  # All non-RDS SGs that need SSH, OTel, and infrastructure rules
  vm_security_groups = {
    monitoring = aws_security_group.monitoring.id
    backend    = aws_security_group.backend.id
    network    = aws_security_group.network.id
    ai         = aws_security_group.ai.id
  }

  # SSH: one rule per (SG × CIDR) combination
  ssh_rules = merge([
    for sg_name, sg_id in local.vm_security_groups : {
      for cidr in var.allowed_ssh_cidrs :
      "${sg_name}-${cidr}" => {
        sg_id   = sg_id
        sg_name = sg_name
        cidr    = cidr
      }
    }
  ]...)

  # OTel Collector: gRPC (:4317) and HTTP (:4318) on every VM
  otel_rules = merge([
    for sg_name, sg_id in local.vm_security_groups : {
      "${sg_name}-otel-grpc" = { sg_id = sg_id, sg_name = sg_name, port = 4317, desc = "OTel Collector gRPC" }
      "${sg_name}-otel-http" = { sg_id = sg_id, sg_name = sg_name, port = 4318, desc = "OTel Collector HTTP" }
    }
  ]...)

  # Node Exporter (:9100) and cAdvisor (:8081) — scraped by Prometheus (sg-monitoring)
  # backend, network, ai only (monitoring scrapes itself via localhost)
  infra_scrape_sgs = {
    backend = aws_security_group.backend.id
    network = aws_security_group.network.id
    ai      = aws_security_group.ai.id
  }

  infra_scrape_rules = merge([
    for sg_name, sg_id in local.infra_scrape_sgs : {
      "${sg_name}-node-exporter" = { sg_id = sg_id, sg_name = sg_name, port = 9100, desc = "Node Exporter (Prometheus scrape)" }
      "${sg_name}-cadvisor"      = { sg_id = sg_id, sg_name = sg_name, port = 8081, desc = "cAdvisor (Prometheus scrape)" }
    }
  ]...)
}

# --- SSH (all 4 VMs × each CIDR) ---
resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = local.ssh_rules

  security_group_id = each.value.sg_id
  description       = "SSH"
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value.cidr

  tags = { Name = "${var.project_name}-${each.value.sg_name}-ssh" }
}

# --- OTel Collector (all 4 VMs × 2 ports) ---
resource "aws_vpc_security_group_ingress_rule" "otel" {
  for_each = local.otel_rules

  security_group_id = each.value.sg_id
  description       = each.value.desc
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
  cidr_ipv4         = var.private_subnet_cidr

  tags = { Name = "${var.project_name}-${each.key}" }
}

# --- Node Exporter + cAdvisor (backend, network, ai — from sg-monitoring) ---
resource "aws_vpc_security_group_ingress_rule" "infra_scrape" {
  for_each = local.infra_scrape_rules

  security_group_id            = each.value.sg_id
  description                  = each.value.desc
  from_port                    = each.value.port
  to_port                      = each.value.port
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id

  tags = { Name = "${var.project_name}-${each.key}" }
}


# =============================================================================
# Ingress Rules — Monitoring SG (service-specific, unique ports)
# =============================================================================

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
# Ingress Rules — Backend SG (service-specific)
# =============================================================================

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


# =============================================================================
# Ingress Rules — Network SG (service-specific)
# =============================================================================

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


# =============================================================================
# Ingress Rules — AI SG (service-specific)
# =============================================================================

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

resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  for_each = {
    monitoring = aws_security_group.monitoring.id
    backend    = aws_security_group.backend.id
    network    = aws_security_group.network.id
    ai         = aws_security_group.ai.id
    rds        = aws_security_group.rds.id
  }

  security_group_id = each.value
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "${var.project_name}-${each.key}-egress-all" }
}
