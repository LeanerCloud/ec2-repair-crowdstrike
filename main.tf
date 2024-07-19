# Provider configuration
provider "aws" {
  region = var.aws_region
}

# HTTP provider for IP detection
provider "http" {}

# Variables
variable "aws_region" {
  default = "us-east-1"
}

variable "key_name" {
  default = "crowdstrike-test"
}

variable "test_mode" {
  description = "Enable test mode (deploys only in first AZ with a test instance)"
  type        = bool
  default     = true
}

# Data source to get all Availability Zones in the region
data "aws_availability_zones" "available" {
  state = "available"
}

# Data source to get the latest Windows Server AMI from SSM Parameter Store
data "aws_ssm_parameter" "windows_ami" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2019-English-Full-Base"
}

# Data source to get the public IP of the machine running Terraform
data "http" "myip" {
  url = "http://ipv4.icanhazip.com"
}

# IAM role for EC2 instances
resource "aws_iam_role" "ec2_repair_role" {
  name = "ec2_repair_role"

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
}

# IAM policy for EC2 instances
resource "aws_iam_role_policy" "ec2_repair_policy" {
  name = "ec2_repair_policy"
  role = aws_iam_role.ec2_repair_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:AttachVolume",
          "ec2:CreateSnapshot",
          "ec2:CreateTags",
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:DescribeSnapshots",
          "ec2:DescribeVolumes",
          "ec2:DetachVolume",
          "ec2:StartInstances",
          "ec2:StopInstances",
          "ec2:TerminateInstances",
          "ssm:GetParameter"
        ]
        Resource = "*"
      }
    ]
  })
}

# IAM instance profile
resource "aws_iam_instance_profile" "ec2_repair_profile" {
  name = "ec2_repair_profile"
  role = aws_iam_role.ec2_repair_role.name
}

# Security group for EC2 instances
resource "aws_security_group" "ec2_repair_sg" {
  name        = "ec2_repair_sg"
  description = "Security group for EC2 repair instances"

  ingress {
    from_port   = 3389
    to_port     = 3389
    protocol    = "tcp"
    cidr_blocks = ["${chomp(data.http.myip.body)}/32"]
    description = "Allow RDP from my IP"
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# EC2 instances for repair (one per AZ or just one in test mode)
resource "aws_instance" "ec2_repair" {
  count                  = var.test_mode ? 1 : length(data.aws_availability_zones.available.names)
  ami                    = data.aws_ssm_parameter.windows_ami.value
  instance_type          = "t3.medium"
  key_name               = var.key_name
  availability_zone      = data.aws_availability_zones.available.names[count.index]
  iam_instance_profile   = aws_iam_instance_profile.ec2_repair_profile.name
  vpc_security_group_ids = [aws_security_group.ec2_repair_sg.id]

  user_data = base64encode(<<-EOF
              <powershell>
              # Your PowerShell script goes here
              ${file("ec2_repair_script.ps1")}
              </powershell>
              EOF
  )

  tags = {
    Name = "CrowdStrike-Repair-${data.aws_availability_zones.available.names[count.index]}"
  }
}

# Test instance (only created in test mode)
resource "aws_instance" "ec2_test" {
  count                  = var.test_mode ? 1 : 0
  ami                    = data.aws_ssm_parameter.windows_ami.value
  instance_type          = "t3.micro"
  key_name               = var.key_name
  availability_zone      = data.aws_availability_zones.available.names[0]
  vpc_security_group_ids = [aws_security_group.ec2_repair_sg.id]

  user_data = base64encode(<<-EOF
              <powershell>
              New-Item -Path "C:\Windows\System32\drivers\CrowdStrike" -ItemType Directory -Force
              New-Item -Path "C:\Windows\System32\drivers\CrowdStrike\C-00000291.sys" -ItemType File -Force
              </powershell>
              EOF
  )

  tags = {
    Name = "EC2-Test-Instance"
  }
}

# Outputs
output "repair_instance_ids" {
  value = aws_instance.ec2_repair[*].id
}

output "test_instance_id" {
  value = var.test_mode ? aws_instance.ec2_test[0].id : "No test instance deployed"
}

output "your_ip" {
  value = data.http.myip.body
}
