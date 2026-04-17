# Sección 4 — Amazon DynamoDB

> [← Volver al índice](./README.md) | [Siguiente →](./05_elasticache.md)

---

## 1. DynamoDB: La Base de Datos Que No Necesita DBA

DynamoDB resuelve el problema de escalar bases de datos relacionales más allá de lo que un solo servidor puede manejar. No es una mejora de SQL — es un modelo diferente. Tabla → Item → Atributo. Sin esquema fijo, sin joins, sin stored procedures. A cambio: latencia de milisegundos de un dígito a cualquier escala, con SLA de 99.999%.

> **En la práctica:** "La trampa más común con DynamoDB es querer usarla como si fuera MySQL. El éxito con DynamoDB empieza por el modelado: defines primero tus access patterns y luego diseñas la tabla para servirlos eficientemente. Si empiezas por el esquema y luego piensas en los queries, probablemente la estás usando mal."

**Cuándo usar DynamoDB vs RDS:**
- DynamoDB: acceso por clave conocida, escala horizontal, latencia < 10ms, SLA 99.999%.
- RDS: joins complejos, transacciones ACID complejas, reporting con SQL ad-hoc.

---

## 2. Partition Key y Sort Key — El Modelo de Datos

```
┌─────────────────────────────────────────────────┐
│               TABLA: orders                     │
│                                                 │
│  PK: user_id (Partition Key / HASH)             │
│  SK: order_date (Sort Key / RANGE)              │
│                                                 │
│  ┌──────────┬──────────────┬───────────────┐    │
│  │ user_id  │  order_date  │    status     │    │
│  ├──────────┼──────────────┼───────────────┤    │
│  │ u-123    │ 2024-01-15   │ DELIVERED     │    │
│  │ u-123    │ 2024-02-01   │ PROCESSING    │    │
│  │ u-456    │ 2024-01-20   │ PENDING       │    │
│  └──────────┴──────────────┴───────────────┘    │
│                                                 │
│  Query: user_id = "u-123"                       │
│       AND order_date BETWEEN "2024-01" "2024-03"│
└─────────────────────────────────────────────────┘
```

- **Partition Key (HASH):** DynamoDB aplica hash para distribuir datos entre particiones. Elige valores con alta cardinalidad (user_id, order_id). Una mala elección — por ejemplo `country_code` con solo 3 valores — crea hot partitions que saturan la capacidad.
- **Sort Key (RANGE):** Ordena items dentro de la misma partición. Permite queries con `begins_with`, `between`, `>`, `<`. Ideal para datos jerárquicos (usuario + timestamp).

---

## 3. `aws_dynamodb_table` — Definición Básica

```hcl
resource "aws_dynamodb_table" "orders" {
  name         = "orders-table"
  billing_mode = "PAY_PER_REQUEST"   # On-demand: sin planificación de capacidad
  hash_key     = "user_id"
  range_key    = "order_date"

  attribute {
    name = "user_id"
    type = "S"          # S = String, N = Number, B = Binary
  }

  attribute {
    name = "order_date"
    type = "S"          # ISO 8601
  }

  tags = {
    Env = "production"
  }
}
```

> **Nota Terraform:** Solo defines `attribute` para las claves (Partition Key, Sort Key, y claves de GSI/LSI). Los demás atributos del item son libres — DynamoDB es schema-less. Intentar definir todos los atributos en Terraform es un error común.

---

## 4. Modos de Capacidad: On-Demand vs Provisioned

| Característica | On-Demand (PAY_PER_REQUEST) | Provisioned + AutoScaling |
|----------------|-----------------------------|-----------------------------|
| Planificación | Sin necesidad de definir RCU/WCU | Defines target utilization |
| Escalado | Instantáneo | AutoScaling con cooldown |
| Costo | Más caro por request | Hasta 77% más barato con Reserved |
| Mejor para | Tráfico impredecible, dev | Workloads estables y predecibles |

```hcl
# Modo Provisioned con Auto Scaling
resource "aws_dynamodb_table" "orders" {
  billing_mode   = "PROVISIONED"
  read_capacity  = 5
  write_capacity = 5
  # ... keys y attributes
}

resource "aws_appautoscaling_target" "read" {
  max_capacity       = 100
  min_capacity       = 5
  resource_id        = "table/${aws_dynamodb_table.orders.name}"
  scalable_dimension = "dynamodb:table:ReadCapacityUnits"
  service_namespace  = "dynamodb"
}

resource "aws_appautoscaling_policy" "read" {
  name               = "ddb-read-autoscaling"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.read.resource_id
  scalable_dimension = aws_appautoscaling_target.read.scalable_dimension
  service_namespace  = aws_appautoscaling_target.read.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "DynamoDBReadCapacityUtilization"
    }
    target_value = 70.0
  }
}
```

