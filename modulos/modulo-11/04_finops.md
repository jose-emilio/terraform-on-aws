# Sección 4 — FinOps y Gestión de Costes

> [← Volver al índice](./README.md) | [Siguiente →](./05_compliance_code.md)

---

## 1. FinOps: La Cultura del Valor en la Nube

FinOps une ingeniería, finanzas y negocio para maximizar el valor de cada euro en la nube. Terraform actúa como brazo ejecutor: convierte políticas de ahorro en código reproducible y auditable.

> **En la práctica:** "FinOps no es 'gastar menos en la nube'. Es 'obtener el máximo valor por cada euro que gastas en la nube'. La diferencia es fundamental. Un equipo que gasta 50.000€ al mes y entrega 10 millones en valor es más eficiente que uno que gasta 10.000€ y no entrega nada. Lo que FinOps le pide a los ingenieros es visibilidad y responsabilidad. Terraform se convierte en el vehículo perfecto porque cada `terraform apply` tiene un impacto económico medible — y con Infracost ese impacto es visible antes de hacer el apply."

**Los tres pilares de FinOps:**

| Pilar | Pregunta clave | Herramienta AWS |
|-------|----------------|----------------|
| **Visibilidad** | ¿Cuánto gasta cada equipo? | Cost Explorer + Cost Allocation Tags |
| **Propiedad** | ¿Quién es responsable de qué coste? | Budgets + Notificaciones por equipo |
| **Optimización** | ¿Cómo reducir sin perder valor? | Compute Optimizer + Infracost + Spot |

---

## 2. `aws_budgets_budget`: Alertas Preventivas

El primer paso de FinOps es la visibilidad: saber cuándo el gasto se acerca al límite antes de que lo supere.

```hcl
# Presupuesto mensual con alerta predictiva por IA
resource "aws_budgets_budget" "cost_guard" {
  name         = "${var.project}-monthly-budget"
  budget_type  = "COST"
  limit_amount = "1000"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Alerta al 85% del presupuesto PREDICHO (IA anticipa el fin de mes)
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 85
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"   # Predicción — no real
    subscriber_email_addresses = [var.finance_email]
  }

  # Alerta al 100% del gasto REAL
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"   # Cuando ya se ha superado
    subscriber_sns_arns        = [aws_sns_topic.alerts.arn]
  }
}

# Budget por servicio: detectar explosiones en un servicio específico
resource "aws_budgets_budget" "ec2_budget" {
  name         = "ec2-monthly-budget"
  budget_type  = "COST"
  limit_amount = "300"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name   = "Service"
    values = ["Amazon Elastic Compute Cloud - Compute"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 90
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.ops_email]
  }
}
```

---

## 3. Cost Anomaly Detection: Protección Inteligente

Cost Anomaly Detection usa ML para identificar picos de gasto inesperados: errores de código, ataques de cryptomining o recursos mal configurados.

> **En la práctica:** "Tuve un cliente que tenía una Lambda con un bug en producción que entraba en un bucle infinito. Llevaba 3 días corriendo sin que nadie lo notara. La factura de Lambda ese mes fue de 40.000 euros cuando lo normal era 200. Con Cost Anomaly Detection configurado, hubieran recibido una alerta en la primera hora. Sin él, lo descubrieron cuando el CFO preguntó qué había pasado con la factura de AWS. Ese día el CTO entendió el valor de FinOps."

```hcl
# Monitor de anomalías por servicio AWS
resource "aws_ce_anomaly_monitor" "service" {
  name              = "${var.project}-service-monitor"
  monitor_type      = "DIMENSIONAL"
  monitor_dimension = "SERVICE"   # Agrupa por servicio AWS
}

# Monitor de anomalías por tag (por equipo o proyecto)
resource "aws_ce_anomaly_monitor" "by_team" {
  name         = "${var.project}-team-monitor"
  monitor_type = "CUSTOM"

  monitor_specification = jsonencode({
    And = null
    Not = null
    Or  = null
    Dimensions = null
    Tags = {
      Key    = "Team"
      Values = ["payments", "platform"]
      MatchOptions = ["EQUALS"]
    }
  })
}

# Suscripción: alerta si la anomalía supera $50/día
resource "aws_ce_anomaly_subscription" "daily_alerts" {
  name      = "${var.project}-daily-alerts"
  frequency = "DAILY"

  threshold_expression {
    dimension {
      key           = "ANOMALY_TOTAL_IMPACT_ABSOLUTE"
      match_options = ["GREATER_THAN_OR_EQUAL"]
      values        = ["50"]   # USD por encima de lo esperado
    }
  }

  monitor_arn_list = [
    aws_ce_anomaly_monitor.service.arn,
    aws_ce_anomaly_monitor.by_team.arn,
  ]

  subscriber {
    address = var.finops_email
    type    = "EMAIL"
  }

  subscriber {
    address = aws_sns_topic.cost_alerts.arn
    type    = "SNS"
  }
}
```

