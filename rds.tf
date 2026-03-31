# -----------------------------------------------------------------------------
# DB Subnet Group (requires 2 AZs)
# -----------------------------------------------------------------------------
resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet"
  subnet_ids = [aws_subnet.private.id, aws_subnet.private_b.id]

  tags = { Name = "${var.project_name}-db-subnet-group" }
}

# -----------------------------------------------------------------------------
# RDS MySQL — db.t3.micro, single-AZ, 20 GB gp3
# -----------------------------------------------------------------------------
resource "aws_db_instance" "mysql" {
  identifier     = "${var.project_name}-mysql"
  engine         = "mysql"
  engine_version = "8.0"
  instance_class = var.db_instance_class

  allocated_storage = var.db_storage_gb
  storage_type      = "gp3"

  db_name  = replace(var.db_name, "-", "_") # RDS doesn't allow hyphens
  username = var.db_username
  password = var.db_password

  db_subnet_group_name   = aws_db_subnet_group.main.name
  vpc_security_group_ids = [aws_security_group.rds.id]

  multi_az            = false
  publicly_accessible = false
  skip_final_snapshot = true

  tags = { Name = "${var.project_name}-mysql" }
}
