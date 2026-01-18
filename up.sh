#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Get region from terraform variables
REGION=$(awk '/variable "aws_region"/,/}/' variables.tf | grep default | sed 's/.*= *"\([^"]*\)".*/\1/')

echo "=========================================="
echo "GPU Streaming Workstation - Start"
echo "=========================================="
echo ""

# Check if we have an existing instance in terraform state
if [ -f "terraform.tfstate" ] && terraform state list 2>/dev/null | grep -q "aws_instance.streaming_workstation"; then
    INSTANCE_ID=$(terraform output -raw instance_id 2>/dev/null || echo "")

    if [ -n "$INSTANCE_ID" ]; then
        # Check instance state
        STATE=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
            --query 'Reservations[0].Instances[0].State.Name' --output text 2>/dev/null || echo "terminated")

        if [ "$STATE" = "stopped" ]; then
            echo "Found stopped instance: $INSTANCE_ID"
            echo "Starting instance..."
            aws ec2 start-instances --instance-ids "$INSTANCE_ID" --region "$REGION" > /dev/null

            echo "Waiting for instance to start..."
            aws ec2 wait instance-running --instance-ids "$INSTANCE_ID" --region "$REGION"

            # Get the new public IP
            PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
                --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)

            echo ""
            echo "=========================================="
            echo "Instance Started!"
            echo "=========================================="
            echo ""
            echo "Instance ID: $INSTANCE_ID"
            echo "Public IP: $PUBLIC_IP"
            echo ""
            echo "Connect via SSM:"
            echo "  aws ssm start-session --target $INSTANCE_ID --region $REGION"
            echo ""
            echo "NOTE: WireGuard endpoint changed to $PUBLIC_IP:51820"
            echo "Update your client config's Endpoint line."
            echo ""
            exit 0
        elif [ "$STATE" = "running" ]; then
            PUBLIC_IP=$(aws ec2 describe-instances --instance-ids "$INSTANCE_ID" --region "$REGION" \
                --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)
            echo "Instance already running!"
            echo ""
            echo "Instance ID: $INSTANCE_ID"
            echo "Public IP: $PUBLIC_IP"
            echo ""
            echo "Connect via SSM:"
            echo "  aws ssm start-session --target $INSTANCE_ID --region $REGION"
            echo ""
            exit 0
        fi
    fi
fi

# No existing instance or it was terminated - do full terraform deploy
echo "No existing instance found. Running full Terraform deploy..."
echo ""

# Check for required variables
if [ -z "${TF_VAR_my_ip:-}" ]; then
    echo "Detecting your public IP..."
    export TF_VAR_my_ip=$(curl -s https://api.ipify.org || curl -s https://ifconfig.me)
    echo "Detected IP: $TF_VAR_my_ip"
fi

echo ""
echo "Configuration:"
echo "  SSH allowed from: $TF_VAR_my_ip/32"
echo "  Access method: AWS SSM Session Manager"
echo ""

# Initialize Terraform
echo "Initializing Terraform..."
terraform init -upgrade

# Apply
echo ""
echo "Applying Terraform configuration..."
terraform apply -var="my_ip=$TF_VAR_my_ip" -auto-approve

echo ""
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""

# Get outputs
PUBLIC_IP=$(terraform output -raw public_ip)
INSTANCE_ID=$(terraform output -raw instance_id)

echo "Instance ID: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo ""
echo "Connect via SSM:"
echo "  aws ssm start-session --target $INSTANCE_ID --region $REGION"
echo ""
echo "NOTE: Instance needs a few minutes to complete cloud-init setup."
echo "WireGuard config will be at: /home/ubuntu/wg0-client.conf"
echo ""
