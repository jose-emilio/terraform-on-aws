# Laboratorio 30: Procesamiento Asíncrono y Resiliencia de Eventos

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 7 — Cómputo en AWS con Terraform](../../modulos/modulo-07/README.md)


## Visión general

En este laboratorio construirás un sistema de procesamiento asíncrono de órdenes sobre AWS usando SQS y Lambda. Aprenderás a configurar el **polling automático de colas** con `aws_lambda_event_source_mapping`, a reducir invocaciones innecesarias mediante **filtros de eventos** (`filter_criteria`) que descartan mensajes que no cumplen los criterios de negocio, y a implementar dos mecanismos de resiliencia complementarios: las **Lambda Destinations** para capturar el resultado de invocaciones asíncronas directas, y la **Dead Letter Queue** con `redrive_policy` para aislar los mensajes que fallan repetidamente en el polling SQS.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Configurar `aws_lambda_event_source_mapping` para que Lambda consuma mensajes SQS automáticamente con un `batch_size` de hasta 10 mensajes por invocación
- Aplicar `filter_criteria` para que Lambda solo procese mensajes cuyo cuerpo JSON cumpla condiciones específicas (como `order_type = "premium"`), eliminando el resto sin invocación
- Implementar `aws_lambda_function_event_invoke_config` con `destination_config` para enrutar el resultado de invocaciones asíncronas a colas de éxito o fallo
- Crear una Dead Letter Queue con `aws_sqs_queue` y `redrive_policy` que capture los mensajes que fallan tras `maxReceiveCount` intentos de procesamiento
- Dimensionar correctamente el `visibility_timeout_seconds` de SQS respecto al `timeout` de Lambda para evitar reprocesamientos accidentales
- Distinguir cuándo actúan las Lambda Destinations (invocación asíncrona directa) vs cuándo actúa la DLQ (path de Event Source Mapping)

## Requisitos Previos

- Terraform >= 1.5 instalado
- Laboratorio 2 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir
- Perfil AWS con permisos sobre Lambda, SQS, IAM y CloudWatch Logs
- LocalStack en ejecución (para la sección de LocalStack)

---

## Conceptos Clave

### Event Source Mapping y Polling de Colas SQS

`aws_lambda_event_source_mapping` configura Lambda para que pida mensajes a SQS periódicamente sin necesidad de código de polling propio. Lambda gestiona el ciclo completo: recibe el lote, invoca la función y, si la función retorna con éxito, elimina los mensajes de la cola.

```hcl
resource "aws_lambda_event_source_mapping" "orders" {
  event_source_arn = aws_sqs_queue.orders.arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 10
  enabled          = true
}
```

El evento que llega al handler tiene la forma `{"Records": [...]}`, donde cada elemento es un mensaje SQS. El handler debe procesar todos los mensajes del lote:

```python
def lambda_handler(event, context):
    for record in event["Records"]:
        body = json.loads(record["body"])
        # procesar body...
```

Un `batch_size` de 10 reduce el número de invocaciones Lambda comparado con procesar un mensaje a la vez, optimizando tanto el coste como la latencia.

### Filtros de Eventos con filter_criteria

`filter_criteria` permite descartar mensajes en el lado de AWS antes de que Lambda se invoque. Los mensajes que no coinciden con el patrón se eliminan automáticamente de la cola — no se reencolan ni van a la DLQ.

```hcl
filter_criteria {
  filter {
    pattern = jsonencode({
      body = {
        order_type = ["premium"]
      }
    })
  }
}
```

AWS parsea el `body` del mensaje SQS como JSON para evaluar el filtro. El valor `["premium"]` es una lista de valores aceptados (equivale a `order_type == "premium"`). Si el body no es JSON válido o no contiene el campo, el mensaje no coincide y se descarta.

Se pueden definir múltiples `filter` dentro de un mismo `filter_criteria`: los filtros actúan como un OR lógico — un mensaje activa Lambda si coincide con **cualquiera** de los filtros.

### Lambda Destinations: Destinos Post-Ejecución

`aws_lambda_function_event_invoke_config` configura los destinos a los que Lambda envía el resultado de una invocación **asíncrona** (cuando el cliente invoca con `InvocationType = Event` y no espera respuesta). Lambda genera automáticamente un registro de invocación y lo envía al destino correspondiente:

