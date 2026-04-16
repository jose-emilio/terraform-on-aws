# Sección 3 — AWS CodeDeploy: Despliegue de Aplicaciones

> [← Volver al índice](./README.md) | [Siguiente →](./04_codepipeline.md)

---

## 1. La Separación de Responsabilidades: Terraform vs CodeDeploy

En el modelo de CI/CD en AWS, Terraform y CodeDeploy tienen dominios claramente separados. Terraform gestiona la infraestructura — las piezas que no cambian con cada release de la aplicación. CodeDeploy gestiona el código de la aplicación — las piezas que cambian con cada deploy.

> **El profesor explica:** "Uno de los errores más comunes que veo es querer usar Terraform para desplegar código de aplicación. Terraform no sabe si tu aplicación está healthcheck. No entiende de Blue/Green ni Canary. No puede pausar el tráfico mientras instala dependencias. CodeDeploy sí. La pregunta es: ¿esto pertenece a la infraestructura o a la aplicación? Si cambia con cada release de código, es CodeDeploy. Si cambia cuando rediseñas la arquitectura, es Terraform."

**División de responsabilidades:**

| Terraform (Infraestructura) | CodeDeploy (Aplicación) |
|-----------------------------|-------------------------|
| VPC, subnets, security groups | Mapping de archivos (source/dest) |
| ALB, Target Groups, listeners | Hooks del ciclo de vida |
| ASG con launch template | Scripts de instalación (bash) |
| `aws_codedeploy_app` resource | `appspec.yml` (en el repo de la app) |
| `aws_codedeploy_deployment_group` | `BeforeInstall`, `AfterInstall`, `ValidateService` |
| IAM roles y policies | Permisos de archivos destino |
| CloudWatch alarms de rollback | Lógica de healthcheck |

---

## 2. Setup Inicial con Terraform

```hcl
# 1. Aplicación CodeDeploy (contenedor lógico)
resource "aws_codedeploy_app" "main" {
  name             = "${var.project}-app"
  compute_platform = "Server"   # "Server", "Lambda", o "ECS"
}

# 2. IAM Service Role para CodeDeploy
resource "aws_iam_role" "codedeploy" {
  name = "${var.project}-codedeploy-role"

  assume_role_policy = jsonencode({
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codedeploy.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

# 3. Instance Profile para EC2 (descargar artefactos de S3)
resource "aws_iam_instance_profile" "app" {
  name = "${var.project}-app-profile"
  role = aws_iam_role.ec2_role.name
}
```

---

## 3. Deployment Group — Definir el Alcance del Despliegue

```hcl
resource "aws_codedeploy_deployment_group" "app" {
  app_name              = aws_codedeploy_app.main.name
  deployment_group_name = "${var.env}-deploy-group"
  service_role_arn      = aws_iam_role.codedeploy.arn

  deployment_style {
    deployment_type   = "IN_PLACE"          # o "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  # Vincula al ASG: nuevas instancias reciben el código automáticamente
  autoscaling_groups = [aws_autoscaling_group.app.name]

  # Rollback automático si el despliegue falla
  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }
}
```

**Filtrado por tags (flota estática de EC2):**

```hcl
ec2_tag_set {
  ec2_tag_filter {
    key   = "Environment"
    type  = "KEY_AND_VALUE"
    value = var.environment
  }
  ec2_tag_filter {
    key   = "App"
    type  = "KEY_AND_VALUE"
    value = var.project
  }
}
```

---

## 4. Deployment Configurations — Estrategias de Velocidad

```hcl
# Configuración personalizada: Canary 10% + espera 10 minutos
resource "aws_codedeploy_deployment_config" "canary" {
  deployment_config_name = "canary-10-percent"
  compute_platform       = "Server"

  minimum_healthy_hosts {
    type  = "FLEET_PERCENT"
    value = 90   # Al menos 90% de instancias sanas durante el deploy
  }

  traffic_routing_config {
    type = "TimeBasedCanary"
    time_based_canary {
      interval   = 10   # Minutos de espera antes de continuar
      percentage = 10   # % inicial de tráfico a la nueva versión
    }
  }
}
```

**Comparativa de estrategias:**

| Configuración | Velocidad | Riesgo | Disponibilidad | Recomendado para |
|---------------|-----------|--------|----------------|------------------|
| `CodeDeployDefault.AllAtOnce` | Máxima | Máximo | 0% si falla | Solo dev |
| `CodeDeployDefault.HalfAtATime` | Media | Medio | 50% garantizada | Staging |
| `CodeDeployDefault.OneAtATime` | Mínima | Mínimo | 99%+ garantizada | Producción crítica |
| `TimeBasedCanary` (10%, 10 min) | Gradual | Mínimo | Total + validación | Producción ideal |
| `TimeBasedLinear` (10%, 5 min) | Muy gradual | Mínimo | Total + validación | High-stakes |

---

## 5. Blue/Green — Zero Downtime con ALB

Terraform configura dos Target Groups (azul y verde). CodeDeploy redirige el tráfico del grupo azul al verde durante el despliegue, con rollback instantáneo si falla.

