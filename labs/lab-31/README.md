# Laboratorio 31: API Serverless: Lambda, API Gateway v2 y Layers

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 7 — Cómputo en AWS con Terraform](../../modulos/modulo-07/README.md)


## Visión general

En este laboratorio construirás una API REST completa usando el ecosistema serverless de AWS sin gestionar servidores. Automatizarás el empaquetado del código Python con el data source `archive_file` y forzarás redespliegues precisos mediante `source_code_hash`, de modo que cualquier cambio en el código fuente se detecta en el `terraform plan` antes de aplicar. Separarás las utilidades compartidas del código lógico usando una **Lambda Layer**, desplegando una API en API Gateway v2 con `auto_deploy = true` e integración `AWS_PROXY`, y configurarás los permisos de invocación con `aws_lambda_permission` limitado al ARN de ejecución de esta API concreta.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Usar `data "archive_file"` del provider `archive` para empaquetar directorios de código fuente en ZIPs localmente y calcular su hash con `output_base64sha256`
- Pasar `source_code_hash` a `aws_lambda_function` y `aws_lambda_layer_version` para que Terraform detecte cambios en el contenido del código y fuerce el redespliegue aunque el nombre del ZIP no cambie
- Crear una Lambda Layer con `aws_lambda_layer_version` usando la estructura de directorio `python/` que el runtime Python añade automáticamente al `sys.path`
- Desplegar una HTTP API v2 con `aws_apigatewayv2_api`, un stage `$default` con `auto_deploy = true` y una integración `AWS_PROXY` con `payload_format_version = "2.0"` que delega toda la lógica HTTP a Lambda
- Definir rutas con `aws_apigatewayv2_route` usando placeholders de path (`{id}`) que se exponen en el evento Lambda como `pathParameters`
- Configurar `aws_lambda_permission` con `source_arn` acotado al `execution_arn` de la API para que solo esa API pueda invocar la función

## Requisitos Previos

- Terraform >= 1.5 instalado
- Laboratorio 2 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir
- Perfil AWS con permisos sobre Lambda, API Gateway v2, IAM y CloudWatch Logs
- LocalStack en ejecución (para la sección de LocalStack)

---

## Conceptos Clave

### Empaquetado con archive_file y source_code_hash

`data "archive_file"` es un data source del provider `hashicorp/archive` que genera ZIPs localmente sin llamar a ninguna API de AWS. Procesa el directorio fuente en tiempo de `terraform plan` y expone el atributo `output_base64sha256` con el hash SHA-256 del ZIP resultante.

```hcl
data "archive_file" "function" {
  type        = "zip"
  source_dir  = "${path.module}/src/function"
  output_path = "${path.module}/function.zip"
}
```

El problema que resuelve `source_code_hash` es sutil: si solo usas `filename` en `aws_lambda_function`, Terraform detecta cambios en el archivo ZIP comparando su checksum en disco. Si el ZIP se regenera con el mismo contenido (por ejemplo, tras un `terraform init` en otra máquina), Terraform podría no detectar el cambio. Con `source_code_hash`, el hash se almacena explícitamente en el estado y se compara en cada plan:

```hcl
resource "aws_lambda_function" "api" {
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256
  # ...
}
```

Cuando modificas `handler.py`, el ZIP cambia, su hash cambia, y la salida de `terraform plan` muestra:

```
~ source_code_hash = "aBcDe..." -> "XyZwV..."
```

### Lambda Layers

Una Lambda Layer es un paquete ZIP que Lambda monta en el entorno de ejecución en `/opt`. Para el runtime Python, la estructura dentro del ZIP debe ser:

```
layer.zip
└── python/
    └── utils.py      ← accesible como "from utils import ..."
```

Lambda añade `/opt/python` al `sys.path` del runtime automáticamente. El código de la función puede importar el módulo sin instalación adicional ni rutas explícitas.

```hcl
resource "aws_lambda_layer_version" "utils" {
  layer_name          = "${var.project}-utils"
  filename            = data.archive_file.layer.output_path
  source_code_hash    = data.archive_file.layer.output_base64sha256
  compatible_runtimes = ["python3.12"]
}
```

