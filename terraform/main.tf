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

    # Install minimal k3s
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="v1.27.6+k3s1" \
      K3S_KUBECONFIG_MODE="644" \
      sh -s - server \
              --disable servicelb \
              --disable local-storage \
              --disable metrics-server \
              --disable traefik \
              --disable helm-controller \
              --disable-network-policy \
              --disable coredns \
              --flannel-backend=none \
              --kubelet-arg="serialize-image-pulls=false"

    # Install minimal Traefik
    sudo mkdir -p /var/lib/rancher/k3s/server/manifests
    cat <<'EOL' | sudo tee /var/lib/rancher/k3s/server/manifests/traefik.yaml
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: traefik
      namespace: kube-system
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: traefik
      template:
        metadata:
          labels:
            app: traefik
        spec:
          containers:
          - name: traefik
            image: traefik:v2.10
            args:
              - --entryPoints.web.address=:80
              - --providers.kubernetesingress
            ports:
              - containerPort: 80
                hostPort: 80
                name: web
            resources:
              requests:
                cpu: "20m"
                memory: "30Mi"
          hostNetwork: true
    EOL

    # Wait for Traefik
    until kubectl get pods -n kube-system -l app=traefik 2>/dev/null | grep -q Running; do
      echo "Waiting for Traefik..."
      kubectl get pods -n kube-system -l app=traefik || true
      sleep 10
    done
  EOF

  vpc_security_group_ids = [aws_security_group.flask_app_sg.id]
  tags = {
    Name = "flask-app-instance"
  }
}