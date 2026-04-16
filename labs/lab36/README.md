# Laboratorio 36: Arquitectura Moderna NoSQL — DynamoDB con Caché y Eventos

[← Módulo 8 — Almacenamiento y Bases de Datos con Terraform](../../modulos/modulo-08/README.md)


## Visión general

En este laboratorio construirás una capa de datos NoSQL ultra-rápida y orientada a eventos. Desplegarás una **tabla DynamoDB On-Demand** con un **Global Secondary Index** para consultas flexibles, activarás **DynamoDB Streams** y conectarás una **Lambda** que procesa cada cambio en tiempo real. Para acelerar las lecturas, desplegará un **cluster Redis de ElastiCache** con cifrado en tránsito y autenticación AUTH. Toda la infraestructura se monitoriza con **alarmas de CloudWatch** que notifican vía **SNS**.

La capa de aplicación es un **Product Catalog** Flask desplegado en EC2 que demuestra en tiempo real la diferencia de latencia entre una lectura desde Redis (< 5 ms) y una lectura directa a DynamoDB (~30-80 ms), con contadores de hits/misses y un feed de eventos CDC en vivo.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Crear un `aws_dynamodb_table` con modo `PAY_PER_REQUEST` (On-Demand), Partition Key y Sort Key
- Añadir un `global_secondary_index` con proyección `ALL` para consultas por atributo secundario
- Activar `stream_enabled = true` con `stream_view_type = "NEW_AND_OLD_IMAGES"`
- Conectar un `aws_lambda_event_source_mapping` al stream para procesar cambios en tiempo real
- Desplegar un `aws_elasticache_replication_group` Redis con `transit_encryption_enabled` y `auth_token`
- Implementar el patrón **Cache-Aside** en Python: Redis como capa de lectura sobre DynamoDB
- Crear `aws_cloudwatch_metric_alarm` para `EngineCPUUtilization` y `Evictions` de Redis
- Usar `aws_sns_topic` como destino de notificaciones de alarmas
- Medir y visualizar la diferencia de latencia entre cache hit (~2 ms) y cache miss (~50 ms)

## Requisitos Previos

- Terraform >= 1.5 instalado
- Laboratorio 2 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir
- Perfil AWS con permisos sobre DynamoDB, ElastiCache, Lambda, EC2, S3, Secrets Manager, IAM, CloudWatch y SNS

---

## Arquitectura

```
                         Internet
                             │ HTTP :8080
                             ▼
┌─── VPC 10.32.0.0/16 ──────────────────────────────────────────────────────┐
│                                                                           │
│  ┌─ Subnet pública (us-east-1a) ────────────────────────────────────────┐ │
│  │                                                                      │ │
│  │  ┌─────────────────────────────────────────────────────────────────┐ │ │
│  │  │  EC2 t4g.small  ·  Flask Product Catalog                        │ │ │
│  │  │  Patrón Cache-Aside: HIT → Redis  /  MISS → DynamoDB + cache    │ │ │
│  │  └──────────────────────┬──────────────────────────┬───────────────┘ │ │
│  │                         │                          │                 │ │
│  └─────────────────────────┼──────────────────────────┼─────────────────┘ │
│        MISS (escribe cache)│                          │HIT (lectura local)│
│                            │                          │                   │
│  ┌─ Subnets privadas ──────┼──────────────────────────┼──────────────────┐│
│  │  (us-east-1a / 1b)      │                          ▼                  ││
│  │                         │          ┌───────────────────────────────┐  ││
│  │                         │          │  ElastiCache Redis 7.1        │  ││
│  │                         │          │  Primary  ·  us-east-1a       │  ││
│  │                         │          │  Replica  ·  us-east-1b       │  ││
│  │                         │          │  TLS enforced  ·  AUTH token  │  ││
│  │                         │          └───────────────────────────────┘  ││
│  └─────────────────────────┼─────────────────────────────────────────────┘│
└───────────────────────────┬┼──────────────────────────────────────────────┘
                            ││ API calls vía endpoint público
          ┌─────────────────┘│
          │                  │
          ▼                  ▼
┌──────────────────────────────────────┐   ┌──────────────────────────────┐
│  DynamoDB · lab36-products           │   │  DynamoDB · lab36-events     │
│  Billing: PAY_PER_REQUEST (On-Demand)│   │  Billing: PAY_PER_REQUEST    │
│  PK: category (S)                    │   │  PK: event_date (S)          │
│  SK: product_id (S)                  │   │  SK: event_id (S)            │
│  ──────────────────────────────────  │   │  TTL: expires_at (7 días)    │
│  GSI: by-status-index                │   └──────────────▲───────────────┘
│    PK: status (S)                    │                  │ PutItem
│    SK: price_cents (N)               │   ┌──────────────┴───────────────┐
│    Projection: ALL                   │   │  Lambda · lab36-cdc-processor│
│  ──────────────────────────────────  │   │  Runtime: python3.12         │
│  Streams: NEW_AND_OLD_IMAGES ────────┼──►│  Trigger: DynamoDB Streams   │
└──────────────────────────────────────┘   └──────────────────────────────┘

┌──────────────────────┐   ┌──────────────────────────────────────────────┐
│  S3 · app-artifacts  │   │  CloudWatch Alarms                           │
│  └─ app/app.py       │   │  ├─ EngineCPUUtilization > 65 % (10 min)     │
└──────────────────────┘   │  └─ Evictions > 100 (1 min)                  │
                           └──────────────────────┬───────────────────────┘
┌──────────────────────┐                          │
│  Secrets Manager     │              ┌───────────▼────────────┐
│  redis/auth-token    │              │  SNS · lab36-alerts    │
└──────────────────────┘              └────────────────────────┘
```