Cada `terraform apply` que modifica `utils.py` crea una **nueva versión numerada** de la Layer. Las versiones son inmutables: no se sobreescriben. La función Lambda referencia la Layer por su ARN versionado, por lo que un cambio en la Layer fuerza automáticamente el redespliegue de la función:

```hcl
layers = [aws_lambda_layer_version.utils.arn]
# ARN ejemplo: arn:aws:lambda:us-east-1:123:layer:lab31-utils:3
```

### HTTP API con API Gateway v2

API Gateway v2 ofrece HTTP API (barata y rápida) y WebSocket API. La HTTP API es hasta 70 % más barata que la REST API v1 y tiene menor latencia porque elimina muchas funcionalidades de transformación que REST API incluye por defecto.

```hcl
resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project}-api"
  protocol_type = "HTTP"   # HTTP API (v2) — no REST API (v1)
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"    # stage especial: URL sin sufijo de stage
  auto_deploy = true          # publica cambios de rutas e integraciones automáticamente
}
```

El stage `$default` es especial: su URL no incluye el nombre del stage. En REST API v1, la URL sería `https://{id}.execute-api.{region}.amazonaws.com/prod/items`; en HTTP API con `$default` es simplemente `https://{id}.execute-api.{region}.amazonaws.com/items`.

### Integración AWS_PROXY y Payload Format 2.0

`integration_type = "AWS_PROXY"` delega toda la lógica HTTP a Lambda. API Gateway reenvía el evento completo (método, path, headers, body, query params…) a la función y devuelve la respuesta sin transformarla. La función Lambda controla completamente el `statusCode`, `headers` y `body`.

```hcl
resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.api.invoke_arn
  payload_format_version = "2.0"
}
```

`payload_format_version = "2.0"` usa el esquema de evento simplificado que expone `requestContext.http.method`, `rawPath`, `pathParameters`, etc. — en lugar del esquema verbose de la REST API v1.

Los placeholders `{id}` en `route_key` se mapean automáticamente a `event["pathParameters"]["id"]` en Lambda:

```hcl
resource "aws_apigatewayv2_route" "get_item" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /items/{id}"   # {id} → event["pathParameters"]["id"]
  target    = "integrations/${aws_apigatewayv2_integration.lambda.id}"
}
```

### Permiso de Invocación Lambda

Sin `aws_lambda_permission`, API Gateway recibe `403 Forbidden` al intentar invocar Lambda. Este recurso añade una política basada en recursos a la función Lambda que autoriza a `apigateway.amazonaws.com` como principal.

```hcl
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"

  # execution_arn: arn:aws:execute-api:{region}:{account}:{api-id}
  # El patrón "/*/*" cubre cualquier stage y ruta de ESTA API.
  # Es más seguro que "*" porque limita el permiso a una API concreta.
  source_arn = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
```

---

## Estructura del proyecto

```
lab31/
├── aws/
│   ├── aws.s3.tfbackend      # Parámetros del backend S3 (sin bucket)
│   ├── providers.tf          # Backend S3, Terraform >= 1.5, providers AWS y archive
│   ├── variables.tf          # region, project, runtime, app_env
│   ├── main.tf               # archive_file, IAM, CloudWatch, Layer, Lambda, APIGW, Permission
│   ├── outputs.tf            # api_endpoint, function_name, layer_arn, log_group, curl_*
│   └── src/
│       ├── function/
│       │   └── handler.py    # Handler Lambda: GET /items, GET /items/{id}, POST /items
│       └── layer/
│           └── python/
│               └── utils.py  # Layer: format_response() y get_metadata()
└── localstack/
    ├── providers.tf          # Endpoints apuntando a LocalStack (lambda, apigatewayv2, iam, logs)
    ├── variables.tf          # Mismas variables, project = "lab31-local"
    ├── main.tf               # Idéntico a aws/main.tf
    ├── outputs.tf
    └── src/                  # Copia del código fuente (idéntica a aws/src/)
        ├── function/
        │   └── handler.py
        └── layer/
            └── python/
                └── utils.py
```

