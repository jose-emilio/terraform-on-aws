# Laboratorio 29: Microservicios con ECS Fargate y Malla de Servicios

[← Módulo 7 — Cómputo en AWS con Terraform](../../modulos/modulo-07/README.md)


## Visión general

En este laboratorio desplegarás dos microservicios dockerizados sin gestionar servidores físicos: un servicio **Web** que sirve una interfaz HTML y un microservicio **API** que responde JSON. El servicio Web llama al API internamente usando Service Connect, adjuntando una clave de API como header `X-API-Key` que el microservicio API valida en cada petición mediante un bloque `map{}` de nginx generado dinámicamente en tiempo de arranque. Combinarás un repositorio ECR con etiquetas inmutables y política de limpieza, dos task definitions definidas con `jsonencode()`, la inyección del secreto compartido desde SSM Parameter Store, Service Connect para la comunicación interna Web→API y el Deployment Circuit Breaker para revertir automáticamente despliegues defectuosos.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Crear un repositorio ECR con `image_tag_mutability = "IMMUTABLE"` y definir una política de limpieza con `aws_ecr_lifecycle_policy` para mantener solo las 10 imágenes más recientes
- Usar `jsonencode()` en HCL para definir los `container_definitions` de una task definition de Fargate, asignando límites de CPU y memoria
- Almacenar una clave de API en SSM Parameter Store como `SecureString` y referenciarla en la task definition para que ECS la inyecte como variable de entorno sin exponerla en el estado
- Configurar dos servicios ECS con Service Connect: el servicio Web como cliente que llama a `http://api:8080` y el microservicio API como servidor que se registra con ese nombre DNS privado
- Implementar autenticación basada en header entre microservicios: el servicio Web adjunta `X-API-Key` en cada `proxy_pass` al API; el microservicio API usa un bloque `map{}` de nginx generado en tiempo de arranque para validar el header sin exponer el secreto en configuración estática
- Habilitar el Deployment Circuit Breaker con `rollback = true` para revertir automáticamente si los nuevos contenedores fallan el health check durante un despliegue

## Requisitos Previos

- Terraform >= 1.5 instalado
- Laboratorio 2 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir
- Perfil AWS con permisos sobre VPC, ECR, ECS, SSM, IAM y CloudWatch Logs
- Docker instalado (para hacer push de imágenes a ECR en la sección opcional)
- LocalStack en ejecución (para la sección de LocalStack)

---

## Conceptos Clave

### Ciclo de Vida de Imágenes en ECR

`aws_ecr_repository` con `image_tag_mutability = "IMMUTABLE"` rechaza cualquier intento de sobreescribir una etiqueta existente. Si `api:v1.0.0` ya está en el repositorio, un segundo `docker push` con la misma etiqueta falla inmediatamente, garantizando que cada etiqueta corresponde a exactamente un artefacto.

```hcl
resource "aws_ecr_repository" "app" {
  name                 = "lab29/api"
  image_tag_mutability = "IMMUTABLE"
}
```

La política de limpieza controla el coste de almacenamiento eliminando imágenes antiguas automáticamente. La regla `imageCountMoreThan` elimina las imágenes más antiguas cuando el total supera el umbral definido:

```hcl
resource "aws_ecr_lifecycle_policy" "app" {
  repository = aws_ecr_repository.app.name

  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "Mantener solo las 10 imagenes mas recientes"
      selection = {
        tagStatus   = "any"
        countType   = "imageCountMoreThan"
        countNumber = 10
      }
      action = { type = "expire" }
    }]
  })
}
```

### Definición de Tareas con jsonencode()

`jsonencode()` convierte una estructura HCL nativa a JSON válido para la API de ECS. Frente a un heredoc (`<<EOF`), tiene dos ventajas clave: Terraform valida los tipos en tiempo de `plan` (no en `apply`) y los valores de otros recursos se pueden interpolar directamente sin manipulación de cadenas.

```hcl
resource "aws_ecs_task_definition" "api" {
  family                   = "lab29-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"   # 0.25 vCPU
  memory                   = "512"   # 0.5 GB

  container_definitions = jsonencode([{
    name  = "api"
    image = var.container_image
    cpu   = 256
    memory = 512
    # ...
  }])
}
```

En Fargate, `cpu` y `memory` se declaran a nivel de tarea (requerido) y opcionalmente a nivel de contenedor. Las combinaciones válidas están documentadas en la referencia de AWS ECS.

### Inyección de Secretos desde SSM

Almacenar secretos en código fuente o variables de entorno en texto plano es un riesgo de seguridad. El flujo correcto con ECS es:

1. El secreto se almacena en SSM Parameter Store como `SecureString` (cifrado con KMS)
2. La task definition referencia el ARN del parámetro en el bloque `secrets`
3. El agente ECS descifra el valor con KMS **antes** de lanzar el contenedor
4. El contenedor recibe el secreto como variable de entorno ya descifrada

```hcl
resource "aws_ssm_parameter" "api_key" {
  name  = "/lab29/api-key"
  type  = "SecureString"   # KMS cifra el valor en reposo con la clave aws/ssm
  value = var.api_key
}
```

En la task definition:

```hcl
secrets = [{
  name      = "API_KEY"          # Nombre de la variable de entorno en el contenedor
  valueFrom = aws_ssm_parameter.api_key.arn  # ARN del parámetro SSM
}]
```

El rol de ejecución (`execution_role_arn`) necesita los permisos `ssm:GetParameters` y `kms:Decrypt` sobre el parámetro y la clave KMS correspondiente.

En este laboratorio el mismo parámetro SSM se inyecta en **ambos** microservicios, pero cada uno lo usa de forma diferente:

