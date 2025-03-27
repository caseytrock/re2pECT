variable "aws_region" {
  description = "The AWS region to deploy resources"
  type        = string
  default     = "us-west-2"
}

variable "aws_access_key" {
  description = "AWS access key"
  type        = string
}

variable "aws_secret_key" {
  description = "AWS secret key"
  type        = string
}

variable "ami_id" {
  description = "The AMI ID to use for the EC2 instance"
  type        = string
  default     = "ami-075686beab831bb7f"
}

variable "docker_image" {
  description = "The Docker image to deploy"
  type        = string
}

variable "key_name" {
  description = "The name of the EC2 key pair"
  type        = string
}

variable "instance_type" {
  description = "The instance type for the EC2 instance"
  type        = string
  default     = "t2.micro"
}

variable "app_repo_url" {
  description = "Git repository URL for the Flask app"
  type        = string
  default     = "https://github.com/caseytrock/re2pECT.git"
}