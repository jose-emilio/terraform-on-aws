# Sección 4 — Serverless: Lambda y API Gateway

> [← Sección anterior](./03_ecs_fargate.md) | [Volver al índice →](./README.md)

---

## 4.1 Arquitectura Serverless: `aws_lambda_function`

Lambda lleva el concepto de abstracción al extremo: no hay instancias, no hay clusters, no hay sistemas operativos que parchear. Solo subes código y defines cuándo ejecutarlo. Pagas únicamente por el tiempo de ejecución real — hasta el milisegundo.

> *"Lambda es como contratar músicos por horas en lugar de tener una orquesta fija. Si no hay concierto, no hay coste. Si de repente necesitas 1000 músicos tocando a la vez, los tienes. La diferencia es que con Lambda eso ocurre en milisegundos."*

Terraform gestiona el ciclo completo de una función Lambda: empaquetado del código, configuración del runtime, permisos IAM, triggers y destinos.

```hcl
resource "aws_lambda_function" "api" {
  function_name    = "${var.project}-api"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "nodejs20.x"
  architectures    = ["arm64"]   # Graviton: 20% ahorro, mejor rendimiento

  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256   # Fuerza redeploy

  memory_size = 256    # MB — más memoria = más CPU
  timeout     = 30     # Segundos (default: 3s — ¡sorpresa!)

  logging_config {
    log_format = "JSON"   # Structured logging
    log_group  = aws_cloudwatch_log_group.lambda.name
  }

  tags = var.tags
}
```

**Atención al timeout**: el timeout por defecto de Lambda es **3 segundos**. Para cualquier función que haga llamadas a bases de datos o APIs externas, esto es insuficiente. Aumenta siempre conscientemente.

---

## 4.2 Empaquetado: `data.archive_file`

El data source `archive_file` genera un ZIP del código fuente en tiempo de `terraform plan`, sin necesidad de scripts externos. La clave está en `output_base64sha256`:

```hcl
data "archive_file" "api" {
  type        = "zip"
  source_dir  = "${path.module}/functions/api"   # Carpeta con el código
  output_path = "${path.module}/dist/api.zip"    # ZIP generado
}

resource "aws_lambda_function" "api" {
  # ...
  filename         = data.archive_file.api.output_path
  source_code_hash = data.archive_file.api.output_base64sha256
  # ↑↑↑ Si el código cambia, el hash cambia, Terraform hace redeploy
  #     Si el código NO cambia, no hay redeploy innecesario
}
```

Sin `source_code_hash`, Terraform no detecta cambios en el ZIP y nunca haría redeploy del código actualizado. Este es uno de los errores más comunes al desplegar Lambda por primera vez.

---

## 4.3 Despliegue desde S3: Para Paquetes Grandes y CI/CD

Para paquetes mayores de 50 MB (obligatorio) o para desacoplar el proceso de build del de infraestructura (recomendado en producción), el código se despliega desde S3:

```hcl
# ── Bucket para artefactos con versionado ──
resource "aws_s3_bucket" "artifacts" {
  bucket = "${var.project}-lambda-artifacts"
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration { status = "Enabled" }
}

# ── CI/CD sube el ZIP a S3 ──
resource "aws_s3_object" "lambda_code" {
  bucket = aws_s3_bucket.artifacts.id
  key    = "lambda/api-${var.app_version}.zip"
  source = data.archive_file.api.output_path
  etag   = data.archive_file.api.output_md5
}

# ── Lambda desde S3 ──
resource "aws_lambda_function" "api" {
  function_name    = "${var.project}-api"
  s3_bucket        = aws_s3_bucket.artifacts.id
  s3_key           = aws_s3_object.lambda_code.key
  s3_object_version = aws_s3_object.lambda_code.version_id   # Para rollbacks

  # ... runtime, handler, role ...
}
```

Con `s3_object_version`, el rollback es trivial: cambias `var.app_version` a una versión anterior y haces `terraform apply`. El historial de versiones en S3 lo tienes todo.

---

## 4.4 Lambda Layers: Dependencias Compartidas

Un Lambda Layer es un ZIP con bibliotecas, runtimes custom o datos que se monta en `/opt` y se comparte entre múltiples funciones. Ventajas:

- Las funciones son más pequeñas y se despliegan más rápido
- Las dependencias se versionan independientemente del código
- Se pueden compartir entre cuentas AWS