---

## Conceptos Clave

### DynamoDB On-Demand: sin aprovisionamiento de capacidad

Con `billing_mode = "PAY_PER_REQUEST"`, DynamoDB escala automáticamente para cualquier volumen de tráfico. No hay que estimar RCU/WCU: pagas por cada operación de lectura/escritura real. Es la opción ideal para cargas impredecibles o laboratorios.

```hcl
resource "aws_dynamodb_table" "products" {
  name         = "lab36-products"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "category"
  range_key    = "product_id"
  # ...
}
```

### Global Secondary Index: consultas flexibles

Un GSI permite consultar la tabla por atributos que no son la Primary Key. En este lab, el GSI `by-status-index` con `PK=status` y `SK=price_cents` permite obtener todos los productos con un estado concreto, ordenados por precio de menor a mayor:

```python
# Consulta via GSI: productos activos ordenados por precio
resp = products_table.query(
    IndexName="by-status-index",
    KeyConditionExpression=Key("status").eq("active"),
)
```

Sin el GSI, esta consulta requeriría un `Scan` con `FilterExpression`, mucho menos eficiente a medida que crece la tabla.

### DynamoDB Streams y CDC

Al activar `stream_enabled = true`, DynamoDB publica cada INSERT, MODIFY y REMOVE en un stream de tiempo real. El `stream_view_type = "NEW_AND_OLD_IMAGES"` incluye el estado antes y después de cada modificación, lo que permite detectar exactamente qué cambió:

```
Evento MODIFY:
  OldImage: { name: "Laptop", price_cents: 99900, status: "active" }
  NewImage: { name: "Laptop", price_cents: 94900, status: "active" }
  → El precio bajó de $999 a $949
```

### Lambda Event Source Mapping

`aws_lambda_event_source_mapping` conecta el stream de DynamoDB con la Lambda. DynamoDB gestiona automáticamente la entrega en batches, los reintentos y el checkpointing del shard. La Lambda solo necesita permisos de `AWSLambdaDynamoDBExecutionRole` para leer del stream:

```hcl
resource "aws_lambda_event_source_mapping" "dynamodb_stream" {
  event_source_arn  = aws_dynamodb_table.products.stream_arn
  function_name     = aws_lambda_function.cdc_processor.arn
  starting_position = "LATEST"
  batch_size        = 10
}
```

### ElastiCache Redis con TLS y AUTH

`transit_encryption_enabled = true` exige TLS en todas las conexiones (los clientes deben usar `rediss://` en lugar de `redis://`). `auth_token` añade una capa de autenticación: el cliente debe presentar el token además de la conexión TLS.

La combinación de ambas garantiza:
- **Confidencialidad**: los datos en tránsito van cifrados (TLS)
- **Autenticación**: solo clientes con el token correcto pueden conectar (AUTH)

```python
r = redis.Redis(
    host=REDIS_HOST, port=6379,
    password=REDIS_AUTH,
    ssl=True, ssl_cert_reqs=None,
)
```