---

## 4. Infracost: Estimación de Costes Pre-Deploy

Infracost analiza el plan de Terraform y calcula el coste mensual estimado. Integrado en CI/CD, cada Pull Request muestra el diff económico de los cambios.

```yaml
# .github/workflows/infracost.yml
name: infracost-cost-estimate
on: [pull_request]

jobs:
  cost-estimate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Infracost
        uses: infracost/actions/setup@v3
        with:
          api-key: ${{ secrets.INFRACOST_API_KEY }}

      - name: Generate Infracost diff
        run: |
          infracost diff \
            --path=. \
            --format=json \
            --out-file=/tmp/infracost.json \
            --terraform-var-file=environments/prod/prod.tfvars

      - name: Post PR comment with cost diff
        uses: infracost/actions/comment@v3
        with:
          path: /tmp/infracost.json
          behavior: update   # Actualiza el comentario si ya existe

      # Policy: bloquear si el coste sube más del 20%
      - name: Check cost policy
        run: |
          DIFF=$(infracost output --path /tmp/infracost.json --format=json | jq '.diffTotalMonthlyCost | tonumber')
          if (( $(echo "$DIFF > 200" | bc -l) )); then
            echo "❌ Coste mensual incrementa >$200. Requiere aprobación manual."
            exit 1
          fi
```

**Output de Infracost en un PR:**

```
💰 Infracost estimate

Project: myapp-prod

Name                            Monthly Qty  Unit     Monthly Cost
aws_instance.app                          1  instance       $73.00
  └─ Instance type: m6i.large → m6i.xlarge (changed)
aws_db_instance.main                      1  instance      $145.00
  (no change)

TOTAL CHANGE: +$73.00/month (+0.53%)
Previously: $13,700/month
Now:        $13,773/month
```

---

## 5. Right-Sizing: Ajuste Continuo de Capacidad

AWS Compute Optimizer analiza métricas históricas y recomienda cambios de tipo de instancia. Con variables en Terraform, el cambio es un PR con diff visible.

```hcl
# variables.tf — Mapa de instancias por entorno (fácil de ajustar)
variable "instance_types" {
  type = map(string)
  default = {
    dev  = "t3.small"
    stg  = "t3.medium"
    prd  = "m6i.large"   # Cambiar aquí → PR con infracost diff automático
  }
}

# main.tf — Consumo flexible del tipo de instancia
resource "aws_instance" "app" {
  ami           = data.aws_ami.latest.id
  instance_type = var.instance_types[var.environment]

  tags = merge(local.common_tags, {
    Name       = "${module.naming.name_prefix}-ec2"
    RightSized = "2024-03"          # Cuándo se revisó
    PrevType   = "m5.xlarge"        # Tracking del cambio para auditoría
  })
}
```

**Señales de instancia sobredimensionada:**

| Métrica | Umbral de alerta | Acción |
|---------|-----------------|--------|
| CPU promedio | < 20% en 2 semanas | Reducir familia o tipo |
| Memoria libre | > 60% consistente | Reducir memoria (si el tipo lo permite) |
| Network throughput | < 10% del límite | Tipo más pequeño o serverless |
| I/O disk | < 5% del límite | Reducir o cambiar a storage class menor |

---

## 6. Spot Instances: Compute al 90% Menos

Las Spot Instances aprovechan capacidad EC2 no utilizada con descuentos de hasta 90%. Son ideales para cargas tolerantes a interrupciones.

> **En la práctica:** "El mayor error con Spot es usarlo para servidores de producción sin preparación. Spot puede interrumpirse con 2 minutos de aviso. Pero para CI/CD runners, batch processing o cualquier carga stateless con ASG bien configurado, es transformador. Un runner de GitHub Actions que corre 8 horas al día en un `m5.4xlarge` on-demand cuesta ~$550/mes. El mismo runner en Spot cuesta ~$55. Para un equipo con 20 runners, eso es $9.900/mes de ahorro — un salario junior gratis."

