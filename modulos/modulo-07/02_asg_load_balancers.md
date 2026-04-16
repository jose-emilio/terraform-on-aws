# Sección 2 — Auto Scaling Groups y Load Balancers

> [← Sección anterior](./01_ec2_launch_templates.md) | [Siguiente →](./03_ecs_fargate.md)

---

## 2.1 Escalabilidad Automática: `aws_autoscaling_group`

Una instancia EC2 sola tiene dos problemas insolubles: si se cae, la aplicación cae con ella; y si el tráfico se multiplica por diez, no puede absorberlo. El Auto Scaling Group (ASG) resuelve ambos problemas.

> *"Un ASG es como tener un jefe de turno que constantemente mira el número de clientes en la tienda. Si hay demasiados, abre más cajas. Si alguien se pone enfermo, trae un sustituto. Y si la tienda cierra a las 10, manda a todo el mundo a casa."*

El ASG gestiona automáticamente tres responsabilidades:

- **Auto-reparación**: detecta instancias con fallos y las reemplaza sin intervención manual
- **Escalado dinámico**: añade o quita instancias según políticas de CPU, tráfico o métricas custom
- **Alta disponibilidad**: distribuye instancias en múltiples zonas de disponibilidad

```hcl
resource "aws_autoscaling_group" "app" {
  name                = "${var.project}-asg"
  min_size            = 1
  max_size            = 6
  desired_capacity    = 2
  vpc_zone_identifier = var.private_subnet_ids

  health_check_type         = "ELB"   # ALB health checks en lugar de EC2
  health_check_grace_period = 300     # 5 min para arrancar la app

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }

  tag {
    key                 = "Name"
    value               = "${var.project}-instance"
    propagate_at_launch = true
  }

  lifecycle {
    ignore_changes = [desired_capacity]   # Las políticas de scaling controlan desired
  }
}
```

---

## 2.2 Los Controles de Vuelo: Min, Max y Desired

Tres parámetros controlan el tamaño de la flota en todo momento:

| Parámetro | Función | Impacto |
|-----------|---------|---------|
| `min_size` | Disponibilidad mínima garantizada | SLA de la flota — nunca menos de N instancias |
| `desired_capacity` | Objetivo actual del ASG | AWS ajusta la flota a este valor en todo momento |
| `max_size` | Techo de coste y seguridad | Límite absoluto — previene escalado descontrolado |

La jerarquía: `min_size ≤ desired_capacity ≤ max_size`. Si Terraform o una política de scaling intenta violar esto, AWS lo rechaza.

---

## 2.3 Terraform vs. Scaling Policies: El Conflicto

> *"Este es uno de los conflictos más frecuentes en producción: el ASG escala automáticamente a 10 instancias a las 3pm. A las 4pm alguien hace terraform apply... y vuelve a 2. Silencio. La web empieza a fallar."*

Cuando las Scaling Policies ajustan `desired_capacity` en runtime, el siguiente `terraform apply` lo revierte al valor en el código. La solución es `lifecycle { ignore_changes }`:

```hcl
resource "aws_autoscaling_group" "fleet" {
  min_size         = 2
  max_size         = 20
  desired_capacity = 2   # Solo valor inicial — nunca cambia tras el primer apply

  # CLAVE: Terraform gestiona min/max; las políticas de AWS gestionan desired
  lifecycle {
    ignore_changes = [desired_capacity]
  }

  # ... launch_template, vpc_zone_identifier ...
}
```

Con esto, Terraform mantiene la configuración estructural (min/max, Launch Template) pero deja que AWS gestione el número de instancias activas según la demanda real.

---

## 2.4 Disponibilidad: `vpc_zone_identifier`

`vpc_zone_identifier` recibe una lista de subnets en distintas AZs. El ASG distribuye las instancias equitativamente entre todas ellas. Si una AZ completa falla (algo que AWS ha experimentado), el ASG detecta que las instancias en esa zona están unhealthy y escala en las zonas sanas.