### Patrón Cache-Aside

La aplicación sigue el patrón Cache-Aside (Lazy Loading):

```
READ:
  1. Consultar Redis
  2a. HIT  → devolver datos del cache (< 5 ms)
  2b. MISS → consultar DynamoDB (~50 ms)
           → almacenar resultado en Redis con TTL
           → devolver datos

WRITE/UPDATE/DELETE:
  1. Escribir en DynamoDB
  2. Invalidar clave del cache afectada
```

La invalidación reactiva evita servir datos obsoletos. El TTL de 60 segundos es la red de seguridad final.

### CloudWatch Alarms para Redis

`EngineCPUUtilization` mide el CPU exclusivo del proceso Redis, no del sistema operativo. Redis es single-threaded, por lo que su CPU determina el throughput máximo. Por encima del 65% durante 10 minutos es una señal temprana de saturación:

```hcl
resource "aws_cloudwatch_metric_alarm" "redis_cpu" {
  metric_name         = "EngineCPUUtilization"
  namespace           = "AWS/ElastiCache"
  threshold           = 65
  evaluation_periods  = 2
  period              = 300
  dimensions = {
    ReplicationGroupId = aws_elasticache_replication_group.redis.id
  }
}
```

`Evictions` indica que Redis alcanzó su límite de memoria y está expulsando claves. En un cache de aplicación, las evictions generan un pico de cache misses y mayor presión sobre DynamoDB.

---

## Estructura del proyecto

```
labs/lab36/
├── README.md
└── aws/
    ├── app/
    │   └── app.py                 # Flask Product Catalog: CRUD DynamoDB + caché Redis
    ├── lambda/
    │   └── lambda_function.py     # CDC processor: consume DynamoDB Streams → escribe eventos
    ├── scripts/
    │   └── user_data.sh.tpl       # Bootstrap EC2: instala deps, seed DynamoDB, inicia systemd
    │
    ├── locals.tf                  # locals (tags, CIDRs) + data sources (AMI, account_id)
    ├── networking.tf              # VPC, IGW, subnets públicas/privadas, route tables, SGs
    ├── iam.tf                     # Roles e instance profiles para EC2 y Lambda
    ├── dynamodb.tf                # Tabla products (GSI + Streams) y tabla events (TTL)
    ├── elasticache.tf             # random_password, Secrets Manager, subnet group, Redis cluster
    ├── lambda.tf                  # archive_file, función CDC, event source mapping
    ├── monitoring.tf              # SNS topic + CloudWatch alarms (CPU y Evictions)
    ├── ec2.tf                     # S3 bucket/object (app.py) + instancia EC2
    │
    ├── outputs.tf                 # 18 outputs con endpoints, ARNs y comandos de verificación
    ├── providers.tf               # AWS ~> 6.0 + random + archive
    ├── variables.tf               # region, project, instance_type, redis_node_type, cache_ttl
    └── aws.s3.tfbackend           # Configuración del backend S3
```

---

## 1. Despliegue en AWS

```bash
# Obtén el ID de cuenta para el backend
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Desde labs/lab36/aws/
terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=terraform-state-labs-$ACCOUNT_ID"
terraform plan
terraform apply
```

> **Nota**: `terraform apply` puede tardar más de 20 minutos. El cuello de botella es el cluster de Redis — `aws_elasticache_replication_group` con Multi-AZ puede superar los **20 minutos** en pasar a estado `available`. DynamoDB, Lambda y la instancia EC2 se aprovisionan en paralelo en cuestión de segundos.

Una vez completado, obtén la URL:

```bash
terraform output app_url
```

---

## Verificación final

### 2.1 Aplicación web — Product Catalog

```bash
APP_URL=$(terraform output -raw app_url)

# Health check
curl -s "$APP_URL/health"
# {"status": "ok"}

# Abre el dashboard
echo "$APP_URL"
```

El dashboard muestra:
- **Stats bar**: hits, misses, hit rate %, latencia media Redis (ms), latencia media DynamoDB (ms), latencia media escritura
- **Badge de fuente**: `⚡ REDIS HIT · X ms` o `◎ CACHE MISS — DynamoDB: X ms`
- **Tabla de productos**: 15 productos precargados, filtrables por categoría y estado
- **Latencia comparada**: barras visuales de rendimiento en la barra lateral
- **Feed de eventos CDC**: cambios procesados por Lambda en tiempo real

