provider "aws" {
    region = "us-west-2"
}

terraform {
    backend "s3" {
        bucket  = "lynker-spatial-tfstate"
        key     = "hfsubset.tfstate"
        region  = "us-west-2"
        encrypt = "true"
    }
}

// Creates infrastructure to support an ECS service for the hfsubset API.

// ============================================================================
// ECR ========================================================================
// ============================================================================

// hfsubset image, correponds to infra/api.dockerfile in lynker-spatial/hfsubsetCLI
data "aws_ecr_image" "hfsubset_image" {
    repository_name = "hfsubset"
    image_tag = "latest"
}

// ============================================================================
// VPC ========================================================================
// ============================================================================

data "aws_vpc" "default" {
    cidr_block = "10.5.0.0/16"
}

data "aws_subnets" "public" {
    filter {
        name = "vpc-id"
        values = [data.aws_vpc.default.id]
    }

    tags = {
        Visibility = "Public"
    }
}

data "aws_subnets" "private" {
    filter {
        name = "vpc-id"
        values = [data.aws_vpc.default.id]
    }

    tags = {
        Visibility = "Private"
    }
}

data "aws_subnet" "private" {
    for_each = toset(data.aws_subnets.private.ids)
    id = each.value
}

data "aws_ec2_managed_prefix_list" "cloudfront" {
 name = "com.amazonaws.global.cloudfront.origin-facing"
}

resource "aws_security_group" "hfsubset_sg" {
    name = "hfsubset-service"
    vpc_id = data.aws_vpc.default.id
}

resource "aws_vpc_security_group_ingress_rule" "hfsubset_allow_cloudfront" {
    security_group_id = aws_security_group.hfsubset_sg.id
    from_port = 443
    to_port = 443
    ip_protocol = "tcp"
    prefix_list_id = data.aws_ec2_managed_prefix_list.cloudfront.id
}

resource "aws_vpc_security_group_ingress_rule" "hfsubset_allow_https" {
    security_group_id = aws_security_group.hfsubset_sg.id
    from_port = 443
    to_port = 443
    ip_protocol = "tcp"
    cidr_ipv4 = "0.0.0.0/0"
}

resource "aws_vpc_security_group_ingress_rule" "hfsubset_allow_http_ipv4" {
    security_group_id = aws_security_group.hfsubset_sg.id
    cidr_ipv4 = data.aws_vpc.default.cidr_block
    from_port = 80
    ip_protocol = "tcp"
    to_port = 80
}

resource "aws_vpc_security_group_ingress_rule" "hfsubset_allow_8080_ipv4" {
    security_group_id = aws_security_group.hfsubset_sg.id
    cidr_ipv4 = data.aws_vpc.default.cidr_block
    from_port = 8080
    ip_protocol = "tcp"
    to_port = 8080
}

resource "aws_vpc_security_group_ingress_rule" "hfsubset_allow_private_inbound" {
    for_each = toset([for s in data.aws_subnet.private : s.cidr_block])
    security_group_id = aws_security_group.hfsubset_sg.id
    cidr_ipv4 = each.value
    ip_protocol = -1
}

resource "aws_vpc_security_group_egress_rule" "hfsubset_allow_all" {
    security_group_id = aws_security_group.hfsubset_sg.id
    cidr_ipv4 = "0.0.0.0/0"
    ip_protocol = -1
}

// ============================================================================
// ALB ========================================================================
// ============================================================================

resource "aws_lb" "hfsubset_alb" {
    name = "hfsubset-lb"
    internal = false
    load_balancer_type = "application"
    security_groups = [aws_security_group.hfsubset_sg.id]
    subnets = data.aws_subnets.public.ids
    enable_deletion_protection = true

    access_logs {
      enabled = true
      bucket = "lynker-hydrofabric-logs"
      prefix = "hfsubset-logs"
    }
}

resource "aws_lb_target_group" "hfsubset_tg" {
    name = "hfsubset-tg"
    port = 8080
    target_type = "ip"
    protocol = "HTTP"
    vpc_id = data.aws_vpc.default.id
    health_check {
      enabled = true
      protocol = "HTTP"
      path = "/__docs__/"
      port = "traffic-port"
      matcher = "200,404"
      interval = 300
    }
}

resource "aws_lb_listener" "hfsubset_listener" {
    load_balancer_arn = aws_lb.hfsubset_alb.arn
    protocol = "HTTPS"
    port = 443
    certificate_arn = aws_acm_certificate_validation.certificate_validation.certificate_arn

    default_action {
      type = "forward"
      target_group_arn = aws_lb_target_group.hfsubset_tg.arn
    }
}

