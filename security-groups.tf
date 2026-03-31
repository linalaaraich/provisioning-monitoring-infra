# -----------------------------------------------------------------------------
# sg-monitoring — Prometheus, Grafana, Loki, Jaeger, OTel Collector
# -----------------------------------------------------------------------------
resource "aws_security_group" "monitoring" {
  name_prefix = "${var.project_name}-monitoring-"
  description = "Monitoring stack: Prometheus, Grafana, Loki, Jaeger, OTel Collector"
  vpc_id      = aws_vpc.main.id

  # SSH
  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # Prometheus
  ingress {
    description = "Prometheus"
    from_port   = 9090
    to_port     = 9090
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  # Grafana
  ingress {
    description = "Grafana"
    from_port   = 3000
    to_port     = 3000
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  # Loki
  ingress {
    description = "Loki"
    from_port   = 3100
    to_port     = 3100
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  # Jaeger UI
  ingress {
    description = "Jaeger UI"
    from_port   = 16686
    to_port     = 16686
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  # Jaeger OTLP (remapped host ports)
  ingress {
    description = "Jaeger OTLP gRPC"
    from_port   = 4327
    to_port     = 4327
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  ingress {
    description = "Jaeger OTLP HTTP"
    from_port   = 4328
    to_port     = 4328
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  # OTel Collector
  ingress {
    description = "OTel Collector gRPC"
    from_port   = 4317
    to_port     = 4317
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  ingress {
    description = "OTel Collector HTTP"
    from_port   = 4318
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  ingress {
    description = "OTel Collector metrics"
    from_port   = 8888
    to_port     = 8888
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  # Node Exporter + cAdvisor (self-scrape)
  ingress {
    description = "Node Exporter"
    from_port   = 9100
    to_port     = 9100
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  ingress {
    description = "cAdvisor"
    from_port   = 8081
    to_port     = 8081
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # HTTP from Kong (network VM)
  ingress {
    description     = "HTTP from Kong"
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.network.id]
  }

  # Spring Boot direct (for health checks from monitoring)
  ingress {
    description     = "Spring Boot direct"
    from_port       = 8080
    to_port         = 8080
    protocol        = "tcp"
    cidr_blocks     = [var.private_subnet_cidr]
  }

  # Node Exporter (scraped by Prometheus)
  ingress {
    description     = "Node Exporter"
    from_port       = 9100
    to_port         = 9100
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  # cAdvisor
  ingress {
    description     = "cAdvisor"
    from_port       = 8081
    to_port         = 8081
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  # OTel Collector ports (for trace/log shipping)
  ingress {
    description = "OTel Collector gRPC"
    from_port   = 4317
    to_port     = 4317
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  ingress {
    description = "OTel Collector HTTP"
    from_port   = 4318
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # Kong Proxy
  ingress {
    description = "Kong Proxy"
    from_port   = 8000
    to_port     = 8000
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  # Kong Admin
  ingress {
    description = "Kong Admin"
    from_port   = 8001
    to_port     = 8001
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  # Node Exporter
  ingress {
    description     = "Node Exporter"
    from_port       = 9100
    to_port         = 9100
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  # cAdvisor
  ingress {
    description     = "cAdvisor"
    from_port       = 8081
    to_port         = 8081
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  # OTel Collector ports
  ingress {
    description = "OTel Collector gRPC"
    from_port   = 4317
    to_port     = 4317
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  ingress {
    description = "OTel Collector HTTP"
    from_port   = 4318
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.allowed_ssh_cidrs
  }

  # Triage Service webhook (from Grafana on monitoring VM)
  ingress {
    description     = "Triage Service webhook"
    from_port       = 8090
    to_port         = 8090
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  # Ollama API (internal access)
  ingress {
    description = "Ollama API"
    from_port   = 11434
    to_port     = 11434
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  # Node Exporter
  ingress {
    description     = "Node Exporter"
    from_port       = 9100
    to_port         = 9100
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  # cAdvisor
  ingress {
    description     = "cAdvisor"
    from_port       = 8081
    to_port         = 8081
    protocol        = "tcp"
    security_groups = [aws_security_group.monitoring.id]
  }

  # OTel Collector ports
  ingress {
    description = "OTel Collector gRPC"
    from_port   = 4317
    to_port     = 4317
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  ingress {
    description = "OTel Collector HTTP"
    from_port   = 4318
    to_port     = 4318
    protocol    = "tcp"
    cidr_blocks = [var.private_subnet_cidr]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

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

  ingress {
    description     = "MySQL from backend"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.backend.id]
  }

  egress {
    description = "All outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project_name}-sg-rds" }

  lifecycle {
    create_before_destroy = true
  }
}
