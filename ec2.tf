# -----------------------------------------------------------------------------
# Ubuntu 22.04 AMI (latest)
# -----------------------------------------------------------------------------
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# -----------------------------------------------------------------------------
# User data: create deploy user, add SSH key, install Python3
# -----------------------------------------------------------------------------
locals {
  user_data = <<-EOF
    #!/bin/bash
    set -e

    # Create deploy user with passwordless sudo
    useradd -m -s /bin/bash -G sudo deploy
    echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy
    chmod 0440 /etc/sudoers.d/deploy

    # Set up SSH for deploy user
    mkdir -p /home/deploy/.ssh
    cp /home/ubuntu/.ssh/authorized_keys /home/deploy/.ssh/authorized_keys
    chown -R deploy:deploy /home/deploy/.ssh
    chmod 700 /home/deploy/.ssh
    chmod 600 /home/deploy/.ssh/authorized_keys

    # Install Python3 (required by Ansible)
    apt-get update -y
    apt-get install -y python3 python3-apt
  EOF
}

# -----------------------------------------------------------------------------
# Elastic IPs (1 per EC2, for stable addressing)
# -----------------------------------------------------------------------------
resource "aws_eip" "monitoring" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-monitoring-eip" }
}

resource "aws_eip" "backend" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-backend-eip" }
}

resource "aws_eip" "network" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-network-eip" }
}

resource "aws_eip" "ai" {
  domain = "vpc"
  tags   = { Name = "${var.project_name}-ai-eip" }
}

# -----------------------------------------------------------------------------
# Monitoring VM — t3.large, 50 GB gp3
# -----------------------------------------------------------------------------
resource "aws_instance" "monitoring" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.monitoring_instance_type
  key_name               = aws_key_pair.ansible.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.monitoring.id]
  user_data              = local.user_data

  root_block_device {
    volume_size = var.monitoring_volume_size
    volume_type = "gp3"
  }

  tags = { Name = "${var.project_name}-monitoring" }
}

resource "aws_eip_association" "monitoring" {
  instance_id   = aws_instance.monitoring.id
  allocation_id = aws_eip.monitoring.id
}

# -----------------------------------------------------------------------------
# Backend VM — t3.small, 20 GB gp3
# -----------------------------------------------------------------------------
resource "aws_instance" "backend" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.backend_instance_type
  key_name               = aws_key_pair.ansible.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.backend.id]
  user_data              = local.user_data

  root_block_device {
    volume_size = var.backend_volume_size
    volume_type = "gp3"
  }

  tags = { Name = "${var.project_name}-backend" }
}

resource "aws_eip_association" "backend" {
  instance_id   = aws_instance.backend.id
  allocation_id = aws_eip.backend.id
}

# -----------------------------------------------------------------------------
# Network VM — t3.small, 20 GB gp3
# -----------------------------------------------------------------------------
resource "aws_instance" "network" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.network_instance_type
  key_name               = aws_key_pair.ansible.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.network.id]
  user_data              = local.user_data

  root_block_device {
    volume_size = var.network_volume_size
    volume_type = "gp3"
  }

  tags = { Name = "${var.project_name}-network" }
}

resource "aws_eip_association" "network" {
  instance_id   = aws_instance.network.id
  allocation_id = aws_eip.network.id
}

# -----------------------------------------------------------------------------
# AI/LLM VM — g4dn.xlarge, 50 GB gp3, NVIDIA T4 GPU
# -----------------------------------------------------------------------------
resource "aws_instance" "ai" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.ai_instance_type
  key_name               = aws_key_pair.ansible.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.ai.id]
  user_data              = local.user_data

  root_block_device {
    volume_size = var.ai_volume_size
    volume_type = "gp3"
  }

  tags = { Name = "${var.project_name}-ai" }
}

resource "aws_eip_association" "ai" {
  instance_id   = aws_instance.ai.id
  allocation_id = aws_eip.ai.id
}
