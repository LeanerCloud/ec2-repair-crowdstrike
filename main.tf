# Provider configuration
provider "aws" {
}

# Data source to get all Availability Zones in the region
data "aws_availability_zones" "available" {
  state = "available"
}

# Data source to get the latest Windows Server AMI from SSM Parameter Store
data "aws_ssm_parameter" "windows_ami" {
  name = "/aws/service/ami-windows-latest/Windows_Server-2019-English-Full-Base"
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
          "ec2:DescribeInstances",
          "ec2:DescribeInstanceStatus",
          "ec2:StopInstances",
          "ec2:StartInstances",
          "ec2:DetachVolume",
          "ec2:AttachVolume",
          "ec2:DescribeVolumes",
          "ec2:CreateSnapshot",
          "ec2:DescribeSnapshots",
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

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# Launch template for EC2 instances
resource "aws_launch_template" "ec2_repair_template" {
  name_prefix   = "ec2-repair-"
  image_id      = data.aws_ssm_parameter.windows_ami.value
  instance_type = "t3.medium" # Adjust instance type as needed

  iam_instance_profile {
    name = aws_iam_instance_profile.ec2_repair_profile.name
  }

  vpc_security_group_ids = [aws_security_group.ec2_repair_sg.id]

  user_data = base64encode(<<-EOF
              <powershell>
              # Your PowerShell script goes here
              ${file("ec2_repair_script.ps1")}
              </powershell>
              EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "EC2-Repair-Instance"
    }
  }
}

# Auto Scaling Group
resource "aws_autoscaling_group" "ec2_repair_asg" {
  name                = "ec2-repair-asg"
  vpc_zone_identifier = data.aws_availability_zones.available.zone_ids
  desired_capacity    = length(data.aws_availability_zones.available.names)
  min_size            = length(data.aws_availability_zones.available.names)
  max_size            = length(data.aws_availability_zones.available.names) * 2

  launch_template {
    id      = aws_launch_template.ec2_repair_template.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "EC2-Repair-ASG"
    propagate_at_launch = true
  }
}
