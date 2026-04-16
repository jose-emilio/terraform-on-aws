# Sección 2 — Consolidación de Registros y Trazas

> [← Volver al índice](./README.md) | [Siguiente →](./03_tagging.md)

---

## 1. El Problema de la Dispersión: Por Qué Centralizar

Sin una estrategia de centralización, los datos de telemetría se dispersan entre decenas de cuentas y servicios. Terraform unifica el envío de logs hacia destinos especializados según el caso de uso.

> **El profesor explica:** "En una organización con 20 cuentas AWS, cada una tiene sus propios CloudWatch Log Groups, sus propios VPC Flow Logs, su propio CloudTrail. Cuando hay un incidente de seguridad a las 2 de la mañana y necesitas correlacionar actividad entre la cuenta de producción y la cuenta de red, tienes que abrir 5 consolas distintas y saltar entre ellas manualmente. La centralización es el prerrequisito de la correlación, y la correlación es el prerrequisito del tiempo de resolución rápido."

**Destinos según caso de uso:**

| Destino | Propósito | Retención | Coste |
|---------|-----------|-----------|-------|
| **S3** | Archivo a largo plazo, auditoría, Athena | Años con Glacier | Mínimo por TB |
| **CloudWatch** | Tiempo real, alarmas, Insights | 7-365 días | Medio |
| **OpenSearch** | Búsqueda full-text, análisis, Kibana | Semanas/meses | Alto |

---

## 2. VPC Flow Logs: Visibilidad Total de Red

VPC Flow Logs registra cada conexión aceptada o rechazada en la VPC — un requisito de seguridad y auditoría en cualquier entorno de producción.

```hcl
# VPC Flow Logs hacia CloudWatch (troubleshooting en tiempo real)
resource "aws_flow_log" "vpc_flow" {
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.vpc.arn
  traffic_type         = "ALL"   # ACCEPT + REJECT + ALL
  vpc_id               = aws_vpc.main.id
  iam_role_arn         = aws_iam_role.flow_log.arn

  max_aggregation_interval = 60   # Segundos: 60 o 600

  tags = local.common_tags
}

# Log Group centralizado para Flow Logs
resource "aws_cloudwatch_log_group" "vpc" {
  name              = "/aws/vpc/flow-logs"
  retention_in_days = 90
  kms_key_id        = aws_kms_key.logs.arn
}

# VPC Flow Logs hacia S3 (auditoría a largo plazo con Athena)
resource "aws_flow_log" "vpc_s3" {
  log_destination_type = "s3"
  log_destination      = "${aws_s3_bucket.audit.arn}/vpc-flow-logs/"
  traffic_type         = "ALL"
  vpc_id               = aws_vpc.main.id

  destination_options {
    file_format        = "parquet"   # Mejor rendimiento con Athena
    per_hour_partition = true         # Particionado para consultas eficientes
  }
}
```

---

## 3. CloudTrail: El Registro Inmutable de Auditoría

CloudTrail captura cada llamada a la API de AWS, creando un registro inmutable de toda la actividad. Sin CloudTrail, no hay respuesta posible a "¿quién borró ese recurso?".

> **El profesor explica:** "CloudTrail es el testigo que nunca miente. Cada `CreateInstance`, cada `DeleteBucket`, cada `AssumeRole` — todo queda registrado con la identidad del usuario, la IP de origen, la hora y los parámetros exactos. Cuando hay un incidente de seguridad, CloudTrail es el primer sitio al que voy. Si no está configurado con `is_organization_trail = true` y `enable_log_file_validation = true`, no tienes un trail de auditoría — tienes una ilusión de auditoría."

```hcl
# CloudTrail Multi-Cuenta y Multi-Región (nivel organización)
resource "aws_cloudtrail" "org_trail" {
  name                       = "org-audit-trail"
  s3_bucket_name             = aws_s3_bucket.audit.id
  is_multi_region_trail      = true    # Captura actividad en todas las regiones
  is_organization_trail      = true    # Aplica a toda la organización AWS

  enable_log_file_validation = true    # SHA-256 digest para probar integridad
  kms_key_id                 = aws_kms_key.audit.arn

  include_global_service_events = true   # IAM, STS, Route53

  # Envío también a CloudWatch para alertas en tiempo real
  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.trail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.trail.arn

  # Data Events: capturar accesos a S3 y Lambda (caro, usar con scope)
  event_selector {
    read_write_type           = "WriteOnly"   # Solo escrituras para reducir volumen
    include_management_events = true

    data_resource {
      type   = "AWS::S3::Object"
      values = ["arn:aws:s3:::${var.critical_bucket}/"]
    }
  }

  tags = local.common_tags
}
```

