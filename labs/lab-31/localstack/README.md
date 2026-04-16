# Laboratorio 27 — LocalStack: API Serverless: Lambda, API Gateway v2 y Layers

Este documento describe cómo ejecutar el laboratorio 27 contra LocalStack. El código Terraform de `localstack/` es una versión reducida respecto a `aws/`: **API Gateway v2 no está disponible en LocalStack Community** (requiere licencia Pro) y se ha eliminado del `main.tf`. Los recursos disponibles — Lambda Layer, Lambda Function, IAM y CloudWatch Logs — funcionan completamente y permiten verificar los mecanismos clave del laboratorio (`archive_file`, `source_code_hash`, Layer).

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
| Lambda Layer (`aws_lambda_layer_version`) | Parcial — el recurso se crea y versiona, pero LocalStack Community no monta la Layer en `/opt/python`; el handler fallaría con `No module named 'utils'`. Solución aplicada en `main.tf`: `utils.py` se empaqueta también dentro del ZIP de la función. |
| Lambda Function (Python 3.12) | Completo — el código Python se ejecuta realmente |
| IAM roles y políticas | Completo |
| CloudWatch Log Groups | Completo |
| **API Gateway v2** (`aws_apigatewayv2_*`) | **No disponible** — requiere LocalStack Pro |
| **`aws_lambda_permission`** | Eliminado (dependía de APIGW) |

### 1.2 Inicialización y despliegue

Asegúrate de que LocalStack está en ejecución:

```bash
localstack status
```

Desde el directorio `lab31/localstack/`:

```bash
terraform fmt
terraform init
terraform plan
terraform apply
```

El `apply` despliega Lambda Layer + Lambda Function + IAM + CloudWatch. No fallará porque los recursos de API Gateway v2 se han eliminado de `localstack/main.tf`.

### 1.3 Verificación

```bash
# Lambda Function
awslocal lambda get-function \
  --function-name "$(terraform output -raw function_name)" \
  --query 'Configuration.{Estado:State,Runtime:Runtime,Handler:Handler}'

# Lambda Layer adjunta
awslocal lambda get-function-configuration \
  --function-name "$(terraform output -raw function_name)" \
  --query 'Layers[*].Arn'

# Versiones de la Layer
awslocal lambda list-layer-versions \
  --layer-name lab31-local-utils \
  --query 'LayerVersions[*].{Version:Version,ARN:LayerVersionArn}'

# Log group
awslocal logs describe-log-groups \
  --log-group-name-prefix /aws/lambda/lab31-local
```

### 1.4 Invocar Lambda directamente

Sin API Gateway, la función se invoca con `awslocal lambda invoke`. El output `invoke_example` ya contiene el comando listo para ejecutar:

```bash
terraform output -raw invoke_example | bash
```

O manualmente, construyendo el evento en payload format 2.0:

```bash
FUNCTION=$(terraform output -raw function_name)

# GET /items — lista todos los items
awslocal lambda invoke \
  --function-name "$FUNCTION" \
  --payload '{"requestContext":{"http":{"method":"GET"}},"rawPath":"/items"}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/response.json && cat /tmp/response.json | python3 -m json.tool

# GET /items/2 — item por ID
awslocal lambda invoke \
  --function-name "$FUNCTION" \
  --payload '{"requestContext":{"http":{"method":"GET"}},"rawPath":"/items/2","pathParameters":{"id":"2"}}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/response.json && cat /tmp/response.json | python3 -m json.tool

# POST /items — crear item
awslocal lambda invoke \
  --function-name "$FUNCTION" \
  --payload '{"requestContext":{"http":{"method":"POST"}},"rawPath":"/items","body":"{\"nombre\":\"Nuevo Item\",\"precio\":29.99}"}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/response.json && cat /tmp/response.json | python3 -m json.tool

# Ruta inexistente (404)
awslocal lambda invoke \
  --function-name "$FUNCTION" \
  --payload '{"requestContext":{"http":{"method":"DELETE"}},"rawPath":"/items/1"}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/response.json && cat /tmp/response.json | python3 -m json.tool
```

### 1.5 Demostración de source_code_hash

El mecanismo de detección de cambios funciona exactamente igual que en AWS real, ya que es una operación puramente local de Terraform:

```bash
# Modifica una línea del handler y observa el cambio de hash en el plan
echo "# cambio de prueba" >> src/function/handler.py
terraform plan
# ~ source_code_hash = "aBcDe..." -> "XyZwV..."

terraform apply

# Verifica que LocalStack ejecuta el nuevo código
FUNCTION=$(terraform output -raw function_name)
awslocal lambda invoke \
  --function-name "$FUNCTION" \
  --payload '{"requestContext":{"http":{"method":"GET"}},"rawPath":"/items"}' \
  --cli-binary-format raw-in-base64-out \
  /tmp/response.json && cat /tmp/response.json | python3 -m json.tool
```

---

## 2. Limpieza

```bash
# Desde lab31/localstack/
terraform destroy

# Eliminar los ZIPs generados localmente
rm -f layer.zip function.zip
```

---

## 3. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| `archive_file` | Genera ZIP localmente (sin llamadas AWS) | Idéntico — operación local |
| `source_code_hash` | Detecta cambios y fuerza redeploy | Detecta cambios y fuerza redeploy |
| Lambda Layer | Versión numerada inmutable en el servicio real | Se crea y numera correctamente |
| Lambda Function | Ejecuta Python 3.12 real en infraestructura AWS | Ejecuta Python 3.12 real en contenedor local |
| Cold start | Latencia real (100–500 ms) | Latencia mínima (entorno local) |
| API Gateway v2 | URL HTTPS pública, rutas, integración AWS_PROXY | **No disponible** en Community |
| `aws_lambda_permission` | Control de acceso real; sin permiso → 403 | No desplegado (depende de APIGW) |
| CloudWatch Logs | Logs reales con `aws logs tail` | Registrados; `awslocal logs` limitado |
| Coste | ~$0 (capa gratuita generosa) | Sin coste |

---

## 4. Buenas Prácticas

- Usa LocalStack para validar que el código Python (`handler.py` + `utils.py`) se ejecuta correctamente antes de desplegar en AWS real, invocando la función directamente con `awslocal lambda invoke`.
- El mecanismo de `source_code_hash` funciona igual en LocalStack: practica el ciclo completo de editar código → `terraform apply` → verificar cambio aquí antes de afectar AWS real.
- Para verificar el flujo completo HTTP → API Gateway v2 → Lambda (rutas, permisos, CORS, throttling), usa AWS real o LocalStack Pro.
- El flag `terraform validate` y `terraform plan` son suficientes para detectar errores de configuración sin necesidad de LocalStack.

---

## 5. Recursos Adicionales

- [LocalStack — Lambda](https://docs.localstack.cloud/aws/services/lambda/)
- [LocalStack coverage — API Gateway v2](https://docs.localstack.cloud/aws/services/apigateway/)
- [LocalStack Pro — soporte ampliado](https://docs.localstack.cloud/aws/getting-started/)