> **Nota**: `layer.zip` y `function.zip` son artefactos generados por `archive_file` durante `terraform plan/apply`. No se versionan en Git — añádelos a `.gitignore`.

---

## 1. Despliegue en AWS Real

### 1.1 Arquitectura

```
Cliente (curl / navegador)
    │
    │  GET /items
    │  GET /items/{id}
    │  POST /items
    ▼
┌──────────────────────────────────────────────────────────────────┐
│  API Gateway v2 — HTTP API                                       │
│  https://{api-id}.execute-api.us-east-1.amazonaws.com            │
│                                                                  │
│  Stage: $default  (auto_deploy = true)                           │
│  Integración: AWS_PROXY → payload_format_version = "2.0"         │
└─────────────────────────────┬────────────────────────────────────┘
                              │ lambda:InvokeFunction
                              │ (aws_lambda_permission · source_arn = execution_arn/*/*)
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  Lambda Function: lab31-function (Python 3.12)                   │
│  handler = "handler.lambda_handler"                              │
│                                                                  │
│  Variables de entorno:                                           │
│    APP_ENV     = "production"                                    │
│    APP_PROJECT = "lab31"                                         │
│                                                                  │
│  Layers:                                                         │
│  ┌──────────────────────────────────────────┐                    │
│  │  lab31-utils (Lambda Layer)              │                    │
│  │  /opt/python/utils.py                    │                    │
│  │    · format_response(status, body) → {}  │                    │
│  │    · get_metadata(context) → {}          │                    │
│  └──────────────────────────────────────────┘                    │
└─────────────────────────────┬────────────────────────────────────┘
                              │ logs
                              ▼
┌──────────────────────────────────────────────────────────────────┐
│  CloudWatch Logs: /aws/lambda/lab31-function  (7 días)           │
└──────────────────────────────────────────────────────────────────┘

Terraform local:
  data "archive_file" "layer"    → src/layer/ → layer.zip
  data "archive_file" "function" → src/function/ → function.zip
  source_code_hash               → hash del ZIP → detecta cambios → redeploy
```

### 1.2 Código Terraform

**`aws/main.tf`** — Fragmentos clave:

El laboratorio usa **dos `archive_file` independientes** para empaquetar la Layer y la función por separado. Así un cambio en `utils.py` solo actualiza la capa sin recrear la función ZIP, y viceversa:

```hcl
# Empaqueta src/layer/ → layer.zip (contiene python/utils.py)
data "archive_file" "layer" {
  type        = "zip"
  source_dir  = "${path.module}/src/layer"
  output_path = "${path.module}/layer.zip"
}

# Empaqueta src/function/ → function.zip (contiene handler.py)
data "archive_file" "function" {
  type        = "zip"
  source_dir  = "${path.module}/src/function"
  output_path = "${path.module}/function.zip"
}
```

El log group se crea **antes** de la función con `depends_on` para capturar los logs del cold start inicial. Sin él, Lambda crea el grupo automáticamente pero sin `retention_in_days`, acumulando logs indefinidamente:

```hcl
resource "aws_cloudwatch_log_group" "lambda" {
  name              = "/aws/lambda/${var.project}-function"
  retention_in_days = 7
}

resource "aws_lambda_function" "api" {
  function_name    = "${var.project}-function"
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256
  runtime          = var.runtime
  handler          = "handler.lambda_handler"
  role             = aws_iam_role.lambda.arn
  layers           = [aws_lambda_layer_version.utils.arn]

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_cloudwatch_log_group.lambda,
  ]
}
```

El `aws_lambda_permission` usa el `execution_arn` de la API (no el ARN de la función) como `source_arn`. Esto garantiza que solo las invocaciones originadas en esta API puedan ejecutar la función:

```hcl
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
```

### 1.3 Inicialización y despliegue

```bash
export BUCKET="terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"

# Desde lab31/aws/
terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform plan
terraform apply
```

Al finalizar, los outputs mostrarán:

```
api_endpoint   = "https://abc123def4.execute-api.us-east-1.amazonaws.com"
api_id         = "abc123def4"
curl_get_items = "curl -s 'https://abc123def4.execute-api.us-east-1.amazonaws.com/items' | python3 -m json.tool"
curl_post_item = "curl -s -X POST 'https://...' -H 'Content-Type: application/json' -d '{...}' | python3 -m json.tool"
function_arn   = "arn:aws:lambda:us-east-1:123456789:function:lab31-function"
function_name  = "lab31-function"
layer_arn      = "arn:aws:lambda:us-east-1:123456789:layer:lab31-utils:1"
layer_version  = 1
log_group      = "/aws/lambda/lab31-function"
```

### 1.4 Verificar la API

**Paso 1** — Obtén la URL base y comprueba que la función responde:

```bash
API=$(terraform output -raw api_endpoint)
echo "API endpoint: $API"
```

**Paso 2** — `GET /items` — lista todos los items del catálogo:

```bash
curl -s "$API/items" | python3 -m json.tool
```

Respuesta esperada:
```json
{
  "items": [
    {"id": "1", "nombre": "Laptop Pro",       "precio": 1299.99, "categoria": "Electrónica"},
    {"id": "2", "nombre": "Teclado Mecánico", "precio": 149.99,  "categoria": "Electrónica"},
    {"id": "3", "nombre": "Monitor 4K",        "precio": 599.99,  "categoria": "Electrónica"}
  ],
  "total": 3,
  "metadata": {
    "function":    "lab31-function",
    "request_id":  "abc123...",
    "timestamp":   "2025-01-15T10:30:00.123456+00:00",
    "environment": "production",
    "project":     "lab31"
  }
}
```

**Paso 3** — `GET /items/{id}` — item por ID:

```bash
# Item existente (200 OK)
curl -s "$API/items/2" | python3 -m json.tool

# Item inexistente (404 Not Found)
curl -s "$API/items/999" | python3 -m json.tool
```

**Paso 4** — `POST /items` — crear un nuevo item:

```bash
# Creación correcta (201 Created)
curl -s -X POST "$API/items" \
  -H "Content-Type: application/json" \
  -d '{"nombre": "Ratón Ergonómico", "precio": 79.99, "categoria": "Electrónica"}' \
  | python3 -m json.tool

# El item quedó en memoria — verifica que existe (id 4)
curl -s "$API/items/4" | python3 -m json.tool

# Validación: campo 'nombre' requerido (400 Bad Request)
curl -s -X POST "$API/items" \
  -H "Content-Type: application/json" \
  -d '{"precio": 19.99}' | python3 -m json.tool
```

> **Nota sobre warm starts**: el catálogo `_CATALOG` vive en memoria del contenedor Lambda. Se conserva entre invocaciones "cálidas" (mismo contenedor) y se reinicia en cada cold start. Después de POST /items, la siguiente petición GET /items puede devolver 3 ó 4 items dependiendo de si Lambda reutilizó el mismo contenedor. En producción usa DynamoDB u otro almacén persistente.

**Paso 5** — Verifica la Layer adjunta a la función:

```bash
FUNCTION=$(terraform output -raw function_name)

# Versiones de la Layer publicadas
aws lambda list-layer-versions \
  --layer-name "$(terraform output -raw function_name | sed 's/-function//')-utils" \
  --query 'LayerVersions[*].{Version:Version,ARN:LayerVersionArn,Runtime:CompatibleRuntimes[0]}' \
  --output table

# Layers adjuntas a la función
aws lambda get-function-configuration \
  --function-name "$FUNCTION" \
  --query 'Layers[*].Arn' \
  --output table
```

**Paso 6** — Verifica la configuración de la integración y las rutas:

```bash
API_ID=$(terraform output -raw api_id)

# Integración AWS_PROXY
aws apigatewayv2 get-integrations \
  --api-id "$API_ID" \
  --query 'Items[*].{Tipo:IntegrationType,URI:IntegrationUri,Formato:PayloadFormatVersion}' \
  --output table

# Rutas registradas
aws apigatewayv2 get-routes \
  --api-id "$API_ID" \
  --query 'Items[*].{Ruta:RouteKey,Target:Target}' \
  --output table
```

