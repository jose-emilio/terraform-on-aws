# Laboratorio 26 — LocalStack: Procesamiento Asíncrono y Resiliencia de Eventos

![Terraform on AWS](../../../images/lab-banner.svg)


Este documento describe cómo ejecutar el laboratorio 26 contra LocalStack. El código Terraform de `localstack/` es equivalente al de `aws/` con las adaptaciones necesarias para los servicios disponibles en LocalStack Community.

## Requisitos Previos

- LocalStack en ejecución: `localstack start -d`
- Terraform >= 1.5

---

## 1. Despliegue en LocalStack

### 1.1 Limitaciones conocidas

| Servicio | Soporte en Community |
|---|---|
| `archive_file` (provider archive) | Completo — operación local, sin llamadas a AWS |
| `source_code_hash` | Completo — detecta cambios y redespliega |
| SQS (`aws_sqs_queue`, `redrive_policy`) | Completo — colas, DLQ y política de redrive funcionan correctamente |
| Lambda Function (Python 3.12) | Completo — el código Python se ejecuta realmente |
| `aws_lambda_event_source_mapping` (SQS) | Completo — Lambda recibe mensajes de la cola automáticamente |
| IAM roles y políticas | Completo |
| CloudWatch Log Groups | Completo |
| `filter_criteria` | Parcial — los filtros pueden no aplicarse en Community; todos los mensajes podrían activar Lambda independientemente del `order_type` |
| `aws_lambda_function_event_invoke_config` (Lambda Destinations) | Parcial — el recurso se crea sin errores, pero LocalStack Community puede no enrutar el resultado a las colas de destino |

### 1.2 Inicialización y despliegue

Asegúrate de que LocalStack está en ejecución:

```bash
localstack status
```

Desde el directorio `lab30/localstack/`:

```bash
terraform fmt
terraform init
terraform plan
terraform apply
```

El `apply` despliega todas las colas SQS, Lambda, IAM y CloudWatch. No fallará por las limitaciones de `filter_criteria` o Lambda Destinations — los recursos se crean correctamente.

### 1.3 Verificación de recursos

```bash
# Función Lambda
awslocal lambda get-function \
  --function-name "$(terraform output -raw function_name)" \
  --query 'Configuration.{Estado:State,Runtime:Runtime,Handler:Handler}'

# Event Source Mapping
awslocal lambda list-event-source-mappings \
  --function-name "$(terraform output -raw function_name)" \
  --query 'EventSourceMappings[*].{UUID:UUID,Estado:State,BatchSize:BatchSize,Source:EventSourceArn}'

# Colas SQS creadas
awslocal sqs list-queues

# Atributos de la cola de órdenes (redrive policy)
awslocal sqs get-queue-attributes \
  --queue-url "$(terraform output -raw orders_queue_url)" \
  --attribute-names All \
  --query 'Attributes.{RetentionSeconds:MessageRetentionPeriod,VisibilityTimeout:VisibilityTimeout,RedrivePolicy:RedrivePolicy}'

# Log group
awslocal logs describe-log-groups \
  --log-group-name-prefix /aws/lambda/lab30-local
```

### 1.4 Flujo SQS → Lambda (Event Source Mapping)

El Event Source Mapping está activo y Lambda pollea la cola automáticamente. Envía mensajes y observa cómo Lambda los procesa:

```bash
ORDERS_URL=$(terraform output -raw orders_queue_url)

# Orden premium (debería activar Lambda según filter_criteria)
awslocal sqs send-message \
  --queue-url "$ORDERS_URL" \
  --message-body '{"order_id":"ORD-001","order_type":"premium","amount":299.99}'

# Orden estándar (debería ser filtrada en AWS real; en Community puede activar Lambda)
awslocal sqs send-message \
  --queue-url "$ORDERS_URL" \
  --message-body '{"order_id":"ORD-002","order_type":"standard","amount":49.99}'

# Orden con amount > 9999 (procesamiento fallará → 3 reintentos → DLQ)
awslocal sqs send-message \
  --queue-url "$ORDERS_URL" \
  --message-body '{"order_id":"ORD-003","order_type":"premium","amount":99999.99}'

# Espera unos segundos y verifica los logs de Lambda
awslocal logs describe-log-streams \
  --log-group-name "$(terraform output -raw log_group)" \
  --order-by LastEventTime --descending --max-items 3

# Verifica mensajes en la DLQ (tras varios segundos para que los reintentos completen)
awslocal sqs get-queue-attributes \
  --queue-url "$(terraform output -raw dlq_url)" \
  --attribute-names ApproximateNumberOfMessages
```

