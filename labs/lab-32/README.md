# Laboratorio 32: FinOps y Rendimiento: Optimización de Cómputo

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 7 — Cómputo en AWS con Terraform](../../modulos/modulo-07/README.md)


## Visión general

En este laboratorio aplicarás técnicas avanzadas para reducir la factura de AWS y mejorar la latencia de tus servicios. Aprenderás a configurar una **estrategia de Fargate Spot** con ratio 3:1 frente a On-Demand para ahorrar hasta un 70% en el coste de cómputo de tus contenedores, a eliminar los **cold starts de Lambda** con Provisioned Concurrency sobre un alias versionado, a desplegar Lambda dentro de una **VPC privada** con `vpc_config` para acceder a bases de datos internas sin exponer esos recursos a internet, y a habilitar **observabilidad de costes** con Container Insights, CloudWatch Alarms y notificaciones SNS.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Configurar `aws_ecs_cluster_capacity_providers` con `FARGATE` y `FARGATE_SPOT` usando una estrategia de peso 3:1 para distribuir tareas entre capacidad Spot (barata) y On-Demand (estable)
- Publicar versiones numeradas de Lambda con `publish = true` y crear un `aws_lambda_alias` que actúe como punto de entrada estable mientras el código evoluciona
- Configurar `aws_lambda_provisioned_concurrency_config` sobre un alias para mantener instancias pre-calentadas y verificar la ausencia de cold start con la variable `AWS_LAMBDA_INITIALIZATION_TYPE`
- Desplegar Lambda en subredes privadas mediante `vpc_config` y adjuntar `AWSLambdaVPCAccessExecutionRole` para que el servicio Lambda pueda crear las ENIs necesarias
- Activar Container Insights en el cluster ECS con el bloque `setting { name = "containerInsights", value = "enabled" }`
- Crear un `aws_cloudwatch_metric_alarm` sobre `CPUUtilization` con `evaluation_periods = 2` para evitar falsas alarmas por picos momentáneos, y enrutar notificaciones a un `aws_sns_topic`

## Requisitos Previos

- Terraform >= 1.5 instalado
- Laboratorio 2 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir
- Perfil AWS con permisos sobre Lambda, ECS, EC2 (VPC), IAM, CloudWatch y SNS

---

## Conceptos Clave

### Estrategia Spot: Capacity Providers en ECS Fargate

`aws_ecs_cluster_capacity_providers` define qué tipos de capacidad puede usar el cluster y cuál es la estrategia por defecto. La estrategia de peso 3:1 indica que por cada 4 tareas nuevas, 3 se solicitan en FARGATE_SPOT y 1 en FARGATE On-Demand:

```hcl
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 3
    base              = 0
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1  # garantiza al menos 1 tarea On-Demand siempre activa
  }
}
```

`base = 1` en FARGATE es crítico: asegura que al menos 1 tarea On-Demand esté activa antes de distribuir el resto según los pesos. Esto protege el servicio de una interrupción total si AWS reclama toda la capacidad Spot disponible.

AWS puede interrumpir las tareas FARGATE_SPOT con 2 minutos de aviso cuando necesita recuperar capacidad. Por eso, las aplicaciones que usen Spot deben ser **stateless** y capaces de terminar limpiamente en ese tiempo.

### Alias de Lambda y Versiones Publicadas

Con `publish = true`, cada `terraform apply` que cambie el código ZIP genera una versión numerada e inmutable. `aws_lambda_alias` crea un nombre estable que apunta a una versión concreta:

```hcl
resource "aws_lambda_function" "main" {
  publish = true
  # ...
}

resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.main.function_name
  function_version = aws_lambda_function.main.version  # versión más reciente publicada
}
```

Los clientes que invocan el alias `live` siempre reciben la misma versión hasta que el alias se actualice explícitamente. Esto permite hacer rollback cambiando `function_version` sin afectar la integración del cliente.

### Provisioned Concurrency: Eliminación de Cold Starts