```hcl
resource "aws_autoscaling_group" "workers" {
  min_size         = 2
  max_size         = 10
  desired_capacity = 4

  vpc_zone_identifier = module.vpc.private_subnets

  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity  = 1     # 1 instancia siempre on-demand (base)
      on_demand_percentage     = 25    # 25% on-demand, 75% Spot
      spot_allocation_strategy = "capacity-optimized"   # AWS elige la AZ con más Spot disponible
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.app.id
        version            = "$Latest"
      }

      # Múltiples tipos: si un tipo no tiene Spot, usa otro
      override { instance_type = "m6i.large"  }
      override { instance_type = "m6a.large"  }
      override { instance_type = "m5.large"   }
      override { instance_type = "m5a.large"  }
    }
  }

  tag {
    key                 = "Name"
    value               = "${var.project}-${var.environment}-worker"
    propagate_at_launch = true
  }
}
```

---

## 7. Recursos Zombi: Limpieza Automatizada

Los recursos zombi son artefactos que quedan tras un destroy parcial o una migración. Cuestan dinero sin aportar valor.

**Tipos más comunes:**

| Recurso zombi | Coste mensual típico | Cómo se crea |
|---------------|---------------------|--------------|
| EBS sin attach | $8-40/100GB | `terraform destroy` parcial |
| Elastic IP sin asociar | $3.60/IP | IP reservada y olvidada |
| Snapshots > 90 días | $0.05/GB/mes | DLM no configurado |
| Load Balancer sin targets | $18/mes | Servicio migrado, ALB olvidado |
| NAT Gateway sin tráfico | $32/mes | VPC de test no eliminada |

```hcl
# S3 Lifecycle — transición y expiración automática de logs
resource "aws_s3_bucket_lifecycle_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id

  rule {
    id     = "archive-and-expire"
    status = "Enabled"

    transition {
      days          = 30
      storage_class = "GLACIER"
    }

    expiration {
      days = 365
    }
  }
}

# DLM (Data Lifecycle Manager) — retención de snapshots EBS
resource "aws_dlm_lifecycle_policy" "snapshots" {
  description        = "Retain 7 daily EBS snapshots"
  execution_role_arn = aws_iam_role.dlm.arn
  state              = "ENABLED"

  policy_details {
    resource_types = ["VOLUME"]

    target_tags = {
      Backup = "daily"   # Solo volúmenes con este tag
    }

    schedule {
      name = "daily-snapshots"

      create_rule {
        interval      = 24
        interval_unit = "HOURS"
        times         = ["23:45"]
      }

      retain_rule {
        count = 7   # Mantener solo los últimos 7
      }

      copy_tags = true
    }
  }
}
```

---

## 8. Graviton: ARM Native al 20-40% Menos

Migrar a instancias Graviton (ARM) ofrece mejor precio/rendimiento sin cambios en el código de la aplicación (siempre que la aplicación sea compatible).

```hcl
# variables.tf — Feature flag para Graviton
variable "use_graviton" {
  type        = bool
  default     = true
  description = "Usar instancias Graviton (ARM) para mejor precio/rendimiento"
}

locals {
  # Mapa x86 → Graviton equivalente
  instance_family = var.use_graviton ? "m7g" : "m6i"
}

# RDS — Graviton3 para bases de datos
resource "aws_db_instance" "main" {
  engine          = "postgres"
  engine_version  = "15.4"
  instance_class  = "db.r7g.large"   # Graviton3: 20% más barato que db.r6i.large
  storage_type    = "gp3"
  allocated_storage = 100
}

# ElastiCache — Graviton nodo de caché
resource "aws_elasticache_replication_group" "redis" {
  replication_group_id = "${var.project}-redis"
  description          = "Redis Graviton cluster"
  node_type            = "cache.r7g.large"   # ARM: ahorro vs cache.r6g.large
  num_cache_clusters   = 3
  automatic_failover_enabled = true
}
```

**Ahorro estimado con Graviton:**

| Servicio | Tipo x86 | Tipo Graviton | Ahorro |
|---------|----------|---------------|--------|
| EC2 | m6i.large ($70/mes) | m7g.large ($56/mes) | -20% |
| RDS PostgreSQL | db.r6i.large ($145/mes) | db.r7g.large ($116/mes) | -20% |
| ElastiCache | cache.r6g.large ($105/mes) | cache.r7g.large ($84/mes) | -20% |
| Lambda | x86 | arm64 | -20% |

