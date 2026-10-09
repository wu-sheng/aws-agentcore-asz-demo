# ---------------------------------------------------------------------------
# Infra for the asz collector (persistent service) + the agent's ECR repo.
#
#   - VPC with public + private subnets across 2 AZs
#   - ECR repo for the LangGraph agent image (AgentCore pulls from here)
#   - EFS for asz durable /asz/data (survives Fargate task restarts)
#   - ECS/Fargate service running the official asz image
#   - ALB fronting asz:asz_port so the AgentCore microVM can POST traces
#
# The LangGraph agent itself is NOT deployed by Terraform — it is registered on
# AgentCore Runtime via the starter toolkit (scripts/deploy-agent.sh), which is
# outside Terraform's resource model.
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

locals {
  name = var.project_name
  tags = merge({
    Project   = var.project_name
    ManagedBy = "opentofu"
  }, var.tags)
}

# --- VPC --------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = merge(local.tags, { Name = "${local.name}-vpc" })
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = merge(local.tags, { Name = "${local.name}-igw" })
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
  tags                    = merge(local.tags, { Name = "${local.name}-public-${count.index}" })
}

resource "aws_subnet" "private" {
  count             = length(var.private_subnet_cidrs)
  vpc_id            = aws_vpc.this.id
  cidr_block        = var.private_subnet_cidrs[count.index]
  availability_zone = data.aws_availability_zones.available.names[count.index]
  tags              = merge(local.tags, { Name = "${local.name}-private-${count.index}" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = merge(local.tags, { Name = "${local.name}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${local.name}-nat-eip" })
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = merge(local.tags, { Name = "${local.name}-nat" })
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
  tags = merge(local.tags, { Name = "${local.name}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# --- ECR for the agent image ------------------------------------------------
resource "aws_ecr_repository" "agent" {
  name                 = var.agent_ecr_repo_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true # PoC convenience; remove for production
  image_scanning_configuration {
    scan_on_push = true
  }
  tags = local.tags
}

# --- Security groups --------------------------------------------------------
resource "aws_security_group" "alb" {
  name_prefix = "${local.name}-alb-"
  vpc_id      = aws_vpc.this.id
  description = "asz ALB ingress"

  ingress {
    description = "asz port from allowed CIDRs (AgentCore microVM must be here)"
    from_port   = var.asz_port
    to_port     = var.asz_port
    protocol    = "tcp"
    cidr_blocks = var.asz_ingress_cidrs
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${local.name}-alb-sg" })
}

resource "aws_security_group" "asz" {
  name_prefix = "${local.name}-asz-"
  vpc_id      = aws_vpc.this.id
  description = "asz task"

  ingress {
    description     = "from ALB only"
    from_port       = var.asz_port
    to_port         = var.asz_port
    protocol        = "tcp"
    security_groups = [aws_security_group.alb.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = merge(local.tags, { Name = "${local.name}-asz-sg" })
}

resource "aws_security_group" "efs" {
  name_prefix = "${local.name}-efs-"
  vpc_id      = aws_vpc.this.id
  description = "EFS mount targets"

  ingress {
    description     = "NFS from asz task"
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.asz.id]
  }
  tags = merge(local.tags, { Name = "${local.name}-efs-sg" })
}

# --- EFS for durable /asz/data ---------------------------------------------
resource "aws_efs_file_system" "asz" {
  creation_token = "${local.name}-asz-data"
  encrypted      = true
  tags           = merge(local.tags, { Name = "${local.name}-asz-data" })
}

resource "aws_efs_mount_target" "asz" {
  count           = length(aws_subnet.private)
  file_system_id  = aws_efs_file_system.asz.id
  subnet_id       = aws_subnet.private[count.index].id
  security_groups = [aws_security_group.efs.id]
}

resource "aws_efs_access_point" "asz" {
  file_system_id = aws_efs_file_system.asz.id
  posix_user {
    gid = 65532 # distroless nonroot
    uid = 65532
  }
  root_directory {
    path = "/asz-data"
    creation_info {
      owner_gid   = 65532
      owner_uid   = 65532
      permissions = "0755"
    }
  }
  tags = local.tags
}

# --- ALB --------------------------------------------------------------------
resource "aws_lb" "asz" {
  name               = substr("${local.name}-alb", 0, 32)
  internal           = var.asz_alb_internal
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.asz_alb_internal ? aws_subnet.private[*].id : aws_subnet.public[*].id
  tags               = local.tags
}

resource "aws_lb_target_group" "asz" {
  name        = substr("${local.name}-tg", 0, 32)
  port        = var.asz_port
  protocol    = "HTTP"
  vpc_id      = aws_vpc.this.id
  target_type = "ip"
  health_check {
    path                = "/"
    matcher             = "200-399"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
  tags = local.tags
}

resource "aws_lb_listener" "asz" {
  load_balancer_arn = aws_lb.asz.arn
  port              = var.asz_port
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.asz.arn
  }
}

# --- ECS cluster + Fargate service for asz ---------------------------------
resource "aws_ecs_cluster" "this" {
  name = "${local.name}-cluster"
  tags = local.tags
}

resource "aws_iam_role" "task_execution" {
  name_prefix = "${substr(local.name, 0, 20)}-exec-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
    }]
  })
  tags = local.tags
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "asz" {
  name              = "/ecs/${local.name}-asz"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_ecs_task_definition" "asz" {
  family                   = "${local.name}-asz"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.asz_cpu
  memory                   = var.asz_memory
  execution_role_arn       = aws_iam_role.task_execution.arn

  volume {
    name = "asz-data"
    efs_volume_configuration {
      file_system_id     = aws_efs_file_system.asz.id
      transit_encryption = "ENABLED"
      authorization_config {
        access_point_id = aws_efs_access_point.asz.id
        iam             = "DISABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "asz"
    image     = var.asz_image
    essential = true
    command   = ["server", "0.0.0.0:${var.asz_port}"]
    portMappings = [{
      containerPort = var.asz_port
      protocol      = "tcp"
    }]
    mountPoints = [{
      sourceVolume  = "asz-data"
      containerPath = "/asz/data"
      readOnly      = false
    }]
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.asz.name
        "awslogs-region"        = var.aws_region
        "awslogs-stream-prefix" = "asz"
      }
    }
  }])

  tags = local.tags
}

resource "aws_ecs_service" "asz" {
  name            = "${local.name}-asz"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.asz.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.asz.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.asz.arn
    container_name   = "asz"
    container_port   = var.asz_port
  }

  depends_on = [aws_lb_listener.asz, aws_efs_mount_target.asz]
  tags       = local.tags
}