**Paso 7** — Verifica el permiso Lambda:

```bash
aws lambda get-policy \
  --function-name "$FUNCTION" \
  --query 'Policy' --output text | python3 -m json.tool
```

La política debe mostrar `apigateway.amazonaws.com` como principal y el `execution_arn` de la API como `AWS:SourceArn`.

**Paso 8** — Ver logs en CloudWatch:

```bash
LOG_GROUP=$(terraform output -raw log_group)
aws logs tail "$LOG_GROUP" --follow --format short
```

### 1.5 Forzar redeploy con source_code_hash

Este es el mecanismo central del laboratorio. Modifica el código fuente y observa cómo Terraform detecta el cambio sin que el nombre del ZIP varíe:

```bash
# Añade un campo nuevo a la respuesta de GET /items
# Edita src/function/handler.py y añade "version": "1.1" en el return de la ruta /items

# terraform plan muestra el cambio en source_code_hash
terraform plan
# ~ source_code_hash = "aBcDe..." -> "XyZwV..."
# ~ last_modified    = "2025-01-15T10:30:00.000+0000" -> (known after apply)

terraform apply

# Verifica que el nuevo campo aparece
curl -s "$API/items" | python3 -m json.tool
```

Prueba también modificar `utils.py` — Terraform detectará el cambio en la Layer y redespliegará tanto la capa (nueva versión) como la función (nuevo ARN de Layer):

```bash
# Añade un campo "lab_version": "1.0" en get_metadata() de src/layer/python/utils.py
terraform apply
# Verás que TANTO la Layer como la función se actualizan
```

---

> **Antes de comenzar los retos**, asegúrate de que `terraform apply` ha completado sin errores y la API responde correctamente. Ejecuta `curl -s "$API/items"` para confirmarlo.

## 2. Reto 1: CORS y Throttling

La API actual no tiene cabeceras CORS, lo que impide llamarla desde aplicaciones web en el navegador (el navegador bloqueará las peticiones cross-origin). Tampoco tiene limitación de tasa, por lo que un cliente descontrolado podría generar invocaciones masivas de Lambda con coste ilimitado.

### Requisitos

1. Añade un bloque `cors_configuration` en `aws_apigatewayv2_api` que permita:
   - Headers: `Content-Type`
   - Métodos: `GET`, `POST`, `OPTIONS`
   - Orígenes: `*` (en producción se restringiría a dominios concretos)
   - `max_age = 300` (segundos que el navegador cachea la respuesta preflight)
2. Añade un bloque `default_route_settings` en `aws_apigatewayv2_stage` con:
   - `throttling_burst_limit = 100` (peticiones simultáneas máximas)
   - `throttling_rate_limit  = 50`  (peticiones por segundo sostenidas)

### Criterios de éxito

- Una petición `OPTIONS` a `/items` devuelve 200 con la cabecera `Access-Control-Allow-Origin: *`.
- La configuración de throttling es visible en la consola de API Gateway o con `aws apigatewayv2 get-stage`.
- Puedes explicar la diferencia entre `throttling_burst_limit` (capacidad de ráfaga) y `throttling_rate_limit` (tasa sostenida), y qué código HTTP devuelve API Gateway cuando se supera el límite.

