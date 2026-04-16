# ── Datos ─────────────────────────────────────────────────────────────────────

data "aws_availability_zones" "available" {
  state = "available"

  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_caller_identity" "current" {}

# ── Locales ───────────────────────────────────────────────────────────────────

locals {
  azs          = slice(data.aws_availability_zones.available.names, 0, 2)
  public_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 1)]

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}

# ── Red ───────────────────────────────────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = merge(local.tags, { Name = "${var.project}-vpc" })
}

resource "aws_subnet" "public" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.public_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, { Name = "${var.project}-public-${local.azs[count.index]}" })
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = merge(local.tags, { Name = "${var.project}-igw" })
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = merge(local.tags, { Name = "${var.project}-public-rt" })
}

resource "aws_route_table_association" "public" {
  count          = length(aws_subnet.public)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# ── Seguridad ─────────────────────────────────────────────────────────────────

resource "aws_security_group" "ecs" {
  name        = "${var.project}-ecs-sg"
  description = "Trafico para los contenedores Fargate y el proxy Service Connect"
  vpc_id      = aws_vpc.main.id

  # Puerto 80 desde Internet → servicio Web accesible directamente por el navegador
  ingress {
    description = "HTTP desde Internet al servicio Web"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # Puerto 80 entre tareas del cluster (Service Connect para el servicio Web)
  ingress {
    description = "Puerto 80 entre tareas ECS (Service Connect)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    self        = true
  }

  # Puerto 8080 entre tareas del cluster (Web → API via Service Connect)
  ingress {
    description = "Puerto 8080 entre tareas ECS (Web llama a API)"
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    self        = true
  }

  # El proxy Envoy de Service Connect usa el rango 15000–15010 internamente
  ingress {
    description = "Proxy Envoy de Service Connect entre tareas"
    from_port   = 15000
    to_port     = 15010
    protocol    = "tcp"
    self        = true
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-ecs-sg" })
}

# ── Ciclo de Vida de Imágenes: Repositorio ECR ────────────────────────────────

resource "aws_ecr_repository" "app" {
  name                 = "${var.project}/api"
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = merge(local.tags, { Name = "${var.project}-ecr" })
}

resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Mantener solo las 10 imagenes mas recientes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = {
        type = "expire"
      }
    }]
  })
}

# ── Inyección de Secretos: SSM Parameter Store ────────────────────────────────

resource "aws_ssm_parameter" "api_key" {
  name        = "/${var.project}/api-key"
  description = "Clave de API compartida entre los microservicios Web y API"
  type        = "SecureString"
  value       = var.api_key

  tags = merge(local.tags, { Name = "${var.project}-api-key" })
}

# ── CloudWatch Logs ────────────────────────────────────────────────────────────

resource "aws_cloudwatch_log_group" "web" {
  name              = "/ecs/${var.project}/web"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/ecs/${var.project}/api"
  retention_in_days = 7
  tags              = local.tags
}

# ── IAM ───────────────────────────────────────────────────────────────────────

resource "aws_iam_role" "execution" {
  name = "${var.project}-execution-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "${var.project}-execution-role" })
}

resource "aws_iam_role_policy_attachment" "execution_basic" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role_policy" "ssm_read" {
  name = "${var.project}-ssm-read"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssm:GetParameters",
        "kms:Decrypt"
      ]
      Resource = [
        aws_ssm_parameter.api_key.arn,
        "arn:aws:kms:${var.region}:${data.aws_caller_identity.current.account_id}:alias/aws/ssm"
      ]
    }]
  })
}

resource "aws_iam_role" "task" {
  name = "${var.project}-task-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.tags, { Name = "${var.project}-task-role" })
}

resource "aws_iam_role_policy" "execute_command" {
  name = "${var.project}-execute-command"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel"
      ]
      Resource = "*"
    }]
  })
}

# ── Cluster ECS ───────────────────────────────────────────────────────────────

resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = merge(local.tags, { Name = "${var.project}-cluster" })
}

# ── Malla de Servicios: Namespace de Service Connect ──────────────────────────

