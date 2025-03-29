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
  user_data = <<-EOF
    #!/bin/bash
    set -exuo pipefail
    exec > >(tee /var/log/user-data-debug.log) 2>&1

    echo "=== PHASE 1: SYSTEM PREP ==="
    echo "Freeing port 80..."
    sudo ss -tulnp | grep ':80' || echo "No processes on port 80"
    sudo systemctl stop nginx apache2 httpd || echo "No web servers to stop"
    sudo pkill -f ":80" || echo "No processes to kill on port 80"
    sudo ss -tulnp | grep ':80' && { echo "Port 80 still in use!"; exit 1; } || echo "Port 80 cleared"

    echo "=== PHASE 2: K3S INSTALLATION ==="
    echo "Installing k3s..."
    curl -sfL https://get.k3s.io | \
      INSTALL_K3S_VERSION="v1.27.6+k3s1" \
      K3S_KUBECONFIG_MODE="644" \
      sh -s - server \
              --disable traefik \
              --disable servicelb \
              --disable metrics-server \
              --disable helm-controller \
              --flannel-backend=none \
              --kubelet-arg="v=4"  # Enable verbose logging

    echo "Verifying k3s..."
    until kubectl cluster-info; do
      echo "k3s not ready yet..."
      journalctl -u k3s -n 20 --no-pager
      sleep 10
    done

    echo "=== PHASE 3: TRAEFIK INSTALLATION ==="
    echo "Creating traefik namespace..."
    kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f -
    kubectl get ns traefik || { echo "Failed to create namespace!"; exit 1; }

    echo "Applying Traefik deployment..."
    cat <<DEBUG | kubectl apply -f -
    apiVersion: apps/v1
    kind: Deployment
    metadata:
      name: traefik-debug
      namespace: traefik
      labels:
        app: traefik-debug
    spec:
      replicas: 1
      selector:
        matchLabels:
          app: traefik-debug
      template:
        metadata:
          labels:
            app: traefik-debug
          annotations:
            debug: "true"
        spec:
          containers:
          - name: traefik
            image: traefik:v2.10
            args:
              - --log.level=DEBUG
              - --entryPoints.web.address=:80
              - --providers.kubernetesingress
            ports:
            - containerPort: 80
              hostPort: 80
              name: web
            readinessProbe:
              httpGet:
                path: /ping
                port: 80
              initialDelaySeconds: 5
              periodSeconds: 5
          hostNetwork: true
    DEBUG

    echo "=== PHASE 4: VERIFICATION ==="
    echo "Waiting for Traefik pod..."
    for i in {1..30}; do
      POD_STATUS=$(kubectl -n traefik get pod -l app=traefik-debug -o jsonpath='{.items[0].status.phase}' 2>/dev/null || echo "Missing")
      echo "[Attempt $i/30] Pod status: $POD_STATUS"
      
      if [ "$POD_STATUS" = "Running" ]; then
        echo "Traefik is running!"
        break
      fi
      
      # Debug output if not running
      kubectl -n traefik get events --sort-by='.lastTimestamp' | tail -n 5
      kubectl -n traefik describe pod -l app=traefik-debug || true
      sleep 5
    done

    if [ "$POD_STATUS" != "Running" ]; then
      echo "=== FAILURE DEBUG ==="
      echo "Final pod state:"
      kubectl -n traefik describe pod -l app=traefik-debug
      echo "Traefik logs:"
      kubectl -n traefik logs -l app=traefik-debug --tail=50 || true
      echo "System diagnostics:"
      journalctl -u k3s -n 50 --no-pager
      sudo netstat -tulnp
      exit 1
    fi

    echo "=== FINAL VERIFICATION ==="
    echo "Testing Traefik connectivity..."
    curl -v --retry 10 --retry-delay 5 http://localhost || {
      echo "Failed to connect to Traefik"
      exit 1
    }

    echo "=== INSTALLATION COMPLETE ==="
  EOF
}