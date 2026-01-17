output "public_ip" {
  description = "Public IP address of the streaming workstation"
  value       = aws_instance.streaming_workstation.public_ip
}

output "instance_id" {
  description = "EC2 instance ID"
  value       = aws_instance.streaming_workstation.id
}

output "data_volume_id" {
  description = "EBS data volume ID"
  value       = aws_ebs_volume.data.id
}

output "wireguard_port" {
  description = "WireGuard UDP port"
  value       = var.wireguard_port
}

output "ssh_cidr_used" {
  description = "CIDR block allowed for SSH access"
  value       = "${var.my_ip}/32"
}

output "ssh_command" {
  description = "SSH command to connect to the instance"
  value       = "ssh -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_instance.streaming_workstation.public_ip}"
}

output "scp_wireguard_config" {
  description = "SCP command to fetch WireGuard client config"
  value       = "scp -i ~/.ssh/${var.key_name}.pem ubuntu@${aws_instance.streaming_workstation.public_ip}:~/wg0-client.conf ."
}

output "instance_type_used" {
  description = "EC2 instance type that was deployed"
  value       = aws_instance.streaming_workstation.instance_type
}

output "availability_zone" {
  description = "Availability zone where resources are deployed"
  value       = aws_instance.streaming_workstation.availability_zone
}

output "ami_id" {
  description = "AMI ID used for the instance"
  value       = data.aws_ami.ubuntu.id
}

output "security_group_id" {
  description = "Security group ID"
  value       = aws_security_group.streaming_workstation.id
}

output "wireguard_vpn_subnet" {
  description = "WireGuard VPN subnet"
  value       = var.wireguard_subnet
}