### 2.2 Demostración de latencia

```bash
# Primera carga (CACHE MISS → DynamoDB): ~50-80 ms
curl -s "$APP_URL/" | grep "src-badge"

# Segunda carga (CACHE HIT → Redis): ~1-5 ms
curl -s "$APP_URL/" | grep "src-badge"
```

En el interfaz, recarga la misma página varias veces y observa cómo la latencia cae drásticamente en el segundo request.

### 2.3 DynamoDB: tabla y schema

```bash
TABLE=$(terraform output -raw dynamo_table_name)

# Describe la tabla (modo On-Demand, stream, GSI)
aws dynamodb describe-table \
  --table-name "$TABLE" \
  --query 'Table.{Modo:BillingModeSummary.BillingMode,Stream:StreamSpecification,GSI:GlobalSecondaryIndexes[*].{Nombre:IndexName,PK:KeySchema[0].AttributeName,SK:KeySchema[1].AttributeName}}'

# Escanea todos los productos
aws dynamodb scan --table-name "$TABLE" \
  --query 'Items[*].{Cat:category.S,Nombre:name.S,Precio:price_cents.N,Estado:status.S}'
```

### 2.4 GSI: consulta por estado y precio

```bash
# Productos activos ordenados por precio (via GSI)
aws dynamodb query \
  --table-name "$TABLE" \
  --index-name by-status-index \
  --key-condition-expression "#s = :v" \
  --expression-attribute-names '{"#s":"status"}' \
  --expression-attribute-values '{":v":{"S":"active"}}' \
  --query 'Items[*].{Estado:status.S,Precio:price_cents.N,Nombre:name.S}' \
  --region us-east-1
# Los items vienen ordenados por price_cents de menor a mayor
```

### 2.5 DynamoDB Streams y Lambda CDC

```bash
LAMBDA=$(terraform output -raw lambda_function_name)
STREAM_ARN=$(terraform output -raw dynamo_stream_arn)

# Estado del event source mapping
aws lambda list-event-source-mappings \
  --function-name "$LAMBDA" \
  --query 'EventSourceMappings[0].{Estado:State,Fuente:EventSourceArn,Batch:BatchSize}'
# Estado debe ser "Enabled"

# Crea un producto desde la UI, luego verifica los logs de Lambda
aws logs describe-log-groups \
  --log-group-name-prefix "/aws/lambda/$LAMBDA" \
  --query 'logGroups[0].logGroupName' --output text | \
  xargs -I{} aws logs tail {} --follow --since 5m
```

### 2.6 ElastiCache Redis

```bash
# Estado del cluster Redis
aws elasticache describe-replication-groups \
  --replication-group-id lab36-redis \
  --query 'ReplicationGroups[0].{Estado:Status,TLS:TransitEncryptionEnabled,AtRest:AtRestEncryptionEnabled,MultiAZ:MultiAZ,Nodos:NodeGroups[0].NodeGroupMembers[*].{ID:CacheClusterId,Rol:CurrentRole,AZ:PreferredAvailabilityZone}}'

# Endpoint primario
aws elasticache describe-replication-groups \
  --replication-group-id lab36-redis \
  --query 'ReplicationGroups[0].NodeGroups[0].PrimaryEndpoint'
```

### 2.7 AUTH token de Redis

```bash
SECRET=$(terraform output -raw redis_secret_name)

# Recupera el AUTH token
TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id "$SECRET" \
  --query SecretString --output text)

REDIS_HOST=$(terraform output -raw redis_primary_endpoint)

# Conecta al cluster Redis (desde la instancia EC2 via SSM)
# En el EC2 (usa el paquete Python redis ya instalado):
# python3 -c "import redis; r = redis.Redis(host='$REDIS_HOST', port=6379, password='$TOKEN', ssl=True, ssl_cert_reqs=None); print(r.ping())"
# Debe devolver: True
```

### 2.8 CloudWatch Alarms y SNS

```bash
# Estado de las alarmas
aws cloudwatch describe-alarms \
  --alarm-names lab36-redis-cpu-high lab36-redis-evictions \
  --query 'MetricAlarms[*].{Nombre:AlarmName,Estado:StateValue,Umbral:Threshold,Metrica:MetricName}'

# Suscribirse al topic SNS para recibir notificaciones por email
SNS_ARN=$(terraform output -raw sns_topic_arn)
aws sns subscribe \
  --topic-arn "$SNS_ARN" \
  --protocol email \
  --notification-endpoint TU_EMAIL@ejemplo.com \
  --region us-east-1
# Confirma el email de verificacion que recibiras
```