```hcl
# Dos Target Groups: blue (actual) y green (nuevo)
resource "aws_lb_target_group" "blue" {
  name     = "${var.project}-blue"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

resource "aws_lb_target_group" "green" {
  name     = "${var.project}-green"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

# Deployment Group con Blue/Green
resource "aws_codedeploy_deployment_group" "bg" {
  app_name              = aws_codedeploy_app.main.name
  deployment_group_name = "${var.env}-bg-group"
  service_role_arn      = aws_iam_role.codedeploy.arn

  deployment_style {
    deployment_type   = "BLUE_GREEN"
    deployment_option = "WITH_TRAFFIC_CONTROL"
  }

  # Configuración del ALB con par de Target Groups
  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.prod.arn]
      }
      target_group {
        name = aws_lb_target_group.blue.name   # Tráfico actual
      }
      target_group {
        name = aws_lb_target_group.green.name  # Nuevo código
      }
      test_traffic_route {
        listener_arns = [aws_lb_listener.test.arn]  # Validación previa al swap
      }
    }
  }

  blue_green_deployment_config {
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = 5   # Tiempo antes de terminar instancias azules
    }

    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
      wait_time_in_minutes = 0
    }
  }
}
```

**Flujo Blue/Green:**
```
100% tráfico → Blue TG (v1)

CodeDeploy inicia:
  → Lanza instancias Green con v2
  → Ejecuta health checks en Green
  → Redirige PROD listener: Blue → Green
  → Monitoriza alarmas CloudWatch (N minutos)
  → Si OK: termina instancias Blue
  → Si ALARM: revierte: Green → Blue (rollback instantáneo)

100% tráfico → Green TG (v2) ✓
```

---

## 6. CloudWatch Alarms + Rollback Automático

```hcl
# Alarma: errores HTTP 5xx durante el despliegue
resource "aws_cloudwatch_metric_alarm" "http_5xx" {
  alarm_name          = "${var.project}-5xx-errors"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "HTTPCode_Target_5XX_Count"
  namespace           = "AWS/ApplicationELB"
  period              = 60
  statistic           = "Sum"
  threshold           = 5   # Más de 5 errores 5xx en 1 minuto → rollback

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
  }
}

# Integrar alarmas en el Deployment Group
resource "aws_codedeploy_deployment_group" "app" {
  # ... configuración base ...

  alarm_configuration {
    alarms = [
      aws_cloudwatch_metric_alarm.http_5xx.alarm_name,
      aws_cloudwatch_metric_alarm.latency.alarm_name,
      aws_cloudwatch_metric_alarm.healthy_hosts.alarm_name,
    ]
    enabled                   = true
    ignore_poll_alarm_failure = false   # Si no puede consultar la alarma, para
  }

  auto_rollback_configuration {
    enabled = true
    events  = [
      "DEPLOYMENT_FAILURE",
      "DEPLOYMENT_STOP_ON_ALARM",   # Rollback si cualquier alarma se activa
    ]
  }
}
```

---

## 7. Instalar el Agente CodeDeploy via `user_data`

El agente de CodeDeploy debe estar corriendo en cada EC2 para que el servicio pueda comunicarse con la instancia.

```hcl
resource "aws_launch_template" "app" {
  name_prefix   = "${var.project}-"
  image_id      = data.aws_ami.amazon_linux.id
  instance_type = var.instance_type

  iam_instance_profile {
    arn = aws_iam_instance_profile.app.arn
  }

  user_data = base64encode(<<-EOF
    #!/bin/bash
    set -e

    # Instalar agente CodeDeploy
    yum update -y
    yum install -y ruby wget

    # Descargar desde bucket regional AWS
    REGION=$(curl -s http://169.254.169.254/latest/meta-data/placement/region)
    cd /tmp
    wget "https://aws-codedeploy-${REGION}.s3.${REGION}.amazonaws.com/latest/install"
    chmod +x ./install
    ./install auto

    # Verificar que el agente está corriendo
    service codedeploy-agent start
    service codedeploy-agent status
  EOF
  )

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name        = "${var.project}-app"
      Environment = var.environment
      App         = var.project
    }
  }
}
```

**Verificación:**
```bash
sudo service codedeploy-agent status
# Expected: The AWS CodeDeploy agent is running
# Si no responde: ver /var/log/aws/codedeploy-agent/codedeploy-agent.log
```

---

## 8. Escenario Integrado: La Danza Terraform + CodeDeploy

```
TERRAFORM (Infraestructura)           CODEDEPLOY (Aplicación)
────────────────────────────          ──────────────────────────────────
1. Crea VPC + subnets + SGs           1. Detecta nuevas instancias del ASG
2. Aprovisiona ALB + listeners        2. Descarga artefacto de S3
3. Crea ASG + launch template         3. Ejecuta: BeforeInstall hook
4. Define aws_codedeploy_app          4. Instala dependencias
5. Configura deployment_group         5. Copia archivos de la aplicación
6. Asigna IAM roles necesarios        6. Ejecuta: AfterInstall hook
7. Crea CloudWatch alarms             7. Inicia el servicio
8. terraform apply → infra lista      8. Ejecuta: ValidateService hook
                                      9. Monitoriza alarmas N minutos
                                      10. OK → tráfico 100% → nueva versión
                                      11. ALARM → rollback automático
```

---

## 9. Troubleshooting Común

| Error | Causa | Solución |
|-------|-------|---------|
| `AccessDenied` al descargar artefacto | Instance profile sin `s3:GetObject` | Agregar permiso al rol EC2 |
| Deploy stuck en `Pending` | Agente no corriendo | Revisar `user_data`, ver `/var/log/aws/codedeploy-agent/` |
| Tráfico no redirige en B/G | Nombres de TG incorrectos en HCL | Verificar que los nombres coincidan exactamente |
| `Deployment failed: unhealthy hosts` | Health check falla en instancias nuevas | Revisar path de health check y security groups |
| `InvalidDeploymentGroupNameException` | Nombre del deployment group incorrecto | Verificar `app_name` coincide con el resource `aws_codedeploy_app` |

---

> [← Volver al índice](./README.md) | [Siguiente →](./04_codepipeline.md)
