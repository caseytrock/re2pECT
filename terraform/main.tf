provider "aws" {
  region     = var.aws_region
}

provider "tls" {}

# Generate SSH key pair
resource "tls_private_key" "flask_app_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create AWS key pair
resource "aws_key_pair" "flask_app_key_pair" {
  key_name   = "flask-app-key-${sha256(timestamp())}"
  public_key = tls_private_key.flask_app_key.public_key_openssh
  lifecycle { ignore_changes = [key_name] }
}

# Save private key locally
resource "local_file" "private_key" {
  content         = tls_private_key.flask_app_key.private_key_pem
  filename        = "${path.module}/terraform-generated-key.pem"
  file_permission = "0400"
}

# Security group (restrict SSH to GitHub IPs if possible)
resource "aws_security_group" "flask_app_sg" {
  name_prefix = "flask-app-sg-"
  description = "Security group for Flask app on k3s"

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]  # Restrict to GitHub IPs in production!
  }

  ingress {
    description = "HTTP traffic"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "k3s API"
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle { create_before_destroy = true }
}

# EC2 instance (minimal user_data)
resource "aws_instance" "flask_app" {
  ami           = var.ami_id
  instance_type = var.instance_type
  key_name      = aws_key_pair.flask_app_key_pair.key_name

  user_data = <<-EOF
  #!/bin/bash
  set -euo pipefail
  exec > >(tee /var/log/user-data.log) 2>&1

  echo "=== Installing k3s ==="
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="v1.27.6+k3s1" \
    K3S_KUBECONFIG_MODE="644" \
    sh -

  echo "=== Waiting for k3s ==="
  until kubectl get nodes >/dev/null 2>&1; do sleep 5; done
  EOF

  tags = {
    Name        = "flask-app-instance"
    Environment = "production"
  }

  vpc_security_group_ids = [aws_security_group.flask_app_sg.id]
  monitoring            = true
  lifecycle { ignore_changes = [user_data] }
}