```hcl
# ── Empaquetar dependencias ──
data "archive_file" "deps" {
  type        = "zip"
  source_dir  = "${path.module}/layers/nodejs"
  output_path = "${path.module}/dist/deps-layer.zip"
}

# ── Lambda Layer ──
resource "aws_lambda_layer_version" "deps" {
  layer_name          = "${var.project}-deps"
  filename            = data.archive_file.deps.output_path
  source_code_hash    = data.archive_file.deps.output_base64sha256
  compatible_runtimes = ["nodejs20.x", "nodejs18.x"]
  compatible_architectures = ["arm64"]
}

# ── Función que usa el Layer ──
resource "aws_lambda_function" "api" {
  # ... config base ...
  layers = [aws_lambda_layer_version.deps.arn]   # Hasta 5 layers por función
}
```

**Estructura del ZIP del layer**:
- Python: `python/lib/python3.12/site-packages/<librería>`
- Node.js: `nodejs/node_modules/<módulo>`
- Binarios: `bin/<ejecutable>`

---

## 4.5 Variables de Entorno: Configuración Dinámica

El bloque `environment {}` inyecta configuración sin tocar el código. Los valores se cifran en reposo con KMS:

```hcl
resource "aws_lambda_function" "api" {
  # ...
  environment {
    variables = {
      ENVIRONMENT  = var.environment
      DB_HOST      = aws_db_instance.main.endpoint
      TABLE_NAME   = aws_dynamodb_table.main.name
      BUCKET_NAME  = aws_s3_bucket.data.id
      LOG_LEVEL    = "INFO"
      # NUNCA: SECRET_KEY = "mi-secreto-en-plaintext"
    }
  }

  kms_key_arn = aws_kms_key.lambda.arn   # Cifrar las env vars en reposo
}

# ── Para secrets: usar SSM ──
data "aws_ssm_parameter" "db_password" {
  name = "/app/${var.environment}/db_password"
}

# Opción A: referencia en tiempo de apply (valor en state)
# environment { variables = { DB_PASS = data.aws_ssm_parameter.db_password.value } }

# Opción B (mejor): que Lambda lea el secret en runtime usando el SDK
# La función llama a SSM en cada arranque — el estado no contiene el valor
```

> *"Nunca pongas un secret en texto plano en una variable de entorno de Lambda. Aparecerá en el plan de Terraform, en los logs de CI/CD y en el state. Usa SSM SecureString o Secrets Manager."*

---

## 4.6 Execution Role: La Identidad de tu Lambda

El Execution Role es el IAM Role que Lambda asume para ejecutar. Sin él, la función no puede hacer nada: ni escribir logs, ni leer de S3, ni invocar otros servicios.

```hcl
# ── Trust Policy: solo Lambda puede asumir este rol ──
data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

# ── IAM Role ──
resource "aws_iam_role" "lambda" {
  name               = "${var.project}-lambda"
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

# ── CloudWatch Logs (mínimo obligatorio) ──
resource "aws_iam_role_policy_attachment" "logs" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# ── Permisos adicionales de la aplicación ──
resource "aws_iam_role_policy" "app" {
  name = "${var.project}-app"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "dynamodb:GetItem",
        "dynamodb:PutItem",
        "ssm:GetParameter"
      ]
      Resource = "*"   # En producción: especificar ARNs concretos
    }]
  })
}
```

Managed policies comunes según el caso:
- `AWSLambdaBasicExecutionRole` — CloudWatch Logs (siempre)
- `AWSLambdaVPCAccessExecutionRole` — ENI create/delete para VPC
- `AWSLambdaSQSQueueExecutionRole` — Leer y eliminar de SQS

---

## 4.7 `lambda_permission`: Control de Invocaciones

`aws_lambda_permission` es el guard de la función — autoriza a un servicio externo a invocarla. Sin este recurso, ni API Gateway, ni S3, ni EventBridge pueden invocar la función.

> *"Es la diferencia entre tener el número de teléfono de alguien (saber cómo llamar) y que esa persona tenga configurado tu número en su lista blanca (poder llamar realmente)."*

```hcl
# ── API Gateway invoca la función ──
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ── S3 Event Notification ──
resource "aws_lambda_permission" "s3" {
  statement_id  = "AllowS3Invoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.processor.function_name
  principal     = "s3.amazonaws.com"
  source_arn    = aws_s3_bucket.uploads.arn
}

# ── EventBridge Rule programada ──
resource "aws_lambda_permission" "events" {
  statement_id  = "AllowEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cron.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.schedule.arn
}
```

Necesitas un `aws_lambda_permission` por cada trigger diferente. Si tienes 3 reglas de EventBridge que invocan la misma función, necesitas 3 permissions con `statement_id` distintos.