`aws_lambda_provisioned_concurrency_config` mantiene un número fijo de contenedores Lambda inicializados y listos para responder. Las invocaciones al alias reciben una instancia pre-calentada sin pasar por el proceso de inicialización:

```hcl
resource "aws_lambda_provisioned_concurrency_config" "live" {
  function_name                      = aws_lambda_function.main.function_name
  qualifier                          = aws_lambda_alias.live.name
  provisioned_concurrent_executions  = 5
}
```

La variable de entorno `AWS_LAMBDA_INITIALIZATION_TYPE` es la forma oficial de verificar si una invocación usó un contenedor pre-calentado:

```python
init_type = os.environ.get("AWS_LAMBDA_INITIALIZATION_TYPE", "on-demand")
# "provisioned-concurrency" → sin cold start
# "on-demand"               → cold start normal
```

> **Coste de Provisioned Concurrency**: se factura por GB-segundo de capacidad reservada, independientemente de si hay invocaciones. 5 instancias de 128 MB durante 1 hora ≈ 0,013 USD. Desactiva la configuración (`terraform destroy` o `provisioned_concurrent_executions = 0`) cuando no la necesites.

### Lambda en VPC: vpc_config y Subredes Privadas

`vpc_config` conecta Lambda a tu VPC creando ENIs (Elastic Network Interfaces) en las subredes especificadas. Lambda usa esas ENIs para alcanzar recursos privados como RDS, ElastiCache o servicios internos:

```hcl
resource "aws_lambda_function" "main" {
  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }
}
```

Sin `AWSLambdaVPCAccessExecutionRole`, el despliegue falla con un error de permisos porque el servicio Lambda no puede crear ni eliminar las ENIs:

```hcl
resource "aws_iam_role_policy_attachment" "lambda_vpc" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}
```

Lambda en subredes **privadas** (sin ruta a internet) puede acceder a recursos VPC internos pero no a internet. Para que Lambda también pueda llamar a APIs externas, necesita un NAT Gateway o VPC Endpoints para los servicios AWS que use.

### Observabilidad: Container Insights, CloudWatch Alarm y SNS

Container Insights activa métricas por contenedor (CPU, memoria, red, disco) adicionales a las métricas estándar de servicio:

```hcl
resource "aws_ecs_cluster" "main" {
  setting {
    name  = "containerInsights"
    value = "enabled"
  }
}
```

La alarma usa `evaluation_periods = 2` para requerir que la condición se cumpla durante 2 periodos consecutivos antes de activarse. Esto evita falsas alarmas por picos momentáneos durante el arranque de contenedores:

```hcl
resource "aws_cloudwatch_metric_alarm" "ecs_cpu" {
  namespace           = "AWS/ECS"
  metric_name         = "CPUUtilization"
  dimensions          = { ClusterName = "...", ServiceName = "..." }
  period              = 60
  evaluation_periods  = 2   # 2 minutos sostenidos > 80% para activar
  statistic           = "Average"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
```

---

## Estructura del proyecto

```
lab32/
└── aws/
    ├── aws.s3.tfbackend      # Parámetros del backend S3 (sin bucket)
    ├── providers.tf          # Backend S3, Terraform >= 1.5, providers AWS y archive
    ├── variables.tf          # region, project, runtime, provisioned_concurrency,
    │                         # ecs_desired_count, alert_email
    ├── main.tf               # VPC+subredes+SGs, IAM (Lambda+ECS), CloudWatch,
    │                         # Lambda+Alias+Provisioned Concurrency, ECS cluster+
    │                         # capacity providers+task def+service, SNS, CW Alarm
    ├── outputs.tf            # function_name, function_version, alias_arn,
    │                         # cluster_name, alarm_name, invoke_alias_example
    └── src/
        └── function/
            └── handler.py    # Muestra init_type y vpc_hostname en la respuesta
```

> **Nota**: `function.zip` es un artefacto generado por `archive_file` durante `terraform plan/apply`. No se versiona en Git — añádelo a `.gitignore`.

---

## 1. Despliegue en AWS Real

### 1.1 Arquitectura