```hcl
# ── Descubrir subnets privadas dinámicamente ──
data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [var.vpc_id]
  }
  filter {
    name   = "tag:Tier"
    values = ["private"]
  }
}

# ── ASG distribuido en todas las AZs ──
resource "aws_autoscaling_group" "app" {
  name                = "${var.project}-asg"
  vpc_zone_identifier = data.aws_subnets.private.ids   # Todas las AZs privadas

  min_size         = 2   # Mínimo 2 para sobrevivir el fallo de una AZ
  max_size         = 10
  desired_capacity = 4

  launch_template {
    id      = aws_launch_template.app.id
    version = "$Latest"
  }
}
# AWS balancea automáticamente entre AZs (rebalancing automático)
```

**Regla práctica**: `min_size` debe ser ≥ número de AZs para garantizar que haya al menos una instancia en cada zona.

---

## 2.5 Políticas de Escalado (I): Target Tracking

Target Tracking es la política más sencilla y la más recomendada. Funciona como un termostato: defines un valor objetivo y AWS crea automáticamente las CloudWatch Alarms necesarias para mantenerlo.

```hcl
resource "aws_autoscaling_group" "web" {
  # ... configuración base ...
  target_group_arns = [aws_lb_target_group.web.arn]
  lifecycle { ignore_changes = [desired_capacity] }
}

# ── Target Tracking: mantener CPU al 50% ──
resource "aws_autoscaling_policy" "cpu" {
  name                   = "cpu-target-50"
  autoscaling_group_name = aws_autoscaling_group.web.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50.0   # CPU objetivo: 50%
  }
}
```

Métricas predefinidas disponibles: `ASGAverageCPUUtilization`, `ASGAverageNetworkIn/Out`, `ALBRequestCountPerTarget`.

---

## 2.6 Políticas de Escalado (II): Step Scaling y Scheduled

**Step Scaling** reacciona por tramos a alarmas existentes — proporcional a la magnitud del problema:

```hcl
resource "aws_autoscaling_policy" "step" {
  name                   = "${var.project}-step"
  autoscaling_group_name = aws_autoscaling_group.app.name
  policy_type            = "StepScaling"
  adjustment_type        = "ChangeInCapacity"

  step_adjustment {
    scaling_adjustment          = 1   # CPU 60-80%: +1 instancia
    metric_interval_lower_bound = 0
    metric_interval_upper_bound = 20
  }

  step_adjustment {
    scaling_adjustment          = 3   # CPU >80%: +3 instancias (agresivo)
    metric_interval_lower_bound = 20
  }
}
# Requiere una CloudWatch Alarm que use esta policy como alarm_action
```

**Scheduled Actions** programa cambios para eventos conocidos — Black Friday, ventana de mantenimiento, horario laboral:

```hcl
# ── Scale up: inicio del horario laboral ──
resource "aws_autoscaling_schedule" "scale_up" {
  scheduled_action_name  = "workday"
  autoscaling_group_name = aws_autoscaling_group.app.name
  min_size               = 4
  max_size               = 10
  desired_capacity       = 6
  recurrence             = "0 8 * * MON-FRI"   # 08:00 lunes a viernes
}

# ── Scale down: noches y fines de semana ──
resource "aws_autoscaling_schedule" "scale_down" {
  scheduled_action_name  = "night"
  autoscaling_group_name = aws_autoscaling_group.app.name
  min_size               = 1
  max_size               = 4
  desired_capacity       = 2
  recurrence             = "0 20 * * *"   # 20:00 todos los días
}
```

---

## 2.7 Escalado Predictivo: Machine Learning al Servicio del ASG

El Predictive Scaling va un paso más allá del reactivo: analiza 14 días de métricas CloudWatch para anticipar el tráfico y lanzar instancias **antes** de que llegue el pico.

```hcl
resource "aws_autoscaling_policy" "predictive" {
  name                   = "${var.project}-predictive"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "PredictiveScaling"

  predictive_scaling_configuration {
    mode                         = "ForecastAndScale"   # ForecastOnly para validar primero
    scheduling_buffer_time       = 300                   # Lanzar 5 min antes del pico
    max_capacity_breach_behavior = "IncreaseMaxCapacity"
    max_capacity_buffer          = 10                    # +10% headroom

    metric_specification {
      target_value = 60   # CPU target 60%
      predefined_scaling_metric_specification {
        predefined_metric_type = "ASGAverageCPUUtilization"
        resource_label         = "app/my-alb/abc123"
      }
      predefined_load_metric_specification {
        predefined_metric_type = "ASGTotalCPUUtilization"
        resource_label         = "app/my-alb/abc123"
      }
    }
  }
}
```