---

## 4.8 Event Source Mappings: Triggers Poll-Based

A diferencia de los triggers push (S3, SNS, API GW) que usan `lambda_permission`, los triggers poll-based requieren `aws_lambda_event_source_mapping`. Lambda hace polling activo a la fuente:

```hcl
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn = aws_sqs_queue.orders.arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 10    # Mensajes procesados por invocación
  maximum_batching_window_in_seconds = 5   # Acumular hasta 5s

  enabled = true

  # Filtrar solo órdenes de tipo 'premium'
  filter_criteria {
    filter {
      pattern = jsonencode({
        body = {
          order_type = ["premium"]
        }
      })
    }
  }

  scaling_config {
    maximum_concurrency = 10   # Máximo pollers paralelos
  }

  function_response_types = ["ReportBatchItemFailures"]   # Partial batch success
}
```

**`filter_criteria`** es una feature de ahorro de costes: si solo el 20% de los mensajes SQS requieren procesamiento de Lambda, los filtros evitan invocar la función para el 80% restante.

**`ReportBatchItemFailures`** permite que Lambda devuelva qué mensajes específicos fallaron en un batch, en lugar de reintentar el batch entero.

---

## 4.9 Dead Letter Queue: Captura de Fallos

La DLQ captura las invocaciones asíncronas que fallan después de los reintentos:

```hcl
resource "aws_sqs_queue" "lambda_dlq" {
  name                      = "${var.project}-lambda-dlq"
  message_retention_seconds = 1209600   # 14 días para análisis
}

resource "aws_lambda_function" "async" {
  # ...
  dead_letter_config {
    target_arn = aws_sqs_queue.lambda_dlq.arn
  }
}

# ── Alarma: si algo llega a la DLQ, es un error ──
resource "aws_cloudwatch_metric_alarm" "dlq" {
  alarm_name          = "${var.project}-dlq-messages"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 300
  threshold           = 0   # Cualquier mensaje es anómalo
  dimensions          = { QueueName = aws_sqs_queue.lambda_dlq.name }
  alarm_actions       = [aws_sns_topic.alerts.arn]
}
```

La DLQ aplica solo a **invocaciones asíncronas** (S3, SNS, EventBridge). Para SQS, la DLQ se configura en la propia cola con `redrive_policy`.

---

## 4.10 Lambda Destinations: Enrutamiento por Resultado

Las Destinations son la evolución de la DLQ: enrutan el resultado de una invocación asíncrona a otro servicio, incluyen todo el contexto del error, y distinguen entre éxito y fallo:

```hcl
resource "aws_lambda_function_event_invoke_config" "main" {
  function_name                = aws_lambda_function.main.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600   # Descartar eventos de más de 1 hora

  destination_config {
    on_success {
      destination = aws_sqs_queue.success.arn   # Éxito → cola de éxitos
    }
    on_failure {
      destination = aws_sqs_queue.failures.arn   # Fallo → cola de fallos
    }
  }
}

resource "aws_sqs_queue" "success" {
  name = "${var.project}-lambda-success"
}

resource "aws_sqs_queue" "failures" {
  name                      = "${var.project}-lambda-failures"
  message_retention_seconds = 1209600   # 14 días
}
```

| | DLQ | Destinations |
|--|-----|-------------|
| Información | Solo el payload | Payload + request ID + stack trace |
| Éxito | No aplica | Puedes enrutar resultados exitosos también |
| Flexibilidad | SQS o SNS | SQS, SNS, Lambda o EventBridge |

---

## 4.11 Concurrencia Reservada: Límites y Protección

Lambda tiene un límite de **1000 ejecuciones concurrentes por región** (por defecto, aumentable). `reserved_concurrent_executions` reserva un número de esas 1000 para una función específica:

```hcl
# Reservar 50 ejecuciones para esta función crítica
resource "aws_lambda_function" "api" {
  # ...
  reserved_concurrent_executions = 50
}

# Desactivar completamente una función (mantenimiento)
resource "aws_lambda_function" "disabled" {
  # ...
  reserved_concurrent_executions = 0   # Throttle total = desactivada
}
```

**Usos estratégicos**:
- **Proteger downstream**: si tu Lambda escribe en RDS, limita la concurrencia al máximo de conexiones de la BD
- **Garantizar capacidad**: funciones críticas no compiten con otras por el pool
- **Rate limiting**: cumplir los límites de APIs externas

---

