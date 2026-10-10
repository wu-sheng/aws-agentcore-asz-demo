# ---------------------------------------------------------------------------
# The whole Tier-2 environment. Every AWS resource the demo needs is here, in
# OpenTofu state, so `tofu destroy` (scripts/down.sh) removes all of it:
#
#   - VPC: public + private subnets in 2 AZs, NAT gateway, S3 gateway endpoint
#   - ECR repo for the agent image
#   - asz on ECS/Fargate, /asz/data on EFS
#       * internal load balancer, port 1985: LangSmith receiver (agent -> asz)
#       * public load balancer, port 8787: asz UI, open to asz_ui_cidrs only
#   - the agent on Bedrock AgentCore Runtime, in VPC mode in the private subnets
#
# Created by AWS outside this state (scripts/down.sh handles or reports them):
#   - log groups /aws/bedrock-agentcore/runtimes/<runtime-id>-* (deleted by down.sh)
#   - the AgentCore network service-linked role (account-wide, reported only)
# ---------------------------------------------------------------------------

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  name = var.project_name
  tags = merge({
    Project   = var.project_name
    ManagedBy = "opentofu"
  }, var.tags)

  az_ids = length(var.availability_zone_ids) > 0 ? var.availability_zone_ids : data.aws_availability_zones.available.zone_ids

  asz_ui_port     = 8787
  asz_ingest_port = 1985

  # asz configuration, written to /asz/config/asz.yaml by the init container.
  # Listing adapters replaces asz's defaults: only the LangSmith receiver runs.
  asz_config = yamlencode({
    storage = { root = "/asz/data" }
    adapters = [{
      name      = "langsmith-ingest"
      enabled   = true
      listen    = "0.0.0.0:${local.asz_ingest_port}"
      token     = random_password.asz_ingest_token.result
      collector = { mode = "watch", interval = var.asz_collect_interval }
    }]
  })

  agent_enabled = var.agent_image_tag != ""
}

# Shared secret for the receiver: the agent sends it as LANGSMITH_API_KEY.
resource "random_password" "asz_ingest_token" {
  length  = 32
  special = false
}

# --- VPC --------------------------------------------------------------------
resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.name}-igw" }
}

resource "aws_subnet" "public" {
  count                   = length(var.public_subnet_cidrs)
  vpc_id                  = aws_vpc.this.id
  cidr_block              = var.public_subnet_cidrs[count.index]
  availability_zone_id    = local.az_ids[count.index]
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.name}-public-${count.index}" }
}

resource "aws_subnet" "private" {
  count                = length(var.private_subnet_cidrs)
  vpc_id               = aws_vpc.this.id
  cidr_block           = var.private_subnet_cidrs[count.index]
  availability_zone_id = local.az_ids[count.index]
  tags                 = { Name = "${local.name}-private-${count.index}" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.this.id
  }
  tags = { Name = "${local.name}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = { Name = "${local.name}-nat-eip" }
}

resource "aws_nat_gateway" "this" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id
  tags          = { Name = "${local.name}-nat" }
  depends_on    = [aws_internet_gateway.this]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.this.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.this.id
  }
  tags = { Name = "${local.name}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# AgentCore keeps refreshing the agent image from ECR, whose layers are in S3.
# A gateway endpoint is free and keeps that traffic off the NAT gateway's
# per-GB charge, as the AgentCore VPC guide recommends.
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
  tags              = { Name = "${local.name}-s3" }
}

# --- ECR for the agent image ------------------------------------------------
resource "aws_ecr_repository" "agent" {
  name                 = var.agent_ecr_repo_name
  image_tag_mutability = "MUTABLE"
  force_delete         = true # destroy removes the pushed images too
  image_scanning_configuration {
    scan_on_push = true
  }
}

# --- Security groups --------------------------------------------------------
resource "aws_security_group" "agent" {
  name_prefix = "${local.name}-agent-"
  vpc_id      = aws_vpc.this.id
  description = "AgentCore agent ENIs: outbound only"
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.name}-agent-sg" }
}