---

## 3. Reto 1: TTL en la tabla de productos

La tabla `lab36-events` tiene TTL configurado (7 días). La tabla de productos no lo tiene: los registros eliminados vía la UI desaparecen de inmediato con `DeleteItem`, pero no existe ningún mecanismo de expiración automática para productos que deberían caducar por tiempo.

### Requisitos

Modifica únicamente `dynamodb.tf`:

1. Añade un bloque `ttl` en `aws_dynamodb_table.products` que use el atributo `expires_at` (tipo Number, epoch en segundos)
2. Aplica el cambio con `terraform apply` — DynamoDB activa el TTL sin interrupciones ni recreación de la tabla

### Criterios de éxito

```bash
# Debe mostrar TimeToLiveStatus: ENABLED y AttributeName: expires_at
aws dynamodb describe-time-to-live \
  --table-name lab36-products \
  --query 'TimeToLiveDescription'

# Inserta manualmente un item con expires_at en el pasado
aws dynamodb put-item \
  --table-name lab36-products \
  --item '{
    "category":   {"S": "Test"},
    "product_id": {"S": "ttl-test-01"},
    "name":       {"S": "Producto caducado"},
    "status":     {"S": "inactive"},
    "price_cents":{"N": "0"},
    "stock":      {"N": "0"},
    "expires_at": {"N": "1"}
  }'
# En las proximas 24-48h el item desaparece automaticamente (TTL es eventual)
```

- `terraform plan` muestra `~ update in-place` — no hay destroy/create de la tabla
- La tabla de eventos sigue funcionando con su TTL propio de 7 días sin cambios

---

## 4. Reto 2: Point-in-Time Recovery en la tabla de productos

La tabla de productos almacena el catálogo activo del negocio. Actualmente no tiene ninguna protección frente a borrados accidentales masivos — un `terraform apply` erróneo o un bug en la aplicación podría eliminar todos los productos de forma irrecuperable. **Point-in-Time Recovery (PITR)** activa backups continuos y permite restaurar la tabla a cualquier segundo dentro de los últimos 35 días.

### Requisitos

Modifica únicamente `dynamodb.tf`:

1. Añade un bloque `point_in_time_recovery` en `aws_dynamodb_table.products` con `enabled = true`
2. Aplica con `terraform apply` — DynamoDB activa PITR sin interrupciones ni recreación de la tabla
3. Con la CLI, simula una recuperación restaurando la tabla a su estado de hace 5 minutos en una tabla nueva `lab36-products-restored`
4. Verifica el contenido de la tabla restaurada y elimínala al terminar

### Criterios de éxito

```bash
# PITR debe aparecer como ENABLED con ventana de 35 dias
aws dynamodb describe-continuous-backups \
  --table-name lab36-products \
  --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription'
# {
#   "PointInTimeRecoveryStatus": "ENABLED",
#   "EarliestRestorableDateTime": "...",
#   "LatestRestorableDateTime":  "..."
# }

# Restaura a "ahora mismo" en una tabla nueva (tarda ~3-5 min)
aws dynamodb restore-table-to-point-in-time \
  --source-table-name lab36-products \
  --target-table-name lab36-products-restored \
  --use-latest-restorable-time

aws dynamodb wait table-exists --table-name lab36-products-restored

# Verifica que los productos estan intactos en la tabla restaurada
aws dynamodb scan \
  --table-name lab36-products-restored \
  --select COUNT \
  --query 'Count'
# Debe devolver 15

# Limpieza
aws dynamodb delete-table --table-name lab36-products-restored
```

- `terraform plan` muestra `~ update in-place` — la tabla no se destruye ni recrea
- La tabla `lab36-events` **no** requiere PITR (los eventos tienen TTL de 7 días y son regenerables por el stream)

---

## 5. Solución de los Retos

> Intenta resolver los retos antes de leer esta sección.

### Solución Reto 1 — TTL en la tabla de productos

En `aws/dynamodb.tf`, añade el bloque `ttl` dentro de `aws_dynamodb_table.products`:

