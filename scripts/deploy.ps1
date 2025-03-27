# Function to check if a command is available
function Test-Command {
  param (
      [string]$command
  )
  try {
      Get-Command $command -ErrorAction Stop
      return $true
  } catch {
      return $false
  }
}

# Install Chocolatey (if not already installed)
if (-not (Test-Command "choco")) {
  Write-Output "Installing Chocolatey..."
  Set-ExecutionPolicy Bypass -Scope Process -Force
  [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
  Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1'))
}

# Install Terraform (if not already installed)
if (-not (Test-Command "terraform")) {
  Write-Output "Installing Terraform..."
  choco install terraform -y
}

# Install Docker (if not already installed)
if (-not (Test-Command "docker")) {
  Write-Output "Installing Docker..."
  choco install docker-desktop -y
}

# Load environment variables from .env
Get-Content ..\.env | ForEach-Object {
  $name, $value = $_.Split('=')
  Set-Content env:\$name $value
}

# Build and push the Docker image
Set-Location ..\app
docker build -t $env:DOCKER_HUB_USERNAME/$env:FLASK_APP_NAME`:latest .
docker push $env:DOCKER_HUB_USERNAME/$env:FLASK_APP_NAME`:latest
Set-Location ..\terraform

# Initialize and apply Terraform configuration
terraform init
terraform apply -auto-approve `
-var="aws_access_key=$env:AWS_ACCESS_KEY_ID" `
-var="aws_secret_key=$env:AWS_SECRET_ACCESS_KEY" `
-var="aws_region=$env:AWS_REGION" `
-var="key_name=$env:EC2_KEY_PAIR_NAME" `
-var="docker_image=$env:DOCKER_HUB_USERNAME/$env:FLASK_APP_NAME`:latest" `
-var="ami_id=$env:AMI_ID"

# Output the public IP
Write-Output "Flask app deployed! Access it at:"
terraform output public_ip