**Tipos de eventos CloudTrail:**

| Tipo | Qué captura | Coste |
|------|-------------|-------|
| Management Events | Create, Delete, Modify de recursos | Gratis (primer trail) |
| Data Events | Accesos a objetos S3, invocaciones Lambda | $0.10/100K eventos |
| Insights Events | Anomalías en la actividad de la API | Costo adicional |

---

## 4. Arquitectura Hub & Spoke: Cross-Account Logging

El patrón Hub & Spoke centraliza la operación: cada cuenta workload envía sus logs a una cuenta dedicada de monitoreo, creando una única consola de observabilidad.

```
Cuenta App 1 (Spoke)          Cuenta App 2 (Spoke)
─────────────────────         ─────────────────────
CW Subscription Filter ───┐   CW Subscription Filter ───┐
  (filtra por patrón)      │     (filtra por patrón)     │
                           ▼                             ▼
                   Cuenta Monitoring (Hub)
                   ──────────────────────
                   CW Destination Central
                         │
                         ▼
                   Kinesis Firehose
                         │
                    ┌────┴────┐
                    ▼         ▼
               OpenSearch    S3
               (análisis)  (archivo)
```

```hcl
# Hub: Receptor Central de Logs
resource "aws_cloudwatch_log_destination" "hub" {
  name       = "central-log-hub"
  role_arn   = aws_iam_role.cw_dest.arn
  target_arn = aws_kinesis_firehose_delivery_stream.logs.arn
}

# Resource Policy: permite que todas las cuentas de la organización escriban
resource "aws_cloudwatch_log_destination_policy" "org" {
  destination_name = aws_cloudwatch_log_destination.hub.name

  access_policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = "*" }
      Action    = "logs:PutSubscriptionFilter"
      Resource  = aws_cloudwatch_log_destination.hub.arn
      Condition = {
        StringEquals = {
          "aws:PrincipalOrgID" = var.org_id
        }
      }
    }]
  })
}

# Spoke: Subscription Filter (en cada cuenta workload)
resource "aws_cloudwatch_log_subscription_filter" "to_hub" {
  name            = "forward-to-central"
  log_group_name  = aws_cloudwatch_log_group.app.name
  filter_pattern  = "{ $.level = \"ERROR\" || $.level = \"WARN\" }"
  destination_arn = "arn:aws:logs:us-east-1:MONITORING_ACCOUNT:destination:central-log-hub"
}
```

---

## 5. Protección de Datos: Enmascaramiento de PII

CloudWatch Logs detecta y enmascara automáticamente datos sensibles como emails, tarjetas de crédito e identificadores personales. Cumplimiento GDPR/PCI-DSS mediante reglas de infraestructura.

```hcl
resource "aws_cloudwatch_log_data_protection_policy" "pii" {
  log_group_name = aws_cloudwatch_log_group.app.name

  policy_document = jsonencode({
    Name    = "pii-protection"
    Version = "2021-06-01"
    Statement = [
      {
        Sid            = "audit-pii-detected"
        DataIdentifier = [
          "arn:aws:dataprotection::aws:data-identifier/EmailAddress",
          "arn:aws:dataprotection::aws:data-identifier/CreditCardNumber",
          "arn:aws:dataprotection::aws:data-identifier/IpAddress",
        ]
        Operation = { Audit = { FindingsDestination = {
          S3 = { Bucket = aws_s3_bucket.audit.bucket }
        }}}
      },
      {
        Sid            = "mask-pii-in-logs"
        DataIdentifier = [
          "arn:aws:dataprotection::aws:data-identifier/EmailAddress",
          "arn:aws:dataprotection::aws:data-identifier/CreditCardNumber",
        ]
        Operation = { Deidentify = { MaskConfig = {} } }   # Reemplaza con ****
      }
    ]
  })
}
```

---

## 6. OpenSearch Domain: Análisis Avanzado de Logs

OpenSearch proporciona búsqueda full-text e indexación en tiempo real sobre volúmenes masivos de logs.

```hcl
resource "aws_opensearch_domain" "logs" {
  domain_name    = "log-analytics"
  engine_version = "OpenSearch_2.11"

  cluster_config {
    instance_type          = "r6g.large.search"   # Graviton: 20% más económico
    instance_count         = 3
    zone_awareness_enabled = true   # Multi-AZ

    dedicated_master_enabled = true
    dedicated_master_type    = "r6g.large.search"
    dedicated_master_count   = 3
  }

  ebs_options {
    ebs_enabled = true
    volume_size = 100
    volume_type = "gp3"
  }

  encrypt_at_rest {
    enabled    = true
    kms_key_id = aws_kms_key.logs.arn
  }

  node_to_node_encryption {
    enabled = true   # TLS entre nodos del cluster
  }

  vpc_options {
    subnet_ids         = module.vpc.private_subnets
    security_group_ids = [aws_security_group.opensearch.id]
  }

  access_policies = data.aws_iam_policy_document.os.json

  tags = local.common_tags
}
```