// ============================================================================
// ACM ========================================================================
// ============================================================================

// CloudFront certificates must be in us-east-1, however ALB certificates
// must be in the same region as the ALB
resource "aws_acm_certificate" "certificate" {
    domain_name = "hfsubset.internal.lynker-spatial.com"
    validation_method = "DNS"

    lifecycle {
      create_before_destroy = true
    }
}

// ============================================================================
// DNS ========================================================================
// ============================================================================

data "aws_route53_zone" "dns_zone" {
    name = "lynker-spatial.com."
}

resource "aws_route53_record" "certificate_validation_records" {
    for_each = {
        for dvo in aws_acm_certificate.certificate.domain_validation_options : dvo.domain_name => {
            name = dvo.resource_record_name
            record = dvo.resource_record_value
            type = dvo.resource_record_type
        }
    }

    allow_overwrite = true
    name = each.value.name
    records = [each.value.record]
    ttl = 60
    type = each.value.type
    zone_id = data.aws_route53_zone.dns_zone.zone_id
}

resource "aws_acm_certificate_validation" "certificate_validation" {
    certificate_arn = aws_acm_certificate.certificate.arn
    validation_record_fqdns = [for record in aws_route53_record.certificate_validation_records : record.fqdn]
}

resource "aws_route53_record" "hfsubset_record" {
    zone_id = data.aws_route53_zone.dns_zone.zone_id
    name = "hfsubset.internal.lynker-spatial.com"
    type = "A"
    alias {
      name = aws_lb.hfsubset_alb.dns_name
      zone_id = aws_lb.hfsubset_alb.zone_id
      evaluate_target_health = true
    }
}

// ============================================================================
// ECS ========================================================================
// ============================================================================

data "aws_iam_role" "ecs_task_execution_role" {
    name = "ecsTaskExecutionRole"
}

resource "aws_ecs_cluster" "hfsubset_cluster" {
    name = "hfsubset_cluster"
}

resource "aws_ecs_service" "hfsubset_ecs" {
    name = "hfsubset_service"
    cluster = aws_ecs_cluster.hfsubset_cluster.id
    task_definition = aws_ecs_task_definition.hfsubset_task_def.arn
    desired_count = 1

    capacity_provider_strategy {
        base = 1
        capacity_provider = "FARGATE"
        weight = 0
    }

    capacity_provider_strategy {
      capacity_provider = "FARGATE_SPOT"
      weight = 2
    }

    network_configuration {
      subnets = data.aws_subnets.private.ids
      security_groups = [aws_security_group.hfsubset_sg.id]
      assign_public_ip = false
    }

    load_balancer {
      container_name = "hfsubset"
      container_port = 8080
      target_group_arn = aws_lb_target_group.hfsubset_tg.arn
    }

    deployment_circuit_breaker {
      enable = true
      rollback = true
    }
    
}

resource "aws_ecs_task_definition" "hfsubset_task_def" {
    family = "service"
    network_mode = "awsvpc"
    cpu = 1024
    memory = 2048
    execution_role_arn = data.aws_iam_role.ecs_task_execution_role.arn
    requires_compatibilities = ["FARGATE"]
    container_definitions = jsonencode([
        {
            name = "hfsubset"
            image = "${data.aws_ecr_image.hfsubset_image.registry_id}.dkr.ecr.us-west-2.amazonaws.com/hfsubset:latest"
            essential = true
            cpu = 0
            mountPoints = []
            systemControls = []
            volumesFrom = []
            portMappings = [{
                containerPort = 8080
                hostPort = 8080
                protocol = "tcp"
            }]
            environment = [
                { name = "HFSUBSET_API_HOST", value = "0.0.0.0" },
                { name = "HFSUBSET_API_PORT", value = "8080" },
                { name = "AWS_NO_SIGN_REQUEST", value = "YES" },
                { name = "AWS_REGION", value = "us-west-2" },
                { name = "AWS_DEFAULT_REGION", value = "us-west-2" }
            ]
            logConfiguration = {
                logDriver = "awslogs"
                options = {
                    "awslogs-create-group" = "true"
                    "awslogs-group" = "/aws/ecs/hfsubset"
                    "awslogs-region" = "us-west-2"
                    "awslogs-stream-prefix" = "hfsubset"
                }
            }
        }
    ])

    tags = {
      Owner = "Lynker Spatial"
    }
}
