# -----------------------------------------------------------------------------
# Ubuntu 22.04 AMI — pinned via var.ubuntu_ami_id (E1-02 rescope)
# No data source lookup with most_recent=true: each apply uses the AMI the
# operator explicitly chose, so re-applies don't silently upgrade the OS.
# -----------------------------------------------------------------------------
locals {
  ami_id = var.ubuntu_ami_id
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

resource "aws_eip" "k3s" {
  count  = var.enable_k3s ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.project_name}-k3s-eip" }
}

resource "aws_eip" "gpu" {
  count  = var.enable_gpu ? 1 : 0
  domain = "vpc"
  tags   = { Name = "${var.project_name}-gpu-eip" }
}

# -----------------------------------------------------------------------------
# Monitoring VM — t3.large, 50 GB gp3
# -----------------------------------------------------------------------------
resource "aws_instance" "monitoring" {
  ami                    = local.ami_id
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
# k3s VM — t3.xlarge, 50 GB gp3 (Spring Boot, Kong, Triage, MCP Servers)
# -----------------------------------------------------------------------------
resource "aws_instance" "k3s" {
  count                  = var.enable_k3s ? 1 : 0
  ami                    = local.ami_id
  instance_type          = var.k3s_instance_type
  key_name               = aws_key_pair.ansible.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.k3s.id]
  user_data              = local.user_data

  root_block_device {
    volume_size = var.k3s_volume_size
    volume_type = "gp3"
  }

  tags = { Name = "${var.project_name}-k3s" }
}

resource "aws_eip_association" "k3s" {
  count         = var.enable_k3s ? 1 : 0
  instance_id   = aws_instance.k3s[0].id
  allocation_id = aws_eip.k3s[0].id
}

# -----------------------------------------------------------------------------
# GPU VM — g4dn.xlarge, 50 GB gp3, NVIDIA T4 GPU (Ollama)
# -----------------------------------------------------------------------------
resource "aws_instance" "gpu" {
  count                  = var.enable_gpu ? 1 : 0
  ami                    = local.ami_id
  instance_type          = var.gpu_instance_type
  key_name               = aws_key_pair.ansible.key_name
  subnet_id              = aws_subnet.private.id
  vpc_security_group_ids = [aws_security_group.gpu.id]
  user_data              = local.user_data

  root_block_device {
    volume_size = var.gpu_volume_size
    volume_type = "gp3"
  }

  tags = { Name = "${var.project_name}-gpu" }
}

resource "aws_eip_association" "gpu" {
  count         = var.enable_gpu ? 1 : 0
  instance_id   = aws_instance.gpu[0].id
  allocation_id = aws_eip.gpu[0].id
}