[Ver solución →](#4-solución-de-los-retos)

---

## 3. Reto 2: Lambda Versioning y Alias

En producción, la integración de API Gateway no debería apuntar a `$LATEST` (la versión mutable y siempre actualizable de Lambda) sino a un **alias** que apunte a una versión numerada e inmutable. Esto permite hacer rollback a una versión anterior cambiando solo a qué versión apunta el alias, sin modificar la integración de API Gateway.

### Requisitos

1. Activa `publish = true` en `aws_lambda_function` para que cada despliegue genere una versión numerada inmutable.
2. Crea `aws_lambda_alias` con `name = "live"` apuntando a `aws_lambda_function.api.version` (la versión publicada más reciente).
3. Actualiza `aws_apigatewayv2_integration` para que `integration_uri` apunte al `invoke_arn` del alias.
4. Actualiza `aws_lambda_permission` para usar `qualifier = aws_lambda_alias.live.name`, de modo que el permiso se aplique sobre el alias y no sobre `$LATEST`.
5. Añade un output `function_version` con el número de versión publicada más reciente.

### Criterios de éxito

- `aws lambda list-versions-by-function` muestra al menos la versión `1` publicada.
- `aws lambda get-alias --name live` muestra que el alias apunta a esa versión.
- La API sigue respondiendo correctamente (`curl -s "$API/items"`).
- Al modificar el código y hacer `terraform apply`, se publica una nueva versión y el alias avanza automáticamente.
- Puedes explicar por qué el permiso debe usar `qualifier` y no solo `function_name`.

[Ver solución →](#4-solución-de-los-retos)

---

## 4. Solución de los Retos

> Intenta resolver los retos antes de leer esta sección.

### Solución Reto 1 — CORS y Throttling

Modifica `aws_apigatewayv2_api` y `aws_apigatewayv2_stage` en `main.tf`:

```hcl
resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project}-api"
  protocol_type = "HTTP"
  description   = "HTTP API del lab31 — con CORS y throttling"

  cors_configuration {
    allow_headers = ["Content-Type", "X-Api-Key", "Authorization"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_origins = ["*"]   # en producción: ["https://mi-app.example.com"]
    max_age       = 300
  }

  tags = local.tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  default_route_settings {
    throttling_burst_limit = 100  # capacidad de ráfaga: peticiones simultáneas máximas
    throttling_rate_limit  = 50   # tasa sostenida: peticiones por segundo
  }

  tags = local.tags
}
```

Verificación:

```bash
terraform apply

API=$(terraform output -raw api_endpoint)

# El preflight OPTIONS debe devolver 200 con cabeceras CORS
curl -s -X OPTIONS "$API/items" \
  -H "Origin: https://mi-app.example.com" \
  -H "Access-Control-Request-Method: GET" \
  -D - -o /dev/null | grep -i "access-control"
# access-control-allow-origin: *
# access-control-allow-methods: GET,POST,OPTIONS

# Verifica la configuración del stage
aws apigatewayv2 get-stage \
  --api-id "$(terraform output -raw api_id)" \
  --stage-name '$default' \
  --query 'DefaultRouteSettings.{Burst:ThrottlingBurstLimit,Rate:ThrottlingRateLimit}' \
  --output table
```

Cuando se supera `throttling_rate_limit`, API Gateway devuelve `429 Too Many Requests` sin invocar Lambda — lo que protege la función de picos de coste.

### Solución Reto 2 — Lambda Versioning y Alias

Añade `publish = true` a `aws_lambda_function` y los nuevos recursos en `main.tf`:

```hcl
resource "aws_lambda_function" "api" {
  function_name    = "${var.project}-function"
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256
  runtime          = var.runtime
  handler          = "handler.lambda_handler"
  role             = aws_iam_role.lambda.arn
  layers           = [aws_lambda_layer_version.utils.arn]
  publish          = true   # ← publica una versión numerada en cada cambio de código

  environment {
    variables = {
      APP_ENV     = var.app_env
      APP_PROJECT = var.project
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic,
    aws_cloudwatch_log_group.lambda,
  ]

  tags = merge(local.tags, { Name = "${var.project}-function" })
}

# Alias que siempre apunta a la versión publicada más reciente
resource "aws_lambda_alias" "live" {
  name             = "live"
  description      = "Alias de producción — apunta a la última versión publicada"
  function_name    = aws_lambda_function.api.function_name
  function_version = aws_lambda_function.api.version   # número de versión publicada
}
```

Actualiza la integración para usar el `invoke_arn` del alias:

```hcl
resource "aws_apigatewayv2_integration" "lambda" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_alias.live.invoke_arn   # ← alias, no $LATEST
  payload_format_version = "2.0"
}
```

Actualiza el permiso para usar `qualifier` apuntando al alias:

```hcl
resource "aws_lambda_permission" "apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  qualifier     = aws_lambda_alias.live.name           # ← permiso sobre el alias
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
```

Añade a `outputs.tf`:

```hcl
output "function_version" {
  description = "Número de la última versión Lambda publicada"
  value       = aws_lambda_function.api.version
}
```

Verificación:

```bash
terraform apply

FUNCTION=$(terraform output -raw function_name)

# Listar versiones publicadas
aws lambda list-versions-by-function \
  --function-name "$FUNCTION" \
  --query 'Versions[*].{Version:Version,SHA:CodeSha256,Modified:LastModified}' \
  --output table

# Ver el alias y a qué versión apunta
aws lambda get-alias \
  --function-name "$FUNCTION" \
  --name live \
  --query '{Nombre:Name,Version:FunctionVersion,ARN:AliasArn}' \
  --output table

# La API sigue funcionando a través del alias
API=$(terraform output -raw api_endpoint)
curl -s "$API/items" | python3 -m json.tool

# Modificar el código y comprobar que la versión avanza
echo "# version bump" >> src/function/handler.py
terraform apply -auto-approve
aws lambda get-alias --function-name "$FUNCTION" --name live --query FunctionVersion
# "2"  (la versión anterior era "1")
```

El alias `live` avanza automáticamente porque `function_version = aws_lambda_function.api.version` es un atributo dinámico: cada vez que Terraform crea una nueva versión publicada (`publish = true`), `version` devuelve el nuevo número y el alias se actualiza en el mismo `apply`.

---

## Verificación final

```bash
# Obtener la URL de la API
API_URL=$(terraform output -raw api_url)

# Probar el endpoint raiz
curl -s "${API_URL}/"
# Esperado: {"message": "Hello from Lambda Layer!", ...}

# Probar el endpoint de health
curl -s "${API_URL}/health"
# Esperado: {"status": "ok"}

# Verificar que la Layer esta asociada a la funcion
aws lambda get-function-configuration \
  --function-name $(terraform output -raw lambda_function_name) \
  --query 'Layers[*].Arn' --output text

# Comprobar que los logs se generan en CloudWatch
aws logs describe-log-groups \
  --query 'logGroups[?contains(logGroupName,`lab31`)].logGroupName' \
  --output text
```

---

## 5. Limpieza

```bash
# Desde lab31/aws/
terraform destroy
```

El `destroy` elimina la función Lambda, todas las versiones de la Layer, la HTTP API, los grupos de logs y los roles IAM. Los archivos ZIP generados localmente se pueden borrar manualmente:

```bash
rm -f aws/layer.zip aws/function.zip
```

> El bucket S3 de estado (`terraform-state-labs-<ACCOUNT_ID>`) no se destruye: se reutiliza en otros laboratorios.

---

## 6. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

LocalStack Community soporta Lambda, IAM y CloudWatch Logs. **API Gateway v2 no está disponible en Community** (requiere licencia Pro) y se ha eliminado de `localstack/main.tf`. El código Python se ejecuta realmente invocando la función con `awslocal lambda invoke`, lo que permite verificar `archive_file`, `source_code_hash` y la Layer sin necesitar AWS real.

---

## 7. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| `archive_file` | Genera ZIP localmente (sin llamadas AWS) | Idéntico — operación local, sin diferencias |
| `source_code_hash` | Detecta cambios y fuerza redeploy | Detecta cambios y fuerza redeploy |
| Lambda Layer | Versión numerada inmutable; montada en `/opt/python` | El recurso se crea y versiona, pero Community no la monta en el entorno de ejecución; `utils.py` se bundlea en la función como workaround |
| Lambda Function | Ejecuta Python 3.12 real en infraestructura AWS | Ejecuta Python 3.12 real en contenedor local |
| Cold start | Latencia real (100-500 ms) | Latencia mínima (entorno local) |
| API Gateway v2 HTTP API | URL HTTPS pública, stage `$default` funcional | **No disponible** en Community (requiere Pro) |
| `auto_deploy = true` | Publica cambios de rutas automáticamente | No desplegado |
| `aws_lambda_permission` | Control de acceso real; sin permiso → 403 | No desplegado (depende de APIGW) |
| CloudWatch Logs | Logs reales con `aws logs tail` | Logs registrados; `awslocal logs tail` limitado |
| Payload format 2.0 | Evento con `requestContext.http.method`, `rawPath`… | Funciona al invocar Lambda directamente |
| Coste aproximado | ~$0 (capa gratuita: 1 M invocaciones/mes, 400 000 GB-s) | Sin coste |

---

## Buenas prácticas aplicadas

- **Usa siempre `source_code_hash`.** Sin él, Terraform puede no detectar cambios en el contenido del ZIP si el archivo se regenera con el mismo nombre. `output_base64sha256` de `archive_file` garantiza que cualquier modificación en el código fuente se refleja en el estado y dispara el redeploy.
- **Crea el log group antes que la función.** Sin `depends_on = [aws_cloudwatch_log_group.lambda]`, Lambda crea el grupo automáticamente durante el primer cold start pero sin `retention_in_days`, acumulando logs indefinidamente y generando coste de almacenamiento no planificado.
- **Separa Layer y función en `archive_file` independientes.** Un cambio en `utils.py` solo redespliega la Layer; un cambio en `handler.py` solo redespliega la función. Si usaras un único ZIP para todo, cualquier cambio menor reemplazaría el artefacto completo.
- **Usa `source_arn` en `aws_lambda_permission`, nunca lo omitas.** Sin `source_arn`, cualquier API Gateway de la cuenta podría invocar tu función Lambda. Acotar a `${execution_arn}/*/*` limita el permiso a una API concreta — principio de mínimo privilegio.
- **Prefiere `payload_format_version = "2.0"` para nuevos proyectos.** El formato 2.0 tiene una estructura de evento más limpia (`requestContext.http.method`, `rawPath`, `pathParameters` directamente accesibles) y es el recomendado para HTTP API. El formato 1.0 existe por compatibilidad con REST API v1.
- **Usa `publish = true` con alias en producción.** Apuntar la integración a `$LATEST` significa que cualquier `terraform apply` que actualice el código es inmediatamente visible en producción. Con `publish = true` y un alias, tienes la posibilidad de hacer rollback en segundos cambiando `function_version` del alias a una versión anterior.
- **Mantén el stage `$default` con `auto_deploy = true` solo en desarrollo.** En producción, usa `auto_deploy = false` y gestiona `aws_apigatewayv2_deployment` explícitamente para tener control sobre cuándo se publican los cambios de rutas e integraciones.

---

## Recursos

- [data source archive_file — Terraform Registry](https://registry.terraform.io/providers/hashicorp/archive/latest/docs/data-sources/file)
- [aws_lambda_function — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_function)
- [aws_lambda_layer_version — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_layer_version)
- [aws_lambda_alias — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_alias)
- [aws_lambda_permission — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lambda_permission)
- [aws_apigatewayv2_api — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_api)
- [aws_apigatewayv2_stage — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_stage)
- [aws_apigatewayv2_integration — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_integration)
- [aws_apigatewayv2_route — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/apigatewayv2_route)
- [Lambda Layers — AWS Docs](https://docs.aws.amazon.com/lambda/latest/dg/chapter-layers.html)
- [Working with Lambda functions — AWS Docs](https://docs.aws.amazon.com/lambda/latest/dg/lambda-functions.html)
- [HTTP API con integración Lambda proxy — AWS Docs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-lambda.html)
- [Payload format 2.0 — AWS Docs](https://docs.aws.amazon.com/apigateway/latest/developerguide/http-api-develop-integrations-lambda.html#http-api-develop-integrations-lambda.proxy-format)
- [Lambda versioning — AWS Docs](https://docs.aws.amazon.com/lambda/latest/dg/configuration-versions.html)
- [Lambda aliases — AWS Docs](https://docs.aws.amazon.com/lambda/latest/dg/configuration-aliases.html)
