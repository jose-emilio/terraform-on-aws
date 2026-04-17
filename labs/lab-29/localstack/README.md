# Laboratorio 25 — LocalStack: Microservicios con ECS Fargate y Malla de Servicios

![Terraform on AWS](../../../images/lab-banner.svg)


Este documento describe cómo ejecutar el laboratorio 25 contra LocalStack. El código Terraform es el mismo que en `aws/`; solo cambia la configuración del provider.

## Requisitos Previos

- LocalStack en ejecución: `localstack start -d`
- Terraform >= 1.5

---

## 1. Despliegue en LocalStack

### 1.1 Limitaciones conocidas

LocalStack Community simula los servicios de AWS con algunas restricciones relevantes para este laboratorio:

| Servicio | Soporte en Community |
|---|---|
| ECR (`aws_ecr_repository`, `aws_ecr_lifecycle_policy`) | Completo — el repositorio se crea; el push no rechaza tags duplicados (IMMUTABLE no se valida) |
| SSM Parameter Store (`SecureString`) | Completo — `--with-decryption` devuelve el valor almacenado |
| IAM roles y políticas | Completo |
| CloudWatch Log Groups | Completo |
| ECS Cluster y Task Definitions | Parcial — los recursos se registran en el estado de Terraform correctamente |
| Tareas Fargate | No se lanzan contenedores reales; los scripts `startup.sh` y `startup-api.sh` no se ejecutan |
| Service Connect / Cloud Map | Configuración registrada, sin proxy Envoy real ni resolución DNS interna |
| Deployment Circuit Breaker | Se configura, no hay despliegue real que fallar |
| ECS Execute Command | No disponible sin contenedores reales |

El valor del laboratorio con LocalStack radica en verificar que el código Terraform es sintácticamente válido y que todos los recursos se crean sin errores de API. Para observar el comportamiento real de Service Connect, la inyección de secretos SSM y el Circuit Breaker, se requiere AWS real.

### 1.2 Inicialización y despliegue

Asegúrate de que LocalStack está en ejecución:

```bash
localstack status
```

Desde el directorio `lab29/localstack/`:

```bash
terraform fmt
terraform init
terraform plan
terraform apply
```

### 1.3 Verificación

Comprueba que los recursos se han creado correctamente:

```bash
# ECR
awslocal ecr describe-repositories \
  --query 'repositories[].{Nombre:repositoryName,Mutabilidad:imageTagMutability}'

# SSM — el parámetro SecureString se almacena y se puede recuperar
awslocal ssm get-parameter \
  --name /lab29-local/api-key \
  --with-decryption \
  --query 'Parameter.{Nombre:Name,Tipo:Type,Valor:Value}'

# ECS Cluster
awslocal ecs describe-clusters \
  --clusters lab29-local-cluster \
  --query 'clusters[].{Nombre:clusterName,Estado:status}'

# Task Definitions (web y api)
awslocal ecs describe-task-definition \
  --task-definition lab29-local-web \
  --query 'taskDefinition.{Family:family,Revision:revision,CPU:cpu,Memoria:memory}'

awslocal ecs describe-task-definition \
  --task-definition lab29-local-api \
  --query 'taskDefinition.{Family:family,Revision:revision,CPU:cpu,Memoria:memory}'

# Servicios ECS
awslocal ecs describe-services \
  --cluster lab29-local-cluster \
  --services lab29-local-web lab29-local-api \
  --query 'services[].{Nombre:serviceName,Estado:status,Deseadas:desiredCount}'

# Namespace Service Connect
awslocal servicediscovery list-namespaces \
  --query 'Namespaces[].{Nombre:Name,Tipo:Type}'
```

---

## 2. Limpieza

```bash
# Desde lab29/localstack/
terraform destroy
```

---

## 3. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| ECR con IMMUTABLE | Rechaza push con tag duplicado | El repositorio se crea; IMMUTABLE no se valida en Community |
| Lifecycle policy | Se evalúa automáticamente | Se almacena pero no se evalúa |
| SSM SecureString | Cifrado con KMS real | Almacenado; `--with-decryption` devuelve el valor |
| ECS Task Definition | Registrada y utilizable | Registrada correctamente |
| Tareas Fargate | Se lanzan y ejecutan `startup.sh` | No se lanzan contenedores reales |
| Service Connect | Proxy Envoy funcional entre tareas | Configuración registrada, sin proxy real |
| Circuit Breaker | Detecta fallos y revierte automáticamente | Se configura, sin despliegue real que fallar |
| Execute Command | Funcional con el SSM Agent | No disponible sin contenedores |
| Inyección de secretos SSM | El agente ECS descifra y entrega la variable de entorno | Sin contenedor que reciba la variable |
| Coste aproximado | ~$0.03/hora × 4 tareas Fargate (2 web + 2 api, 256 CPU / 512 MB) | Sin coste |

---

## 4. Buenas Prácticas

- Usa LocalStack para validar la sintaxis de las task definitions y los `jsonencode()` antes de desplegar en AWS real.
- Para probar el comportamiento dinámico de Service Connect, la autenticación por header y el Circuit Breaker, usa AWS real.
- El flag `terraform validate` y `terraform plan` son suficientes para detectar errores de configuración sin necesidad de LocalStack.
- Verifica siempre el parámetro SSM con `--with-decryption` para confirmar que el valor se almacenó correctamente, aunque en LocalStack no haya cifrado KMS real.

---

## 5. Recursos Adicionales

- [LocalStack — ECR](https://docs.localstack.cloud/aws/services/ecr/)
- [LocalStack — ECS](https://docs.localstack.cloud/aws/services/ecs/)
- [LocalStack — SSM](https://docs.localstack.cloud/aws/services/ssm/)
- [LocalStack Pro — soporte ampliado](https://docs.localstack.cloud/aws/getting-started/)
