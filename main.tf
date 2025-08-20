# Provider Configuration

provider "aws" {
  region = var.aws_region
}

# VPC and Networking

resource "aws_vpc" "mara" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "MaraVPC"
  }
}

# Internet Gateway and Routing
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.mara.id

  tags = {
    Name = "MaraIGW"
  }
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.mara.id
  cidr_block              = "10.0.1.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1a"

  tags = {
    Name = "MaraPublicSubnet"
    Type = "Public"
  }
}

# Create a second public subnet in a different AZ for High Availability (ALB requirement)
resource "aws_subnet" "public_b" {
  vpc_id                  = aws_vpc.mara.id
  cidr_block              = "10.0.2.0/24"
  map_public_ip_on_launch = true
  availability_zone       = "us-east-1b"

  tags = {
    Name = "MaraPublicSubnetB"
    Type = "Public"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.mara.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  tags = {
    Name = "MaraPublicRT"
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "public_b" {
  subnet_id      = aws_subnet.public_b.id
  route_table_id = aws_route_table.public.id
}

# Security Groups

# Security Group for the ALB
resource "aws_security_group" "alb_sg" {
  name        = "alb_sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = aws_vpc.mara.id

  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"] # Allow HTTP from anywhere
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"] # Allow all outbound traffic
  }

  tags = {
    Name = "alb_sg"
  }
}

# Security Group for Web Instances (Modified)
resource "aws_security_group" "web_sg" {
  name        = "web_sg"
  description = "Security group for web tier instances. Allow SSH and HTTP from ALB only."
  vpc_id      = aws_vpc.mara.id

  # Allow HTTP traffic ONLY from the ALB's security group
  ingress {
    from_port       = 80
    to_port         = 80
    protocol        = "tcp"
    security_groups = [aws_security_group.alb_sg.id] # This is the key change
  }

  # Allow SSH from anywhere (for debugging, restrict this in production!)
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
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
    Name = "web_sg"
  }
}


# The Interesting Part starts here🧑🏽‍💻

# Application Load Balancer Resources

# 1. Create the Target Group
resource "aws_lb_target_group" "web_tg" {
  name     = "web-target-group"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.mara.id
  target_type = "instance"

  # Health check settings. The ALB will use this to know if an instance is healthy.
  health_check {
    path                = "/"
    protocol            = "HTTP"
    port                = "traffic-port"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }

  tags = {
    Name = "WebTargetGroup"
  }
}

# 2. Create the Application Load Balancer
resource "aws_lb" "web_alb" {
  name               = "web-app-alb"
  internal           = false # This makes it an internet-facing ALB
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb_sg.id]
  subnets            = [aws_subnet.public.id, aws_subnet.public_b.id] # ALB needs at least 2 subnets in different AZs

  tags = {
    Name = "WebAppALB"
  }
}

# 3. Create a Listener on the ALB (port 80 -> forward to target group)
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.web_alb.arn
  port              = "80"
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web_tg.arn
  }
}

# Launch Template and Auto Scaling

resource "aws_launch_template" "web" {
  name_prefix            = "web-template-"
  image_id               = "ami-00ca32bbc84273381" # Amazon Linux 2023 AMI in us-east-1, always update this!
  instance_type          = "t3.micro"
  vpc_security_group_ids = [aws_security_group.web_sg.id] # Using security group IDs is more common for LT
  key_name               = "terrakey"           #  Add your existing EC2 Key Pair name here for SSH access

  user_data = base64encode(<<-EOF
    #!/bin/bash
    sudo yum update -y
    sudo yum install -y httpd
    sudo systemctl start httpd
    sudo systemctl enable httpd
    # Create a simple index.html file
    echo "<html><body><h1>Hello World from $(hostname -f) served via the ALB!</h1></body></html>" | sudo tee /var/www/html/index.html
  EOF
  )

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "WebInstance"
      Tier = "Web"
    }
  }

   lifecycle {
     create_before_destroy = true # Good practice for rolling updates with ASG
   }
}

# Create Auto Scaling Group
resource "aws_autoscaling_group" "web_asg" {
  name                = "web-asg"
  desired_capacity    = 2
  max_size            = 3
  min_size            = 1
  vpc_zone_identifier = [aws_subnet.public.id, aws_subnet.public_b.id] # Spread instances across AZs
  target_group_arns   = [aws_lb_target_group.web_tg.arn] # <<< This is crucial: it auto-registers instances

  launch_template {
    id      = aws_launch_template.web.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "WebASGInstance"
    propagate_at_launch = true
  }

  # Wait for instances to pass health checks before continuing
  health_check_type = "ELB"
}

# Output the ALB DNS name to easily access your website
output "alb_dns_name" {
  description = "The DNS name of the Application Load Balancer."
  value       = aws_lb.web_alb.dns_name
}