---

## 7. OpenSearch Serverless: Vector Search para IA

Las colecciones VECTORSEARCH permiten almacenar y consultar embeddings generados por modelos de IA. Ideal para RAG, búsqueda semántica y recomendaciones sin gestionar infraestructura.

```hcl
# Política de cifrado
resource "aws_opensearchserverless_security_policy" "enc" {
  name = "vector-encryption"
  type = "encryption"
  policy = jsonencode({
    Rules = [{
      ResourceType = "collection"
      Resource     = ["collection/vector-kb"]
    }]
    AWSOwnedKey = true
  })
}

# Colección Serverless de tipo VectorSearch
resource "aws_opensearchserverless_collection" "kb" {
  name = "vector-kb"
  type = "VECTORSEARCH"

  depends_on = [
    aws_opensearchserverless_security_policy.enc,
    aws_opensearchserverless_security_policy.net,
  ]
}

# Data Access Policy para Bedrock
resource "aws_opensearchserverless_access_policy" "bedrock" {
  name = "vector-access"
  type = "data"
  policy = jsonencode([{
    Rules = [{
      ResourceType = "index"
      Resource     = ["index/vector-kb/*"]
      Permission   = [
        "aoss:CreateIndex",
        "aoss:WriteDocument",
        "aoss:ReadDocument",
      ]
    }]
    Principal = [var.bedrock_role_arn]
  }])
}
```

---

## 8. Kinesis Data Firehose: El Router Universal

Firehose ingesta, transforma y entrega datos a destinos sin necesidad de gestionar infraestructura. Es el conector entre CloudWatch y el almacén final.

```hcl
resource "aws_kinesis_firehose_delivery_stream" "logs" {
  name        = "log-delivery-stream"
  destination = "opensearch"

  opensearch_configuration {
    domain_arn = aws_opensearch_domain.logs.arn
    role_arn   = aws_iam_role.firehose.arn
    index_name = "logs"

    buffering_size     = 5    # MB antes de enviar
    buffering_interval = 60   # Segundos máximo de espera

    # Backup de todos los documentos en S3 (resiliencia)
    s3_backup_mode = "AllDocuments"
    s3_configuration {
      role_arn   = aws_iam_role.firehose.arn
      bucket_arn = aws_s3_bucket.backup.arn
      prefix     = "firehose-backup/"
    }
  }

  tags = local.common_tags
}
```

**Capacidades de transformación en Firehose:**

| Capacidad | Descripción |
|-----------|-------------|
| Lambda Transform | ETL: parsear, enriquecer o filtrar registros |
| Format Conversion | Convertir JSON a Parquet/ORC para análisis |
| Dynamic Partitioning | Particionar S3 por date/hour/source automáticamente |
| GZIP/Snappy | Compresión antes de entregar al destino |

---

## 9. AWS X-Ray: Tracing Distribuido

X-Ray permite seguir una petición a través de múltiples saltos, identificando cuellos de botella y errores en cada segmento de la cadena de microservicios.

> **El profesor explica:** "Imagina que tienes una petición que tarda 800ms y no sabes por qué. Con métricas puedes saber que está lenta, pero no dónde. Con X-Ray puedes ver: 50ms en API Gateway, 200ms en Lambda (de los cuales 180ms son cold start), 400ms en DynamoDB (por un query sin índice), y 150ms en el downstream HTTP. X-Ray convierte 'el servicio está lento' en 'el query sin índice de DynamoDB es el culpable'. Esa es la diferencia entre observabilidad y debugging a ciegas."

```hcl
# Lambda con X-Ray Tracing Activo
resource "aws_lambda_function" "api" {
  function_name = "api-handler"
  runtime       = "python3.12"
  handler       = "main.handler"
  role          = aws_iam_role.lambda.arn

  tracing_config {
    mode = "Active"   # Active: muestrea todas las peticiones
                      # PassThrough: solo si el upstream lo solicita
  }

  environment {
    variables = {
      AWS_XRAY_TRACING_NAME   = "api-service"
      POWERTOOLS_SERVICE_NAME = "api"
    }
  }

  # ADOT Layer: OpenTelemetry para exportar a X-Ray y otros backends
  layers = [aws_lambda_layer_version.adot.arn]

  tags = local.common_tags
}
```

---

## 10. AWS Distro for OpenTelemetry (ADOT)