| Microservicio | Uso de `API_KEY` |
|---|---|
| **Web** | `startup.sh` lo incrusta en la config de nginx como `proxy_set_header X-API-Key "$API_KEY"` → se envía en cada petición al API |
| **API** | `startup-api.sh` lo incrusta en el bloque `map{}` de nginx → valida el header `X-API-Key` en cada petición entrante |

El secreto **nunca aparece en texto plano** en archivos de configuración estáticos ni en el estado de Terraform: el shell lo expande en tiempo de arranque del contenedor y nginx lo recibe ya como cadena literal.

### Malla de Servicios con Service Connect

Service Connect es la solución nativa de ECS para la comunicación entre microservicios. A diferencia de un ALB (que opera en capa 7 y tiene coste por hora), Service Connect usa un proxy Envoy que ECS inyecta automáticamente como sidecar en cada tarea.

| Característica | Service Connect | ALB interno |
|---|---|---|
| Coste | Sin cargo adicional | $0.008/hora + datos |
| Descubrimiento | DNS privado automático | Requiere target group |
| Balanceo | Envoy (L7) por tarea | ALB entre todas las tareas |
| Visibilidad | Métricas Envoy en CloudWatch | Métricas ALB en CloudWatch |
| Uso típico | Comunicación este-oeste (microservicio→microservicio) | Tráfico norte-sur (usuario→API) |

Para configurar un servicio como **servidor** (accesible por nombre DNS), se añade el bloque `service` dentro de `service_connect_configuration`. Para un servicio que solo **consume** otros servicios (cliente puro), basta con `enabled = true` y `namespace` sin bloque `service`.

En este laboratorio, el microservicio **API** se registra como servidor en el puerto 8080:

```hcl
service_connect_configuration {
  enabled   = true
  namespace = aws_service_discovery_http_namespace.main.arn

  service {
    port_name      = "api-http"    # Debe coincidir con portMappings[].name
    discovery_name = "api"         # DNS privado: http://api:8080

    client_alias {
      port     = 8080
      dns_name = "api"
    }
  }
}
```

El servicio **Web** también declara el bloque `service` (se registra como `web:80`) y actúa a la vez como **cliente** del API — su nginx hace `proxy_pass http://api:8080/` para enrutar las peticiones del navegador al microservicio API a través del proxy Envoy, sin exponer el puerto 8080 al exterior.

El campo `port_name` debe coincidir exactamente con el campo `name` del `portMappings` en el `container_definitions`.

### Deployment Circuit Breaker

El Circuit Breaker de ECS monitoriza el estado de las nuevas tareas durante un despliegue. Si el porcentaje de fallos supera un umbral (tareas que no pasan al estado `RUNNING` o que fallan el health check), ECS considera el despliegue fallido.

Con `rollback = true`, ECS activa automáticamente un nuevo despliegue usando la revisión anterior de la task definition, restaurando el servicio al último estado conocido bueno sin intervención manual.

```hcl
deployment_circuit_breaker {
  enable   = true
  rollback = true
}
```

Sin el Circuit Breaker, un despliegue con un contenedor defectuoso (imagen incorrecta, error de configuración, secreto inválido) dejaría el servicio parcialmente degradado hasta que alguien interviniera manualmente.

---

## Estructura del proyecto

```
lab29/
├── aws/
│   ├── aws.s3.tfbackend   # Parámetros del backend S3 (sin bucket)
│   ├── providers.tf       # Backend S3, Terraform >= 1.5, provider AWS
│   ├── variables.tf       # region, project, vpc_cidr, desired_count, container_image, api_key
│   ├── main.tf            # VPC, ECR, SSM, IAM, ECS Cluster, 2 Task Definitions, 2 Servicios ECS
│   ├── outputs.tf         # ECR URL, cluster, web/api service, SSM, namespace, logs
│   ├── startup.sh         # Script de arranque del servicio Web: genera HTML + proxy_pass nginx
│   └── startup-api.sh     # Script de arranque del microservicio API: genera JSON + nginx:8080
└── localstack/
    ├── providers.tf       # Endpoints apuntando a LocalStack
    ├── variables.tf       # Mismas variables, valores por defecto para entorno local
    ├── main.tf            # Idéntico a aws/main.tf
    ├── outputs.tf
    ├── startup.sh         # Copia de aws/startup.sh
    └── startup-api.sh     # Copia de aws/startup-api.sh
```

---

## 1. Despliegue en AWS Real

### 1.1 Arquitectura

```
Navegador
    │  GET /          → HTML page (tarea Web)
    │  GET /api-data  → nginx proxy_pass → http://api:8080 (Service Connect)
    ▼
┌──────────────────────────────────────────────────────────────┐
│  VPC: 10.0.0.0/16  (subredes públicas, assign_public_ip=true)│
│                                                              │
│  Servicio Web  (lab29-web, puerto 80)                        │
│  ┌─────────────────────────┐  ┌──────────────────────────┐   │
│  │ Tarea Web AZ-a          │  │ Tarea Web AZ-b           │   │
│  │  nginx:80 + Envoy proxy │  │  nginx:80 + Envoy proxy  │   │
│  │  startup.sh             │  │  startup.sh              │   │
│  └────────────┬────────────┘  └──────────┬───────────────┘   │
│               │ proxy_pass http://api:8080 + X-API-Key header│
│               ▼                                              │
│  Servicio API  (lab29-api, puerto 8080 — solo interno)       │
│  ┌─────────────────────────┐  ┌──────────────────────────┐   │
│  │ Tarea API AZ-a          │  │ Tarea API AZ-b           │   │
│  │  nginx:8080 + Envoy     │  │  nginx:8080 + Envoy      │   │
│  │  startup-api.sh → JSON  │  │  startup-api.sh → JSON   │   │
│  └─────────────────────────┘  └──────────────────────────┘   │
│                                                              │
│  Cloud Map Namespace: lab29                                  │
│  ├── DNS: web → IPs tareas Web  (puerto 80)                  │
│  └── DNS: api → IPs tareas API  (puerto 8080)                │
└──────────────────────────────────────────────────────────────┘

SSM Parameter Store: /lab29/api-key (SecureString)
  ├── Web: proxy_set_header X-API-Key "$API_KEY"  (envía la clave al API)
  └── API: map $http_x_api_key $auth_valid { "$API_KEY" 1 }  (valida la clave)

ECR: lab29/api (IMMUTABLE)
  └── Lifecycle Policy: mantener ≤ 10 imágenes
```

