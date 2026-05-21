# =============================================================================
# us-west-2 GPU estate — observability-rca-gpu (g5.xlarge, A10G)
#
# Layout: one VPC (10.1.0.0/16) with one public + one private subnet, no NAT
# gateway. The GPU instance lives in the public subnet with an Elastic IP for
# stable public DNS. The private subnet is reserved for the Phase 3 Lambda
# gateway (its outbound to SQS / EC2 / DynamoDB will go via VPC interface
# endpoints, NOT a NAT gateway — see plan, "Cost protection" §4).
# =============================================================================

# -----------------------------------------------------------------------------
# Locals
# -----------------------------------------------------------------------------
locals {
  vpc_cidr            = "10.1.0.0/16"
  public_subnet_cidr  = "10.1.1.0/24"
  private_subnet_cidr = "10.1.2.0/24"
  availability_zone   = "us-west-2a"

  instance_name = "observability-rca-gpu"

  # Tags applied on top of the provider default_tags. Provider tags already
  # supply Project / Sprint / ManagedBy; per-resource tags add the Name and
  # any resource-specific labels.
  base_tags = {
    Name = local.instance_name
  }

  # Placeholder SQS queue ARN — the real queue is created by the Phase 3
  # Lambda Terraform. We grant the instance role read+delete on this exact
  # ARN now so Phase 3 can just match the name when it creates the queue.
  cold_start_queue_arn = "arn:aws:sqs:us-west-2:735115318342:triage-cold-start-queue"
}

# -----------------------------------------------------------------------------
# VPC
# -----------------------------------------------------------------------------
resource "aws_vpc" "main" {
  cidr_block           = local.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "observability-rca-gpu-vpc" }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = local.public_subnet_cidr
  availability_zone       = local.availability_zone
  map_public_ip_on_launch = true

  tags = { Name = "observability-rca-gpu-public" }
}

resource "aws_subnet" "private" {
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_subnet_cidr
  availability_zone = local.availability_zone

  tags = { Name = "observability-rca-gpu-private" }
}

# -----------------------------------------------------------------------------
# Internet Gateway — public subnet outbound only. The private subnet has NO
# default route; Phase 3 Lambda will reach AWS APIs via VPC interface endpoints.
# -----------------------------------------------------------------------------
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "observability-rca-gpu-igw" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "observability-rca-gpu-public-rt" }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# Private route table — no default route on purpose (see header comment).
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "observability-rca-gpu-private-rt" }
}

resource "aws_route_table_association" "private" {
  subnet_id      = aws_subnet.private.id
  route_table_id = aws_route_table.private.id
}

# -----------------------------------------------------------------------------
# Security group — GPU host
# -----------------------------------------------------------------------------
resource "aws_security_group" "gpu" {
  name_prefix = "observability-rca-gpu-"
  description = "GPU host: triage stack (FastAPI + 5 MCP + Drain3 + Ollama)"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "observability-rca-sg-gpu" }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  for_each = toset(var.allowed_ssh_cidrs)

  security_group_id = aws_security_group.gpu.id
  description       = "SSH from operator CIDRs (Tailscale is the primary path)"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
}

resource "aws_vpc_security_group_ingress_rule" "fastapi_intra_vpc" {
  security_group_id = aws_security_group.gpu.id
  description       = "FastAPI from inside the VPC - Lambda gateway hits this via private IP"
  cidr_ipv4         = local.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 8090
  to_port           = 8090
}

resource "aws_vpc_security_group_ingress_rule" "tailscale_udp" {
  security_group_id = aws_security_group.gpu.id
  description       = "Tailscale DERP / direct-connection NAT traversal"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "udp"
  from_port         = 41641
  to_port           = 41641
}

resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.gpu.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

# -----------------------------------------------------------------------------
# IAM — instance role + profile
#   - AmazonSSMManagedInstanceCore: session-manager fallback if SSH/Tailscale
#     are both unreachable.
#   - Inline SQS policy on the Phase 3 cold-start queue (placeholder ARN).
# -----------------------------------------------------------------------------
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "gpu" {
  name               = "observability-rca-gpu-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = { Name = "observability-rca-gpu-role" }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.gpu.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "sqs_cold_start" {
  statement {
    sid    = "DrainColdStartQueue"
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]
    resources = [local.cold_start_queue_arn]
  }
}

resource "aws_iam_role_policy" "sqs_cold_start" {
  name   = "sqs-cold-start-drain"
  role   = aws_iam_role.gpu.id
  policy = data.aws_iam_policy_document.sqs_cold_start.json
}

resource "aws_iam_instance_profile" "gpu" {
  name = "observability-rca-gpu-profile"
  role = aws_iam_role.gpu.name
}

# -----------------------------------------------------------------------------
# AMI — AWS Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04)
# Owner 898082745236 is Amazon's official DL AMI publisher in us-west-2.
# most_recent=true so re-applies pick up the latest patched build; the
# instance has ignore_changes=[ami] below so existing hosts aren't replaced.
# -----------------------------------------------------------------------------
data "aws_ami" "dl_base" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["Deep Learning Base OSS Nvidia Driver GPU AMI (Ubuntu 22.04) ????????"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# Elastic IP
# -----------------------------------------------------------------------------
resource "aws_eip" "gpu" {
  domain = "vpc"

  tags = { Name = "observability-rca-gpu-eip" }
}

# -----------------------------------------------------------------------------
# GPU instance — g5.xlarge, 200 GB gp3 root
# -----------------------------------------------------------------------------
resource "aws_instance" "gpu" {
  ami                  = data.aws_ami.dl_base.id
  instance_type        = var.instance_type
  key_name             = var.key_pair_name
  subnet_id            = aws_subnet.public.id
  iam_instance_profile = aws_iam_instance_profile.gpu.name

  vpc_security_group_ids = [aws_security_group.gpu.id]

  user_data = templatefile("${path.module}/userdata.sh.tpl", {
    tailscale_auth_key = var.tailscale_auth_key
    tailscale_hostname = "observability-gpu-uswest2"
  })

  root_block_device {
    volume_size = 200
    volume_type = "gp3"
    encrypted   = true
  }

  # user_data only runs on first boot; ami changes would replace the host.
  # Both are ignored so day-2 re-applies don't blow away a warm instance.
  lifecycle {
    ignore_changes = [user_data, ami]
  }

  tags = {
    Name      = local.instance_name
    Project   = "cires-observability"
    Sprint    = "Sprint-4"
    ManagedBy = "Terraform"
  }
}

resource "aws_eip_association" "gpu" {
  instance_id   = aws_instance.gpu.id
  allocation_id = aws_eip.gpu.id
}
