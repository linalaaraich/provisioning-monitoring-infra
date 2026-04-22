# -----------------------------------------------------------------------------
# General
# -----------------------------------------------------------------------------
variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "us-east-1"
}

variable "project_name" {
  description = "Project tag applied to all resources"
  type        = string
  default     = "observability-rca"
}

variable "environment" {
  description = "Environment tag (demo, dev, prod)"
  type        = string
  default     = "demo"
}

# -----------------------------------------------------------------------------
# Networking
# -----------------------------------------------------------------------------
variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidr" {
  description = "CIDR block for the public subnet"
  type        = string
  default     = "10.0.1.0/24"
}

variable "private_subnet_cidr" {
  description = "CIDR block for the private subnet"
  type        = string
  default     = "10.0.2.0/24"
}

variable "availability_zone" {
  description = "AZ for all resources (single-AZ demo)"
  type        = string
  default     = "us-east-1a"
}

# -----------------------------------------------------------------------------
# SSH Access
# -----------------------------------------------------------------------------
variable "allowed_ssh_cidrs" {
  description = "CIDR blocks allowed SSH access (restrict to CIRES IPs)"
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "ssh_public_key_path" {
  description = "Path to the SSH public key for EC2 access"
  type        = string
  default     = "~/.ssh/ansible_key.pub"
}

variable "ssh_key_name" {
  description = "Name for the AWS key pair"
  type        = string
  default     = "ansible-key"
}

# -----------------------------------------------------------------------------
# AMI (E1-02: pinned — no silent AMI drift between applies)
# Find current Ubuntu AMIs at https://cloud-images.ubuntu.com/locator/ec2/
# -----------------------------------------------------------------------------
variable "ubuntu_ami_id" {
  description = "Pinned Ubuntu 22.04 AMI ID for the target region. Required — no default, to prevent silent AMI drift between terraform applies."
  type        = string

  validation {
    condition     = can(regex("^ami-[0-9a-f]{8,17}$", var.ubuntu_ami_id))
    error_message = "ubuntu_ami_id must be a valid AMI ID of the form ami-xxxxxxxx. Look one up for your region at https://cloud-images.ubuntu.com/locator/ec2/"
  }
}

# -----------------------------------------------------------------------------
# EC2 Instance Types
# -----------------------------------------------------------------------------
variable "monitoring_instance_type" {
  description = "EC2 instance type for monitoring VM"
  type        = string
  default     = "t3.large"
}

variable "k3s_instance_type" {
  description = "EC2 instance type for k3s cluster VM"
  type        = string
  default     = "t3.xlarge"
}

variable "gpu_instance_type" {
  description = "EC2 instance type for GPU VM (Ollama)"
  type        = string
  default     = "g4dn.xlarge"
}

# -----------------------------------------------------------------------------
# EBS Volumes
# -----------------------------------------------------------------------------
variable "monitoring_volume_size" {
  description = "Root volume size (GB) for monitoring VM"
  type        = number
  default     = 50
}

variable "k3s_volume_size" {
  description = "Root volume size (GB) for k3s cluster VM"
  type        = number
  default     = 50
}

variable "gpu_volume_size" {
  description = "Root volume size (GB) for GPU VM"
  type        = number
  default     = 50
}

# -----------------------------------------------------------------------------
# RDS
# -----------------------------------------------------------------------------
variable "db_instance_class" {
  description = "RDS instance class"
  type        = string
  default     = "db.t3.micro"
}

variable "db_name" {
  description = "MySQL database name"
  type        = string
  default     = "app-db"
}

variable "db_username" {
  description = "MySQL master username"
  type        = string
  default     = "appuser"
}

variable "db_password" {
  description = "MySQL master password"
  type        = string
  sensitive   = true
}

variable "db_storage_gb" {
  description = "RDS allocated storage in GB"
  type        = number
  default     = 20
}

# -----------------------------------------------------------------------------
# S3 / CloudFront
# -----------------------------------------------------------------------------
variable "s3_bucket_name" {
  description = "S3 bucket name for React frontend and Drain3 snapshots"
  type        = string
  default     = "cires-observability-demo"
}

# -----------------------------------------------------------------------------
# Staged deploy flags (quota-aware)
# Set to false to skip the resource on this apply — lets you deploy monitoring
# first and bring up k3s / GPU later once AWS service quotas allow it.
# -----------------------------------------------------------------------------
variable "enable_k3s" {
  description = "Provision the k3s EC2 instance. Set false if your Standard on-demand vCPU quota is too low for monitoring + k3s on the same apply."
  type        = bool
  default     = true
}

variable "enable_gpu" {
  description = "Provision the GPU (g4dn.xlarge) EC2 instance. Set false if your G+VT on-demand vCPU quota is 0 (common on new accounts)."
  type        = bool
  default     = true
}