```hcl
resource "aws_lambda_function_event_invoke_config" "processor" {
  function_name = aws_lambda_function.processor.function_name

  destination_config {
    on_success {
      destination = aws_sqs_queue.success.arn  # función retornó con éxito
    }
    on_failure {
      destination = aws_sqs_queue.failure.arn  # función lanzó una excepción
    }
  }
}
```

El registro enviado al destino incluye el input original, el output (o el error), metadatos de la invocación y el ARN de la función. Es más rico que una DLQ porque también captura los éxitos.

> **Importante**: Las Lambda Destinations **no** se activan en el path de SQS Event Source Mapping, porque ese path usa invocación síncrona desde el servicio de SQS. Para el path de polling, los fallos se gestionan con la `redrive_policy` de la cola.

### Dead Letter Queue y Política de Redrive

La DLQ es el mecanismo de resiliencia para el path de **SQS Event Source Mapping**. Si Lambda lanza una excepción al procesar un mensaje, SQS lo reencola. Tras `maxReceiveCount` intentos fallidos, SQS mueve el mensaje a la DLQ automáticamente:

```hcl
resource "aws_sqs_queue" "dlq" {
  name                      = "${var.project}-dlq"
  message_retention_seconds = 1209600  # 14 días para análisis post-mortem
}

resource "aws_sqs_queue" "orders" {
  name                       = "${var.project}-orders"
  visibility_timeout_seconds = 30  # debe ser >= timeout de la función Lambda

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3
  })
}
```

`visibility_timeout_seconds` es el tiempo durante el que un mensaje es invisible para otros consumidores después de ser recibido. Debe ser mayor o igual al timeout de Lambda para evitar que el mensaje vuelva a ser visible (y se reencole) mientras Lambda todavía lo está procesando.

### IAM para Event Source Mapping

Lambda necesita permisos explícitos para leer de SQS y para escribir en las colas de destino. El Event Source Mapping no se puede activar sin `sqs:ReceiveMessage`, `sqs:DeleteMessage` y `sqs:GetQueueAttributes` en la cola de origen:

```hcl
resource "aws_iam_role_policy" "sqs" {
  name = "${var.project}-sqs-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.orders.arn
      },
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [aws_sqs_queue.success.arn, aws_sqs_queue.failure.arn]
      },
    ]
  })
}
```

---

## Estructura del proyecto

```
lab30/
├── aws/
│   ├── aws.s3.tfbackend      # Parámetros del backend S3 (sin bucket)
│   ├── providers.tf          # Backend S3, Terraform >= 1.5, providers AWS y archive
│   ├── variables.tf          # region, project, runtime, app_env
│   ├── main.tf               # archive_file, SQS (x4), IAM, CloudWatch, Lambda,
│   │                         # Lambda Destinations, Event Source Mapping
│   ├── outputs.tf            # URLs de colas, function_name, log_group, comandos de ejemplo
│   └── src/
│       └── function/
│           └── handler.py    # Handler: procesa lotes SQS e invocaciones async directas
└── localstack/
    ├── providers.tf          # Endpoints apuntando a LocalStack (lambda, sqs, iam, logs)
    ├── variables.tf          # Mismas variables, project = "lab30-local"
    ├── main.tf               # Idéntico a aws/main.tf (filter_criteria y Destinations con soporte parcial)
    ├── outputs.tf
    └── src/
        └── function/
            └── handler.py    # Copia idéntica a aws/src/
```

> **Nota**: `function.zip` es un artefacto generado por `archive_file` durante `terraform plan/apply`. No se versiona en Git — añádelo a `.gitignore`.

---

## 1. Despliegue en AWS Real

### 1.1 Arquitectura