### 1.2 Código Terraform

**`aws/main.tf`** — Fragmentos clave:

El laboratorio despliega **dos task definitions** que comparten la misma imagen base (`nginx:alpine`), el mismo secreto SSM y los mismos roles IAM, pero ejecutan scripts de arranque distintos y escuchan en puertos diferentes. El campo `command` pasa el contenido del script de arranque al contenedor mediante `file()`:

```hcl
# Task definition del servicio Web (startup.sh: HTML + proxy_pass nginx en :80)
resource "aws_ecs_task_definition" "web" {
  family = "${var.project}-web"
  # ...
  container_definitions = jsonencode([{
    name    = "web"
    command = ["/bin/sh", "-c", file("${path.module}/startup.sh")]

    portMappings = [{
      name          = "web-http"   # Referenciado por service_connect_configuration
      containerPort = 80
      appProtocol   = "http"
    }]
    # ...
  }])
}

# Task definition del microservicio API (startup-api.sh: JSON en :8080)
resource "aws_ecs_task_definition" "api" {
  family = "${var.project}-api"
  # ...
  container_definitions = jsonencode([{
    name    = "api"
    command = ["/bin/sh", "-c", file("${path.module}/startup-api.sh")]

    portMappings = [{
      name          = "api-http"   # Referenciado por service_connect_configuration
      containerPort = 8080
      appProtocol   = "http"
    }]
    # ...
  }])
}
```

El secreto SSM se inyecta en **ambos** contenedores usando el mismo ARN. Un único parámetro `SecureString` puede ser referenciado por múltiples task definitions; el rol de ejecución compartido tiene el permiso `ssm:GetParameters` necesario:

```hcl
secrets = [{
  name      = "API_KEY"
  valueFrom = aws_ssm_parameter.api_key.arn
}]
```

El rol de ejecución necesita un permiso adicional explícito para leer el `SecureString`. La política gestionada `AmazonECSTaskExecutionRolePolicy` no incluye acceso a parámetros SSM arbitrarios:

```hcl
resource "aws_iam_role_policy" "ssm_read" {
  name = "${var.project}-ssm-read"
  role = aws_iam_role.execution.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ssm:GetParameters", "kms:Decrypt"]
      Resource = [
        aws_ssm_parameter.api_key.arn,
        "arn:aws:kms:${var.region}:${data.aws_caller_identity.current.account_id}:alias/aws/ssm"
      ]
    }]
  })
}
```

**Generación dinámica de configuración nginx con autenticación por header**

El microservicio API valida la clave en cada petición usando el bloque `map{}` de nginx, cuyo valor real se incrusta en tiempo de arranque por el shell (`startup-api.sh`):

```sh
# En startup-api.sh: el shell expande $API_KEY → nginx recibe el valor literal
cat > /etc/nginx/conf.d/default.conf << CONF
map \$http_x_api_key \$auth_valid {
    default    0;
    "$API_KEY" 1;         # $API_KEY se expande aquí por el shell
}

server {
    listen 8080;

    location / {
        if (\$auth_valid = 0) {
            return 401 '{"error":"Unauthorized"}';
        }
        root /usr/share/nginx/html;
        try_files /index.json =404;
    }

    # /health no requiere autenticación → necesario para el Circuit Breaker
    location /health {
        return 200 '{"status":"ok","service":"api"}';
    }
}
CONF
```

El servicio Web incrusta la misma clave en el `proxy_pass` de `startup.sh`:

```sh
# En startup.sh: nginx adjunta X-API-Key en cada petición al microservicio API
location /api-data {
    proxy_pass         http://api:8080/;
    proxy_set_header   X-API-Key "$API_KEY";   # $API_KEY expande el shell
    proxy_read_timeout 5s;
}
```

> **Por qué `map{}` y no `if` directamente en `location`**: `map{}` debe estar en el contexto `http{}`, que es donde nginx:alpine incluye los archivos de `/etc/nginx/conf.d/`. Evalúa la condición una sola vez por petición y es más eficiente que múltiples bloques `if`.

El security group permite puerto 80 desde Internet (para el servicio Web) y puertos 80 y 8080 entre tareas del mismo grupo (`self = true`) para que Service Connect pueda enrutar el tráfico interno:

```hcl
resource "aws_security_group" "ecs" {
  # Puerto 80 desde Internet → servicio Web accesible por el navegador
  ingress { from_port = 80,   cidr_blocks = ["0.0.0.0/0"] }
  # Tráfico interno entre tareas (Service Connect)
  ingress { from_port = 80,   self = true }
  ingress { from_port = 8080, self = true }
  ingress { from_port = 15000, to_port = 15010, self = true }  # Envoy
}
```

### 1.3 Inicialización y despliegue

```bash
export BUCKET="terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"

# Desde lab29/aws/
terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform plan
terraform apply
```

Al finalizar, los outputs mostrarán:

```
api_log_group             = "/ecs/lab29/api"
api_service_name          = "lab29-api"
api_task_definition_arn   = "arn:aws:ecs:us-east-1:...:task-definition/lab29-api:1"
docker_login_cmd          = "aws ecr get-login-password --region us-east-1 | docker login ..."
ecr_repository_url        = "123456789.dkr.ecr.us-east-1.amazonaws.com/lab29/api"
ecs_cluster_name          = "lab29-cluster"
service_connect_namespace = "lab29"
ssm_parameter_name        = "/lab29/api-key"
web_log_group             = "/ecs/lab29/web"
web_service_name          = "lab29-web"
web_task_definition_arn   = "arn:aws:ecs:us-east-1:...:task-definition/lab29-web:1"
```

### 1.4 Verificar los servicios y el flujo Web→API

**Paso 1** — Comprueba que ambos servicios están estables:

```bash
aws ecs describe-services \
  --cluster lab29-cluster \
  --services lab29-web lab29-api \
  --query 'services[].{Nombre:serviceName,Estado:status,Deseadas:desiredCount,Corriendo:runningCount}' \
  --output table
```

Espera hasta que `runningCount = desiredCount` en ambos servicios (1-2 minutos la primera vez).

**Paso 2** — Obtén la IP pública de una tarea Web y abre la página en el navegador:

```bash
WEB_TASK=$(aws ecs list-tasks \
  --cluster lab29-cluster --service-name lab29-web \
  --query 'taskArns[0]' --output text)

# En Fargate (awsvpc), todos los contenedores comparten la misma ENI e IP
PRIVATE_IP=$(aws ecs describe-tasks \
  --cluster lab29-cluster --tasks "$WEB_TASK" \
  --query 'tasks[0].containers[0].networkInterfaces[0].privateIpv4Address' \
  --output text)

# La IP pública se obtiene desde EC2 filtrando por IP privada
WEB_IP=$(aws ec2 describe-network-interfaces \
  --filters "Name=private-ip-address,Values=$PRIVATE_IP" \
  --query 'NetworkInterfaces[0].Association.PublicIp' \
  --output text)

echo "http://$WEB_IP/"
```

Abre la URL en el navegador. Verás la página con dos tarjetas:
- **Tarjeta izquierda (cyan)** — datos de la tarea Web: Task ID, Cluster, Family/Revision, Región, API Key enmascarada
- **Tarjeta derecha (morado)** — datos del microservicio API cargados vía `fetch('/api-data')`, actualizándose cada 15 segundos

> Recarga la página varias veces. El Task ID de la tarjeta API puede cambiar: Service Connect hace round-robin entre las 2 tareas del servicio API, demostrando el balanceo interno sin ALB.

**Paso 3** — Verifica el flujo Service Connect desde el interior del contenedor Web:

```bash
aws ecs execute-command \
  --cluster lab29-cluster \
  --task "$WEB_TASK" \
  --container web \
  --interactive \
  --command "/bin/sh"
```

Dentro del contenedor:

```sh
# Comprueba que API_KEY fue inyectada desde SSM
echo $API_KEY

# Sin header → el API devuelve 401 Unauthorized
wget -qO- http://api:8080/ 2>&1
# wget: server returned error: HTTP/1.1 401 Unauthorized

# Con header correcto → respuesta JSON con metadatos de la tarea API
wget -qO- --header "X-API-Key: $API_KEY" http://api:8080/
# {"service":"api","task_id":"...","cluster":"lab29-cluster",...}

# /health siempre responde 200, sin autenticación (necesario para Circuit Breaker)
wget -qO- http://api:8080/health
# {"status":"ok","service":"api"}

exit
```

> Si `execute-command` falla con "The execute command failed", asegúrate de que el servicio tiene `enable_execute_command = true` y que el rol de tarea tiene los permisos `ssmmessages:*`. Puede tardar 1-2 minutos después del `apply`.

**Paso 4** — Verifica los logs de ambos servicios y del proxy Envoy:

```bash
# Logs del servicio Web
aws logs tail /ecs/lab29/web --log-stream-name-prefix web/ --follow

# Logs del microservicio API
aws logs tail /ecs/lab29/api --log-stream-name-prefix api/ --follow

# Logs del proxy Envoy del servicio Web (registra cada proxy_pass a la API)
aws logs tail /ecs/lab29/web --log-stream-name-prefix service-connect-web/ --follow
```

### 1.5 Verificar ECR y la política de limpieza

**Paso 1** — Autentica Docker contra ECR:

```bash
ECR_URL=$(terraform output -raw ecr_repository_url)
aws ecr get-login-password --region us-east-1 | \
  docker login --username AWS --password-stdin "$ECR_URL"
```

**Paso 2** — Intenta hacer push de dos imágenes **distintas** con la misma etiqueta para comprobar IMMUTABLE:

```bash
# Push de nginx:alpine como v1.0.0
docker pull nginx:alpine
docker tag nginx:alpine "$ECR_URL:v1.0.0"
docker push "$ECR_URL:v1.0.0"

# Intenta sobreescribir v1.0.0 con una imagen diferente — debe fallar
# (usar la misma imagen no genera error porque Docker omite el push al detectar digest idéntico)
docker pull nginx:stable-alpine
docker tag nginx:stable-alpine "$ECR_URL:v1.0.0"
docker push "$ECR_URL:v1.0.0"
# Error: tag invalid: The image tag 'v1.0.0' already exists in the 'lab29/api' repository
#        and cannot be overwritten because the repository is immutable.
```

**Paso 3** — Confirma la política de limpieza activa:

```bash
aws ecr get-lifecycle-policy --repository-name lab29/api \
  --query 'lifecyclePolicyText' --output text | python3 -m json.tool
```

### 1.6 Demostrar el Deployment Circuit Breaker

Provoca un despliegue fallido cambiando la imagen a una que no existe para observar el rollback automático.

