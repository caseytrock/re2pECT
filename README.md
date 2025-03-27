# Flask App on k3s with AWS EC2

This repository automates the deployment of a simple Flask app on a single-node k3s cluster running on an AWS EC2 instance.

## Prerequisites
1. **AWS CLI**: Install and configure the AWS CLI with your credentials (`aws configure`).
2. **Terraform**: Install Terraform ([download here](https://www.terraform.io/downloads.html)).
3. **Docker**: Install Docker ([download here](https://www.docker.com/get-started)).

## Steps
1. Clone this repository:
   ```bash
   git clone https://github.com/your-username/flask-k3s-ec2.git
   cd flask-k3s-ec2

       Copy .env.example to .env and update the values:
    bash
    Copy

    cp .env.example .env
    nano .env  # Update the values

    Run the deployment script:
    powershell
    Copy

    .\scripts\deploy.ps1

    Access the Flask app at:
    Copy

    http://<public-ip>

    Clean up (when done):
    powershell
    Copy

    cd terraform
    terraform destroy -auto-approve

Customizing the Flask App

    Replace the app/app.py file with your own Flask app.

    Update app/requirements.txt with your app's dependencies.

Notes

    Replace placeholders in .env with your own values.

    Ensure the EC2 key pair (EC2_KEY_PAIR_NAME) exists in the specified AWS region.

   Summary of User Steps

    Install Prerequisites:

        Terraform, Docker, AWS CLI, Git.

    Set Up AWS:

        Create an EC2 key pair.

    Set Up Docker Hub:

        Create a Docker Hub account and generate an access token.

    Clone the Repository:

        Clone the repo and update .env.

    Build and Push the Docker Image:

        Replace the Flask app code and push the image to Docker Hub.

    Run the Deployment Script:

        Deploy the app using deploy.ps1.

    Access the App:

        Access the app at the public IP.

    Clean Up:

        Destroy the resources when done.


notes to add:
- repo must be lowercase