resource "aws_security_group" "ingest_lb" {
  name_prefix = "${local.name}-ingest-lb-"
  vpc_id      = aws_vpc.this.id
  description = "asz LangSmith receiver load balancer: from the agent only"
  ingress {
    description     = "LangSmith wire from the AgentCore agent"
    from_port       = local.asz_ingest_port
    to_port         = local.asz_ingest_port
    protocol        = "tcp"
    security_groups = [aws_security_group.agent.id]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
  tags = { Name = "${local.name}-ingest-lb-sg" }
}

resource "aws_security_group" "ui_lb" {
  name_prefix = "${local.name}-ui-lb-"
  vpc_id      = aws_vpc.this.id
  description = "asz UI load balancer: from asz_ui_cidrs only"
  ingress {
    description = "asz UI"
    from_port   = local.asz_ui_port
    to_port     = local.asz_ui_port
    protocol    = "tcp"
    cidr_blocks = var.asz_ui_cidrs
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }
  tags = { Name = "${local.name}-ui-lb-sg" }
}

resource "aws_security_group" "asz" {
  name_prefix = "${local.name}-asz-"
  vpc_id      = aws_vpc.this.id
  description = "asz task: from its two load balancers"
  ingress {
    description     = "receiver"
    from_port       = local.asz_ingest_port
    to_port         = local.asz_ingest_port
    protocol        = "tcp"
    security_groups = [aws_security_group.ingest_lb.id]
  }
  ingress {
    description     = "UI"
    from_port       = local.asz_ui_port
    to_port         = local.asz_ui_port
    protocol        = "tcp"
    security_groups = [aws_security_group.ui_lb.id]
  }
  egress {
    description = "image pulls, logs, EFS"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
  tags = { Name = "${local.name}-asz-sg" }
}

resource "aws_security_group" "efs" {
  name_prefix = "${local.name}-efs-"
  vpc_id      = aws_vpc.this.id
  description = "EFS mount targets: NFS from the asz task"
  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.asz.id]
  }
  tags = { Name = "${local.name}-efs-sg" }
}

# --- EFS for durable /asz/data ---------------------------------------------
resource "aws_efs_file_system" "asz" {
  creation_token = "${local.name}-asz-data"
  encrypted      = true
  tags           = { Name = "${local.name}-asz-data" }
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
    gid = 65532 # distroless nonroot, the user the asz image runs as
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
}

# --- Load balancers ---------------------------------------------------------
resource "aws_lb" "ingest" {
  name               = substr("${local.name}-ingest", 0, 32)
  internal           = true
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ingest_lb.id]
  subnets            = aws_subnet.private[*].id
}

resource "aws_lb_target_group" "ingest" {
  name = substr("${local.name}-ingest", 0, 32)
  # One task, stopped before its replacement starts: nothing to drain, and the
  # default 300s would hold every update and every destroy for five minutes.
  deregistration_delay = 15
  port                 = local.asz_ingest_port
  protocol             = "HTTP"
  vpc_id               = aws_vpc.this.id
  target_type          = "ip"
  health_check {
    path    = "/info" # the receiver's LangSmith /info answers 200
    matcher = "200"
  }
}

resource "aws_lb_listener" "ingest" {
  load_balancer_arn = aws_lb.ingest.arn
  port              = local.asz_ingest_port
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ingest.arn
  }
}

resource "aws_lb" "ui" {
  name               = substr("${local.name}-ui", 0, 32)
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.ui_lb.id]
  subnets            = aws_subnet.public[*].id
}

resource "aws_lb_target_group" "ui" {
  name                 = substr("${local.name}-ui", 0, 32)
  deregistration_delay = 15
  port                 = local.asz_ui_port
  protocol             = "HTTP"
  vpc_id               = aws_vpc.this.id
  target_type          = "ip"
  health_check {
    path    = "/"
    matcher = "200-399"
  }
}

resource "aws_lb_listener" "ui" {
  load_balancer_arn = aws_lb.ui.arn
  port              = local.asz_ui_port
  protocol          = "HTTP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ui.arn
  }
}

# --- asz on ECS/Fargate -----------------------------------------------------
resource "aws_ecs_cluster" "this" {
  name = "${local.name}-cluster"
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
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  role       = aws_iam_role.task_execution.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_cloudwatch_log_group" "asz" {
  name              = "/ecs/${local.name}-asz"
  retention_in_days = 7
}

