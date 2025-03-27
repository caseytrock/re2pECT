provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

provider "tls" {}

# Generate an SSH key pair with timestamp for rotation
resource "tls_private_key" "flask_app_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create an AWS key pair with rotation support
resource "aws_key_pair" "flask_app_key_pair" {
  key_name   = "flask-app-key-${sha256(timestamp())}"
  public_key = tls_private_key.flask_app_key.public_key_openssh

  lifecycle {
    ignore_changes = [key_name]  # Allow manual override of key name
  }
}

# Save the private key with strict permissions
resource "local_file" "private_key" {
  content         = tls_private_key.flask_app_key.private_key_pem
  filename        = "${path.module}/terraform-generated-key.pem"
  file_permission = "0400"
}

# Security group with minimum necessary ports
resource "aws_security_group" "flask_app_sg" {
  name_prefix = "flask-app-sg-"
  description = "Security group for Flask app on k3s"

  ingress {
    description = "SSH access"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
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

  lifecycle {
    create_before_destroy = true
  }
}

# EC2 instance with improved user_data
resource "aws_instance" "flask_app" {
  ami           = var.ami_id
  instance_type = var.instance_type
  key_name      = aws_key_pair.flask_app_key_pair.key_name

  user_data = <<-EOF
  #!/bin/bash
  set -euo pipefail
  exec > >(tee /var/log/user-data.log) 2>&1

  echo "=== Starting User Data $(date) ==="

  # 1. Install dependencies
  echo "[1/4] Installing packages..."
  sudo yum update -y
  sudo yum install -y git

  # 3. Install k3s with Traefik
  echo "[3/4] Installing k3s..."
  curl -sfL https://get.k3s.io | \
    INSTALL_K3S_VERSION="v1.27.6+k3s1" \
    K3S_KUBECONFIG_MODE="644" \
    sh -

  # Wait for cluster
  echo -n "Waiting for k3s API..."
  until kubectl get nodes >/dev/null 2>&1; do
    echo -n "."
    sleep 5
  done
  echo "Ready!"

  # 4. Set up persistent storage
  echo "[4/4] Configuring storage..."
  sudo mkdir -p /mnt/app-data
  sudo chown -R ec2-user:ec2-user /mnt/app-data

  # Clone initial app code
  git clone ${var.app_repo_url} /mnt/app-data || \
    { echo "Failed to clone repo"; exit 1; }

  # Apply Kubernetes manifest
  cat <<EOL > /tmp/flask-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: flask-app
spec:
  replicas: 1
  selector:
    matchLabels:
      app: flask-app
  template:
    metadata:
      labels:
        app: flask-app
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 1000
      containers:
      - name: flask
        image: ${var.docker_image}
        workingDir: /app
        command: ["flask", "run", "--host=0.0.0.0"]
        volumeMounts:
          - name: app-code
            mountPath: /app
        env:
          - name: FLASK_APP
            value: "app.py"
          - name: FLASK_ENV
            value: "production"
      volumes:
        - name: app-code
          hostPath:
            path: /mnt/app-data
---
apiVersion: v1
kind: Service
metadata:
  name: flask-service
spec:
  ports:
    - port: 80
      targetPort: 5000
  selector:
    app: flask-app
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: flask-ingress
  annotations:
    traefik.ingress.kubernetes.io/router.entrypoints: web
spec:
  rules:
    - http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: flask-service
                port:
                  number: 80
EOL

  kubectl apply -f /tmp/flask-app.yaml
  echo "=== Deployment Complete ==="
  EOF

  tags = {
    Name        = "flask-app-instance"
    Environment = "production"
  }

  vpc_security_group_ids = [aws_security_group.flask_app_sg.id]
  monitoring            = true

  lifecycle {
    ignore_changes = [user_data]  # Allow CI/CD to manage updates
  }
}

# Output the connection information
output "instance_public_ip" {
  description = "Public IP address of the EC2 instance"
  value       = aws_instance.flask_app.public_ip
}

output "ssh_command" {
  description = "Command to SSH into the instance"
  value       = "ssh -i ${local_file.private_key.filename} ec2-user@${aws_instance.flask_app.public_ip}"
}