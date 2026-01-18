variable "aws_region" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "us-west-2"
}

variable "instance_type" {
  description = "EC2 instance type"
  type        = string
  default     = "g4dn.xlarge"
}

variable "root_volume_size" {
  description = "Size of root EBS volume in GB"
  type        = number
  default     = 200
}

variable "my_ip" {
  description = "Your current public IP address for SSH access (will be appended with /32)"
  type        = string
}

variable "wireguard_port" {
  description = "UDP port for WireGuard VPN"
  type        = number
  default     = 51820
}

variable "wireguard_server_ip" {
  description = "WireGuard server IP in the VPN subnet"
  type        = string
  default     = "10.200.200.1"
}

variable "wireguard_client_ip" {
  description = "WireGuard client IP in the VPN subnet"
  type        = string
  default     = "10.200.200.2"
}

variable "wireguard_subnet" {
  description = "WireGuard VPN subnet CIDR"
  type        = string
  default     = "10.200.200.0/24"
}

variable "project_name" {
  description = "Project name for resource tagging"
  type        = string
  default     = "gpu-streaming-workstation"
}