**Consejo**: empieza con `mode = "ForecastOnly"` durante una semana para validar que los patrones predichos son correctos antes de activar el escalado automático.

---

## 2.8 Lifecycle Hooks: Pausar Instancias Antes de Vivir o Morir

Los lifecycle hooks interrumpen el ciclo de vida normal del ASG para ejecutar acciones personalizadas. Ponen la instancia en estado de espera (`Pending:Wait` o `Terminating:Wait`) durante un tiempo configurable.

```hcl
# ── SNS Topic para notificaciones de lifecycle ──
resource "aws_sns_topic" "lifecycle" {
  name = "${var.project}-lifecycle"
}

# ── Hook al lanzar: tiempo para calentar ──
resource "aws_autoscaling_lifecycle_hook" "launch" {
  name                   = "validate-instance"
  autoscaling_group_name = aws_autoscaling_group.app.name
  lifecycle_transition   = "autoscaling:EC2_INSTANCE_LAUNCHING"
  heartbeat_timeout      = 600   # 10 min máximo de espera
  default_result         = "ABANDON"   # Si no responde: descartar instancia
}

# ── Hook al terminar: drenar conexiones ──
resource "aws_autoscaling_lifecycle_hook" "drain" {
  name                    = "drain-connections"
  autoscaling_group_name  = aws_autoscaling_group.app.name
  lifecycle_transition    = "autoscaling:EC2_INSTANCE_TERMINATING"
  heartbeat_timeout       = 300   # 5 min para drenar
  default_result          = "CONTINUE"
  notification_target_arn = aws_sns_topic.lifecycle.arn
  role_arn                = aws_iam_role.lifecycle.arn
}
```

Casos de uso típicos:
- **Al lanzar**: registrar en Service Discovery, calentar cachés, instalar software pesado
- **Al terminar**: extraer logs a S3, desregistrar de Consul/Eureka, completar jobs en curso

---

## 2.9 Instance Refresh: Rolling Updates sin Downtime

Cuando cambias la AMI en el Launch Template, el ASG no reemplaza las instancias existentes automáticamente — hasta que activas `instance_refresh`:

```hcl
resource "aws_autoscaling_group" "web" {
  # ... min/max/launch_template ...

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 90    # Mantén al menos el 90% de la flota sana
      instance_warmup        = 120   # 2 min para que cada instancia nueva arranque
    }
    triggers = ["launch_template"]   # Disparar cuando cambie el LT
  }
}
# Al hacer terraform apply con una AMI nueva en el LT,
# el rolling update se dispara automáticamente
```

El ASG reemplaza las instancias por lotes, respetando siempre el `min_healthy_percentage`. Si alguna instancia nueva falla el health check, el refresh se detiene automáticamente.

---

## 2.10 Elastic Load Balancing: La Puerta de Entrada

El Elastic Load Balancer es el componente que recibe todo el tráfico externo y lo distribuye entre las instancias sanas del ASG. Se compone de **tres recursos Terraform** que trabajan en cadena:

```
Internet → aws_lb → aws_lb_listener → aws_lb_target_group → Instancias EC2
```

| Recurso | Función |
|---------|---------|
| `aws_lb` | El balanceador en sí — ALB (Capa 7) o NLB (Capa 4) |
| `aws_lb_listener` | Escucha en un puerto (80/443) y aplica reglas |
| `aws_lb_target_group` | Grupo de destinos con health checks |

```hcl
resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = var.public_subnet_ids
  enable_deletion_protection = true
}

resource "aws_lb_target_group" "app" {
  name     = "${var.project}-tg"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id

  health_check {
    path                = "/health"
    healthy_threshold   = 2
    unhealthy_threshold = 3
    interval            = 30
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = var.certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}
```

---

## 2.11 ALB: Enrutamiento Inteligente con Listener Rules

El Application Load Balancer opera en la Capa 7 (HTTP/HTTPS) e inspecciona el contenido de las peticiones para enrutarlas. Un solo ALB puede servir a múltiples servicios:

```hcl
# /api/* → Backend API
resource "aws_lb_listener_rule" "api" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 100

  condition {
    path_pattern { values = ["/api/*"] }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}

# admin.example.com → Panel de administración
resource "aws_lb_listener_rule" "admin" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 50   # Número más bajo = mayor prioridad

  condition {
    host_header { values = ["admin.example.com"] }
  }

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.admin.arn
  }
}

# Despliegue Canary: 90% stable / 10% canary
resource "aws_lb_listener_rule" "canary" {
  listener_arn = aws_lb_listener.https.arn
  priority     = 10

  condition {
    path_pattern { values = ["/*"] }
  }

  action {
    type = "forward"
    forward {
      target_group {
        arn    = aws_lb_target_group.stable.arn
        weight = 90
      }
      target_group {
        arn    = aws_lb_target_group.canary.arn
        weight = 10
      }
      stickiness {
        enabled  = true
        duration = 3600   # 1 hora — usuario siempre va al mismo TG
      }
    }
  }
}
```

El **despliegue canary** con pesos es una técnica poderosa: envías el 10% del tráfico a la nueva versión, mides métricas, y si todo va bien incrementas gradualmente hasta el 100%.

---

## 2.12 Sticky Sessions y Slow Start

**Sticky sessions** vincula un usuario a la misma instancia usando una cookie:

```hcl
resource "aws_lb_target_group" "sticky" {
  name     = "${var.project}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  stickiness {
    type            = "lb_cookie"   # ALB genera la cookie
    cookie_duration = 3600          # 1 hora
    enabled         = true
    # Alternativa: app_cookie para usar la cookie de sesión propia
    # type = "app_cookie", cookie_name = "SESSIONID"
  }
}
```

**Slow start** incrementa gradualmente el tráfico a instancias nuevas, dándoles tiempo para calentar:

```hcl
resource "aws_lb_target_group" "web" {
  name     = "${var.project}-tg"
  port     = 80
  protocol = "HTTP"
  vpc_id   = aws_vpc.main.id

  deregistration_delay = 120   # 120s para drenar conexiones al quitar una instancia
  slow_start           = 90    # 90s de warm-up gradual para instancias nuevas
}
```

`deregistration_delay` elimina los errores 503 durante el escalado: cuando el ASG quita una instancia, el ALB espera que las conexiones activas terminen antes de cerrar la instancia.

---

## 2.13 Health Checks: EC2 vs. ELB

| Tipo | Qué verifica | Cuándo usar |
|------|-------------|------------|
| **EC2** | Estado de la VM a nivel hypervisor | Default — básico |
| **ELB** | HTTP GET al endpoint `/health` de la app | Siempre que haya ALB |

Con `health_check_type = "ELB"`, el ASG usa los health checks del ALB para decidir si una instancia es sana. Si la app responde con 5XX, el ASG la considera unhealthy y la reemplaza — algo que EC2 health check nunca detectaría porque la VM sigue funcionando.

```hcl
resource "aws_autoscaling_group" "web" {
  # ...
  health_check_type         = "ELB"    # Usa el health check del ALB
  health_check_grace_period = 300      # 5 min antes de empezar a comprobar
                                        # (tiempo de arranque de la app)
}
```

---

## 2.14 Network Load Balancer (NLB): Capa 4

El NLB opera en la Capa 4 (TCP/UDP), no inspecciona HTTP. Sus características únicas:

- **IP estática por AZ** — permite whitelisting en firewalls de clientes
- **Latencia ultra-baja** — no introduce cabeceras ni inspecciona contenido
- **Millones de req/s** — para cargas de trabajo masivas
- **Preserva IP del cliente** — el backend ve la IP real del cliente

```hcl
resource "aws_lb" "nlb" {
  name               = "${var.project}-nlb"
  internal           = false
  load_balancer_type = "network"
  subnets            = var.public_subnet_ids
  enable_cross_zone_load_balancing = true
}

resource "aws_lb_target_group" "tcp" {
  name        = "${var.project}-tcp-tg"
  port        = 443
  protocol    = "TCP"
  vpc_id      = var.vpc_id
  target_type = "instance"

  health_check {
    protocol = "TCP"
    interval = 10   # NLB: mínimo 10s
  }
}

# ── Elastic IPs fijas para el NLB ──
resource "aws_eip" "nlb" {
  count  = length(var.public_subnet_ids)
  domain = "vpc"
  tags   = { Name = "${var.project}-nlb-${count.index}" }
}
```