```hcl
resource "aws_dynamodb_table" "products" {
  # ... resto de la configuracion sin cambios ...

  ttl {
    attribute_name = "expires_at"
    enabled        = true
  }

  tags = local.tags
}
```

Aplica y verifica:

```bash
terraform apply

aws dynamodb describe-time-to-live \
  --table-name lab36-products \
  --query 'TimeToLiveDescription'
# { "TimeToLiveStatus": "ENABLED", "AttributeName": "expires_at" }
```

> DynamoDB activa el TTL como operación `in-place`: no hay downtime ni recreación de la tabla. Los items sin el atributo `expires_at` no se ven afectados.

### Solución Reto 2 — Point-in-Time Recovery

En `aws/dynamodb.tf`, añade el bloque `point_in_time_recovery` dentro de `aws_dynamodb_table.products`:

```hcl
resource "aws_dynamodb_table" "products" {
  # ... resto de la configuracion sin cambios ...

  point_in_time_recovery {
    enabled = true
  }

  tags = local.tags
}
```

Aplica y verifica:

```bash
terraform apply

aws dynamodb describe-continuous-backups \
  --table-name lab36-products \
  --query 'ContinuousBackupsDescription.PointInTimeRecoveryDescription'
```

Restaura y comprueba la integridad:

```bash
aws dynamodb restore-table-to-point-in-time \
  --source-table-name lab36-products \
  --target-table-name lab36-products-restored \
  --use-latest-restorable-time

aws dynamodb wait table-exists --table-name lab36-products-restored

aws dynamodb scan --table-name lab36-products-restored --select COUNT --query 'Count'

aws dynamodb delete-table --table-name lab36-products-restored
```

> PITR se activa como operación `in-place` — no hay downtime. DynamoDB mantiene backups continuos incrementales; la restauración genera una tabla nueva independiente, sin afectar a la tabla de origen.

---

## 6. Limpieza

```bash
# Desde labs/lab36/aws/
terraform destroy
```

> ElastiCache tarda ~5-10 minutos en eliminarse. DynamoDB y Lambda se eliminan en segundos.

---

## Buenas prácticas aplicadas

- **Cache-Aside vs Write-Through**: Cache-Aside es más simple pero puede servir datos obsoletos durante el TTL. Write-Through actualiza el cache en cada escritura — reduce misses pero aumenta la latencia de escritura.
- **TTL del cache**: Un TTL de 60 segundos es conservador. Para datos que cambian poco (catálogo de productos), puedes aumentarlo a 5-15 minutos. Para datos financieros o de inventario, mantenlo bajo (10-30s).
- **`ssl_cert_reqs=None`** en el cliente Redis de laboratorio: en producción usa `ssl_cert_reqs=ssl.CERT_REQUIRED` con el certificado de la CA de AWS (`AmazonRootCA1.pem`).
- **Nunca expongas el AUTH token en variables de entorno del proceso**: guárdalo en Secrets Manager y recupéralo al arrancar, como hace este lab.
- **GSI no es gratis**: en modo On-Demand, un GSI duplica el costo de escritura porque cada write a la tabla base se replica al índice. Crea solo los GSI que vayas a usar.
- **DynamoDB Streams tiene 24 horas de retención**: si la Lambda falla durante más de 24 horas, los registros del stream se pierden. Considera DLQ (Dead Letter Queue) para capturar errores.
- **Evictions = problema de memoria**: si ves evictions frecuentes, aumenta el `node_type` del cluster Redis o reduce el TTL del cache para liberar memoria antes.

---

## Recursos

- [DynamoDB On-Demand — AWS](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/capacity-mode.html)
- [Global Secondary Indexes — AWS](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/GSI.html)
- [DynamoDB Streams — AWS](https://docs.aws.amazon.com/amazondynamodb/latest/developerguide/Streams.html)
- [ElastiCache for Redis — Auth Token](https://docs.aws.amazon.com/AmazonElastiCache/latest/dg/auth.html)
- [Cache-Aside Pattern — Microsoft](https://learn.microsoft.com/en-us/azure/architecture/patterns/cache-aside)
- [Terraform: aws_dynamodb_table](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dynamodb_table)
- [Terraform: aws_elasticache_replication_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/elasticache_replication_group)
- [Terraform: aws_lambda_event_source_mapping](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_event_source_mapping)
