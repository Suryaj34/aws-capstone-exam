terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
 
provider "aws" {
  region = "ap-south-1"
}
 
# Choose two AZs
variable "azs" {
  type    = list(string)
  default = ["ap-south-1a", "ap-south-1b"]
}
 
# Your Ubuntu AMI (us-east-1)
variable "ubuntu_ami" {
  type    = string
  default = "ami-019715e0d74f695be"
}
 
# Where your SSH public key is located locally
variable "ssh_public_key_path" {
  type    = string
  default = "~/.ssh/streamline-key.pub"
}
 
data "aws_vpc" "default" {
  default = true
}
 
# Default-for-az subnets are the AWS-created public subnets
data "aws_subnets" "default_public" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  filter {
    name   = "default-for-az"
    values = ["true"]
  }
}
 
# Pick two public subnets
locals {
  selected_public_subnet_ids = slice(data.aws_subnets.default_public.ids, 0, 2)
}
 
resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = data.aws_vpc.default.id
  # Carve subnets from the VPC CIDR (adds 8 bits, indexes start at 100 to avoid overlap)
  cidr_block              = cidrsubnet(data.aws_vpc.default.cidr_block, 8, count.index + 100)
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false
 
  tags = {
    Name = "streamline-private-${count.index + 1}"
  }
}
 
resource "aws_route_table" "private_rt" {
  vpc_id = data.aws_vpc.default.id
  tags = { Name = "streamline-private-rt" }
}
 
resource "aws_route_table_association" "private_assoc" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private_rt.id
}
 
resource "aws_security_group" "web_sg" {
  name        = "streamline-web-sg"
  description = "Allow HTTP from anywhere and SSH from my IP"
  vpc_id      = data.aws_vpc.default.id
 
  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
ingress {
   description = "SSH from anywhere"
   from_port   = 22
   to_port     = 22
   protocol    = "tcp"
   cidr_blocks = ["0.0.0.0/0"]
}
 
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  tags = { Name = "streamline-web-sg" }
}
 
resource "aws_security_group" "db_sg" {
  name        = "streamline-db-sg"
  description = "Allow MySQL from web SG only"
  vpc_id      = data.aws_vpc.default.id
 
  ingress {
    description     = "MySQL"
    from_port       = 3306
    to_port         = 3306
    protocol        = "tcp"
    security_groups = [aws_security_group.web_sg.id]
  }
 
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
 
  tags = { Name = "streamline-db-sg" }
}
 
 
resource "aws_db_subnet_group" "db_subnets" {
  name       = "streamline-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "streamline-db-subnet-group" }
}
 
resource "aws_db_instance" "mysql" {
  identifier              = "streamline-db1"
  allocated_storage       = 20
  engine                  = "mysql"
  engine_version          = "8.0"
  instance_class          = "db.t3.micro"
  username                = "surya"
  password                = "surya123"   # For demo only. Rotate in real env.
  db_subnet_group_name    = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids  = [aws_security_group.db_sg.id]
  skip_final_snapshot     = true
  publicly_accessible     = false
  multi_az                = false
  deletion_protection     = false
  # Storage type defaults are fine for free-tier
  tags = { Name = "streamline-rds" }
}
 
resource "aws_instance" "web" {
  count                       = 2
  ami                         = var.ubuntu_ami
  instance_type               = "t3.micro"
  subnet_id                   = local.selected_public_subnet_ids[count.index]
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = true
 
  key_name = "02-06-2026-Nvirginia"   # ← use your existing AWS key pair name
 
  tags = {
    Name = "streamline-web-${count.index + 1}"
  }
}
 
resource "aws_lb" "app_lb" {
  name               = "streamline-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = local.selected_public_subnet_ids
  tags               = { Name = "streamline-alb" }
}
 
resource "aws_lb_target_group" "tg" {
  name     = "streamline-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = data.aws_vpc.default.id
 
  health_check {
    path                = "/"
    healthy_threshold   = 2
    unhealthy_threshold = 2
    timeout             = 5
    interval            = 30
    matcher             = "200-399"
  }
 
  tags = { Name = "streamline-tg" }
}
 
resource "aws_lb_target_group_attachment" "attach" {
  count            = 2
  target_group_arn = aws_lb_target_group.tg.arn
  target_id        = aws_instance.web[count.index].id
  port             = 80
}
 
resource "aws_lb_listener" "listener" {
  load_balancer_arn = aws_lb.app_lb.arn
  port              = 80
  protocol          = "HTTP"
 
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.tg.arn
  }
}
 

output "alb_dns_name" {
  value = aws_lb.app_lb.dns_name
}
 
output "web_public_ips" {
  value = aws_instance.web[*].public_ip
}
 
output "rds_endpoint" {
  value = aws_db_instance.mysql.address
}