```
Producer (aws sqs send-message)
    │
    │  {"order_id":"ORD-001","order_type":"premium","amount":299.99}
    ▼
┌──────────────────────────────────────────────────────────────────┐
│  SQS: lab30-orders                                               │
│  visibility_timeout = 30 s                                       │
│  redrive_policy:                                                 │
│    deadLetterTargetArn = lab30-dlq                               │
│    maxReceiveCount     = 3                                       │
└─────────────────────────┬────────────────────────────────────────┘
                          │ event_source_mapping
                          │ batch_size = 10
                          │ filter_criteria: order_type = "premium"
                          │ (mensajes "standard" se descartan aquí)
                          ▼
┌──────────────────────────────────────────────────────────────────┐
│  Lambda: lab30-processor (Python 3.12)                           │
│  timeout = 30 s                                                  │
│                                                                  │
│  destination_config (invocaciones async directas):               │
│    on_success → lab30-success                                    │
│    on_failure → lab30-failure                                    │
└──────────────────────────────────────────────────────────────────┘
         │ [3 fallos en ESM]            │ logs
         ▼                              ▼
┌────────────────────┐    ┌──────────────────────────────────────┐
│  SQS: lab30-dlq    │    │  CloudWatch: /aws/lambda/lab30-proc  │
│  retención 14 días │    │  (7 días)                            │
└────────────────────┘    └──────────────────────────────────────┘

Path async directo (aws lambda invoke --invocation-type Event):
  Éxito  (amount ≤ 9999) → lab30-success
  Fallo  (amount > 9999) → lab30-failure

Terraform local:
  data "archive_file" "function" → src/function/ → function.zip
  source_code_hash               → hash del ZIP  → detecta cambios → redeploy
```

### 1.2 Código Terraform

**`aws/main.tf`** — Fragmentos clave:

La cola principal define la DLQ a través de `redrive_policy`. El `visibility_timeout_seconds` iguala el timeout de Lambda para evitar reprocesamientos accidentales:

```hcl
resource "aws_sqs_queue" "orders" {
  name                       = "${var.project}-orders"
  visibility_timeout_seconds = 30  # igual que el timeout de Lambda

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = 3  # 3 intentos fallidos → DLQ
  })
}
```

El `filter_criteria` usa `jsonencode()` para construir el patrón de filtro. El campo `body` es especial: AWS parsea el body del mensaje SQS como JSON para evaluar el filtro:

```hcl
resource "aws_lambda_event_source_mapping" "orders" {
  event_source_arn = aws_sqs_queue.orders.arn
  function_name    = aws_lambda_function.processor.arn
  batch_size       = 10

  filter_criteria {
    filter {
      pattern = jsonencode({
        body = {
          order_type = ["premium"]
        }
      })
    }
  }
}
```

Las Lambda Destinations se configuran en un recurso separado, no como argumento de `aws_lambda_function`. Esto permite modificarlas sin redesplegar la función:

```hcl
resource "aws_lambda_function_event_invoke_config" "processor" {
  function_name = aws_lambda_function.processor.function_name

  destination_config {
    on_success {
      destination = aws_sqs_queue.success.arn
    }
    on_failure {
      destination = aws_sqs_queue.failure.arn
    }
  }
}
```

### 1.3 Inicialización y despliegue

```bash
export BUCKET="terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"

# Desde lab30/aws/
terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform plan
terraform apply
```

Al finalizar, los outputs mostrarán:

```
dlq_url                      = "https://sqs.us-east-1.amazonaws.com/123456789/lab30-dlq"
failure_queue_url             = "https://sqs.us-east-1.amazonaws.com/123456789/lab30-failure"
function_arn                  = "arn:aws:lambda:us-east-1:123456789:function:lab30-processor"
function_name                 = "lab30-processor"
invoke_async_failure_example  = "aws lambda invoke --function-name lab30-processor ..."
invoke_async_success_example  = "aws lambda invoke --function-name lab30-processor ..."
log_group                     = "/aws/lambda/lab30-processor"
orders_queue_arn              = "arn:aws:sqs:us-east-1:123456789:lab30-orders"
orders_queue_url              = "https://sqs.us-east-1.amazonaws.com/123456789/lab30-orders"
send_premium_example          = "aws sqs send-message --queue-url ... --message-body ..."
send_standard_example         = "aws sqs send-message --queue-url ... --message-body ..."
success_queue_url             = "https://sqs.us-east-1.amazonaws.com/123456789/lab30-success"
```

### 1.4 Verificar el sistema