```
┌──────────────────────────────────────────────────────────────────────────┐
│  VPC: lab32-vpc (10.28.0.0/16)                                           │
│                                                                          │
│  Subredes privadas (Lambda)          Subredes públicas (ECS)             │
│  10.28.1.0/24 · us-east-1a           10.28.10.0/24 · us-east-1a          │
│  10.28.2.0/24 · us-east-1b           10.28.11.0/24 · us-east-1b          │
│                                                                          │
│  ┌───────────────────────────────┐    ┌───────────────────────────────┐  │
│  │  Lambda: lab32-function       │    │  ECS: lab32-cluster           │  │
│  │  Python 3.12 · publish = true │    │  Container Insights: enabled  │  │
│  │  vpc_config → subredes priv.  │    │                               │  │
│  │  SG: lab32-lambda-sg          │    │  Capacity Providers:          │  │
│  │                               │    │    FARGATE_SPOT  weight = 3   │  │
│  │  Alias "live" → versión N     │    │    FARGATE       weight = 1   │  │
│  │  Provisioned Concurrency: 5   │    │    (base = 1 On-Demand)       │  │
│  └───────────────────────────────┘    │                               │  │
│                                       │  Service: lab32-service       │  │
│                                       │  desired_count = 2            │  │
│                                       │  nginx:stable-alpine          │  │
│                                       └───────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────────┘
                    │ CPUUtilization > 80% · 2 períodos
                    ▼
         ┌──────────────────────┐
         │  CloudWatch Alarm    │────► SNS: lab32-alerts ────► Email (opcional)
         │  lab32-ecs-cpu-high  │
         └──────────────────────┘

Terraform local:
  data "archive_file" "function" → src/function/ → function.zip
  source_code_hash               → hash del ZIP  → detecta cambios → redeploy + nueva versión
```

### 1.2 Código Terraform

**`aws/main.tf`** — Fragmentos clave:

Lambda se despliega con `publish = true` y `vpc_config`. Ambos son independientes entre sí — cualquier función puede tener uno, ambos o ninguno:

```hcl
resource "aws_lambda_function" "main" {
  function_name    = "${var.project}-function"
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256
  runtime          = var.runtime
  handler          = "handler.lambda_handler"
  role             = aws_iam_role.lambda.arn
  publish          = true  # genera versión numerada en cada cambio de código

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id
    security_group_ids = [aws_security_group.lambda.id]
  }
}
```

Provisioned Concurrency requiere que el `qualifier` sea un alias o un número de versión — nunca `$LATEST`:

```hcl
resource "aws_lambda_provisioned_concurrency_config" "live" {
  function_name                      = aws_lambda_function.main.function_name
  qualifier                          = aws_lambda_alias.live.name  # alias "live", no $LATEST
  provisioned_concurrent_executions  = var.provisioned_concurrency
}
```

La estrategia Spot se define en `aws_ecs_cluster_capacity_providers`, separado del recurso de cluster. Esto permite modificar la estrategia sin recrear el cluster:

```hcl
resource "aws_ecs_cluster_capacity_providers" "main" {
  cluster_name       = aws_ecs_cluster.main.name
  capacity_providers = ["FARGATE", "FARGATE_SPOT"]

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 3
    base              = 0
  }

  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
    base              = 1
  }
}
```

### 1.3 Inicialización y despliegue

```bash
export BUCKET="terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"

# Desde lab32/aws/
terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform plan
terraform apply
```

> **Nota sobre Provisioned Concurrency**: `terraform apply` puede tardar 2–5 minutos adicionales mientras AWS aprovisiona los 5 contenedores Lambda. Es normal — el recurso `aws_lambda_provisioned_concurrency_config` espera a que el estado sea `READY`.

Al finalizar, los outputs mostrarán:

```
alarm_name           = "lab32-ecs-cpu-high"
alias_arn            = "arn:aws:lambda:us-east-1:123456789:function:lab32-function:live"
alias_invoke_arn     = "arn:aws:apigateway:us-east-1:lambda:path/..."
cluster_name         = "lab32-cluster"
function_name        = "lab32-function"
function_version     = "1"
invoke_alias_example = "aws lambda invoke --function-name lab32-function --qualifier live ..."
invoke_latest_example= "aws lambda invoke --function-name lab32-function ..."
lambda_sg_id         = "sg-0abc123..."
log_group_ecs        = "/ecs/lab32"
log_group_lambda     = "/aws/lambda/lab32-function"
private_subnet_ids   = ["subnet-0abc...", "subnet-0def..."]
service_name         = "lab32-service"
sns_topic_arn        = "arn:aws:sns:us-east-1:123456789:lab32-alerts"
vpc_id               = "vpc-0abc123..."
```

### 1.4 Verificar el sistema

**Paso 1** — Verifica Provisioned Concurrency y el alias:

```bash
FUNCTION=$(terraform output -raw function_name)

# Estado de la Provisioned Concurrency sobre el alias "live"
aws lambda get-provisioned-concurrency-config \
  --function-name "$FUNCTION" \
  --qualifier live \
  --query '{Solicitada:RequestedProvisionedConcurrentExecutions,Asignada:AllocatedProvisionedConcurrentExecutions,Estado:Status}'
```

El estado debe ser `READY`. Si muestra `IN_PROGRESS`, espera un minuto y repite.

**Paso 2** — Invoca a través del alias y verifica que no hay cold start:

```bash
# Invocación vía alias "live" → init_type debe ser "provisioned-concurrency"
terraform output -raw invoke_alias_example | bash
```

Respuesta esperada:
```json
{
  "statusCode": 200,
  "body": {
    "function_name": "lab32-function",
    "function_version": "1",
    "init_type": "provisioned-concurrency",
    "vpc_hostname": "169.254.x.x",
    "env": "production",
    ...
  }
}
```

**Paso 3** — Contrasta con una invocación a `$LATEST` (sin Provisioned Concurrency):

```bash
# Invocación a $LATEST → init_type puede ser "on-demand" (cold start)
terraform output -raw invoke_latest_example | bash
```

Si es la primera invocación a `$LATEST`, verás `"init_type": "on-demand"` y un tiempo de respuesta mayor.

**Paso 4** — Verifica la configuración VPC de Lambda:

```bash
aws lambda get-function-configuration \
  --function-name "$FUNCTION" \
  --query 'VpcConfig.{Subredes:SubnetIds,SG:SecurityGroupIds,VPC:VpcId}'
```

**Paso 5** — Verifica la estrategia Spot del cluster ECS:

> **Nota**: en la consola de ECS la columna *Launch type* muestra `Fargate` para **todas** las tareas, tanto FARGATE como FARGATE_SPOT. Eso es correcto — ambas usan la misma infraestructura Fargate. La distinción está en la columna *Capacity provider*, no en el launch type.

```bash
CLUSTER=$(terraform output -raw cluster_name)
SERVICE=$(terraform output -raw service_name)

# Estrategia configurada en el servicio
aws ecs describe-services \
  --cluster "$CLUSTER" \
  --services "$SERVICE" \
  --query 'services[0].{Deseadas:desiredCount,Corriendo:runningCount,Estrategia:capacityProviderStrategy}'

# Capacity provider real de cada tarea en ejecución
TASK_ARNS=$(aws ecs list-tasks --cluster "$CLUSTER" --query 'taskArns[]' --output text)

aws ecs describe-tasks \
  --cluster "$CLUSTER" \
  --tasks $TASK_ARNS \
  --query 'tasks[*].{ID:taskArn,LaunchType:launchType,CapacityProvider:capacityProviderName}'
```

La salida mostrará `"LaunchType": "Fargate"` en todas las tareas y `"CapacityProvider": "FARGATE_SPOT"` o `"FARGATE"` según la distribución 3:1. Con `desired_count = 2` y `base = 1`, una tarea irá a FARGATE (el base) y la otra a FARGATE_SPOT.

**Paso 6** — Verifica la alarma CloudWatch:

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$(terraform output -raw alarm_name)" \
  --query 'MetricAlarms[0].{Estado:StateValue,Umbral:Threshold,Periodos:EvaluationPeriods}'
