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
    self        = true
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

    sudo mkdir -p /etc/rancher/k3s/
    cat << 'EOL' | sudo tee /etc/rancher/k3s/traefik-config.yaml
    ports:
      web:
        port: 80
        expose: true
        exposedPort: 80
        protocol: TCP
    EOL

    # Install k3s with built-in Traefik (lightweight config)
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="v1.27.6+k3s1" \
      K3S_KUBECONFIG_MODE="644" \
      sh -s - --write-kubeconfig-mode 644 \
              --disable servicelb \
              --disable local-storage \
              --disable metrics-server

    # Configure Traefik via k3s addon (not Helm)
    sudo cat << 'EOL' > /var/lib/rancher/k3s/server/manifests/traefik-config.yaml
    apiVersion: helm.cattle.io/v1
    kind: HelmChartConfig
    metadata:
      name: traefik
      namespace: kube-system
    spec:
      valuesContent: |-
        ports:
          web:
            port: 80
            hostPort: 80
        hostNetwork: true
    EOL

    # Wait for cluster
    until kubectl cluster-info; do sleep 5; done

    # Configure GHCR authentication
    sudo mkdir -p /etc/rancher/k3s/
    cat << 'EOL' | sudo tee /etc/rancher/k3s/registries.yaml
    mirrors:
      ghcr.io:
        endpoint:
          - "https://ghcr.io"
    configs:
      "ghcr.io":
        auth:
          username: "${var.ghcr_username}"
          password: "${var.ghcr_token}"
    EOL

    # Restart k3s to apply registry config
    sudo systemctl restart k3s

    # Verify cluster
    until kubectl get nodes >/dev/null 2>&1; do sleep 5; done
  EOF

  vpc_security_group_ids = [aws_security_group.flask_app_sg.id]
  tags = {
    Name = "flask-app-instance"
  }
}