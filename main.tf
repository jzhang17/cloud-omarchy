terraform {
  required_version = ">= 1.0.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Get the latest Ubuntu 22.04 LTS AMI
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

# Get available AZs
data "aws_availability_zones" "available" {
  state = "available"
}

# Security Group
resource "aws_security_group" "streaming_workstation" {
  name        = "${var.project_name}-sg"
  description = "Security group for GPU streaming workstation"

  # SSH from my IP only
  ingress {
    description = "SSH from my IP"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["${var.my_ip}/32"]
  }

  # WireGuard UDP from anywhere
  ingress {
    description = "WireGuard VPN"
    from_port   = var.wireguard_port
    to_port     = var.wireguard_port
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Allow all outbound traffic
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name    = "${var.project_name}-sg"
    Project = var.project_name
  }
}

# Persistent Data Volume (created separately to survive instance rebuilds)
resource "aws_ebs_volume" "data" {
  availability_zone = data.aws_availability_zones.available.names[0]
  size              = var.data_volume_size
  type              = "gp3"

  # Prevent accidental deletion unless explicitly requested
  lifecycle {
    prevent_destroy = false
  }

  tags = {
    Name    = "${var.project_name}-data-volume"
    Project = var.project_name
  }
}

# IAM Role for SSM Session Manager access
resource "aws_iam_role" "streaming_workstation" {
  name = "${var.project_name}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name    = "${var.project_name}-role"
    Project = var.project_name
  }
}

# Attach SSM Managed Instance Core policy for Session Manager access
resource "aws_iam_role_policy_attachment" "ssm_managed_instance_core" {
  role       = aws_iam_role.streaming_workstation.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# Instance Profile to attach IAM role to EC2
resource "aws_iam_instance_profile" "streaming_workstation" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.streaming_workstation.name

  tags = {
    Name    = "${var.project_name}-instance-profile"
    Project = var.project_name
  }
}

# EC2 Instance
resource "aws_instance" "streaming_workstation" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.instance_type
  iam_instance_profile   = aws_iam_instance_profile.streaming_workstation.name
  vpc_security_group_ids = [aws_security_group.streaming_workstation.id]
  availability_zone      = data.aws_availability_zones.available.names[0]

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }

  user_data = templatefile("${path.module}/user_data.sh", {
    data_device         = "/dev/nvme1n1"
    wireguard_port      = var.wireguard_port
    wireguard_server_ip = var.wireguard_server_ip
    wireguard_client_ip = var.wireguard_client_ip
    wireguard_subnet    = var.wireguard_subnet
  })

  tags = {
    Name    = "${var.project_name}"
    Project = var.project_name
  }

  # Wait for instance to be ready before attaching volume
  depends_on = [aws_ebs_volume.data]
}

# Attach the data volume to the instance
resource "aws_volume_attachment" "data" {
  device_name = "/dev/sdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.streaming_workstation.id

  # Don't force detach - allow clean shutdown
  force_detach = false
}

# Null resource to handle data volume deletion based on variable
resource "null_resource" "data_volume_lifecycle" {
  triggers = {
    delete_data_volume = var.delete_data_volume
    volume_id          = aws_ebs_volume.data.id
  }
}