resource "aws_ecs_task_definition" "asz" {
  family                   = "${local.name}-asz"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.asz_cpu
  memory                   = var.asz_memory
  execution_role_arn       = aws_iam_role.task_execution.arn

  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = "ARM64" # the asz image is multi-arch; Graviton is cheaper
  }

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

  # Task-local scratch volume carrying asz.yaml from the init container.
  volume {
    name = "asz-config"
  }

  container_definitions = jsonencode([
    {
      # The asz image is distroless (no shell), so a one-shot init container
      # writes the configuration file it reads.
      name        = "asz-config"
      image       = "public.ecr.aws/docker/library/busybox:1.37"
      essential   = false
      command     = ["sh", "-c", "printf '%s' \"$ASZ_CONFIG\" > /config/asz.yaml"]
      environment = [{ name = "ASZ_CONFIG", value = local.asz_config }]
      mountPoints = [{ sourceVolume = "asz-config", containerPath = "/config" }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.asz.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "asz-config"
        }
      }
    },
    {
      name      = "asz"
      image     = var.asz_image
      essential = true
      command   = ["server", "-config", "/asz/config/asz.yaml", "0.0.0.0:${local.asz_ui_port}"]
      dependsOn = [{ containerName = "asz-config", condition = "SUCCESS" }]
      portMappings = [
        { containerPort = local.asz_ui_port, protocol = "tcp" },
        { containerPort = local.asz_ingest_port, protocol = "tcp" },
      ]
      mountPoints = [
        { sourceVolume = "asz-data", containerPath = "/asz/data", readOnly = false },
        { sourceVolume = "asz-config", containerPath = "/asz/config", readOnly = true },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.asz.name
          "awslogs-region"        = var.aws_region
          "awslogs-stream-prefix" = "asz"
        }
      }
    },
  ])
}

resource "aws_ecs_service" "asz" {
  name            = "${local.name}-asz"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.asz.arn
  desired_count   = 1 # one writer: asz's storage root is not shared between tasks
  launch_type     = "FARGATE"

  # Stop the old task before starting a new one, so two never write /asz/data.
  deployment_minimum_healthy_percent = 0
  deployment_maximum_percent         = 100

  network_configuration {
    subnets          = aws_subnet.private[*].id
    security_groups  = [aws_security_group.asz.id]
    assign_public_ip = false
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ingest.arn
    container_name   = "asz"
    container_port   = local.asz_ingest_port
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.ui.arn
    container_name   = "asz"
    container_port   = local.asz_ui_port
  }

  depends_on = [aws_lb_listener.ingest, aws_lb_listener.ui, aws_efs_mount_target.asz, aws_route_table_association.private]
}

# --- The agent on Bedrock AgentCore Runtime ---------------------------------
resource "aws_iam_role" "agent" {
  name_prefix = "${substr(local.name, 0, 20)}-agent-"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "bedrock-agentcore.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
      }
    }]
  })
}

resource "aws_iam_role_policy" "agent" {
  name = "agent-runtime"
  role = aws_iam_role.agent.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "PullAgentImage"
        Effect   = "Allow"
        Action   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = aws_ecr_repository.agent.arn
      },
      {
        Sid      = "EcrAuth"
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = "*"
      },
      {
        Sid    = "RuntimeLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams", "logs:DescribeLogGroups"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:/aws/bedrock-agentcore/runtimes/*",
          "arn:${data.aws_partition.current.partition}:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*",
        ]
      },
      {
        Sid      = "Metrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "bedrock-agentcore" }
        }
      },
      {
        Sid      = "InvokeModel"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream", "bedrock:Converse", "bedrock:ConverseStream"]
        Resource = "*"
      },
    ]
  })
}

resource "aws_bedrockagentcore_agent_runtime" "agent" {
  count              = local.agent_enabled ? 1 : 0
  agent_runtime_name = replace("${local.name}_agent", "-", "_") # names allow [a-zA-Z0-9_]
  description        = "LangGraph deployment advisor, traced to asz"
  role_arn           = aws_iam_role.agent.arn

  agent_runtime_artifact {
    container_configuration {
      container_uri = "${aws_ecr_repository.agent.repository_url}:${var.agent_image_tag}"
    }
  }

  # VPC mode: the agent's ENIs sit in the private subnets, reach asz's
  # internal receiver directly, and reach Bedrock/ECR through the NAT gateway.
  network_configuration {
    network_mode = "VPC"
    network_mode_config {
      subnets         = aws_subnet.private[*].id
      security_groups = [aws_security_group.agent.id]
    }
  }

  # Unset = AgentCore's defaults: 15 minutes idle, 8 hours at most.
  lifecycle_configuration = var.agent_idle_session_timeout == null ? null : [{
    idle_runtime_session_timeout = var.agent_idle_session_timeout
    max_lifetime                 = var.agent_max_session_lifetime
  }]

  environment_variables = merge(
    {
      LANGSMITH_TRACING  = "true"
      LANGSMITH_ENDPOINT = "http://${aws_lb.ingest.dns_name}:${local.asz_ingest_port}"
      LANGSMITH_API_KEY  = random_password.asz_ingest_token.result
      LANGSMITH_PROJECT  = var.project_name
      AWS_REGION         = var.aws_region
    },
    var.bedrock_model_id != "" ? { BEDROCK_MODEL_ID = var.bedrock_model_id } : {},
  )

  depends_on = [
    aws_iam_role_policy.agent,
    aws_ecs_service.asz,
    aws_route_table_association.private,
  ]
}