### 1.5 Lambda Destinations (invocación async directa)

Para demostrar Lambda Destinations con invocación asíncrona:

```bash
FUNCTION=$(terraform output -raw function_name)

# Invocación async exitosa (amount ≤ 9999) → debería llegar a success-queue
awslocal lambda invoke \
  --function-name "$FUNCTION" \
  --invocation-type Event \
  --payload '{"order_id":"ASYNC-001","order_type":"premium","amount":500.00}' \
  --cli-binary-format raw-in-base64-out \
  /dev/null

# Invocación async fallida (amount > 9999) → debería llegar a failure-queue
awslocal lambda invoke \
  --function-name "$FUNCTION" \
  --invocation-type Event \
  --payload '{"order_id":"ASYNC-002","order_type":"premium","amount":99999.99}' \
  --cli-binary-format raw-in-base64-out \
  /dev/null

# Verifica mensajes en success-queue (soporte parcial en Community)
awslocal sqs receive-message \
  --queue-url "$(terraform output -raw success_queue_url)" \
  --max-number-of-messages 5

# Verifica mensajes en failure-queue (soporte parcial en Community)
awslocal sqs receive-message \
  --queue-url "$(terraform output -raw failure_queue_url)" \
  --max-number-of-messages 5
```

### 1.6 Invocación sync directa (para verificar el handler)

Para verificar que el handler Python funciona correctamente sin esperar al Event Source Mapping, invoca Lambda de forma síncrona:

```bash
FUNCTION=$(terraform output -raw function_name)

# Orden premium válida
awslocal lambda invoke \
  --function-name "$FUNCTION" \
  --payload '{"Records":[{"body":"{\"order_id\":\"ORD-TEST\",\"order_type\":\"premium\",\"amount\":150.00}"}]}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/response.json && cat /tmp/response.json | python3 -m json.tool

# Orden que falla (amount > 9999) — verifica el mensaje de error
awslocal lambda invoke \
  --function-name "$FUNCTION" \
  --payload '{"Records":[{"body":"{\"order_id\":\"ORD-FAIL\",\"order_type\":\"premium\",\"amount\":99999.99}"}]}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/response_fail.json && cat /tmp/response_fail.json | python3 -m json.tool
```

---

## 2. Limpieza

```bash
# Desde lab30/localstack/
terraform destroy

# Eliminar el ZIP generado localmente
rm -f function.zip
```

---

## 3. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| SQS colas y DLQ | Colas reales con latencia de red | Emulado localmente — comportamiento idéntico |
| `redrive_policy` (maxReceiveCount=3) | Mueve mensajes a DLQ tras 3 fallos reales | Funciona correctamente |
| `aws_lambda_event_source_mapping` | Lambda pollea SQS continuamente | Funciona; puede haber mayor latencia de polling |
| `filter_criteria` (order_type=premium) | Solo activa Lambda para mensajes premium | Soporte parcial — puede ignorar el filtro |
| Lambda Destinations (on_success/on_failure) | Enruta resultado a colas según éxito/fallo | Soporte parcial — puede no enrutar |
| `source_code_hash` | Detecta cambios y fuerza redeploy | Detecta cambios y fuerza redeploy |
| CloudWatch Logs | Logs reales con `aws logs tail` | Registrados; `awslocal logs` limitado |
| Coste | ~$0 con volumen de laboratorio | Sin coste |

---

## 4. Buenas Prácticas

- Usa LocalStack para verificar que el handler Python (`handler.py`) procesa correctamente tanto lotes SQS como invocaciones directas, antes de desplegar en AWS real.
- El mecanismo de `source_code_hash` funciona igual en LocalStack: practica el ciclo editar → `terraform apply` → verificar aquí antes de afectar AWS real.
- Para verificar el comportamiento preciso de `filter_criteria` (solo mensajes premium activan Lambda) y Lambda Destinations (enrutamiento correcto a success/failure queues), usa AWS real.
- Verifica siempre que `visibility_timeout_seconds` de la cola es >= `timeout` de la función Lambda para evitar que mensajes se reencolen mientras Lambda los procesa.

---

## 5. Recursos Adicionales

- [LocalStack — SQS](https://docs.localstack.cloud/aws/services/sqs/)
- [LocalStack — Lambda](https://docs.localstack.cloud/aws/services/lambda/)
- [LocalStack coverage — Lambda Event Source Mappings](https://docs.localstack.cloud/aws/services/lambda/)