**Paso 1** — Envía una orden premium y observa cómo Lambda la procesa:

```bash
ORDERS_URL=$(terraform output -raw orders_queue_url)

aws sqs send-message \
  --queue-url "$ORDERS_URL" \
  --message-body '{"order_id":"ORD-001","order_type":"premium","amount":299.99,"customer":"cliente-test"}'
```

Espera unos segundos (Lambda pollea periódicamente) y verifica los logs:

```bash
LOG_GROUP=$(terraform output -raw log_group)
aws logs tail "$LOG_GROUP" --follow --format short
```

Deberías ver algo como:
```
Procesando orden order_id=ORD-001 order_type=premium amount=299.99
[SQS] Batch completado: 1 órdenes procesadas — env=production project=lab26
```

**Paso 2** — Verifica que filter_criteria descarta órdenes estándar:

```bash
# Esta orden NO debería activar Lambda (order_type = "standard")
aws sqs send-message \
  --queue-url "$ORDERS_URL" \
  --message-body '{"order_id":"ORD-002","order_type":"standard","amount":49.99}'

# Espera y comprueba que la cola de órdenes queda vacía (mensaje descartado)
aws sqs get-queue-attributes \
  --queue-url "$ORDERS_URL" \
  --attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible
```

**Paso 3** — Prueba la DLQ con un mensaje que falla sistemáticamente:

```bash
# amount > 9999 → handler lanza ValueError → 3 reintentos → DLQ
aws sqs send-message \
  --queue-url "$ORDERS_URL" \
  --message-body '{"order_id":"ORD-FAIL","order_type":"premium","amount":99999.99}'
```

Tras unos minutos (3 intentos × visibility_timeout), el mensaje aparecerá en la DLQ:

```bash
DLQ_URL=$(terraform output -raw dlq_url)
aws sqs receive-message \
  --queue-url "$DLQ_URL" \
  --max-number-of-messages 10 \
  --query 'Messages[*].Body'
```

**Paso 4** — Inspecciona el Event Source Mapping y su estado:

```bash
FUNCTION=$(terraform output -raw function_name)

aws lambda list-event-source-mappings \
  --function-name "$FUNCTION" \
  --query 'EventSourceMappings[*].{UUID:UUID,Estado:State,BatchSize:BatchSize,Filtros:FilterCriteria}'
```

**Paso 5** — Demuestra Lambda Destinations con invocación asíncrona:

```bash
# Invocación exitosa → debería llegar a success-queue
terraform output -raw invoke_async_success_example | bash

# Invocación fallida (amount > 9999) → debería llegar a failure-queue
terraform output -raw invoke_async_failure_example | bash

# Espera unos segundos y verifica las colas de destino
SUCCESS_URL=$(terraform output -raw success_queue_url)
FAILURE_URL=$(terraform output -raw failure_queue_url)

aws sqs receive-message \
  --queue-url "$SUCCESS_URL" \
  --max-number-of-messages 5 \
  --query 'Messages[*].Body' | python3 -m json.tool

aws sqs receive-message \
  --queue-url "$FAILURE_URL" \
  --max-number-of-messages 5 \
  --query 'Messages[*].Body' | python3 -m json.tool
```

El mensaje en `success_queue` tendrá la forma:
```json
{
  "version": "1.0",
  "timestamp": "2025-01-15T10:30:00.000Z",
  "requestContext": { "functionArn": "...", "requestId": "..." },
  "requestPayload": { "order_id": "ASYNC-001", ... },
  "responseContext": { "statusCode": 200 },
  "responsePayload": { "order_id": "ASYNC-001", "status": "processed", ... }
}
```

### 1.5 Forzar redeploy con source_code_hash

Modifica el handler y verifica que Terraform detecta el cambio:

```bash
# Añade un campo "version" al resultado del handler
# Edita src/function/handler.py y añade "lab_version": "1.1" en el return de _process_order

terraform plan
# ~ source_code_hash = "aBcDe..." -> "XyZwV..."

terraform apply

# Verifica que el nuevo código se ejecuta
aws sqs send-message \
  --queue-url "$ORDERS_URL" \
  --message-body '{"order_id":"ORD-v2","order_type":"premium","amount":99.99}'

aws logs tail "$LOG_GROUP" --format short
```