---

## 2.15 Gateway Load Balancer (GWLB) e Integración WAF

El GWLB opera en Capa 3 y usa encapsulación GENEVE (puerto 6081) para enviar tráfico transparente a appliances de seguridad (firewalls, IDS/IPS):

```hcl
resource "aws_lb" "gwlb" {
  name               = "${var.project}-gwlb"
  load_balancer_type = "gateway"
  subnets            = var.appliance_subnets
}

resource "aws_lb_target_group" "appliances" {
  name        = "${var.project}-appliances"
  port        = 6081     # Puerto GENEVE
  protocol    = "GENEVE"
  vpc_id      = var.appliance_vpc_id
  target_type = "instance"
  health_check { protocol = "HTTP"; port = 80 }
}
```

Para protección OWASP, el ALB se integra con AWS WAF:

```hcl
resource "aws_wafv2_web_acl" "main" {
  name  = "${var.project}-waf"
  scope = "REGIONAL"

  default_action { allow {} }

  rule {
    name     = "aws-managed"
    priority = 1
    override_action { none {} }
    statement {
      managed_rule_group_statement {
        vendor_name = "AWS"
        name        = "AWSManagedRulesCommonRuleSet"
      }
    }
    visibility_config {
      metric_name                = "waf-common"
      sampled_requests_enabled   = true
      cloudwatch_metrics_enabled = true
    }
  }

  visibility_config {
    metric_name                = "waf-main"
    sampled_requests_enabled   = true
    cloudwatch_metrics_enabled = true
  }
}

# Asociar WAF al ALB
resource "aws_wafv2_web_acl_association" "alb" {
  resource_arn = aws_lb.main.arn
  web_acl_arn  = aws_wafv2_web_acl.main.arn
}
```

---

## 2.16 Troubleshooting: ¿Por qué mis instancias están Unhealthy?

| Categoría | Síntomas / Causas | Solución |
|-----------|------------------|---------|
| **Health Check** | Path incorrecto, timeout muy bajo, app tarda en arrancar | Verificar `/health` devuelve 200, aumentar `grace_period` |
| **Security Groups** | ALB SG no permite salida, instancia SG no acepta al ALB | SG instancia debe aceptar tráfico del SG del ALB |
| **Launch Template** | AMI sin la app instalada, `user_data` falla silencioso | Revisar logs en `/var/log/cloud-init-output.log` |
| **ASG Config** | Grace period muy corto, AZs no coinciden con ALB | `health_check_grace_period` debe ser > tiempo de arranque |

---

## 2.17 Resumen: El Ecosistema de Alta Disponibilidad

| Componente | Clave | Buena práctica |
|-----------|-------|---------------|
| `aws_autoscaling_group` | min/max/desired | `ignore_changes = [desired_capacity]` |
| `vpc_zone_identifier` | Multi-AZ | Mínimo 2 AZs, ideal 3 |
| Target Tracking | CPU al 50-60% | Política más simple y efectiva |
| Step Scaling | Tramos por umbral | Combinar con CW Alarms |
| Scheduled Actions | Cron predecible | Para picos conocidos (Black Friday) |
| Predictive Scaling | ML 14 días | `ForecastOnly` primero, luego activar |
| Lifecycle Hooks | Pausa al lanzar/terminar | Tiempo de drenado graceful |
| Instance Refresh | Rolling update AMI | `min_healthy_percentage = 90` |
| ALB | Capa 7, path/host routing | TLS 1.3 + WAF + Listener Rules |
| NLB | Capa 4, IP estática, ultra-latencia | Cross-zone enabled |
| Health Checks | ELB > EC2 | `grace_period` = tiempo de arranque |
| `deregistration_delay` | Drenado de conexiones | 120s APIs, 300s WebSockets |

---

> **Siguiente:** [Sección 3 — Contenedores: Amazon ECS y Fargate →](./03_ecs_fargate.md)