resource "aws_service_discovery_http_namespace" "main" {
  name        = var.project
  description = "Namespace Service Connect del cluster ${var.project}"
  tags        = local.tags
}

# ── Task Definition: Servicio Web ─────────────────────────────────────────────
# Sirve la página HTML. nginx escucha en el puerto 80 y hace proxy_pass
# a http://api:8080/ (resuelto por Service Connect) para /api-data.

resource "aws_ecs_task_definition" "web" {
  family                   = "${var.project}-web"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "web"
    image     = var.container_image
    essential = true
    cpu       = 256
    memory    = 512

    command = ["/bin/sh", "-c", file("${path.module}/startup.sh")]

    portMappings = [{
      name          = "web-http"
      containerPort = 80
      protocol      = "tcp"
      appProtocol   = "http"
    }]

    secrets = [{
      name      = "API_KEY"
      valueFrom = aws_ssm_parameter.api_key.arn
    }]

    environment = [
      { name = "APP_ENV",     value = "production" },
      { name = "APP_REGION",  value = var.region },
      { name = "APP_PROJECT", value = var.project },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.web.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "web"
      }
    }
  }])

  tags = merge(local.tags, { Name = "${var.project}-web-task-def" })
}

# ── Task Definition: Microservicio API ────────────────────────────────────────
# Sirve una respuesta JSON con metadatos de la tarea ECS.
# nginx escucha en el puerto 8080, accesible únicamente via Service Connect.

resource "aws_ecs_task_definition" "api" {
  family                   = "${var.project}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "api"
    image     = var.container_image
    essential = true
    cpu       = 256
    memory    = 512

    command = ["/bin/sh", "-c", file("${path.module}/startup-api.sh")]

    portMappings = [{
      name          = "api-http"
      containerPort = 8080
      protocol      = "tcp"
      appProtocol   = "http"
    }]

    # El servicio API necesita la clave para validar el header X-API-Key
    # en cada petición entrante. startup-api.sh embebe el valor en el
    # bloque map{} del config de nginx en tiempo de arranque.
    secrets = [{
      name      = "API_KEY"
      valueFrom = aws_ssm_parameter.api_key.arn
    }]

    environment = [
      { name = "APP_ENV",     value = "production" },
      { name = "APP_REGION",  value = var.region },
      { name = "APP_PROJECT", value = var.project },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "api"
      }
    }
  }])

  tags = merge(local.tags, { Name = "${var.project}-api-task-def" })
}

# ── Servicio ECS: Web ─────────────────────────────────────────────────────────

resource "aws_ecs_service" "web" {
  name            = "${var.project}-web"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.web.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  # El servicio Web se registra como servidor ("web" DNS) Y como cliente
  # que puede llamar a "api:8080". Ambos roles en el mismo namespace.
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    service {
      port_name      = "web-http"
      discovery_name = "web"

      client_alias {
        port     = 80
        dns_name = "web"
      }
    }

    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.web.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "service-connect-web"
      }
    }
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  depends_on = [
    aws_iam_role_policy_attachment.execution_basic,
    aws_iam_role_policy.ssm_read,
  ]

  tags = merge(local.tags, { Name = "${var.project}-web-service" })
}

# ── Servicio ECS: API ─────────────────────────────────────────────────────────

resource "aws_ecs_service" "api" {
  name            = "${var.project}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.desired_count
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  # El servicio API se registra como "api" en el namespace.
  # El servicio Web llama a http://api:8080/ y Service Connect enruta
  # la petición a cualquiera de las tareas activas del servicio API.
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    service {
      port_name      = "api-http"
      discovery_name = "api"

      client_alias {
        port     = 8080
        dns_name = "api"
      }
    }

    log_configuration {
      log_driver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.api.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "service-connect-api"
      }
    }
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  depends_on = [
    aws_iam_role_policy_attachment.execution_basic,
    aws_iam_role_policy.ssm_read,
  ]

  tags = merge(local.tags, { Name = "${var.project}-api-service" })
}
