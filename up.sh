#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

echo "=========================================="
echo "GPU Streaming Workstation - Deploy"
echo "=========================================="
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

# Plan and apply
echo ""
echo "Planning deployment..."
terraform plan -out=tfplan

echo ""
read -p "Do you want to apply this plan? (yes/no): " confirm
if [ "$confirm" != "yes" ]; then
    echo "Deployment cancelled."
    exit 0
fi

echo ""
echo "Applying Terraform configuration..."
terraform apply tfplan

# Clean up plan file
rm -f tfplan

echo ""
echo "=========================================="
echo "Deployment Complete!"
echo "=========================================="
echo ""

# Get outputs
PUBLIC_IP=$(terraform output -raw public_ip)
INSTANCE_ID=$(terraform output -raw instance_id)
DATA_VOLUME_ID=$(terraform output -raw data_volume_id)
SSM_CMD=$(terraform output -raw ssm_session_command)

echo "Instance ID: $INSTANCE_ID"
echo "Data Volume ID: $DATA_VOLUME_ID"
echo "Public IP: $PUBLIC_IP"
echo ""
echo "Connect via SSM Session Manager:"
echo "  aws ssm start-session --target $INSTANCE_ID --region us-west-1"
echo ""
echo "=========================================="
echo ""
echo "NOTE: The instance needs a few minutes to complete setup."
echo "You can check the cloud-init log with:"
echo "  aws ssm start-session --target $INSTANCE_ID --region us-west-1"
echo "  Then run: tail -f /var/log/user-data.log"
echo ""
echo "Once setup is complete, the WireGuard config will be at:"
echo "  /home/ubuntu/wg0-client.conf"
echo ""
