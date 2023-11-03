terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-west-2"
}

data "aws_subnets" "lynker_spatial_service_subnets" {
  filter {
    name = "vpc-id"
    values = [
      aws_subnet.lynker_spatial_public_subnet_a.cidr_block,
      aws_subnet.lynker_spatial_public_subnet_b.cidr_block,
      aws_subnet.lynker_spatial_public_subnet_c.cidr_block
    ]
  }
}

//! IAM: provides permissions to assume ECS and ECR roles
data "aws_iam_policy_document" "hfsubset_ecs_task_policy_document" {
  statement {
    actions = ["sts:AssumeRole"]
    effect  = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com", "ecs.amazonaws.com", "ecr.amazonaws.com"]
    }
  }
}

//! IAM: provides permissions for read-only access to S3 bucket
data "aws_iam_policy_document" "hfsubset_s3_access_policy_document" {
  statement {
    effect = "Allow"
    actions = [
      "s3:ListBucket",
      "s3:ListObjects",
      "s3:GetObject"
    ]
    resources = [
      "arn:aws:s3:::lynker-spatial",
      "arn:aws:s3:::lynker-spatial/*"
    ]
  }
}

//! IAM: provides permissions to create ECS cluster nodes, pull from ECR, and logging
data "aws_iam_policy_document" "hfsubset_ecs_exec_policy_document" {
  statement {
    effect = "Allow"
    actions = [
      "ec2:AttachNetworkInterface",
      "ec2:CreateNetworkInterface",
      "ec2:CreateNetworkInterfacePermission",
      "ec2:DeleteNetworkInterface",
      "ec2:DeleteNetworkInterfacePermission",
      "ec2:Describe*",
      "ec2:DetachNetworkInterface",
      "elasticloadbalancing:DeregisterInstancesFromLoadBalancer",
      "elasticloadbalancing:DeregisterTargets",
      "elasticloadbalancing:Describe*",
      "elasticloadbalancing:RegisterInstancesWithLoadBalancer",
      "elasticloadbalancing:RegisterTargets",
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams"
    ]
    resources = ["*"] // FIXME: least privilege
  }
}

# Resources ===================================================================

//! Lynker-Spatial VPC
resource "aws_vpc" "lynker_spatial_vpc" {
  cidr_block                           = "172.25.0.0/16"
  enable_network_address_usage_metrics = true
}

resource "aws_subnet" "lynker_spatial_public_subnet_a" {
  vpc_id            = aws_vpc.lynker_spatial_vpc.id
  cidr_block        = "172.25.1.0/24"
  availability_zone = "us-west-2a"

  tags = {
    Name = "Lynker Spatial Public Subnet A"
  }
}

resource "aws_subnet" "lynker_spatial_public_subnet_b" {
  vpc_id            = aws_vpc.lynker_spatial_vpc.id
  cidr_block        = "172.25.2.0/24"
  availability_zone = "us-west-2b"

  tags = {
    Name = "Lynker Spatial Public Subnet B"
  }
}

resource "aws_subnet" "lynker_spatial_public_subnet_c" {
  vpc_id            = aws_vpc.lynker_spatial_vpc.id
  cidr_block        = "172.25.3.0/24"
  availability_zone = "us-west-2c"

  tags = {
    Name = "Lynker Spatial Public Subnet C"
  }
}

//! ECR Repository
resource "aws_ecr_repository" "hfsubset_ecr" {
  name                 = "hydrofabric-hfsubset"
  image_tag_mutability = "IMMUTABLE"
  image_scanning_configuration {
    scan_on_push = true
  }
}

//! ECS Cluster
resource "aws_ecs_cluster" "hfsubset_ecs" {
  name = "hydrofabric-hfsubset-ecs-cluster"
}

//! IAM Resource for ECS Tasks
resource "aws_iam_role" "hfsubset_ecs_task_role" {
  name               = "hydrofabric-hfsubset-ecs-task-role"
  description        = "Allows attached service to assume ECS and ECR roles"
  assume_role_policy = data.aws_iam_policy_document.hfsubset_ecs_task_policy_document.json
}

//! IAM Resource for ECS Execution
resource "aws_iam_role" "hfsubset_ecs_exec_role" {
  name               = "hydrofabric-hfsubset-ecs-exec-role"
  description        = "Allows attached service to execute ECS tasks, pull from ECR, and output logs"
  assume_role_policy = data.aws_iam_policy_document.hfsubset_ecs_exec_policy_document.json
}

