#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

LOG_FILE="$SCRIPT_DIR/.auto-deploy.log"
STATE_FILE="$SCRIPT_DIR/.state.json"

# Configuration
REGION="us-west-1"
AZ="us-west-1a"
INSTANCE_TYPE="g4dn.xlarge"
AMI_ID="ami-072028e29f8a73b88"
SECURITY_GROUP_ID="sg-096ee569153e5e1cc"
VOLUME_ID="vol-0382f199122082a2f"
INSTANCE_PROFILE="gpu-streaming-workstation-instance-profile"
QUOTA_REQUEST_ID="ef52070396ff4b22ba65919d400518bfsIgZFx8h"
POLL_INTERVAL=60  # seconds

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

check_quota() {
    local status
    status=$(aws service-quotas get-requested-service-quota-change \
        --request-id "$QUOTA_REQUEST_ID" \
        --region "$REGION" \
        --query 'RequestedQuota.Status' \
        --output text 2>/dev/null || echo "UNKNOWN")
    echo "$status"
}

check_quota_value() {
    local value
    value=$(aws service-quotas get-service-quota \
        --service-code ec2 \
        --quota-code L-DB2E81BA \
        --region "$REGION" \
        --query 'Quota.Value' \
        --output text 2>/dev/null || echo "0")
    echo "$value"
}

launch_instance() {
    log "Launching EC2 instance..."

    local instance_id
    instance_id=$(aws ec2 run-instances \
        --region "$REGION" \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --security-group-ids "$SECURITY_GROUP_ID" \
        --iam-instance-profile Name="$INSTANCE_PROFILE" \
        --placement AvailabilityZone="$AZ" \
        --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":40,"VolumeType":"gp3","DeleteOnTermination":true,"Encrypted":true}}]' \
        --user-data file:///tmp/user_data_processed.sh \
        --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=gpu-streaming-workstation},{Key=Project,Value=gpu-streaming-workstation}]' \
        --query 'Instances[0].InstanceId' \
        --output text 2>&1)

    if [[ "$instance_id" == i-* ]]; then
        echo "$instance_id"
        return 0
    else
        log "ERROR: Failed to launch instance: $instance_id"
        return 1
    fi
}

wait_for_instance() {
    local instance_id="$1"
    log "Waiting for instance $instance_id to be running..."

    aws ec2 wait instance-running \
        --region "$REGION" \
        --instance-ids "$instance_id"

    log "Instance is running"
}

attach_volume() {
    local instance_id="$1"
    log "Attaching volume $VOLUME_ID to instance $instance_id..."

    aws ec2 attach-volume \
        --region "$REGION" \
        --volume-id "$VOLUME_ID" \
        --instance-id "$instance_id" \
        --device /dev/sdf \
        --output text

    log "Volume attachment initiated"
}

get_public_ip() {
    local instance_id="$1"
    aws ec2 describe-instances \
        --region "$REGION" \
        --instance-ids "$instance_id" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text
}

save_state() {
    local instance_id="$1"
    local public_ip="$2"

    cat > "$STATE_FILE" << EOF
{
    "instance_id": "$instance_id",
    "public_ip": "$public_ip",
    "volume_id": "$VOLUME_ID",
    "security_group_id": "$SECURITY_GROUP_ID",
    "region": "$REGION",
    "az": "$AZ",
    "ssm_command": "aws ssm start-session --target $instance_id --region $REGION"
}
EOF
    log "State saved to $STATE_FILE"
}

main() {
    log "=========================================="
    log "Auto-deploy script started"
    log "=========================================="
    log "Polling quota status every ${POLL_INTERVAL}s..."
    log "Quota request ID: $QUOTA_REQUEST_ID"
    log ""

    while true; do
        # First check if quota value is now > 0
        local quota_value
        quota_value=$(check_quota_value)

        if (( $(echo "$quota_value >= 4" | bc -l) )); then
            log "Quota is now $quota_value vCPUs - sufficient for deployment!"
            break
        fi

        # Check request status
        local status
        status=$(check_quota)
        log "Quota request status: $status (current value: $quota_value vCPUs)"

        if [[ "$status" == "APPROVED" ]]; then
            log "Quota request approved!"
            sleep 5  # Give AWS a moment to propagate
            break
        elif [[ "$status" == "DENIED" ]]; then
            log "ERROR: Quota request was denied. Please request manually via AWS console."
            exit 1
        fi

        sleep "$POLL_INTERVAL"
    done

    log ""
    log "=========================================="
    log "Quota available - Starting deployment"
    log "=========================================="

    # Launch instance
    local instance_id
    if ! instance_id=$(launch_instance); then
        log "Failed to launch instance"
        exit 1
    fi
    log "Instance launched: $instance_id"

    # Wait for instance to be running
    wait_for_instance "$instance_id"

    # Attach data volume
    attach_volume "$instance_id"

    # Get public IP
    sleep 5
    local public_ip
    public_ip=$(get_public_ip "$instance_id")
    log "Public IP: $public_ip"

    # Save state
    save_state "$instance_id" "$public_ip"

    log ""
    log "=========================================="
    log "DEPLOYMENT COMPLETE!"
    log "=========================================="
    log ""
    log "Instance ID: $instance_id"
    log "Public IP: $public_ip"
    log ""
    log "Connect via SSM:"
    log "  aws ssm start-session --target $instance_id --region $REGION"
    log ""
    log "Cloud-init will take 2-3 minutes to complete."
    log "Check progress with: tail -f /var/log/user-data.log"
    log ""
    log "WireGuard config will be at: /home/ubuntu/wg0-client.conf"
    log ""
}

main "$@"
