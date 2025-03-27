output "public_ip" {
  description = "Public IP of the EC2 instance"
  value       = aws_instance.flask_app.public_ip
}

output "private_key_path" {
  description = "Path to the generated private key"
  value       = local_file.private_key.filename
}

# New outputs for GitHub Actions
output "ssh_private_key" {
  description = "Private key for GitHub Actions (add to secrets)"
  value       = tls_private_key.flask_app_key.private_key_pem
  sensitive   = true
}

output "kubeconfig" {
  description = "Command to fetch kubeconfig"
  value       = "ssh -i ${local_file.private_key.filename} ec2-user@${aws_instance.flask_app.public_ip} sudo cat /etc/rancher/k3s/k3s.yaml"
  sensitive   = true
}