//! IAM Resource for Read-only S3 Access
resource "aws_iam_role" "hfsubset_s3_access_role" {
  name               = "hydrofabric-hfsubset-s3-access-role"
  description        = "Allows attached service read-only access to the lynker-spatial S3 bucket"
  assume_role_policy = data.aws_iam_policy_document.hfsubset_s3_access_policy_document.json
}

//! Application Load Balancer Security Group
resource "aws_security_group" "hfsubset_alb_sg" {
  name        = "hydrofabric-hfsubset-alb-security-group"
  description = "Security group for hfsubset ALB; allows TCP/80 access bidirectionally anywhere."

  ingress {
    description = "TCP/80 incoming from anywhere"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    description = "TCP/80 outgoing to anywhere"
    protocol    = "tcp"
    from_port   = 80
    to_port     = 80
    cidr_blocks = ["0.0.0.0/0"]
  }
}

//! ECS Task Security Group
resource "aws_security_group" "hfsubset_ecs_task_sg" {
  name   = "hydrofabric-hfsubset-ecs-task-security-group"
  vpc_id = aws_vpc.lynker_spatial_vpc.id

  description = "Security group for hfsubset ECS Task; allows TCP/8080 to hfsubset ALB only."

  ingress {
    description     = "TCP/8080 incoming from hfsubset ALB"
    protocol        = "tcp"
    from_port       = 8080
    to_port         = 8080
    security_groups = [aws_security_group.hfsubset_alb_sg.id]
  }

  egress {
    description     = "TCP/8080 outgoing to hfsubset ALB"
    protocol        = "tcp"
    from_port       = 8080
    to_port         = 8080
    security_groups = [aws_security_group.hfsubset_alb_sg.id]
  }
}

//! Application Load Balancer
resource "aws_lb" "hfsubset_alb" {
  name                       = "hydrofabric-hfsubset-alb"
  internal                   = false
  load_balancer_type         = "application"
  enable_deletion_protection = false
  drop_invalid_header_fields = true
  security_groups            = [aws_security_group.hfsubset_alb_sg.id]
  subnets                    = data.aws_subnets.lynker_spatial_service_subnets.ids
}

//! ALB Target Group
resource "aws_lb_target_group" "hfsubset_alb_target_group" {
  name        = "hydrofabric-hfsubset-alb-target"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.lynker_spatial_vpc.id
}

//! ALB Listener
resource "aws_lb_listener" "hfsubset_alb_listener" {
  load_balancer_arn = aws_lb.hfsubset_alb.arn
  port              = "443"
  protocol          = "HTTPS"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.hfsubset_alb_target_group.arn
  }
}

//! ECS Task Definition
resource "aws_ecs_task_definition" "hfsubset_ecs_task_def" {
  family = "hydrofabric-hfsubset-task-definition"
  container_definitions = jsonencode([{
    name   = "hydrofabric-hfsubset-container"
    image  = aws_ecr_repository.hfsubset_ecr.repository_url
    cpu    = 1024 // 1024 CPU units ~ 1 vCPU
    memory = 4096
    portMappings = [
      {
        name          = "hydrofabric-hfsubset-http"
        containerPort = 8080
        hostPort      = 8080
        protocol      = "tcp"
        appProtocol   = "http"
      }
    ]
    essential   = true
    environment = []
    mountPoints = []
    volumesFrom = []
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-create-group" = "true"
        "awslogs-group"        = "/ecs/hydrofabric-hfsubset"
        "awslogs-region"       = "us-west-1"
      }
    }
  }])

  task_role_arn            = aws_iam_role.hfsubset_ecs_task_role.arn
  execution_role_arn       = aws_iam_role.hfsubset_ecs_exec_role.arn
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "4096"

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "X86_64"
  }
}

//! ECS Service
resource "aws_ecs_service" "hfsubset_ecs_service" {
  name            = "hydrofabric-hfsubset-ecs-service"
  cluster         = aws_ecs_cluster.hfsubset_ecs.id
  task_definition = aws_ecs_task_definition.hfsubset_ecs_task_def.arn
  desired_count   = 1
  depends_on      = [aws_lb_listener.hfsubset_alb_listener]
  launch_type     = "FARGATE"

  load_balancer {
    target_group_arn = aws_lb_target_group.hfsubset_alb_target_group.arn
    container_name   = "hydrofabric-hfsubset-container"
    container_port   = 8080
  }

  network_configuration {
    subnets          = data.aws_subnets.lynker_spatial_service_subnets.ids
    assign_public_ip = true
    security_groups  = [aws_security_group.hfsubset_ecs_task_sg.id]
  }
}

