#!/bin/bash

# Function to check if a command is available
function command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# Install Homebrew (if not already installed)
if ! command_exists brew; then
    echo "Installing Homebrew..."
    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Install Terraform (if not already installed)
if ! command_exists terraform; then
    echo "Installing Terraform..."
    brew install terraform
fi

# Install Docker (if not already installed)
if ! command_exists docker; then
    echo "Installing Docker..."
    brew install --cask docker
    # Open Docker to complete installation (macOS only)
    if [[ "$OSTYPE" == "darwin"* ]]; then
        open /Applications/Docker.app
    fi
fi

# Load environment variables from .env
set -a
source ../.env
set +a

# Build and push the Docker image
cd ../app
docker build -t "$DOCKER_HUB_USERNAME/$FLASK_APP_NAME:latest" .
docker push "$DOCKER_HUB_USERNAME/$FLASK_APP_NAME:latest"
cd ../terraform

# Initialize and apply Terraform configuration
terraform init
terraform apply -auto-approve \
  -var="aws_access_key=$AWS_ACCESS_KEY_ID" \
  -var="aws_secret_key=$AWS_SECRET_ACCESS_KEY" \
  -var="aws_region=$AWS_REGION" \
  -var="key_name=$EC2_KEY_PAIR_NAME" \
  -var="docker_image=$DOCKER_HUB_USERNAME/$FLASK_APP_NAME:latest \
  -var="ami_id=$AMI_ID"

# Output the public IP
echo "Flask app deployed! Access it at:"
terraform output public_ip