```

La alarma comenzará en `INSUFFICIENT_DATA` y pasará a `OK` tras el primer ciclo de 60 segundos si el cluster tiene tareas corriendo con CPU < 80%.

**Paso 7** — Verifica la suscripción SNS (si configuraste `alert_email`):

```bash
aws sns list-subscriptions-by-topic \
  --topic-arn "$(terraform output -raw sns_topic_arn)" \
  --query 'Subscriptions[*].{Protocolo:Protocol,Endpoint:Endpoint,Estado:SubscriptionArn}'
```

Si la suscripción está en `PendingConfirmation`, revisa tu bandeja de entrada y confirma el email de AWS.

### 1.5 Publicar una nueva versión y ver cómo avanza el alias

Cuando modificas el código y aplicas, Terraform publica una nueva versión y actualiza el alias automáticamente:

```bash
# Añade un comentario al handler para cambiar el hash del ZIP
echo "# v1.1" >> src/function/handler.py

terraform plan
# ~ source_code_hash = "aBcDe..." -> "XyZwV..."
# + function_version: "1" -> "2" (nueva versión publicada)

terraform apply

# Verifica que el alias apunta ahora a la versión 2
aws lambda get-alias \
  --function-name "$(terraform output -raw function_name)" \
  --name live \
  --query '{Alias:Name,Version:FunctionVersion}'

# Invoca vía el alias "live" — ahora apunta a la versión 2
# El campo "function_version" en la respuesta debe mostrar "2"
terraform output -raw invoke_alias_example | bash
```

El alias `live` siempre usa `--qualifier live`, no el número de versión directamente. Eso es correcto: el alias actúa como punto de entrada estable. Lo que cambia en la respuesta es `"function_version": "2"` — el handler expone `context.function_version`, que refleja la versión real que ejecutó AWS.

---

> **Antes de comenzar los retos**, verifica que la invocación al alias devuelve `"init_type": "provisioned-concurrency"` y que el servicio ECS tiene tareas en estado `RUNNING`.

## 2. Reto 1: Lambda Function URL para Invocacion Directa

La función Lambda está dentro de una VPC y actualmente solo se puede invocar con `aws lambda invoke`. Añadir una **Lambda Function URL** permite invocarla directamente mediante HTTPS sin necesidad de API Gateway, manteniendo el alias y la Provisioned Concurrency activos.

### Requisitos

1. Crea `aws_lambda_function_url` apuntando al alias `"live"` (usa `qualifier = aws_lambda_alias.live.name`).
   - `authorization_type = "NONE"` para permitir invocaciones sin autenticación (válido para laboratorio; en producción usa `"AWS_IAM"`).
   - El provider AWS añade automáticamente los permisos necesarios (`lambda:InvokeFunctionUrl` y `lambda:InvokeFunction`) al crear el recurso.
2. Añade un output `function_url` con la URL generada.
3. Invoca la URL con `curl` y verifica que `init_type` es `"provisioned-concurrency"`.

### Criterios de éxito

- `terraform output -raw function_url` devuelve una URL `https://` válida.
- `curl -s "$(terraform output -raw function_url)" | python3 -m json.tool` devuelve la respuesta del handler con `"init_type": "provisioned-concurrency"`.
- Puedes explicar por qué la Function URL debe apuntar al alias y no a `$LATEST` para beneficiarse de la Provisioned Concurrency.