ADOT implementa el estándar OpenTelemetry, evitando el lock-in con un solo proveedor. Un único SDK instrumenta métricas, logs y trazas hacia múltiples backends simultáneamente.

**Arquitectura ADOT en ECS/EKS:**

```
Aplicación
    │ SDK OTel (auto-instrumentación)
    ▼
ADOT Collector (sidecar)
    │
    ├── Receiver: otlp (métricas + trazas)
    │
    ├── Processor: batch, resource detection
    │
    └── Exporters:
         ├── awsxray  → AWS X-Ray
         ├── awsemf   → CloudWatch Metrics (EMF)
         ├── prometheus → Amazon Managed Prometheus
         └── otlp     → Datadog / Splunk / Jaeger
```

**Backends soportados:**

| Backend | Tipo de datos | Uso |
|---------|--------------|-----|
| AWS X-Ray | Trazas | Análisis de latencia y errores |
| CloudWatch | Métricas | Alarmas e integración nativa AWS |
| Amazon Managed Prometheus | Métricas | Grafana dashboards |
| Datadog / Splunk | Todos | Herramientas corporativas externas |

---

## 11. Gobernanza de Almacenamiento: S3 Lifecycle para Logs

Terraform automatiza la transición de logs históricos desde S3 Standard a Glacier Deep Archive, reduciendo costes de retención hasta un 95%.

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "audit_logs" {
  bucket = aws_s3_bucket.audit.id

  rule {
    id     = "archive-and-expire"
    status = "Enabled"

    filter {
      prefix = "vpc-flow-logs/"
    }

    # Transición escalonada
    transition {
      days          = 30
      storage_class = "STANDARD_IA"   # $23/TB → $12.50/TB
    }
    transition {
      days          = 90
      storage_class = "GLACIER"       # $12.50/TB → ~$3.60/TB (Flexible Retrieval)
    }
    transition {
      days          = 365
      storage_class = "DEEP_ARCHIVE"  # ~$3.60/TB → $1/TB
    }

    expiration {
      days = 2555   # 7 años (requisito PCI-DSS / SOX)
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
```

**Comparativa de costes S3 por clase:**

| Clase | Coste/TB/mes | Latencia de acceso | Caso de uso |
|-------|-------------|-------------------|-------------|
| Standard | $23 | Instantáneo | Logs recientes, acceso frecuente |
| Standard-IA | $12.50 | Instantáneo | Logs 30-90 días |
| Glacier Flexible Retrieval | $3.60 | Minutos-horas | Logs 90-365 días |
| Glacier Deep Archive | $1 | 12-48 horas | Compliance a 7+ años |

---

## 12. Cifrado de Extremo a Extremo con KMS

Una CMK para gobernar toda la cadena de telemetría garantiza privacidad y simplifica la gestión de claves.

```hcl
# CMK para toda la cadena de observabilidad
resource "aws_kms_key" "observability" {
  description             = "KMS key for observability pipeline"
  enable_key_rotation     = true
  deletion_window_in_days = 30

  policy = jsonencode({
    Statement = [
      # Acceso completo para la cuenta
      {
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "kms:*"
        Resource  = "*"
      },
      # CloudWatch Logs puede usar la clave
      {
        Effect    = "Allow"
        Principal = { Service = "logs.${var.region}.amazonaws.com" }
        Action    = ["kms:Encrypt*", "kms:Decrypt*", "kms:GenerateDataKey*", "kms:Describe*"]
        Resource  = "*"
      },
      # Firehose puede usar la clave
      {
        Effect    = "Allow"
        Principal = { Service = "firehose.amazonaws.com" }
        Action    = ["kms:Encrypt*", "kms:Decrypt*", "kms:GenerateDataKey*"]
        Resource  = "*"
      },
    ]
  })
}
```

---

## 13. Troubleshooting: Pérdida de Datos en el Pipeline

| Síntoma | Causa probable | Diagnóstico | Solución |
|---------|---------------|-------------|---------|
| Logs no llegan a Firehose | Buffer interval alto | Ver métricas `DeliveryToS3.DataFreshness` | Reducir `buffering_interval` |
| Firehose falla silenciosamente | IAM Trust rota | Ver S3 bucket `firehose-error/` | Corregir Trust Relationship |
| OpenSearch rechaza documentos | Mapping conflict | Ver índice `_cat/health` | Forzar rollover o reindexar |
| X-Ray sin trazas | Rol sin `xray:PutTraceSegments` | Revisar IAM del rol Lambda | Agregar política `AWSXRayDaemonWriteAccess` |
| CloudTrail gaps | Región no cubierta | Verificar `is_multi_region_trail` | Habilitar multi-región |

---

> [← Volver al índice](./README.md) | [Siguiente →](./03_tagging.md)
