resource "aws_key_pair" "ansible" {
  key_name   = var.ssh_key_name
  public_key = file(var.ssh_public_key_path)

  tags = { Name = "${var.project_name}-${var.ssh_key_name}" }
}
