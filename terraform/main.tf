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
    description = "Internal App Communication"
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["172.31.0.0/16"] # Only allow within VPC
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

    # Free up port 80
    sudo systemctl stop nginx 2>/dev/null || true
    sudo systemctl stop apache2 2>/dev/null || true
    sudo pkill -f ":80" || true

    # Install k3s WITH Traefik enabled (default)
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="v1.27.6+k3s1" \
      K3S_KUBECONFIG_MODE="644" \
      sh -s - server \
              --disable servicelb \
              --disable local-storage \
              --disable metrics-server

    # Configure Traefik via k3s manifest
    sudo mkdir -p /var/lib/rancher/k3s/server/manifests
    cat << 'EOL' | sudo tee /var/lib/rancher/k3s/server/manifests/traefik-config.yaml
    apiVersion: helm.cattle.io/v1
    kind: HelmChartConfig
    metadata:
      name: traefik
      namespace: kube-system
    spec:
      valuesContent: |-
        deployment:
          replicas: 1
        ports:
          web:
            port: 8000
            hostPort: 80
        hostNetwork: true
        additionalArguments:
          - --entryPoints.web.address=:80
          - --providers.kubernetesIngress
        resources:
          requests:
            cpu: "50m"
            memory: "50Mi"
    EOL

    # Wait for Traefik
    until kubectl get pods -n kube-system -l app.kubernetes.io/name=traefik 2>/dev/null | grep -q Running; do
      echo "Waiting for Traefik..."
      sleep 5
    done
  EOF

  vpc_security_group_ids = [aws_security_group.flask_app_sg.id]
  tags = {
    Name = "flask-app-instance"
  }
}