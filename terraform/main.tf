provider "aws" {
  region     = var.aws_region
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

provider "tls" {}

# Generate an SSH key pair
resource "tls_private_key" "flask_app_key" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# Create an AWS key pair using the generated public key
resource "aws_key_pair" "flask_app_key_pair" {
  key_name   = "flask-app-key-pair"
  public_key = tls_private_key.flask_app_key.public_key_openssh
}

# Save the private key to a file
resource "local_file" "private_key" {
  content  = tls_private_key.flask_app_key.private_key_pem
  filename = "${path.module}/terraform-generated-key.pem"
  file_permission = "0400" # Restrict permissions to the owner
}

# Define the security group for the Flask app
resource "aws_security_group" "flask_app_sg" {
  name_prefix = "flask-app-sg"

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    from_port   = 5000
    to_port     = 5000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  #k3s/traefik ports
  ingress {
    from_port   = 6443
    to_port     = 6443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Define the EC2 instance
resource "aws_instance" "flask_app" {
  ami           = var.ami_id
  instance_type = var.instance_type
  key_name      = aws_key_pair.flask_app_key_pair.key_name

user_data = <<-EOF
#!/bin/bash
set -e
exec > >(tee /var/log/user-data.log) 2>&1

echo "=== Starting User Data ==="

# 1. Install Docker
echo "[1/4] Installing Docker..."
sudo yum update -y
sudo yum install -y docker
sudo systemctl start docker
sudo systemctl enable docker
echo "Docker installed."

# 2. Install k3s
echo "[2/4] Installing k3s..."
curl -sfL https://get.k3s.io | K3S_KUBECONFIG_MODE="644" sh -
echo "Waiting for k3s to initialize..."

# Wait for k3s to be ready
until sudo kubectl get nodes >/dev/null 2>&1; do
  echo "Waiting for k3s API..."
  sleep 10
done

# 3. Configure kubectl access
echo "[3/4] Configuring kubectl..."
KUBECONFIG=/etc/rancher/k3s/k3s.yaml
sudo chmod 644 $KUBECONFIG
mkdir -p /home/ec2-user/.kube
sudo cp $KUBECONFIG /home/ec2-user/.kube/config
sudo chown ec2-user:ec2-user /home/ec2-user/.kube/config

# 4. Deploy Flask app
echo "[4/4] Deploying Flask app..."
cat <<'EOL' > /tmp/flask-app.yaml
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
      containers:
        - name: flask-app
          image: ${var.docker_image}
          ports:
            - containerPort: 5000
          env:
            - name: FLASK_APP
              value: "app.py"
            - name: FLASK_ENV
              value: "development"
          command: ["flask", "run", "--host=0.0.0.0"]
---
apiVersion: v1
kind: Service
metadata:
  name: flask-app-service
spec:
  ports:
    - port: 80
      targetPort: 5000
  selector:
    app: flask-app
  type: ClusterIP
---
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: flask-app-ingress
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
                name: flask-app-service
                port:
                  number: 80
EOL

kubectl apply -f /tmp/flask-app.yaml --validate=false
echo "=== Deployment Complete ==="
EOF

  tags = {
    Name = "flask-app-instance"
  }

  security_groups = [aws_security_group.flask_app_sg.name]
}