---

## 9. Patrones Avanzados: Scheduling y Serverless

```hcl
# Instance Scheduler: apagar entornos non-prod en horario no laboral
# dev/stg OFF 19h-07h + fines de semana → ahorro ~65%
resource "aws_cloudwatch_event_rule" "stop_dev" {
  name                = "stop-dev-instances"
  description         = "Stop dev instances at end of business day"
  schedule_expression = "cron(0 19 ? * MON-FRI *)"   # L-V a las 19:00 UTC
}

resource "aws_cloudwatch_event_rule" "start_dev" {
  name                = "start-dev-instances"
  description         = "Start dev instances at start of business day"
  schedule_expression = "cron(0 7 ? * MON-FRI *)"    # L-V a las 07:00 UTC
}

resource "aws_cloudwatch_event_target" "stop" {
  rule     = aws_cloudwatch_event_rule.stop_dev.name
  arn      = aws_lambda_function.instance_scheduler.arn
  input    = jsonencode({ action = "stop", tag_key = "Environment", tag_value = "dev" })
}
```

**Impacto del scheduling en costes:**

| Entorno | Horas activas/mes | vs 24x7 | Ahorro |
|---------|------------------|---------|--------|
| Desarrollo (L-V 8h) | 160h | 730h | 78% |
| Staging (L-V 12h) | 240h | 730h | 67% |
| Producción | 730h | 730h | 0% |

---

## 10. Reserved Instances y Savings Plans

Los Savings Plans ofrecen descuentos a cambio de compromiso de gasto por hora. Terraform no los provisiona directamente, pero prepara la infraestructura para maximizar su beneficio.

**Tipos de compromiso:**

| Tipo | Flexibilidad | Descuento máximo | Aplica a |
|------|-------------|-----------------|---------|
| Compute Savings Plan | Alta (EC2+Fargate+Lambda, cualquier región) | 66% | Compute en general |
| EC2 Instance SP | Media (familia fija) | 72% | EC2 específico |
| RDS Reserved | Baja (tipo+AZ fijo) | 69% | RDS |
| ElastiCache Reserved | Baja | 55% | ElastiCache |

```hcl
# Terraform prepara la infraestructura para maximizar coverage de SP:
# Variables flexibles de tipo de instancia → fácil de ajustar antes de comprar
variable "instance_family" {
  type    = string
  default = "m6i"   # Cambiar familia completa con una sola variable
}

# Tags de tracking para coverage analysis
resource "aws_instance" "app" {
  instance_type = "${var.instance_family}.large"
  tags = merge(local.common_tags, {
    SavingsPlanEligible = "true"    # Tag para reportes de coverage
    CommitmentType      = "1year"   # Para recordar el plazo del compromiso
  })
}
```

---

## 11. Resumen: Las Palancas de Optimización de Costes

```
Impacto vs Esfuerzo de implementación:

IMPACTO ALTO
    │
    │  ✦ Spot Instances (70-90%)
    │  ✦ Scheduling non-prod (65-78%)
    │  ✦ Reserved/Savings Plans (50-72%)
    │  ✦ Graviton migration (20-40%)
    │
    │  ✧ Right-sizing (10-50%)
    │  ✧ S3 Lifecycle (hasta 95% en archivos)
    │  ✧ Log retention policies
    │
IMPACTO BAJO
    │
    └────────────────────────────────────── ESFUERZO →
         Bajo                              Alto
```

**Hoja de ruta FinOps con Terraform:**

1. `aws_budgets_budget` — Visibilidad inmediata (1 día)
2. `default_tags` + Cost Allocation Tags — Asignación por equipo (1 día)
3. `retention_in_days` en Log Groups — Limpieza de logs (horas)
4. `aws_ce_anomaly_monitor` — Protección contra spikes (1 día)
5. Infracost en CI/CD — Visibilidad pre-deploy (2 días)
6. Right-sizing con variables flexibles — Revisión mensual
7. Spot Instances en ASG — Para cargas tolerantes a interrupciones
8. Graviton migration — Para cargas estables en producción
9. Scheduling non-prod — Ahorro inmediato en entornos dev/staging
10. Reserved/Savings Plans — Después de estabilizar la arquitectura

---

> [← Volver al índice](./README.md) | [Siguiente →](./05_compliance_code.md)