**Paso 1** — Despliega una imagen inexistente:

```bash
terraform apply -var="container_image=nginx:esta-etiqueta-no-existe-abc123"
```

Terraform registrará el cambio en la task definition y ECS intentará lanzar las nuevas tareas.

> **Tiempo hasta activación**: el Circuit Breaker necesita al menos **3 tareas fallidas** (hasta un máximo de 10) con un 50 % de tasa de fallo. Con una imagen inexistente (`ImagePullBackOff`), cada tarea falla en segundos, por lo que el breaker se activa en **3-5 minutos**. Con fallos por health check timeout el proceso puede tardar hasta 15 minutos.

**Paso 2** — Monitoriza ambos servicios en otra terminal (el Circuit Breaker afecta a los dos):

```bash
watch -n 10 "aws ecs describe-services \
  --cluster lab29-cluster \
  --services lab29-web lab29-api \
  --query 'services[].{Nombre:serviceName,Deployments:length(deployments),Corriendo:runningCount,Fallidas:deployments[0].failedTasks}' \
  --output table"
```

**Paso 3** — Comprueba el estado del deployment y los eventos:

```bash
# Estado del deployment — cuando el Circuit Breaker dispara, rolloutState = FAILED
aws ecs describe-services \
  --cluster lab29-cluster \
  --services lab29-web \
  --query 'services[0].deployments[*].{ID:id,Estado:rolloutState,Corriendo:runningCount,Fallidas:failedTasks}' \
  --output table

# Eventos recientes (los más recientes primero)
aws ecs describe-services \
  --cluster lab29-cluster \
  --services lab29-web \
  --query 'services[0].events[:10].{Tiempo:createdAt,Mensaje:message}' \
  --output table
```

> El Circuit Breaker necesita **al menos 3 tareas fallidas** con una tasa de fallo ≥ 50 %. Con `CannotPullContainerError` (imagen inexistente) cada intento falla en segundos, pero ECS introduce esperas entre reintentos — espera **8-12 minutos** hasta que `rolloutState` cambie a `FAILED`.

Cuando el Circuit Breaker dispara verás en los eventos (orden cronológico inverso):

```
(service lab29-web) has reached a steady state.
(service lab29-web) (deployment ecs-svc/AAA) deployment completed.
(service lab29-web) rolling back to deployment ecs-svc/AAA.
(service lab29-web) (deployment ecs-svc/BBB) deployment failed: tasks failed to start.
```

`BBB` es el deployment fallido (imagen inexistente) y `AAA` es el deployment anterior bueno al que ECS revierte automáticamente.

> El rollback es automático — no es necesario hacer nada. Sin embargo, el estado de Terraform ha quedado desincronizado (Terraform cree que la imagen es `nginx:esta-etiqueta-no-existe-abc123`). Ejecuta `terraform apply` sin `-var` para reconciliar el estado con la configuración real:
>
> ```bash
> terraform apply
> ```

---

> **Antes de comenzar los retos**, asegúrate de que todos los cambios de `main.tf` están aplicados y el servicio tiene `runningCount = desiredCount`. Si hay un despliegue en curso, espera a que complete.

## 2. Reto 1: Microservicio Worker como Cliente Puro de Service Connect

Ya existen dos servicios: `web` (servidor en puerto 80) y `api` (servidor en puerto 8080). Añade un tercer microservicio `worker` que actúe como **cliente puro** de Service Connect: consume el endpoint `http://api:8080` sin necesitar registrar un nombre DNS propio, lo que demuestra la diferencia entre servidor y cliente en la malla de servicios.

### Requisitos

1. Crea un archivo `worker.tf` en `aws/` con los siguientes recursos:
   - `aws_cloudwatch_log_group` para `/ecs/lab29/worker`
   - `aws_ecs_task_definition` para la tarea worker (misma imagen, cpu=256, memory=512)
   - `aws_ecs_service` para el servicio worker con `desired_count = 1`
2. El servicio worker debe tener Service Connect **activado como cliente puro** (`enabled = true` y `namespace`, **sin bloque `service {}`** — no necesita nombre DNS propio).
3. Añade la variable de entorno `API_URL = "http://api:8080"` en el contenedor para documentar la dependencia.
4. Usa el mismo Security Group (`aws_security_group.ecs`) y subredes públicas que los demás servicios.
5. Añade el output `worker_service_name` en `outputs.tf`.

### Criterios de éxito

- `terraform plan` no modifica los servicios `web` ni `api` existentes — solo añade los recursos del worker.
- `aws ecs describe-services --cluster lab29-cluster --services lab29-worker` muestra el servicio activo.
- Desde el contenedor worker (`execute-command`), `wget -qO- http://api:8080/health` devuelve `{"status":"ok"}`.
- Puedes explicar por qué el worker no necesita el bloque `service {}` dentro de `service_connect_configuration`.