## 4.12 Provisioned Concurrency: Cero Cold Starts

Los cold starts son el talón de Aquiles de Lambda: la primera invocación después de un período de inactividad puede tardar 1-10 segundos porque AWS necesita inicializar el container. Para APIs síncronas de baja latencia, esto es inaceptable.

Provisioned Concurrency pre-calienta N instancias de la función, manteniéndolas siempre listas:

```hcl
# ── Lambda con versión publicada ──
resource "aws_lambda_function" "main" {
  # ...
  publish = true   # Obligatorio para Provisioned Concurrency
}

# ── Alias que apunta a la versión actual ──
resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.main.arn
  function_version = aws_lambda_function.main.version
}

# ── Provisioned Concurrency: 5 instancias siempre calientes ──
resource "aws_lambda_provisioned_concurrency_config" "main" {
  function_name                          = aws_lambda_function.main.function_name
  qualifier                              = aws_lambda_alias.live.name
  provisioned_concurrent_executions      = 5   # 5 instancias warm 24/7
}

# ── Auto Scaling del Provisioned Concurrency ──
resource "aws_appautoscaling_target" "lam" {
  max_capacity       = 50
  min_capacity       = 5
  resource_id        = "function:${aws_lambda_function.main.function_name}:live"
  scalable_dimension = "lambda:function:ProvisionedConcurrency"
  service_namespace  = "lambda"
}

resource "aws_appautoscaling_policy" "lam" {
  name        = "concurrency-scaling"
  policy_type = "TargetTrackingScaling"
  # ... ids from target ...
  target_tracking_scaling_policy_configuration {
    target_value = 0.7   # 70% de utilización del provisioned concurrency
    predefined_metric_specification {
      predefined_metric_type = "LambdaProvisionedConcurrencyUtilization"
    }
  }
}
```

**Coste**: Provisioned Concurrency tiene un coste adicional por hora de provisión. Combínalo con Auto Scaling para escalar el provisioning según el horario de tráfico.

---

## 4.13 Lambda en VPC: Acceso a Recursos Privados

Por defecto, Lambda ejecuta en la red de AWS y no tiene acceso a recursos en tu VPC privada (RDS, ElastiCache, instancias EC2). `vpc_config` conecta Lambda a subnets privadas:

```hcl
# ── Security Group para Lambda ──
resource "aws_security_group" "lambda" {
  name   = "${var.project}-lambda-sg"
  vpc_id = aws_vpc.main.id

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]   # Lambda necesita salida para STS, SSM, etc.
  }
}

# ── Lambda en VPC ──
resource "aws_lambda_function" "vpc" {
  function_name = "${var.project}-vpc-fn"
  runtime       = "python3.12"
  handler       = "main.handler"
  filename      = data.archive_file.fn.output_path
  role          = aws_iam_role.lambda_vpc.arn

  vpc_config {
    subnet_ids         = aws_subnet.private[*].id    # Mínimo 2 AZs
    security_group_ids = [aws_security_group.lambda.id]
  }
}
```

**Consideraciones importantes**:
- El Execution Role necesita `AWSLambdaVPCAccessExecutionRole` para crear ENIs
- Para acceder a servicios AWS (S3, SSM) desde una Lambda en VPC **sin internet**, necesitas **VPC Endpoints**
- Para acceder a internet (npm registries, APIs externas), necesitas **NAT Gateway**
- Los cold starts aumentan ~2-5 segundos en VPC (aunque AWS ha mejorado esto con Hyperplane)

---

## 4.14 API Gateway v2: HTTP APIs

`aws_apigatewayv2_api` crea HTTP APIs de baja latencia — la opción recomendada para la mayoría de los casos, especialmente microservicios y SPAs:

| | HTTP API (v2) | REST API (v1) |
|--|--------------|--------------|
| Coste | 70% menor | Referencia |
| Latencia | Hasta 60% menor | Referencia |
| CORS | Nativo en la API | Por recurso |
| JWT Auth | Nativo | Plugin |
| WAF | No directo | Sí |
| API Keys | No | Sí |
| Caching | No | Sí |

```hcl
resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project}-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["https://${var.domain}"]
    allow_methods = ["GET", "POST", "PUT", "DELETE"]
    allow_headers = ["Content-Type", "Authorization"]
  }
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true   # Cada cambio se despliega automáticamente
}

resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"   # Formato moderno de evento
}

resource "aws_apigatewayv2_route" "get_users" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /api/users"   # Método + path
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}
```

