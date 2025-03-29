output "instance_id" {
  value = aws_instance.flask_app.id
}

output "public_ip" {
  value = try(aws_instance.flask_app.public_ip, "NOT_ASSIGNED_YET")
}

output "ssh_private_key" {
  description = "Private key for GitHub Actions"
  value       = tls_private_key.flask_app_key.private_key_pem
  sensitive   = true
}