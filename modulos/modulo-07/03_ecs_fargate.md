# Sección 3 — Contenedores: Amazon ECS y Fargate

> [← Sección anterior](./02_asg_load_balancers.md) | [Siguiente →](./04_lambda_api_gateway.md)

---

## 3.1 ECR: Elastic Container Registry

Antes de ejecutar contenedores, necesitas un lugar donde almacenar tus imágenes Docker. ECR es el registro privado de AWS — el Docker Hub de tu organización, pero con integración nativa con IAM, ECS, EKS y Lambda.

> *"ECR no es solo un sitio donde guardar imágenes. Es el control de calidad de tu pipeline: si la imagen no pasa el escaneo de CVEs, no llega a producción. Si alguien intenta sobreescribir una imagen en prod, el tag inmutable lo bloquea."*

```hcl
# ── Repositorio ECR ──
resource "aws_ecr_repository" "app" {
  name                 = "${var.project}/app"
  image_tag_mutability = "IMMUTABLE"   # Evita sobrescribir tags en producción

  image_scanning_configuration {
    scan_on_push = true   # Escaneo automático de CVEs al hacer push
  }

  encryption_configuration {
    encryption_type = "KMS"
  }
}

# ── Lifecycle: conservar solo las 10 últimas imágenes ──
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Keep last 10 images"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
```

**`image_tag_mutability = "IMMUTABLE"`** es especialmente crítico en producción: si pudieras sobreescribir el tag `v1.2.3`, ¿cómo sabes qué código estás ejecutando realmente? La inmutabilidad garantiza que `v1.2.3` siempre apunta al mismo código exacto.

Las lifecycle policies evitan que el registry crezca indefinidamente. Sin ellas, un pipeline activo puede acumular cientos de imágenes en semanas, generando costes innecesarios.

---

## 3.2 `aws_ecs_cluster`: El Plano de Control

El cluster ECS es el plano de control — el componente que sabe qué tasks están ejecutándose y en qué compute. Con Fargate, no hay instancias EC2 que gestionar: AWS se encarga de toda la infraestructura subyacente.

```hcl
resource "aws_ecs_cluster" "main" {
  name = "${var.project}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"   # Métricas CPU/Mem por task en CloudWatch
  }

  configuration {
    execute_command_configuration {
      logging = "OVERRIDE"
      log_configuration {
        cloud_watch_log_group_name = aws_cloudwatch_log_group.ecs.name
      }
    }
  }
}

# ── Log Group para ECS Exec (acceso shell a contenedores) ──
resource "aws_cloudwatch_log_group" "ecs" {
  name              = "/ecs/${var.project}"
  retention_in_days = 30
}
```

**Container Insights** activa métricas detalladas a nivel de task y servicio (CPU, memoria, red), y centraliza los logs en CloudWatch. Tiene un coste adicional por métrica, pero en producción es indispensable para detectar problemas.

`execute_command_configuration` habilita **ECS Exec** — la capacidad de hacer `aws ecs execute-command` para abrir un shell en un contenedor Fargate, similar al `kubectl exec` de Kubernetes. Invaluable para debugging.

---

## 3.3 Launch Types: Fargate vs. EC2 vs. External

| Launch Type | Control | Gestión | Ideal para |
|------------|---------|---------|-----------|
| **FARGATE** | Sin acceso al host | AWS gestiona todo | 90% de los casos — microservicios |
| **EC2** | Acceso total al SO | Tú gestionas AMI y ASG | GPUs, hardware especial, RI/SP |
| **EXTERNAL** | On-premises | SSM Agent + ECS Agent | ECS Anywhere — orquestación híbrida |

Para la mayoría de los proyectos, **Fargate es la elección correcta**: no gestionas parches del SO, no necesitas configurar AMIs ECS optimizadas, no tienes que calcular el bin-packing de contenedores en instancias.

---

## 3.4 `aws_ecs_task_definition`: El Blueprint del Contenedor

La Task Definition es la especificación que dice **qué ejecutar**: qué imagen Docker, con cuánta CPU y memoria, qué puertos exponer, qué variables de entorno inyectar, y con qué permisos IAM.

