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
            mountPoints = [
                {
                    sourceVolume = "hfsubset-efs"
                    containerPath = "/efs"
                    readOnly = false
                }
            ]
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
                { name = "EFS_PATH", value = "/efs"}
                
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

    # EFS volume
    volume {
      name = "hfsubset-efs"
      efs_volume_configuration {
        file_system_id = aws_efs_file_system.hfsubset_efs.id
        root_directory = "/"
      }
    }

    tags = {
      Owner = "Lynker Spatial"
    }
}

// ============================================================================
// EFS ========================================================================
// ============================================================================

variable "efs_creation_token" {
  description = "The creation token for the EFS file system"
  type        = string
  default    = "hfsubset-efs"
}

# EFS File system
resource "aws_efs_file_system" "hfsubset_efs" {
  creation_token = var.efs_creation_token
  encrypted      = true

  tags = {
    Name = "hfsubset-efs"
    Owner = "Lynker Spatial"
  }
}

# EFS Mount Target
resource "aws_efs_mount_target" "hfsubset_efs_mount_target" {
  count = length(data.aws_subnet.private.ids)

  file_system_id = aws_efs_file_system.hfsubset_efs.id
  subnet_id      = data.aws_subnet.private.ids[count.index]
}

# EFS Access Point (not sure if we need this)
resource "aws_efs_access_point" "efs_access_point" {
  file_system_id = aws_efs_file_system.hfsubset_efs.id
}

variable "lynker_spatial_s3_bucket_name" {
  description = "The name of the S3 bucket to use for the DataSync task"
  type        = string
  default     = "lynker-spatial"
}

// ============================================================================
// Lynker Spatial S3 Bucket  ========================================================================
// ============================================================================
data "aws_s3_bucket" "lynker_spatial_s3_bucket" {
    bucket = var.lynker_spatial_s3_bucket_name
}

// ============================================================================
// DataSync ========================================================================
// ============================================================================

resource "aws_datasync_location_efs" "datasync_efs_location" {
  efs_file_system_arn = aws_efs_mount_target.hfsubset_efs_mount_target.file_system_arn

  ec2_config {
    security_group_arns = [aws_security_group.hfsubset_sg.arn]
    subnet_arn          = data.aws_subnet.private.ids[0]
  }
}

resource "aws_iam_role" "example" {
  name = "hfsubset-s3-to-efs-datasync-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = {
          Service = "datasync.amazonaws.com",
        },
        Action = "sts:AssumeRole",
      },
    ],
  })
}

# IAM policy document for the DataSync role
data "aws_iam_policy_document" "datasync_policy_document" {
  statement {
    actions = [
    "s3:GetObject",
    "s3:ListBucket",
    "s3:GetBucketLocation",
    "s3:GetObjectTagging",
    "s3:ListObjectV2",
    "s3:CopyObject",
    "elasticfilesystem:DescribeFileSystems",
    "elasticfilesystem:DescribeFileSystemPolicy",
    "elasticfilesystem:ClientMount",
    "elasticfilesystem:ClientWrite",
    "elasticfilesystem:ClientRootAccess"
    ]

    resources = [
      data.aws_s3_bucket.lynker_spatial_s3_bucket.arn,
      "${data.aws_s3_bucket.lynker_spatial_s3_bucket.arn}/*",
    ]
  }
}



resource "aws_datasync_location_s3" "datasync_s3_location" {
  s3_bucket_arn = data.aws_s3_bucket.lynker_spatial_s3_bucket.arn
  subdirectory  = "/hydrofabric"

  s3_config {
    bucket_access_role_arn = aws_iam_role.example.arn
  }
}

// ============================================================================
// DataSync variables for filtering ========================================================================
// ============================================================================

variable "datasync_bucket_filter_v2_2" {
  description = "DataSync bucket filter string for version v2.2"
  type        = string
  default     = "/v2.2/ak/ak_nextgen.gpkg|/v2.2/ak/ak_reference.gpkg|/v2.2/conus/conus_nextgen.gpkg|/v2.2/conus/conus_reference.gpkg|/v2.2/gl/gl_nextgen.gpkg|/v2.2/gl/gl_reference.gpkg|/v2.2/hi/hi_nextgen.gpkg|/v2.2/hi/hi_reference.gpkg|/v2.2/prvi/prvi_nextgen.gpkg|/v2.2/prvi/prvi_reference.gpkg"
}

variable "datasync_bucket_filter_v3_0" {
  description = "DataSync bucket filter string for version v3.0"
  type        = string
  default     = ""
#   default     = "/v3.0/ak/ak_nextgen.gpkg|/v3.0/ak/ak_reference.gpkg|/v3.0/conus/conus_nextgen.gpkg|/v3.0/conus/conus_reference.gpkg|/v3.0/gl/gl_nextgen.gpkg|/v3.0/gl/gl_reference.gpkg|/v3.0/hi/hi_nextgen.gpkg|/v3.0/hi/hi_reference.gpkg|/v3.0/prvi/prvi_nextgen.gpkg|/v3.0/prvi/prvi_reference.gpkg"
}

// ============================================================================
// DataSync Task S3 --> EFS ========================================================================
// ============================================================================
resource "aws_datasync_task" "datasync_s3_to_efs_task" {
  destination_location_arn = aws_datasync_location_efs.datasync_efs_location.arn 
  name                     = "datasync-s3-to-efs-task"
  source_location_arn      = data.aws_datasync_location_s3.source.arn 

  includes {
    filter_type = "SIMPLE_PATTERN"
    # concatonate the datasync_bucket_filter_v2_2 and datasync_bucket_filter_v3_0
    value       = "${var.datasync_bucket_filter_v2_2}|${var.datasync_bucket_filter_v3_0}"
    # value       = "/v2.2/ak/ak_nextgen.gpkg|/v2.2/ak/ak_reference.gpkg|/v2.2/conus/conus_nextgen.gpkg|/v2.2/conus/conus_reference.gpkg|/v2.2/gl/gl_nextgen.gpkg|/v2.2/gl/gl_reference.gpkg|/v2.2/hi/hi_nextgen.gpkg|/v2.2/hi/hi_reference.gpkg|/v2.2/prvi/prvi_nextgen.gpkg|/v2.2/prvi/prvi_reference.gpkg"
  }

}