Cuatro recursos trabajan en cadena: `aws_apigatewayv2_api` → `aws_apigatewayv2_stage` → `aws_apigatewayv2_route` → `aws_apigatewayv2_integration` → `aws_lambda_function`.

---

## 4.15 Lambda@Edge y CloudFront Functions

Para ejecutar código en los edge locations de CloudFront — cerca del usuario final — hay dos opciones:

**Lambda@Edge**: runtime completo (Node.js/Python), hasta 5 segundos en viewer request/response y hasta **30 segundos** en origin request/response, hasta 4 triggers (viewer/origin request/response). **Debe desplegarse en us-east-1**.

**CloudFront Functions**: JavaScript puro sub-milisegundo, máximo 10 KB, solo viewer request/response. Ideal para headers, redirects y URL rewrites.

```hcl
# ── Lambda@Edge (SIEMPRE en us-east-1) ──
resource "aws_lambda_function" "edge" {
  provider      = aws.us_east_1   # Provider alias obligatorio
  function_name = "${var.project}-edge"
  role          = aws_iam_role.edge.arn
  runtime       = "nodejs20.x"
  handler       = "index.handler"
  filename      = data.archive_file.edge.output_path
  publish       = true   # Obligatorio para @Edge — necesita versión publicada
}

# ── CloudFront Distribution con Lambda@Edge ──
resource "aws_cloudfront_distribution" "cdn" {
  # ...
  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = local.origin_id

    lambda_function_association {
      event_type   = "viewer-request"
      lambda_arn   = aws_lambda_function.edge.qualified_arn   # qualified_arn incluye la versión
      include_body = false
    }

    viewer_protocol_policy = "redirect-to-https"
  }
  # ...
}
```

---

## 4.16 Troubleshooting: Problemas Comunes en Serverless

| Categoría | Problema | Solución |
|----------|---------|---------|
| **Despliegue** | `source_code_hash` no cambia → no hay redeploy | Verificar que `archive_file` incluye todos los ficheros |
| **Permisos** | `lambda_permission` faltante | Cada trigger necesita su propio `aws_lambda_permission` |
| **VPC** | Error al acceder a S3/SSM desde Lambda en VPC | Añadir VPC Endpoints o NAT Gateway |
| **Runtime** | Timeout en producción | Aumentar `timeout` — el default 3s es muy bajo |
| **Runtime** | Cold start de 10s en VPC | Usar Provisioned Concurrency o sacar Lambda de VPC |
| **API GW** | Error 403 al invocar la función | `source_arn` incorrecto en `lambda_permission` |
| **API GW** | CORS error en el browser | `allow_origins` no incluye el dominio del cliente |
| **Lambda@Edge** | Deploying en otra región que us-east-1 | El provider alias debe apuntar a us-east-1 |

---

## 4.17 Resumen: El Ecosistema Serverless en AWS

| Componente | Función | Clave |
|-----------|---------|-------|
| `aws_lambda_function` | La función en sí | `source_code_hash` para redeploy automático |
| `data.archive_file` | Empaquetar el código en ZIP | `output_base64sha256` como hash |
| S3 deploy | Para paquetes >50MB o CI/CD | `s3_object_version` para rollbacks |
| `aws_lambda_layer_version` | Dependencias compartidas | Hasta 5 por función, montado en `/opt` |
| `environment` | Variables de configuración | KMS encrypt, nunca secrets en plaintext |
| Execution Role | Identidad de la función | `AWSLambdaBasicExecutionRole` mínimo |
| `aws_lambda_permission` | Autorizar invocadores externos | Un resource por trigger distinto |
| `aws_lambda_event_source_mapping` | Triggers poll-based (SQS, DynamoDB Streams) | `filter_criteria` para reducir coste |
| Dead Letter Queue | Capturar fallos asíncronos | Alarma CW cuando DLQ > 0 |
| Destinations | Enrutar resultado on_success/on_failure | Reemplaza DLQ con más contexto |
| Reserved Concurrency | Limitar o garantizar capacidad | `= 0` para desactivar |
| Provisioned Concurrency | Eliminar cold starts | Solo sobre aliases/versiones |
| `vpc_config` | Acceso a recursos privados | Necesita VPC Endpoints o NAT |
| `aws_apigatewayv2_api` | HTTP API (v2) | 70% más barato que REST API |
| `auto_deploy = true` | Despliegue automático de stage | Con `$default` stage |
| Lambda@Edge | Edge computing en CloudFront | `publish = true` + provider us-east-1 |

---

> **[← Volver al índice del Módulo 7](./README.md)**