> *"La Task Definition en ECS es lo que el Dockerfile es para construir la imagen. Es el contrato que describe el contenedor. Cada cambio genera una nueva revisión numerada — ECS es inmutable por diseño."*

```hcl
resource "aws_ecs_task_definition" "api" {
  family                   = "${var.project}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"   # Obligatorio para Fargate: ENI propia por task
  cpu                      = 256        # 0.25 vCPU
  memory                   = 512        # 512 MB

  execution_role_arn = aws_iam_role.ecs_exec.arn   # Permisos del agente ECS
  task_role_arn      = aws_iam_role.ecs_task.arn   # Permisos de tu aplicación

  container_definitions = jsonencode([{
    name      = "${var.project}-api"
    image     = "${aws_ecr_repository.api.repository_url}:latest"
    essential = true

    portMappings = [{
      containerPort = 8080
      protocol      = "tcp"
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"  = aws_cloudwatch_log_group.ecs.name
        "awslogs-region" = var.region
      }
    }
  }])
}
```

Cada vez que cambias algo en la Task Definition y haces `terraform apply`, ECS crea una nueva revisión (`:1`, `:2`, `:3`...). El rollback es tan simple como apuntar el Service a una revisión anterior.

---

## 3.5 `jsonencode`: Definiciones Nativas en HCL

Las `container_definitions` de ECS son un JSON array. Históricamente se escribía como un heredoc (`<<EOF`), lo que era frágil y difícil de mantener. La función `jsonencode()` transforma estructuras HCL nativas a JSON válido, permitiendo usar variables y expresiones directamente:

```hcl
# ❌ Antes (string JSON, propenso a errores de escapado):
container_definitions = <<EOF
[{"name":"api","image":"...","cpu":256}]
EOF

# ✅ Ahora (jsonencode — variables HCL nativas):
container_definitions = jsonencode([{
  name      = "api"
  image     = var.image_url   # Variables directamente
  cpu       = var.cpu
  memory    = var.memory
  essential = true

  portMappings = [{
    containerPort = var.port
    protocol      = "tcp"
  }]

  environment = [
    { name = "ENV", value = var.environment },
    { name = "PORT", value = tostring(var.port) }
  ]

  logConfiguration = {
    logDriver = "awslogs"
    options = {
      "awslogs-group"  = local.log_group
      "awslogs-region" = var.region
    }
  }
}])
```

---

## 3.6 Sidecar y Secrets en Container Definitions

Un task de ECS puede contener múltiples contenedores. El patrón **sidecar** añade un contenedor auxiliar (Datadog Agent, Envoy proxy, Fluent Bit) que comparte ciclo de vida con el contenedor principal:

```hcl
container_definitions = jsonencode([
  # Contenedor principal de la app
  {
    name      = "${var.project}-api"
    image     = "${local.ecr_url}:${var.tag}"
    essential = true   # Si este falla, el task falla
    cpu       = var.cpu
    memory    = var.memory
    # ...
  },
  # Sidecar: Datadog Agent
  {
    name      = "datadog-agent"
    image     = "public.ecr.aws/datadog/agent:latest"
    essential = false   # Si falla, el task sigue funcionando
    cpu       = 128
    memory    = 256

    # Secrets inyectados desde SSM/Secrets Manager
    secrets = [
      {
        name      = "DD_API_KEY"
        valueFrom = aws_ssm_parameter.dd_key.arn
      },
      {
        name      = "DB_PASSWORD"
        valueFrom = aws_secretsmanager_secret.db.arn
      }
    ]

    environment = [
      { name = "ECS_FARGATE", value = "true" }
    ]
  }
])
```

---

## 3.7 IAM: Execution Role vs. Task Role

Este es uno de los puntos de confusión más comunes en ECS. Hay dos roles IAM distintos con propósitos completamente diferentes:

| | **Execution Role** | **Task Role** |
|--|-------------------|--------------|
| Quién lo usa | El agente ECS | Tu aplicación/contenedor |
| Para qué | Pull ECR, enviar logs, obtener secrets | Acceder a S3, DynamoDB, SQS, etc. |
| Obligatorio | Sí (siempre con Fargate) | No (solo si la app accede a AWS) |
| Policy managed | `AmazonECSTaskExecutionRolePolicy` | Permisos específicos de tu app |