[Ver solución →](#4-solución-de-los-retos)

---

## 3. Reto 2: ECS Auto Scaling con Target Tracking

El servicio ECS tiene `desired_count` fijo. En producción, el número de tareas debe adaptarse a la carga real. El objetivo es añadir un **Auto Scaling** basado en CPU que escale entre 1 y 6 tareas manteniendo la CPU media por debajo del 60%.

### Requisitos

1. Registra el servicio ECS como objetivo escalable con `aws_appautoscaling_target`:
   - `min_capacity = 1`, `max_capacity = 6`
   - `resource_id = "service/${cluster_name}/${service_name}"`
   - `scalable_dimension = "ecs:service:DesiredCount"`
   - `service_namespace = "ecs"`
2. Crea `aws_appautoscaling_policy` de tipo `TargetTrackingScaling`:
   - `target_value = 60` (mantener CPU < 60%)
   - `predefined_metric_type = "ECSServiceAverageCPUUtilization"`
   - `scale_in_cooldown = 300`, `scale_out_cooldown = 60`
3. Añade outputs `autoscaling_min`, `autoscaling_max` y `autoscaling_target_cpu`.

### Criterios de éxito

- `aws application-autoscaling describe-scalable-targets --service-namespace ecs` muestra el servicio registrado con `min = 1` y `max = 6`.
- `aws application-autoscaling describe-scaling-policies --service-namespace ecs` muestra la política con `TargetValue: 60.0`.
- Puedes explicar la diferencia entre `scale_in_cooldown` (300 s) y `scale_out_cooldown` (60 s) y por qué se recomienda un cooldown de scale-in más largo.

[Ver solución →](#4-solución-de-los-retos)

---

## 4. Solución de los Retos

> Intenta resolver los retos antes de leer esta sección.

### Solución Reto 1 — Lambda Function URL

Añade en `main.tf`:

```hcl
resource "aws_lambda_function_url" "live" {
  function_name      = aws_lambda_function.main.function_name
  qualifier          = aws_lambda_alias.live.name
  authorization_type = "NONE"
}
```

El provider AWS añade automáticamente dos statements en la resource-based policy al crear este recurso con `authorization_type = "NONE"`:

- `lambda:InvokeFunctionUrl` con condición `FunctionUrlAuthType: NONE`
- `lambda:InvokeFunction` con condición `InvokedViaFunctionUrl: true`

Ambos son necesarios para que la URL funcione. AWS no los elimina al hacer `terraform destroy` — deben borrarse manualmente si se destruye y recrea la función con otro nombre.

Añade en `outputs.tf`:

```hcl
output "function_url" {
  description = "URL HTTPS para invocar Lambda directamente (alias 'live')"
  value       = aws_lambda_function_url.live.function_url
}
```

Verifica:

```bash
terraform apply

FURL=$(terraform output -raw function_url)
echo "Function URL: $FURL"

curl -s "$FURL" | python3 -m json.tool
```

La respuesta debe incluir `"init_type": "provisioned-concurrency"` porque la URL está vinculada al alias, que tiene los 5 contenedores pre-calentados.

Si usaras `qualifier = "$LATEST"` o no especificaras qualifier, la URL apuntaría a `$LATEST` y la Provisioned Concurrency no se aplicaría — las primeras invocaciones sufrirían cold start.

### Solución Reto 2 — ECS Auto Scaling con Target Tracking

Añade en `main.tf`:

```hcl
resource "aws_appautoscaling_target" "ecs" {
  min_capacity       = 1
  max_capacity       = 6
  resource_id        = "service/${aws_ecs_cluster.main.name}/${aws_ecs_service.app.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "ecs_cpu" {
  name               = "${var.project}-ecs-cpu-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_in_cooldown  = 300  # espera 5 min antes de reducir tareas (evita thrashing)
    scale_out_cooldown = 60   # escala rápido hacia arriba ante picos de carga

    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
  }
}
```

Añade en `outputs.tf`:

```hcl
output "autoscaling_min" {
  value = aws_appautoscaling_target.ecs.min_capacity
}
output "autoscaling_max" {
  value = aws_appautoscaling_target.ecs.max_capacity
}
output "autoscaling_target_cpu" {
  value = 60
}
```

Verifica:

```bash
terraform apply

# Objetivo escalable registrado
aws application-autoscaling describe-scalable-targets \
  --service-namespace ecs \
  --query 'ScalableTargets[?ResourceId!=`null`].{ID:ResourceId,Min:MinCapacity,Max:MaxCapacity}'

# Política de tracking
aws application-autoscaling describe-scaling-policies \
  --service-namespace ecs \
  --query 'ScalingPolicies[*].{Nombre:PolicyName,Tipo:PolicyType,Target:TargetTrackingScalingPolicyConfiguration.TargetValue}'
```

`scale_in_cooldown = 300` evita que el Auto Scaling reduzca tareas inmediatamente después de un pico, lo que provocaría ciclos continuos de scale-out/scale-in ("thrashing"). `scale_out_cooldown = 60` permite reaccionar rápido ante picos de carga sin esperar.

---

## Verificación final

```bash
# Verificar que la funcion Lambda usa Provisioned Concurrency
aws lambda get-provisioned-concurrency-config \
  --function-name $(terraform output -raw lambda_function_name) \
  --qualifier live \
  --query 'RequestedProvisionedConcurrentExecutions'

# Invocar la funcion via alias y comprobar init_type
aws lambda invoke \
  --function-name "$(terraform output -raw lambda_function_name):live" \
  --payload '{}' /tmp/response.json && cat /tmp/response.json
# Esperado: "init_type": "provisioned-concurrency"

# Verificar tareas ECS en RUNNING
aws ecs list-tasks \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --query 'taskArns' --output table

# Comprobar la alarma de CloudWatch
aws cloudwatch describe-alarms \
  --query 'MetricAlarms[?contains(AlarmName,`lab32`)].{Name:AlarmName,State:StateValue}' \
  --output table
```

---

## 5. Limpieza

```bash
# Desde lab32/aws/
terraform destroy

# Eliminar el ZIP generado localmente
rm -f function.zip
```

`terraform destroy` elimina en orden correcto: primero la Provisioned Concurrency, luego el alias, luego la función (esto libera las ENIs de la VPC). Las ENIs pueden tardar hasta 15 minutos en eliminarse antes de que la VPC pueda borrarse.

> Si `terraform destroy` se queda esperando en las ENIs de Lambda, es el comportamiento normal. AWS las elimina automáticamente una vez que confirma que Lambda ya no las usa.

---

## Buenas prácticas aplicadas

- **`base = 1` en FARGATE On-Demand**: garantiza que siempre haya al menos una tarea estable. Sin este mínimo, si AWS reclama toda la capacidad Spot, el servicio puede quedar sin tareas.
- **Provisioned Concurrency solo sobre alias, nunca sobre `$LATEST`**: `$LATEST` es mutable y cambia con cada despliegue. Configurar Provisioned Concurrency sobre `$LATEST` produciría comportamiento impredecible y costes difíciles de controlar.
- **Desactiva Provisioned Concurrency fuera de horario**: si tu tráfico tiene un patrón horario claro (pico diurno), usa `aws_lambda_provisioned_concurrency_config` con un scheduled scaling para reducirla por la noche.
- **`AWSLambdaVPCAccessExecutionRole` es obligatoria**: Lambda necesita permisos para crear y limpiar las ENIs. Sin esta política, el despliegue fallará en la creación de la función o tardará mucho en destruirse.
- **`evaluation_periods = 2` en alarmas de CPU**: un solo periodo basta para activar una alarma, pero dos periodos consecutivos filtran los picos de arranque de contenedores (que generan CPU momentáneamente alta) sin retrasar la notificación ante problemas reales.
- **`scale_in_cooldown` largo**: reducir el número de tareas rápidamente ante bajadas de carga puede provocar que el sistema deba escalar de nuevo si la carga sube otro poco. Un cooldown de 300 s es un punto de partida razonable.

---

## Recursos

- [AWS — Fargate Spot](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/fargate-capacity-providers.html)
- [AWS — Lambda Provisioned Concurrency](https://docs.aws.amazon.com/lambda/latest/dg/provisioned-concurrency.html)
- [AWS — Lambda en VPC](https://docs.aws.amazon.com/lambda/latest/dg/configuration-vpc.html)
- [AWS — Container Insights para ECS](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/ContainerInsights.html)
- [Terraform — aws_ecs_cluster_capacity_providers](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_cluster_capacity_providers)
- [Terraform — aws_lambda_provisioned_concurrency_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_provisioned_concurrency_config)
- [Terraform — aws_appautoscaling_policy](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/appautoscaling_policy)