---

## 5. Global Secondary Indexes (GSI)

Los GSI permiten queries por atributos que no son la clave primaria. Cada GSI define su propio par PK/SK y tiene capacidad independiente.

```hcl
resource "aws_dynamodb_table" "orders" {
  name         = "orders"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "CustomerId"
  range_key    = "OrderDate"

  # GSI para buscar pedidos por estado
  global_secondary_index {
    name            = "StatusIndex"
    hash_key        = "Status"
    range_key       = "OrderDate"
    projection_type = "INCLUDE"
    non_key_attributes = ["Total", "Items"]   # Solo estos atributos en el índice
  }

  attribute { name = "CustomerId"; type = "S" }
  attribute { name = "OrderDate";  type = "S" }
  attribute { name = "Status";     type = "S" }
}
```

**Tipos de proyección:**

| `projection_type` | Atributos en el índice | Storage | Costo WCU |
|-------------------|------------------------|---------|-----------|
| `KEYS_ONLY` | Solo claves | Mínimo | Mínimo |
| `INCLUDE` | Claves + listado específico | Medio | Medio |
| `ALL` | Copia completa del item | Máximo | Máximo |

> **En la práctica:** "Un GSI es esencialmente una segunda tabla sincronizada automáticamente. Tiene su propio índice interno y sus propias WCU. Si escribes 1 item en la tabla con 2 GSI, en realidad estás haciendo 3 escrituras. Esto afecta el costo."

---

## 6. DynamoDB Streams + Lambda Triggers

DynamoDB Streams captura cada cambio en la tabla (INSERT, UPDATE, DELETE) como un evento ordered. Lambda puede consumir este stream para event-driven processing.

```hcl
# Activar Streams en la tabla
resource "aws_dynamodb_table" "orders" {
  # ...
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"   # Captura el antes y después
}

# Event Source Mapping: conecta el Stream con Lambda
resource "aws_lambda_event_source_mapping" "ddb" {
  event_source_arn  = aws_dynamodb_table.orders.stream_arn
  function_name     = aws_lambda_function.processor.arn
  starting_position = "LATEST"

  batch_size                         = 100
  maximum_batching_window_in_seconds = 5   # Espera hasta 5s para completar batch

  # Manejo de errores
  bisect_batch_on_function_error = true    # Divide el batch si falla
  maximum_retry_attempts         = 3
  maximum_record_age_in_seconds  = 86400   # Descarta eventos > 24h

  destination_config {
    on_failure {
      destination_arn = aws_sqs_queue.dlq.arn   # DLQ para eventos fallidos
    }
  }
}
```

**`stream_view_type` opciones:**

| Valor | Incluye |
|-------|---------|
| `KEYS_ONLY` | Solo las claves del item |
| `NEW_IMAGE` | Item completo después del cambio |
| `OLD_IMAGE` | Item completo antes del cambio |
| `NEW_AND_OLD_IMAGES` | Ambas versiones (más costoso, más información) |

**Casos de uso típicos:** replicación a otro sistema, invalidación de caché, auditoría, analytics en tiempo real, notificaciones.

---

## 7. TTL y Point-in-Time Recovery (PITR)

```hcl
resource "aws_dynamodb_table" "sessions" {
  name     = "user-sessions"
  hash_key = "SessionId"

  billing_mode = "PAY_PER_REQUEST"

  attribute {
    name = "SessionId"
    type = "S"
  }

  # TTL: expiración automática sin costo de escritura
  ttl {
    enabled        = true
    attribute_name = "ExpiresAt"   # Atributo epoch timestamp en segundos
  }

  # PITR: recuperación a cualquier segundo en los últimos 35 días
  point_in_time_recovery {
    enabled = true
  }
}
```

**TTL:** DynamoDB elimina los items cuyo atributo `ExpiresAt` (timestamp epoch en segundos) es menor al tiempo actual. La eliminación es eventual (hasta 48h después), sin consumir WCU. Items expirados aún aparecen en Streams — tu Lambda debe filtrarlos.

**PITR:** Recuperación granular a cualquier segundo en los últimos 35 días. El restore crea una tabla nueva (no sobrescribe la existente). No afecta el rendimiento de la tabla en producción.

---

## 8. DAX — DynamoDB Accelerator

DAX es un cache in-memory compatible con la API de DynamoDB que reduce la latencia de lecturas de milisegundos a microsegundos.