```hcl
# ── Trust Policy: solo ECS puede asumir estos roles ──
data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# ── Execution Role: permisos del agente ECS ──
resource "aws_iam_role" "ecs_exec" {
  name               = "${var.project}-ecs-exec-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy_attachment" "exec" {
  role       = aws_iam_role.ecs_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ── Task Role: permisos de tu aplicación ──
resource "aws_iam_role" "task" {
  name               = "${var.project}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json
}

resource "aws_iam_role_policy" "task" {
  name = "app-permissions"
  role = aws_iam_role.task.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:PutObject"]
        Resource = "${aws_s3_bucket.data.arn}/*"
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage", "sqs:ReceiveMessage"]
        Resource = aws_sqs_queue.tasks.arn
      }
    ]
  })
}
```

---

## 3.8 Secrets Management: SSM y Secrets Manager

ECS puede inyectar secrets como variables de entorno en el contenedor sin exponerlos en el código. Los secrets se referencian en `container_definitions` con el bloque `secrets`, y el Execution Role necesita permisos para leerlos:

```hcl
# ── SSM Parameter Store (gratis, ideal para configs) ──
resource "aws_ssm_parameter" "api_key" {
  name  = "/${var.project}/api-key"
  type  = "SecureString"
  value = var.api_key
}

# En container_definitions:
secrets = [
  {
    name      = "API_KEY"
    valueFrom = aws_ssm_parameter.api_key.arn
  }
]

# ── Secrets Manager (rotación automática, para DB credentials) ──
resource "aws_secretsmanager_secret" "db" {
  name = "${var.project}/db-creds"
}

resource "aws_secretsmanager_secret_version" "db" {
  secret_id = aws_secretsmanager_secret.db.id
  secret_string = jsonencode({
    username = var.db_user
    password = var.db_pass
  })
}

# En container_definitions — extraer un campo específico del JSON:
secrets = [
  {
    name      = "DB_USER"
    valueFrom = "${aws_secretsmanager_secret.db.arn}:username::"
  },
  {
    name      = "DB_PASS"
    valueFrom = "${aws_secretsmanager_secret.db.arn}:password::"
  }
]
```

**Decisión SSM vs. Secrets Manager**: SSM Parameter Store es gratuito para el tier standard y suficiente para la mayoría de los casos. Secrets Manager cuesta ~$0.40/secret/mes pero añade rotación automática con Lambda — esencial para credenciales de bases de datos.

---

## 3.9 `aws_ecs_service`: El Orquestador de Tasks

El Service es lo que mantiene tu aplicación viva. Define cuántas réplicas de la Task Definition ejecutar (`desired_count`) y gestiona el rolling deployment, el health check y la integración con el load balancer.

```hcl
resource "aws_ecs_service" "api" {
  name            = "${var.project}-api"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.api.arn
  desired_count   = var.replicas
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false   # Privadas: acceso a internet vía NAT Gateway
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"        # Nombre en container_definitions
    container_port   = 8080
  }

  deployment_minimum_healthy_percent = 100   # Siempre mínimo el 100% activo
  deployment_maximum_percent         = 200   # Permite hasta el doble durante el deploy
  health_check_grace_period_seconds  = 60

  lifecycle {
    ignore_changes = [desired_count]   # App Auto Scaling controla desired_count
  }
}
```

**Estrategia de deployment por defecto**: Rolling update. Con `minimum_healthy_percent = 100` y `maximum_percent = 200`, ECS lanza las tasks nuevas **antes** de terminar las antiguas, garantizando zero downtime durante el deployment.

---

## 3.10 Deployment Circuit Breaker: Rollback Automático

Si el nuevo deployment falla repetidamente el health check, sin circuit breaker las tasks entrarían en un crash-loop indefinido. El circuit breaker detecta el patrón y revierte automáticamente:

```hcl
resource "aws_ecs_service" "api" {
  # ...

  deployment_circuit_breaker {
    enable   = true
    rollback = true   # Restaurar la task_definition anterior automáticamente
  }

  deployment_controller {
    type = "ECS"   # ECS (rolling) | CODE_DEPLOY (blue/green)
  }

  # Rollback adicional si una CloudWatch Alarm dispara
  alarms {
    alarm_names = [aws_cloudwatch_metric_alarm.svc_5xx.alarm_name]
    enable      = true
    rollback    = true
  }

  deployment_minimum_healthy_percent = 100
  deployment_maximum_percent         = 200
  health_check_grace_period_seconds  = 60
}
```

**Flujo del circuit breaker**:
1. Se despliega nueva task_definition
2. La nueva task falla el health check (crash, OOM, error 500)
3. ECS reintenta según la política de deployment
4. Tras N fallos consecutivos: **CIRCUIT OPEN**
5. Con `rollback = true`: restaura la task_definition anterior
6. Service vuelve a estado estable

---

## 3.11 Integración ALB: Target Type `ip` para Fargate

Fargate requiere `target_type = "ip"` en el Target Group porque cada task tiene su propia ENI con IP propia (modo `awsvpc`). A diferencia de EC2, no hay una instancia host que registrar:

```hcl
# ── Target Group para Fargate ──
resource "aws_lb_target_group" "api" {
  name        = "${var.project}-api"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = module.vpc.vpc_id
  target_type = "ip"   # Requerido para Fargate (no "instance")

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
    matcher             = "200"
  }

  deregistration_delay = 60   # 60s para drenar antes de terminar la task
}

# ── Service registra las IPs de las tasks automáticamente ──
resource "aws_ecs_service" "api" {
  # ...
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8080
  }

  depends_on = [aws_lb_listener.https]   # El listener debe existir antes que el service
}
```

---

## 3.12 Cloud Map: Service Discovery Nativo

Cloud Map permite que los servicios ECS se descubran entre sí por nombre DNS privado, sin necesidad de un ALB intermedio. Ideal para comunicación interna entre microservicios:

```hcl
# ── Namespace DNS privado ──
resource "aws_service_discovery_private_dns_namespace" "main" {
  name = "production.local"
  vpc  = module.vpc.vpc_id
}

# ── Registrar el servicio API ──
resource "aws_service_discovery_service" "api" {
  name = "api"   # DNS: api.production.local

  dns_config {
    namespace_id   = aws_service_discovery_private_dns_namespace.main.id
    routing_policy = "MULTIVALUE"
    dns_records { type = "A"; ttl = 10 }
  }

  health_check_custom_config { failure_threshold = 1 }
}

# ── Registrar en el ECS Service ──
resource "aws_ecs_service" "api" {
  # ...
  service_registries {
    registry_arn = aws_service_discovery_service.api.arn
  }
}
```

ECS registra y desregistra automáticamente las IPs de las tasks en Cloud Map. Otros microservicios pueden llamar a `http://api.production.local:8080` sin conocer las IPs dinámicas de Fargate.

---

## 3.13 Service Connect: Mesh Nativo de ECS

Service Connect es la evolución de Cloud Map: añade un proxy sidecar transparente que proporciona load balancing, reintentos, circuit breaker y métricas de observabilidad entre servicios ECS, sin necesitar App Mesh:

```hcl
resource "aws_ecs_service" "api" {
  # ...
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn

    service {
      port_name      = "http"
      discovery_name = "api"

      client_alias {
        port     = 8080
        dns_name = "api"   # Otros servicios llaman a http://api:8080
      }
    }

    log_configuration {
      log_driver = "awslogs"
      options    = { "awslogs-group" = "/ecs/${var.project}-connect" }
    }
  }
}
```

| | Cloud Map | Service Connect |
|--|-----------|----------------|
| Mecanismo | DNS simple | Proxy sidecar |
| Load balancing | Round-robin DNS | Proxy inteligente |
| Reintentos | No | Sí |
| Métricas | CloudWatch DNS | Métricas de conexión por servicio |
| Caso de uso | Simple service discovery | Service mesh completo |

---