---

> **Antes de comenzar los retos**, asegúrate de que `terraform apply` ha completado sin errores y de que enviando un mensaje premium a la cola de órdenes Lambda lo procesa correctamente (verifica los logs).

## 2. Reto 1: Alarma en la Dead Letter Queue

En producción, los mensajes que llegan a la DLQ indican fallos que requieren atención. Sin una alarma, estos mensajes pueden acumularse días sin ser detectados. El objetivo de este reto es configurar un mecanismo de alerta temprana sobre la DLQ.

### Requisitos

1. Crea un recurso `aws_cloudwatch_metric_alarm` que se active cuando `ApproximateNumberOfMessagesVisible` en la DLQ sea `>= 1`.
   - `alarm_name`: `"${var.project}-dlq-not-empty"`
   - `namespace`: `"AWS/SQS"`
   - `metric_name`: `"ApproximateNumberOfMessagesVisible"`
   - `dimensions`: `{ QueueName = aws_sqs_queue.dlq.name }`
   - `period`: `60` segundos
   - `evaluation_periods`: `1`
   - `statistic`: `"Sum"`
   - `comparison_operator`: `"GreaterThanOrEqualToThreshold"`
   - `threshold`: `1`
2. Añade un output `dlq_alarm_name` con el nombre de la alarma.

### Criterios de éxito

- `aws cloudwatch describe-alarms --alarm-names "${var.project}-dlq-not-empty"` muestra la alarma en estado `OK` o `ALARM`.
- Si envías un mensaje que falla sistemáticamente (amount > 9999) y esperas a que llegue a la DLQ, la alarma pasa al estado `ALARM`.
- Puedes explicar la diferencia entre `period` (ventana de evaluación) y `evaluation_periods` (cuántas ventanas consecutivas deben cumplir la condición).

