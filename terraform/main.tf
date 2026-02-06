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

########################
# VARIABLES
########################

variable "azs" {
  type    = list(string)
  default = ["ap-south-1a", "ap-south-1b"]
}

variable "ubuntu_ami" {
  type    = string
  default = "ami-019715e0d74f695be"
}

########################
# DATA SOURCES
########################

data "aws_vpc" "default" {
  default = true
}

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

locals {
  selected_public_subnet_ids = slice(data.aws_subnets.default_public.ids, 0, 2)
}

########################
# PRIVATE SUBNETS
########################

resource "aws_subnet" "private" {
  count                   = 2
  vpc_id                  = data.aws_vpc.default.id
  cidr_block              = cidrsubnet(data.aws_vpc.default.cidr_block, 8, count.index + 100)
  availability_zone       = var.azs[count.index]
  map_public_ip_on_launch = false

  tags = {
    Name = "streamline-private-${count.index + 1}"
  }
}

resource "aws_route_table" "private_rt" {
  vpc_id = data.aws_vpc.default.id

  tags = {
    Name = "streamline-private-rt"
  }
}

resource "aws_route_table_association" "private_assoc" {
  count          = 2
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private_rt.id
}

########################
# SECURITY GROUPS
########################

resource "aws_security_group" "web_sg" {
  name        = "streamline-web-sg-new"
  description = "Allow HTTP and SSH"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    description = "HTTP"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "SSH"
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

  tags = {
    Name = "streamline-web-sg-new"
  }
}

resource "aws_security_group" "db_sg" {
  name        = "streamline-db-sg"
  description = "Allow MySQL from web SG"
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

  tags = {
    Name = "streamline-db-sg"
  }
}

########################
# RDS
########################

resource "aws_db_subnet_group" "db_subnets" {
  name       = "streamline-db-subnet-group"
  subnet_ids = aws_subnet.private[*].id

  tags = {
    Name = "streamline-db-subnet-group"
  }
}

resource "aws_db_instance" "mysql" {
  identifier             = "streamline-db"
  allocated_storage      = 20
  engine                 = "mysql"
  engine_version         = "8.0"
  instance_class         = "db.t3.micro"
  username               = "surya"
  password               = "surya123"
  db_subnet_group_name   = aws_db_subnet_group.db_subnets.name
  vpc_security_group_ids = [aws_security_group.db_sg.id]

  skip_final_snapshot = true
  publicly_accessible = false
  deletion_protection = false
  multi_az            = false

  tags = {
    Name = "streamline-rds"
  }
}

########################
# EC2
########################

resource "aws_instance" "web" {
  count                       = 2
  ami                         = var.ubuntu_ami
  instance_type               = "t3.micro"
  subnet_id                   = local.selected_public_subnet_ids[count.index]
  vpc_security_group_ids      = [aws_security_group.web_sg.id]
  associate_public_ip_address = true

  key_name = "dec-25-surya-mum"

  tags = {
    Name = "streamline-web-${count.index + 1}"
  }
}

########################
# ALB
########################

resource "aws_lb" "app_lb" {
  name               = "streamline-alb"
  internal           = false
  load_balancer_type = "application"
  subnets            = local.selected_public_subnet_ids

  security_groups = [aws_security_group.web_sg.id]

  tags = {
    Name = "streamline-alb"
  }
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

  tags = {
    Name = "streamline-tg"
  }
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

########################
# OUTPUTS
########################

output "alb_dns_name" {
  value = aws_lb.app_lb.dns_name
}

output "web_public_ips" {
  value = aws_instance.web[*].public_ip
}

output "rds_endpoint" {
  value = aws_db_instance.mysql.address
}