## 3.14 Fargate Spot: Ahorro con Contenedores

Al igual que EC2 Spot, Fargate Spot usa capacidad excedente con hasta un 70% de descuento. AWS puede interrumpir las tasks con 2 minutos de aviso (SIGTERM).

```hcl
# ── Cluster con ambos capacity providers ──
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1   # Base garantizada
    base              = 1   # Mínimo 1 task en FARGATE estándar
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 3   # 3:1 ratio Spot vs On-Demand (~75% Spot)
  }
}

# ── Workers 100% Spot (toleran interrupciones) ──
resource "aws_ecs_service" "worker" {
  name            = "${var.project}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 4

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1   # 100% Spot para workers de procesamiento
  }
}
```

**Estrategia recomendada**: mezcla FARGATE (base: 1-2 tasks garantizadas) con FARGATE_SPOT (el resto). Así nunca te quedas sin servicio si AWS reclama la capacidad Spot, pero ahorras en el 70-80% de las tasks.

---

## 3.15 Auto Scaling para ECS Services

`aws_appautoscaling_target` + `aws_appautoscaling_policy` para escalar el `desired_count` automáticamente:

```hcl
# ── Scalable Target ──
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 10
  min_capacity       = 2
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.api.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

# ── Target Tracking: CPU al 60% ──
resource "aws_appautoscaling_policy" "cpu" {
  name               = "${var.project}-cpu-scaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60
    scale_in_cooldown  = 300   # 5 min antes de escalar hacia abajo
    scale_out_cooldown = 60    # 1 min antes de escalar hacia arriba
  }
}
```

---

## 3.16 Troubleshooting: Problemas Comunes en ECS

| Problema | Síntomas | Diagnóstico |
|---------|---------|------------|
| **Task no arranca** | Status STOPPED inmediatamente | Revisar stopped reason en consola ECS |
| **Image not found** | Pull error del ECR | Verificar Execution Role tiene permiso ECR |
| **Service inestable** | Tasks se crean y destruyen | Circuit breaker activo — revisar logs de la app |
| **Health check falla** | Tasks unhealthy en TG | Verificar path `/health` y SG instancia ←→ ALB |
| **Subnets sin NAT** | Error al hacer pull de ECR | Fargate necesita NAT o VPC Endpoints |
| **ECS Exec no funciona** | `execute-command` falla | Verificar Task Role tiene SSM permissions |

Para diagnosticar tasks que fallan: `aws ecs describe-tasks --cluster CLUSTER --tasks TASK_ARN` muestra el `stoppedReason` con el motivo exacto.

---

## 3.17 Resumen: El Ecosistema de Contenedores en AWS

| Componente | Función | Clave |
|-----------|---------|-------|
| `aws_ecr_repository` | Registry privado de imágenes | `image_tag_mutability = "IMMUTABLE"` |
| `aws_ecr_lifecycle_policy` | Limpieza automática de imágenes | Retener solo N recientes |
| `aws_ecs_cluster` | Plano de control | Container Insights + ECS Exec |
| `aws_ecs_task_definition` | Blueprint del contenedor | `jsonencode()` + inmutable por revisión |
| Execution Role | Permisos del agente ECS | `AmazonECSTaskExecutionRolePolicy` |
| Task Role | Permisos de la aplicación | Mínimo privilegio por microservicio |
| `aws_ecs_service` | Mantiene N réplicas activas | `ignore_changes = [desired_count]` |
| Circuit Breaker | Rollback automático en fallos | `enable = true, rollback = true` |
| `target_type = "ip"` | Integración ALB con Fargate | Obligatorio — Fargate usa IPs directas |
| Cloud Map | Service discovery DNS | Sin ALB para comunicación interna |
| Service Connect | Service mesh nativo | Proxy + métricas + reintentos |
| Fargate Spot | 70% ahorro | Solo workloads tolerantes a interrupciones |
| `aws_appautoscaling` | Auto scaling de tasks | Target Tracking en CPU/Mem |

---

> **Siguiente:** [Sección 4 — Serverless: Lambda y API Gateway →](./04_lambda_api_gateway.md)