[Ver solución →](#4-solución-de-los-retos)

---

## 3. Reto 2: Fallos Parciales de Lote (report_batch_item_failures)

Actualmente, si un lote de 10 mensajes contiene 1 mensaje inválido, Lambda lanza una excepción y los 10 mensajes se reencolan. Esto provoca que 9 mensajes válidos se procesen hasta 3 veces antes de que el inválido llegue a la DLQ. `report_batch_item_failures` permite que Lambda reporte exactamente qué mensajes fallaron, para que solo esos se reencolen.

### Requisitos

1. Activa `function_response_types = ["ReportBatchItemFailures"]` en `aws_lambda_event_source_mapping`.
2. Modifica el handler para que, en lugar de lanzar una excepción al fallar un mensaje, capture el error y construya una respuesta de `batchItemFailures`:

```python
def lambda_handler(event, context):
    failures = []
    for record in event["Records"]:
        try:
            body = json.loads(record["body"])
            _process_order(body)
        except Exception as e:
            logger.error("Fallo en mensaje %s: %s", record["messageId"], e)
            failures.append({"itemIdentifier": record["messageId"]})

    return {"batchItemFailures": failures}
```

3. Verifica que, con un lote mixto (un mensaje inválido + varios válidos), solo el inválido se reencola y eventualmente llega a la DLQ, mientras los válidos se procesan una sola vez.

### Criterios de éxito

- `aws lambda list-event-source-mappings` muestra `FunctionResponseTypes: ["ReportBatchItemFailures"]` en el mapping.
- Enviando un lote mixto (puedes enviar varios mensajes rapidamente), los mensajes válidos aparecen procesados en los logs exactamente una vez.
- El mensaje inválido aparece en la DLQ tras `maxReceiveCount` reintentos.
- Puedes explicar por qué sin `report_batch_item_failures` el procesamiento de duplicados puede disparar costes inesperados en colas de alto volumen.

[Ver solución →](#4-solución-de-los-retos)

---

## 4. Solución de los Retos

> Intenta resolver los retos antes de leer esta sección.

### Solución Reto 1 — Alarma en la Dead Letter Queue

Añade el recurso `aws_cloudwatch_metric_alarm` en `main.tf`:

```hcl
resource "aws_cloudwatch_metric_alarm" "dlq_not_empty" {
  alarm_name          = "${var.project}-dlq-not-empty"
  alarm_description   = "La DLQ tiene mensajes — revisar fallos de procesamiento"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions          = { QueueName = aws_sqs_queue.dlq.name }
  period              = 60
  evaluation_periods  = 1
  statistic           = "Sum"
  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  treat_missing_data  = "notBreaching"

  tags = local.tags
}
```

Añade el output en `outputs.tf`:

```hcl
output "dlq_alarm_name" {
  description = "Nombre de la alarma CloudWatch sobre la DLQ"
  value       = aws_cloudwatch_metric_alarm.dlq_not_empty.alarm_name
}
```

Verifica el estado de la alarma:

```bash
aws cloudwatch describe-alarms \
  --alarm-names "$(terraform output -raw dlq_alarm_name)" \
  --query 'MetricAlarms[0].{Estado:StateValue,Razon:StateReason}'
```

Justo después del `terraform apply`, la alarma muestra `INSUFFICIENT_DATA` con razón `"Unchecked: Initial alarm creation"`. Es el estado inicial normal: CloudWatch aún no tiene datos de la métrica `ApproximateNumberOfMessagesVisible` para ese `period`. Tras el primer ciclo de evaluación (60 segundos), transitará a `OK` si la DLQ está vacía.

`treat_missing_data = "notBreaching"` es lo que evita que esa ausencia inicial de datos se interprete como un fallo y dispare la alarma prematuramente.

### Solución Reto 2 — Fallos Parciales de Lote

**Terraform** — actualiza `aws_lambda_event_source_mapping` en `main.tf`:

```hcl
resource "aws_lambda_event_source_mapping" "orders" {
  event_source_arn        = aws_sqs_queue.orders.arn
  function_name           = aws_lambda_function.processor.arn
  batch_size              = 10
  enabled                 = true
  function_response_types = ["ReportBatchItemFailures"]

  filter_criteria {
    filter {
      pattern = jsonencode({
        body = { order_type = ["premium"] }
      })
    }
  }
}
```

**Python** — reemplaza `lambda_handler` en `handler.py`:

```python
def lambda_handler(event, context):
    env     = os.environ.get("APP_ENV", "unknown")
    project = os.environ.get("APP_PROJECT", "unknown")
    failures = []

    for record in event["Records"]:
        try:
            body = json.loads(record["body"])
            result = _process_order(body)
            logger.info("[SQS] Procesado: %s", json.dumps(result))
        except Exception as exc:
            logger.error(
                "[SQS] Fallo en messageId=%s: %s", record["messageId"], exc
            )
            failures.append({"itemIdentifier": record["messageId"]})

    logger.info(
        "[SQS] Lote finalizado: %d ok, %d fallidos — env=%s project=%s",
        len(event["Records"]) - len(failures), len(failures), env, project,
    )
    return {"batchItemFailures": failures}
```

Verifica que el mapping refleja la configuración:

```bash
aws lambda list-event-source-mappings \
  --function-name "$(terraform output -raw function_name)" \
  --query 'EventSourceMappings[0].FunctionResponseTypes'
```

**Paso 1** — Aplica los cambios:

```bash
terraform apply
```

**Paso 2** — Invoca Lambda directamente con un evento SQS sintético que contiene un lote mixto. Lambda recoge mensajes de SQS de uno en uno cuando el volumen es bajo, por lo que la forma fiable de probar el comportamiento de lote es construir el evento manualmente:

```bash
FUNCTION=$(terraform output -raw function_name)

aws lambda invoke \
  --function-name "$FUNCTION" \
  --cli-binary-format raw-in-base64-out \
  --payload '{
    "Records": [
      {"messageId":"msg-ok-1","body":"{\"order_id\":\"ORD-OK-1\",\"order_type\":\"premium\",\"amount\":50.00}"},
      {"messageId":"msg-ok-2","body":"{\"order_id\":\"ORD-OK-2\",\"order_type\":\"premium\",\"amount\":100.00}"},
      {"messageId":"msg-ok-3","body":"{\"order_id\":\"ORD-OK-3\",\"order_type\":\"premium\",\"amount\":150.00}"},
      {"messageId":"msg-ok-4","body":"{\"order_id\":\"ORD-OK-4\",\"order_type\":\"premium\",\"amount\":200.00}"},
      {"messageId":"msg-bad-1","body":"{\"order_id\":\"ORD-BAD-1\",\"order_type\":\"premium\",\"amount\":99999.99}"}
    ]
  }' \
  /tmp/response.json && cat /tmp/response.json | python3 -m json.tool
```

**Paso 3** — Verifica la respuesta. Solo el mensaje inválido debe aparecer en `batchItemFailures`:

```json
{
  "batchItemFailures": [
    { "itemIdentifier": "msg-bad-1" }
  ]
}
```

Si la función devuelve `"batchItemFailures": []` o el campo no aparece, significa que `report_batch_item_failures` no está activo o que el handler no está retornando la estructura correcta.

**Paso 4** — Verifica los logs. Los 4 mensajes válidos deben aparecer procesados exactamente una vez; el inválido, con un error:

```bash
LOG_GROUP=$(terraform output -raw log_group)
aws logs tail "$LOG_GROUP" --format short
```

Salida esperada:
```
[SQS] Procesado: {"order_id": "ORD-OK-1", "status": "processed", ...}
[SQS] Procesado: {"order_id": "ORD-OK-2", "status": "processed", ...}
[SQS] Procesado: {"order_id": "ORD-OK-3", "status": "processed", ...}
[SQS] Procesado: {"order_id": "ORD-OK-4", "status": "processed", ...}
[SQS] Fallo en messageId=msg-bad-1: order_id=ORD-BAD-1: amount 99999.99 supera el límite 9999.99
[SQS] Lote finalizado: 4 ok, 1 fallidos — env=production project=lab26
```

**Paso 5** — Para contrastar, prueba cómo se comportaría el handler **sin** `report_batch_item_failures` — es decir, el handler original que lanza la excepción directamente en lugar de acumular fallos:

```bash
# Simula el handler original: lanza excepción en el primer mensaje inválido
aws lambda invoke \
  --function-name "$FUNCTION" \
  --cli-binary-format raw-in-base64-out \
  --payload '{
    "Records": [
      {"messageId":"msg-ok-1","body":"{\"order_id\":\"ORD-OK-1\",\"order_type\":\"premium\",\"amount\":50.00}"},
      {"messageId":"msg-bad-1","body":"{\"order_id\":\"ORD-BAD-1\",\"order_type\":\"premium\",\"amount\":99999.99}"},
      {"messageId":"msg-ok-2","body":"{\"order_id\":\"ORD-OK-2\",\"order_type\":\"premium\",\"amount\":100.00}"}
    ]
  }' \
  /tmp/response_old.json && cat /tmp/response_old.json | python3 -m json.tool
```

Con el handler del Reto 2, la respuesta sigue siendo `{"batchItemFailures": ["msg-bad-1"]}` — `msg-ok-1` ya se procesó antes del fallo y `msg-ok-2` no llega a procesarse pero tampoco se reporta como fallido, por lo que SQS lo eliminará junto con `msg-ok-1`. Solo `msg-bad-1` se reencola.

---

## Verificación final

```bash
# Verificar las 4 colas SQS creadas (main, premium, dlq, destinations)
aws sqs list-queues \
  --query 'QueueUrls[?contains(@,`lab30`)]' --output table

# Enviar un mensaje de prueba a la cola principal
QUEUE_URL=$(terraform output -raw main_queue_url)
aws sqs send-message \
  --queue-url "$QUEUE_URL" \
  --message-body '{"order_type":"premium","order_id":"test-001"}'

# Verificar que Lambda procesó el mensaje (ver logs)
aws logs tail "/aws/lambda/$(terraform output -raw lambda_function_name)" \
  --since 5m

# Comprobar que la DLQ está vacia (no hay mensajes fallidos)
DLQ_URL=$(terraform output -raw dlq_url)
aws sqs get-queue-attributes \
  --queue-url "$DLQ_URL" \
  --attribute-names ApproximateNumberOfMessages \
  --query 'Attributes.ApproximateNumberOfMessages'
# Esperado: "0"
```

---

## 5. Limpieza

```bash
# Desde lab30/aws/
terraform destroy

# Eliminar el ZIP generado localmente
rm -f function.zip
```

`terraform destroy` elimina las 4 colas SQS, la función Lambda, el Event Source Mapping, las Lambda Destinations, IAM y CloudWatch Logs. No hay recursos de API Gateway ni Layers en este laboratorio.

---

## 6. LocalStack

Las colas SQS, Lambda y el Event Source Mapping funcionan correctamente en LocalStack Community. `filter_criteria` y Lambda Destinations tienen soporte parcial — los recursos se crean sin errores pero su comportamiento puede diferir del real.

Consulta [localstack/README.md](localstack/README.md) para instrucciones detalladas de despliegue y verificación con `awslocal`.

---

## 7. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| SQS colas y DLQ | Colas reales con latencia de red | Emulado localmente — comportamiento idéntico |
| `redrive_policy` (maxReceiveCount=3) | Mueve mensajes a DLQ tras 3 fallos reales | Funciona correctamente |
| `aws_lambda_event_source_mapping` | Lambda pollea SQS continuamente | Funciona; latencia de polling puede ser mayor |
| `filter_criteria` (order_type=premium) | Solo activa Lambda para mensajes premium | Soporte parcial — puede ignorar el filtro |
| Lambda Destinations (on_success/on_failure) | Enruta resultado de invocaciones async | Soporte parcial — puede no enrutar |
| `source_code_hash` | Detecta cambios y fuerza redeploy | Detecta cambios y fuerza redeploy |
| CloudWatch Metric Alarm (Reto 1) | Alarma real visible en consola | Soporte básico; estado puede no actualizarse |
| `report_batch_item_failures` (Reto 2) | Solo los mensajes fallidos se reencolan | Soporte en versiones recientes de LocalStack |
| Coste | ~$0 con volumen de laboratorio | Sin coste |

---

## Buenas prácticas aplicadas

- **`visibility_timeout_seconds` ≥ `timeout` de Lambda**: si el timeout de Lambda es 30 s, el visibility_timeout de la cola debe ser al menos 30 s. De lo contrario, el mensaje puede volver a ser visible mientras Lambda lo procesa y ser recibido por otro consumidor.
- **DLQ siempre presente**: una cola SQS sin DLQ pierde mensajes silenciosamente cuando se supera el tiempo de retención. La DLQ es el último recurso de diagnóstico.
- **Alarma sobre la DLQ**: sin alerta, los mensajes en la DLQ pueden acumularse días sin ser detectados. Un umbral de 1 mensaje es suficiente para producción.
- **`filter_criteria` reduce costes**: los mensajes filtrados no invocán Lambda, eliminando procesamiento innecesario. Úsalo siempre que el volumen de mensajes descartados sea significativo.
- **Lambda Destinations vs DLQ**: usa Destinations para capturar éxitos (imposible con DLQ) y para tener más contexto sobre el fallo (input + output completos). Usa DLQ cuando el procesamiento es síncrono desde SQS o cuando quieres volver a procesar los mensajes fallidos manualmente.
- **`report_batch_item_failures` en producción**: sin esta opción, un único mensaje inválido en un lote de 100 fuerza el reprocesamiento de los 99 mensajes válidos. Con cargas altas esto puede multiplicar el coste por 3 (maxReceiveCount).

---

## Recursos

- [AWS — Lambda Event Source Mapping con SQS](https://docs.aws.amazon.com/lambda/latest/dg/with-sqs.html)
- [AWS — Lambda Destinations](https://docs.aws.amazon.com/lambda/latest/dg/invocation-async.html#invocation-async-destinations)
- [AWS — Filter criteria para Event Source Mapping](https://docs.aws.amazon.com/lambda/latest/dg/invocation-eventfiltering.html)
- [AWS — Dead Letter Queues en SQS](https://docs.aws.amazon.com/AWSSimpleQueueService/latest/SQSDeveloperGuide/sqs-dead-letter-queues.html)
- [Terraform — aws_lambda_event_source_mapping](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_event_source_mapping)
- [Terraform — aws_lambda_function_event_invoke_config](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function_event_invoke_config)