[Ver solución →](#4-solución-de-los-retos)

---

## 3. Reto 2: ALB para Acceso Externo con Subredes Privadas

Service Connect es excelente para comunicación **este-oeste** (entre microservicios), pero los usuarios externos necesitan acceder al servicio a través de Internet. La arquitectura de producción correcta coloca el ALB en subredes públicas y las tareas ECS en subredes **privadas**: las tareas no tienen IP pública y solo son alcanzables desde el ALB, no desde Internet directamente.

```
Internet → ALB (subred pública) → Tareas Web (subred privada) → API (subred privada)
                                        ↑
                               NAT Gateway (salida a Internet para pull de imágenes)
```

### Requisitos

1. Crea un archivo `alb.tf` en `aws/` con los siguientes recursos:
   - Subredes privadas (una por AZ) con su tabla de rutas apuntando al NAT Gateway
   - `aws_eip` + `aws_nat_gateway` en una de las subredes públicas existentes
   - `aws_security_group` para el ALB (acepta HTTP en el puerto 80 desde `0.0.0.0/0`)
   - `aws_lb` de tipo `application` en las subredes **públicas**
   - `aws_lb_target_group` con `target_type = "ip"` y health check al puerto 80
   - `aws_lb_listener` en el puerto 80 que reenvíe al target group
2. Modifica `aws_ecs_service.web` en `main.tf`:
   - Cambia `subnets` a las nuevas subredes privadas
   - Cambia `assign_public_ip` a `false`
   - Añade el bloque `load_balancer`
3. Actualiza el security group `ecs`: reemplaza la regla de puerto 80 desde `0.0.0.0/0` por una regla que solo admita tráfico desde el security group del ALB (`security_groups = [aws_security_group.alb.id]`).
4. Añade a `outputs.tf` el output `alb_url` con la URL pública del ALB.

### Criterios de éxito

- `terraform apply` completa sin errores.
- `curl $(terraform output -raw alb_url)` devuelve la página HTML con las dos tarjetas.
- La tarjeta de la API sigue funcionando (el ALB enruta a la tarea Web que internamente llama al API via Service Connect).
- Las tareas Web **no tienen IP pública** (`assign_public_ip = false`): solo son accesibles a través del ALB.
- Puedes explicar por qué `target_type = "ip"` es obligatorio para Fargate (y no `instance`) y por qué el NAT Gateway es necesario en subredes privadas.

[Ver solución →](#4-solución-de-los-retos)

---

## 4. Solución de los Retos

> Intenta resolver los retos antes de leer esta sección.

### Solución Reto 1 — Microservicio Worker como Cliente Puro de Service Connect

Crea el archivo `aws/worker.tf`:

```hcl
resource "aws_cloudwatch_log_group" "worker" {
  name              = "/ecs/${var.project}/worker"
  retention_in_days = 7
  tags              = local.tags
}

resource "aws_ecs_task_definition" "worker" {
  family                   = "${var.project}-worker"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = "256"
  memory                   = "512"

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  container_definitions = jsonencode([{
    name      = "worker"
    image     = var.container_image
    essential = true
    cpu       = 256
    memory    = 512

    # El worker no expone puertos propios; solo consume el servicio "api".
    # No se declaran portMappings porque Service Connect no necesita registrarlo.
    environment = [
      { name = "APP_ENV",  value = "production" },
      # URL interna al microservicio API via Service Connect:
      { name = "API_URL",  value = "http://api:8080" }
    ]

    secrets = [{
      name      = "API_KEY"
      valueFrom = aws_ssm_parameter.api_key.arn
    }]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.worker.name
        "awslogs-region"        = var.region
        "awslogs-stream-prefix" = "worker"
      }
    }
  }])

  tags = merge(local.tags, { Name = "${var.project}-worker-task-def" })
}

resource "aws_ecs_service" "worker" {
  name            = "${var.project}-worker"
  cluster         = aws_ecs_cluster.main.id
  task_definition = aws_ecs_task_definition.worker.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  enable_execute_command = true

  network_configuration {
    subnets          = aws_subnet.public[*].id
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = true
  }

  # Cliente Service Connect: solo necesita enabled = true y el namespace.
  # Sin bloque service {}: este microservicio NO se registra con nombre DNS propio.
  # ECS aún inyecta el proxy Envoy para que el worker pueda RESOLVER "api:80".
  service_connect_configuration {
    enabled   = true
    namespace = aws_service_discovery_http_namespace.main.arn
  }

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }

  deployment_maximum_percent         = 200
  deployment_minimum_healthy_percent = 100

  depends_on = [
    aws_iam_role_policy_attachment.execution_basic,
    aws_iam_role_policy.ssm_read,
  ]

  tags = merge(local.tags, { Name = "${var.project}-worker-service" })
}
```

Añade a `outputs.tf`:

```hcl
output "worker_service_name" {
  description = "Nombre del servicio ECS worker"
  value       = aws_ecs_service.worker.name
}
```

El worker no incluye el bloque `service {}` porque no necesita ser **descubierto** por nadie — solo necesita **descubrir** al servicio `api`. El proxy Envoy inyectado por ECS resuelve `api:8080` consultando el namespace Cloud Map sin necesidad de declararlo explícitamente.

**Verificación del microservicio worker**

**Paso 1** — Comprueba que el servicio arrancó correctamente:

```bash
aws ecs describe-services \
  --cluster lab29-cluster \
  --services lab29-worker \
  --query 'services[0].{Estado:status,Deseadas:desiredCount,Corriendo:runningCount,Deployment:deployments[0].rolloutState}' \
  --output table
```

Espera hasta que `runningCount = 1` y `rolloutState = COMPLETED`.

**Paso 2** — Obtén el ARN de la tarea worker y abre una shell interactiva:

```bash
WORKER_TASK=$(aws ecs list-tasks \
  --cluster lab29-cluster --service-name lab29-worker \
  --query 'taskArns[0]' --output text)

aws ecs execute-command \
  --cluster lab29-cluster \
  --task "$WORKER_TASK" \
  --container worker \
  --interactive \
  --command "/bin/sh"
```

**Paso 3** — Desde dentro del contenedor, prueba la conectividad Service Connect:

```sh
# /health no requiere autenticación — verifica que Service Connect resuelve "api"
wget -qO- http://api:8080/health
# {"status":"ok","service":"api"}

# GET / requiere X-API-Key — sin header devuelve 401
wget -qO- http://api:8080/ 2>&1
# wget: server returned error: HTTP/1.1 401 Unauthorized

# Con la clave inyectada desde SSM devuelve los metadatos de la tarea API
wget -qO- --header "X-API-Key: $API_KEY" http://api:8080/
# {"service":"api","task_id":"...","cluster":"lab29-cluster",...}

exit
```

**Paso 4** — Verifica los logs del worker:

```bash
aws logs tail /ecs/lab29/worker --log-stream-name-prefix worker/ --follow
```

### Solución Reto 2 — ALB para Acceso Externo

Crea el archivo `aws/alb.tf`:

```hcl
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Permite trafico HTTP desde Internet al ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP desde Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-alb-sg" })
}

# ── Subredes privadas ─────────────────────────────────────────────────────────
# Las tareas ECS se mueven aquí: sin IP pública, solo accesibles desde el ALB.
# Usamos los CIDRs x.x.10.x, x.x.11.x (distintos de los públicos x.x.1.x, x.x.2.x).

locals {
  private_cidrs = [for i, _ in local.azs : cidrsubnet(var.vpc_cidr, 8, i + 10)]
}

resource "aws_subnet" "private" {
  count             = length(local.azs)
  vpc_id            = aws_vpc.main.id
  cidr_block        = local.private_cidrs[count.index]
  availability_zone = local.azs[count.index]

  tags = merge(local.tags, { Name = "${var.project}-private-${local.azs[count.index]}" })
}

# ── NAT Gateway ───────────────────────────────────────────────────────────────
# Las tareas en subredes privadas necesitan salida a Internet para hacer pull
# de imágenes (Docker Hub / ECR público). El NAT Gateway vive en la subred
# pública y enruta el tráfico de salida en nombre de las tareas privadas.

resource "aws_eip" "nat" {
  domain = "vpc"
  tags   = merge(local.tags, { Name = "${var.project}-nat-eip" })
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id   # NAT Gateway en subred pública
  tags          = merge(local.tags, { Name = "${var.project}-nat" })
  depends_on    = [aws_internet_gateway.main]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = merge(local.tags, { Name = "${var.project}-private-rt" })
}

resource "aws_route_table_association" "private" {
  count          = length(aws_subnet.private)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Security Group del ALB ────────────────────────────────────────────────────

resource "aws_security_group" "alb" {
  name        = "${var.project}-alb-sg"
  description = "Permite trafico HTTP desde Internet al ALB"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP desde Internet"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(local.tags, { Name = "${var.project}-alb-sg" })
}

# ── ALB en subredes públicas ──────────────────────────────────────────────────

resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  internal           = false
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id   # ALB siempre en subred pública

  tags = merge(local.tags, { Name = "${var.project}-alb" })
}

# target_type = "ip" es OBLIGATORIO para Fargate con network_mode = "awsvpc".
# En awsvpc, cada tarea tiene su propia ENI con IP propia. El ALB se conecta
# directamente a esa IP, no a la IP de un servidor EC2 como en el modo "instance".
resource "aws_lb_target_group" "web" {
  name        = "${var.project}-web-tg"
  port        = 80
  protocol    = "HTTP"
  target_type = "ip"
  vpc_id      = aws_vpc.main.id

  health_check {
    path                = "/"
    protocol            = "HTTP"
    healthy_threshold   = 3
    unhealthy_threshold = 3
    interval            = 30
    timeout             = 5
    matcher             = "200"
  }

  tags = merge(local.tags, { Name = "${var.project}-web-tg" })
}

resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.web.arn
  }
}
```

Modifica `aws_ecs_service.web` en `main.tf` — mueve las tareas a subredes privadas y añade el ALB:

```hcl
resource "aws_ecs_service" "web" {
  # ...
  network_configuration {
    subnets          = aws_subnet.private[*].id   # ← subredes privadas
    security_groups  = [aws_security_group.ecs.id]
    assign_public_ip = false                       # ← sin IP pública
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.web.arn
    container_name   = "web"
    container_port   = 80
  }

  depends_on = [
    aws_iam_role_policy_attachment.execution_basic,
    aws_iam_role_policy.ssm_read,
    aws_nat_gateway.main,     # las tareas privadas necesitan el NAT antes de arrancar
    aws_lb_listener.http,     # el listener debe existir antes de que las tareas se registren
  ]
  # ...
}
```

Actualiza también la regla de ingreso en el security group `ecs` en `main.tf` para que el puerto 80 solo admita tráfico del ALB (no de toda Internet):

```hcl
# Reemplaza la regla: ingress { from_port = 80, cidr_blocks = ["0.0.0.0/0"] }
# por esta:
ingress {
  description     = "HTTP desde el ALB"
  from_port       = 80
  to_port         = 80
  protocol        = "tcp"
  security_groups = [aws_security_group.alb.id]
}
```

> Las tareas API y Worker permanecen en subredes públicas con `assign_public_ip = true` (necesitan internet para pull de imágenes y no tienen ALB delante). Solo el servicio Web se mueve a subredes privadas porque es el único con un ALB como punto de entrada.

Añade a `outputs.tf`:

```hcl
output "alb_url" {
  description = "URL pública del Application Load Balancer"
  value       = "http://${aws_lb.main.dns_name}"
}
```

Verificación:

```bash
terraform apply

# Espera ~2 minutos a que las tareas pasen los health checks del ALB
curl $(terraform output -raw alb_url)
# Debe devolver la página HTML con las dos tarjetas (Web + API via Service Connect)
```

---

## Verificación final

```bash
# Verificar que el servicio ECS esta en RUNNING
aws ecs describe-services \
  --cluster $(terraform output -raw ecs_cluster_name) \
  --services web api \
  --query 'services[*].{Name:serviceName,Status:status,Running:runningCount}' \
  --output table

# Probar el endpoint del ALB
ALB_URL=$(terraform output -raw alb_url)
curl -s "http://${ALB_URL}" | head -20

# Verificar comunicacion interna via Service Connect
curl -s "http://${ALB_URL}/api"
# Esperado: JSON del microservicio API

# Comprobar que el parametro SSM esta correctamente configurado
aws ssm get-parameter \
  --name "/lab29/api-key" \
  --with-decryption \
  --query 'Parameter.{Name:Name,Type:Type}' \
  --output table
```

---

## 5. Limpieza

```bash
# Desde lab29/aws/
terraform destroy
```

El `destroy` elimina el cluster ECS, el servicio, las tareas en ejecución, el repositorio ECR (si está vacío), el parámetro SSM y todos los recursos de red. Si el repositorio ECR tiene imágenes, el destroy fallará — borra las imágenes primero:

```bash
aws ecr batch-delete-image \
  --repository-name lab29/api \
  --image-ids "$(aws ecr list-images \
    --repository-name lab29/api \
    --query 'imageIds' \
    --output json)"
```

> El bucket S3 de estado (`terraform-state-labs-<ACCOUNT_ID>`) no se destruye: se reutiliza en otros laboratorios.

---

## 6. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

LocalStack Community soporta ECR, SSM e IAM completamente. ECS tiene soporte parcial: los recursos (cluster, task definition, service) se crean correctamente en el estado de Terraform, pero las tareas Fargate no se lanzan realmente. Service Connect y el Circuit Breaker se registran sin efecto observable.

---

## 7. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| ECR con IMMUTABLE | Rechaza push duplicado realmente | El repositorio se crea; el push no rechaza en Community |
| Lifecycle policy | Se ejecuta automáticamente | Se almacena pero no se evalúa |
| SSM SecureString | Cifrado con KMS real | Almacenado, `--with-decryption` devuelve el valor |
| ECS Task Definition | Registrada en la API de ECS | Registrada correctamente |
| Tareas Fargate | Se lanzan y ejecutan los contenedores | No se lanzan contenedores reales |
| Service Connect | Proxy Envoy funcional entre tareas | Configuración registrada, sin proxy real |
| Circuit Breaker | Detecta fallos y revierte | Se configura, no hay despliegue real que fallar |
| Execute Command | Funcional con el SSM Agent | No disponible (sin contenedores reales) |
| startup.sh / startup-api.sh | Generan HTML y JSON en el arranque usando metadatos ECS v4 | Los scripts se ejecutan pero el endpoint de metadatos devuelve vacío |
| Coste aproximado | ~$0.03/hora × 4 tareas Fargate (2 web + 2 api, 256 CPU / 512 MB c/u) | Sin coste |

---

## Buenas prácticas aplicadas

- **Usa `IMMUTABLE` en producción siempre.** Los tags mutables permiten sobreescribir accidentalmente una imagen en producción con otra versión. IMMUTABLE hace que el tag sea un identificador permanente, equivalente a un commit hash en Git.
- **Referencia parámetros SSM por ARN, no por nombre.** En el bloque `secrets` de la task definition, usar el ARN (`aws_ssm_parameter.api_key.arn`) en lugar del nombre (`:ssm:/lab29/api-key`) evita ambigüedades de región y cuenta, y garantiza que el permiso IAM apunta exactamente al mismo recurso.
- **Separa el rol de ejecución del rol de tarea.** El `execution_role_arn` solo lo usa el agente ECS para arrancar el contenedor (pull de imagen, inyección de secretos). El `task_role_arn` lo usa el código dentro del contenedor en tiempo de ejecución. Mezclarlos en un solo rol otorga al código de la aplicación permisos que solo debería tener la infraestructura.
- **`port_name` es el contrato entre Task Definition y Service Connect.** El campo `name` en `portMappings` y el campo `port_name` en `service_connect_configuration.service` deben coincidir exactamente. Un cambio en uno sin actualizar el otro causa un error en el despliegue.
- **Activa Container Insights en el cluster.** El bloque `setting { name = "containerInsights" value = "enabled" }` publica métricas de uso de CPU y memoria de cada tarea en CloudWatch, permitiendo configurar alarmas y políticas de auto-escalado basadas en consumo real.
- **Usa `deployment_minimum_healthy_percent = 100` con cuidado.** Con `desired_count = 1`, este valor impide cualquier despliegue porque ECS no puede lanzar una tarea nueva sin terminar la única existente. En ese caso, usa `50` para permitir un despliegue stop-start o aumenta `desired_count` a 2.
- **Limpia el repositorio ECR antes de `destroy`.** Terraform no puede eliminar un repositorio ECR que contiene imágenes. Añade `force_delete = true` en el recurso si quieres que el `destroy` lo elimine aunque contenga imágenes (útil en entornos de desarrollo, no recomendado en producción).

---

## Recursos

- [aws_ecr_repository — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_repository)
- [aws_ecr_lifecycle_policy — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecr_lifecycle_policy)
- [aws_ecs_task_definition — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_task_definition)
- [aws_ecs_service — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ecs_service)
- [aws_ssm_parameter — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/ssm_parameter)
- [aws_service_discovery_http_namespace — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/service_discovery_http_namespace)
- [Combinaciones válidas de CPU/Memoria en Fargate — AWS Docs](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/task-cpu-memory-error.html)
- [Service Connect — AWS Docs](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/service-connect.html)
- [Deployment Circuit Breaker — AWS Docs](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/deployment-circuit-breaker.html)
- [Pasar datos sensibles a contenedores ECS — AWS Docs](https://docs.aws.amazon.com/AmazonECS/latest/developerguide/secrets-envvar-ssm-paramstore.html)
- [ECR Lifecycle Policies — AWS Docs](https://docs.aws.amazon.com/AmazonECR/latest/userguide/LifecyclePolicies.html)
