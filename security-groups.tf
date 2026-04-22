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
# sg-k3s — k3s cluster (Spring Boot, Kong, Triage, MCP Servers)
# -----------------------------------------------------------------------------
resource "aws_security_group" "k3s" {
  name_prefix = "${var.project_name}-k3s-"
  description = "k3s cluster: Spring Boot, Kong, Triage, MCP Servers"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-sg-k3s" }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# sg-gpu — Ollama (GPU node)
# -----------------------------------------------------------------------------
resource "aws_security_group" "gpu" {
  name_prefix = "${var.project_name}-gpu-"
  description = "GPU: Ollama LLM inference"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.project_name}-sg-gpu" }

  lifecycle {
    create_before_destroy = true
  }
}

# -----------------------------------------------------------------------------
# sg-rds — MySQL (k3s access only)
# -----------------------------------------------------------------------------
resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  description = "RDS MySQL: k3s access only"
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
  # All non-RDS SGs that need SSH and common rules
  vm_security_groups = {
    monitoring = aws_security_group.monitoring.id
    k3s        = aws_security_group.k3s.id
    gpu        = aws_security_group.gpu.id
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
  # gpu only (k3s pods are scraped via kubernetes_sd_configs, monitoring scrapes itself)
  infra_scrape_sgs = {
    gpu = aws_security_group.gpu.id
  }

  infra_scrape_rules = merge([
    for sg_name, sg_id in local.infra_scrape_sgs : {
      "${sg_name}-node-exporter" = { sg_id = sg_id, sg_name = sg_name, port = 9100, desc = "Node Exporter (Prometheus scrape)" }
      "${sg_name}-cadvisor"      = { sg_id = sg_id, sg_name = sg_name, port = 8081, desc = "cAdvisor (Prometheus scrape)" }
    }
  ]...)
}

# --- SSH (all VMs × each CIDR) ---
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

# --- OTel Collector (all VMs × 2 ports) ---
resource "aws_vpc_security_group_ingress_rule" "otel" {
  for_each = local.otel_rules

  security_group_id = each.value.sg_id
  description       = each.value.desc
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-${each.key}" }
}