```hcl
resource "aws_dax_cluster" "cache" {
  cluster_name       = "ddb-cache"
  node_type          = "dax.r5.large"
  replication_factor = 3   # 1 primary + 2 réplicas

  iam_role_arn      = aws_iam_role.dax.arn
  subnet_group_name = aws_dax_subnet_group.main.name
  security_group_ids = [aws_security_group.dax.id]

  server_side_encryption {
    enabled = true
  }

  cluster_endpoint_encryption_type = "TLS"   # TLS para in-transit
  parameter_group_name = "default.dax1.0"
}
```

**Cuándo usar DAX:**
- Read-heavy workloads con queries repetitivas al mismo item.
- Necesitas latencia de microsegundos (vs ms de DynamoDB).
- La aplicación puede tolerar lecturas levemente desactualizadas (cache TTL).

**Cuándo NO usar DAX:**
- Strongly consistent reads (DAX no los puede servir directamente).
- Writes intensivos (DAX es write-through, no ayuda con escrituras).
- Si ya tienes ElastiCache en tu arquitectura — evita doble caché.

---

## 9. Encryption y Control de Acceso IAM Fine-Grained

```hcl
resource "aws_dynamodb_table" "encrypted" {
  name         = "orders-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  # CMK encryption
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.dynamodb.arn
  }

  point_in_time_recovery {
    enabled = true
  }

  attribute { name = "PK"; type = "S" }
  attribute { name = "SK"; type = "S" }
}
```

**IAM Fine-Grained Access Control:**

```hcl
# Política que permite a un usuario solo leer sus propios items
resource "aws_iam_policy" "dynamodb_user_scoped" {
  policy = jsonencode({
    Statement = [{
      Effect   = "Allow"
      Action   = ["dynamodb:GetItem", "dynamodb:Query"]
      Resource = aws_dynamodb_table.orders.arn
      Condition = {
        ForAllValues:StringEquals = {
          "dynamodb:LeadingKeys" = ["$${cognito-identity.amazonaws.com:sub}"]
        }
      }
    }]
  })
}
```

`dynamodb:LeadingKeys` restringe el acceso solo a items donde la Partition Key coincide con el identificador del usuario autenticado. Esto es seguridad a nivel de item sin código adicional en la aplicación.

---

## 10. Tabla Completa con Todas las Best Practices

```hcl
resource "aws_dynamodb_table" "main" {
  name         = "app-main-table"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  # CDC via Streams
  stream_enabled   = true
  stream_view_type = "NEW_AND_OLD_IMAGES"

  # Cifrado con CMK
  server_side_encryption {
    enabled     = true
    kms_key_arn = aws_kms_key.ddb.arn
  }

  # Recovery granular
  point_in_time_recovery {
    enabled = true
  }

  # Limpieza automática de datos temporales
  ttl {
    attribute_name = "expireAt"
    enabled        = true
  }

  # Índice secundario para access pattern alternativo
  global_secondary_index {
    name            = "GSI1"
    hash_key        = "GSI1PK"
    range_key       = "GSI1SK"
    projection_type = "ALL"
  }

  # Claves primarias
  attribute { name = "PK";     type = "S" }
  attribute { name = "SK";     type = "S" }

  # Claves del GSI
  attribute { name = "GSI1PK"; type = "S" }
  attribute { name = "GSI1SK"; type = "S" }

  tags = {
    Name        = "app-main-table"
    Environment = "production"
  }
}
```

---

## 11. Resumen: Cuándo Usar Cada Característica

| Característica | Cuándo activar | Costo adicional |
|----------------|----------------|-----------------|
| `PAY_PER_REQUEST` | Tráfico impredecible, dev | Mayor por request |
| `PROVISIONED` + AutoScaling | Producción estable | Hasta 77% ahorro |
| GSI | Cada access pattern secundario | WCU por escritura |
| Streams + Lambda | CDC, replicación, analytics | Por lectura del stream |
| TTL | Sesiones, tokens, logs temporales | Sin costo de delete |
| PITR | Siempre en producción | Por GB-mes |
| DAX | Read-heavy, latencia < 1ms | Por nodo por hora |
| CMK encryption | Datos sensibles/regulados | Por llamadas KMS |

> **El profesor resume:** "DynamoDB escala infinitamente porque te obliga a pensar en los access patterns antes de escribir código. El costo del aprendizaje inicial — entender partition keys, hot partitions, GSI — se amortiza cuando llegas al millón de requests por segundo sin preocuparte por el tamaño del servidor."

---

> [← Volver al índice](./README.md) | [Siguiente →](./05_elasticache.md)
