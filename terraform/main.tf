provider "aws" {
  region = var.aws_region
}

resource "tls_private_key" "flask_app_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "flask_app_key_pair" {
  key_name   = "flask-app-key-${sha256(timestamp())}"
  public_key = tls_private_key.flask_app_key.public_key_openssh
}

resource "local_file" "private_key" {
  content         = tls_private_key.flask_app_key.private_key_pem
  filename        = "${path.module}/terraform-generated-key.pem"
  file_permission = "0400"
}

resource "aws_security_group" "flask_app_sg" {
  name_prefix = "flask-app-sg-"
  description = "Security group for Flask app with Traefik ingress"

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "HTTPS"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Internal Docker Communication"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    self        = true  # Only allow within the security group
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "flask_app" {
  ami           = var.ami_id
  instance_type = var.instance_type
  key_name      = aws_key_pair.flask_app_key_pair.key_name

  user_data = <<-EOF
    #!/bin/bash
    set -euo pipefail
    exec > >(tee /var/log/user-data.log) 2>&1

    # Install Docker
    sudo yum install -y docker
    sudo systemctl enable docker
    sudo systemctl start docker
    sudo usermod -aG docker ec2-user

    # Install k3s with Docker as the container runtime
    echo "=== Installing k3s with Docker ==="
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="v1.27.6+k3s1" \
      K3S_KUBECONFIG_MODE="644" \
      sh -s - --docker

    # Install kubectl
    echo "=== Installing kubectl ==="
    curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
    chmod +x kubectl
    sudo mv kubectl /usr/local/bin/

    # Configure kubeconfig
    echo "=== Configuring kubeconfig ==="
    mkdir -p /home/ec2-user/.kube
    sudo cp /etc/rancher/k3s/k3s.yaml /home/ec2-user/.kube/config
    sudo chown ec2-user:ec2-user /home/ec2-user/.kube/config

    # Wait for cluster to be ready
    echo "=== Waiting for cluster ==="
    until kubectl get nodes >/dev/null 2>&1; do sleep 5; done

    # Verify Docker is working with k3s
    echo "=== Verifying Docker containers ==="
    sudo docker ps | grep k3s
  EOF

  vpc_security_group_ids = [aws_security_group.flask_app_sg.id]
  tags = {
    Name = "flask-app-instance"
  }
}