# --- Node Exporter + cAdvisor (gpu — from sg-monitoring) ---
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
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-monitoring-prometheus" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_grafana" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Grafana"
  from_port         = 3000
  to_port           = 3000
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-monitoring-grafana" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_loki" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Loki"
  from_port         = 3100
  to_port           = 3100
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-monitoring-loki" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_jaeger_ui" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Jaeger UI"
  from_port         = 16686
  to_port           = 16686
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-monitoring-jaeger-ui" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_jaeger_otlp_grpc" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Jaeger OTLP gRPC (remapped)"
  from_port         = 4327
  to_port           = 4327
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-monitoring-jaeger-otlp-grpc" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_jaeger_otlp_http" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Jaeger OTLP HTTP (remapped)"
  from_port         = 4328
  to_port           = 4328
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-monitoring-jaeger-otlp-http" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_otel_metrics" {
  security_group_id = aws_security_group.monitoring.id
  description       = "OTel Collector metrics"
  from_port         = 8888
  to_port           = 8888
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-monitoring-otel-metrics" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_node_exporter" {
  security_group_id = aws_security_group.monitoring.id
  description       = "Node Exporter"
  from_port         = 9100
  to_port           = 9100
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-monitoring-node-exporter" }
}

resource "aws_vpc_security_group_ingress_rule" "monitoring_cadvisor" {
  security_group_id = aws_security_group.monitoring.id
  description       = "cAdvisor"
  from_port         = 8081
  to_port           = 8081
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-monitoring-cadvisor" }
}


# =============================================================================
# Ingress Rules — k3s SG (service-specific)
# =============================================================================

resource "aws_vpc_security_group_ingress_rule" "k3s_api_server" {
  security_group_id            = aws_security_group.k3s.id
  description                  = "K8s API server (Prometheus kubernetes_sd_configs)"
  from_port                    = 6443
  to_port                      = 6443
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id

  tags = { Name = "${var.project_name}-k3s-api-server" }
}

resource "aws_vpc_security_group_ingress_rule" "k3s_kubelet" {
  security_group_id            = aws_security_group.k3s.id
  description                  = "Kubelet metrics (Prometheus scrape)"
  from_port                    = 10250
  to_port                      = 10250
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id

  tags = { Name = "${var.project_name}-k3s-kubelet" }
}

resource "aws_vpc_security_group_ingress_rule" "k3s_nodeport" {
  security_group_id = aws_security_group.k3s.id
  description       = "NodePort range (Kong external access)"
  from_port         = 30000
  to_port           = 32767
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-k3s-nodeport" }
}

resource "aws_vpc_security_group_ingress_rule" "k3s_http" {
  security_group_id = aws_security_group.k3s.id
  description       = "HTTP (Kong hostPort)"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-k3s-http" }
}

resource "aws_vpc_security_group_ingress_rule" "k3s_https" {
  security_group_id = aws_security_group.k3s.id
  description       = "HTTPS (Kong hostPort)"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-k3s-https" }
}

resource "aws_vpc_security_group_ingress_rule" "k3s_otel_grpc_from_monitoring" {
  security_group_id            = aws_security_group.k3s.id
  description                  = "OTel Collector gRPC (traces/logs forwarding)"
  from_port                    = 4317
  to_port                      = 4317
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id

  tags = { Name = "${var.project_name}-k3s-otel-grpc-from-monitoring" }
}

resource "aws_vpc_security_group_ingress_rule" "k3s_otel_http_from_monitoring" {
  security_group_id            = aws_security_group.k3s.id
  description                  = "OTel Collector HTTP (traces/logs forwarding)"
  from_port                    = 4318
  to_port                      = 4318
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id

  tags = { Name = "${var.project_name}-k3s-otel-http-from-monitoring" }
}


# =============================================================================
# Ingress Rules — GPU SG (service-specific)
# =============================================================================

resource "aws_vpc_security_group_ingress_rule" "gpu_ollama" {
  security_group_id = aws_security_group.gpu.id
  description       = "Ollama API (internal)"
  from_port         = 11434
  to_port           = 11434
  ip_protocol       = "tcp"
  cidr_ipv4         = var.vpc_cidr

  tags = { Name = "${var.project_name}-gpu-ollama" }
}

resource "aws_vpc_security_group_ingress_rule" "gpu_triage_webhook" {
  security_group_id            = aws_security_group.gpu.id
  description                  = "Triage Service webhook (from Grafana)"
  from_port                    = 8090
  to_port                      = 8090
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.monitoring.id

  tags = { Name = "${var.project_name}-gpu-triage-webhook" }
}


# =============================================================================
# Ingress Rules — RDS SG
# =============================================================================

resource "aws_vpc_security_group_ingress_rule" "rds_mysql_from_k3s" {
  security_group_id            = aws_security_group.rds.id
  description                  = "MySQL from k3s"
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  referenced_security_group_id = aws_security_group.k3s.id

  tags = { Name = "${var.project_name}-rds-mysql-from-k3s" }
}


# =============================================================================
# Public-browser access to dashboards + Kong NodePort.
# Opens the UI ports to allowed_ssh_cidrs so they're reachable from the
# operator's browser (the same CIDRs already allowed for SSH).
# NOTE: if allowed_ssh_cidrs is 0.0.0.0/0 these UIs are world-readable.
# Fine for a demo; tighten for production by setting a specific /32.
# =============================================================================

locals {
  public_ui_rules = {
    grafana   = { sg_id = aws_security_group.monitoring.id, port = 3000,  desc = "Grafana UI (operator browser)" }
    prom_ui   = { sg_id = aws_security_group.monitoring.id, port = 9090,  desc = "Prometheus UI (operator browser)" }
    loki_api  = { sg_id = aws_security_group.monitoring.id, port = 3100,  desc = "Loki API (operator browser / Grafana Explore)" }
    jaeger_ui = { sg_id = aws_security_group.monitoring.id, port = 16686, desc = "Jaeger UI (operator browser)" }
    kong_np   = { sg_id = aws_security_group.k3s.id,        port = 30080, desc = "Kong NodePort (public app entry)" }
  }

  public_ui_cidr_rules = merge([
    for name, r in local.public_ui_rules : {
      for cidr in var.allowed_ssh_cidrs :
      "${name}-${cidr}" => { name = name, sg_id = r.sg_id, port = r.port, desc = r.desc, cidr = cidr }
    }
  ]...)
}

resource "aws_vpc_security_group_ingress_rule" "public_ui" {
  for_each = local.public_ui_cidr_rules

  security_group_id = each.value.sg_id
  description       = each.value.desc
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
  cidr_ipv4         = each.value.cidr

  tags = { Name = "${var.project_name}-public-${each.key}" }
}


# =============================================================================
# Egress Rules — All SGs allow all outbound
# =============================================================================

resource "aws_vpc_security_group_egress_rule" "all_outbound" {
  for_each = {
    monitoring = aws_security_group.monitoring.id
    k3s        = aws_security_group.k3s.id
    gpu        = aws_security_group.gpu.id
    rds        = aws_security_group.rds.id
  }

  security_group_id = each.value
  description       = "All outbound"
  ip_protocol       = "-1"
  cidr_ipv4         = "0.0.0.0/0"

  tags = { Name = "${var.project_name}-${each.key}-egress-all" }
}
