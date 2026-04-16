# Laboratorio 7: LocalStack: Backend Remoto Profesional

En este laboratorio configurarás un backend remoto de Terraform usando S3 y DynamoDB, el estándar de la industria para equipos que colaboran en infraestructura. Crearás la infraestructura de soporte (bucket y tabla), configurarás el bloque `backend "s3"` con cifrado y bloqueo de estado, y migrarás un estado local existente al nuevo backend remoto.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Crear un bucket S3 con versionado y Public Access Block activado
- Crear una tabla DynamoDB con la Partition Key `LockID` para gestionar el bloqueo de estado
- Configurar el bloque `backend "s3"` con `encrypt = true` y la tabla de DynamoDB
- Ejecutar `terraform init` para migrar un estado local existente al backend remoto
- Entender por qué el state locking es crítico en entornos de equipo
- Configurar locking nativo de S3 con `use_lockfile = true` sin necesidad de DynamoDB

## Requisitos Previos

- Laboratorio 1 completado (entorno configurado)
- Laboratorio 2 completado (flujo básico de Terraform)
- LocalStack en ejecución (para la sección de LocalStack)

---

## Conceptos Clave

### ¿Por qué un backend remoto?

Por defecto, Terraform almacena el estado en un archivo `terraform.tfstate` local. Esto funciona para proyectos individuales, pero presenta problemas graves en equipos:

| Problema | Backend local | Backend remoto (S3) |
|---|---|---|
| Colaboración | El estado vive en la máquina de un solo desarrollador | Centralizado y accesible por todo el equipo |
| Concurrencia | Dos `apply` simultáneos corrompen el estado | DynamoDB bloquea el estado durante cada operación |
| Historial | Se sobreescribe en cada `apply` | S3 Versioning guarda cada versión del estado |
| Seguridad | Archivo en disco sin cifrar | Cifrado en reposo (AES-256) y en tránsito (TLS) |

### Bloque `backend "s3"`

El bloque `backend` se declara dentro del bloque `terraform {}` y define dónde se almacena el estado. A diferencia de los recursos, **no puede usar variables de Terraform**: todos sus valores deben ser literales.

```hcl
terraform {
  backend "s3" {
    bucket         = "mi-bucket-de-estado"   # nombre del bucket S3
    key            = "global/terraform.tfstate"  # ruta dentro del bucket
    region         = "us-east-1"
    encrypt        = true                    # cifrado AES-256 en tránsito
    dynamodb_table = "terraform-state-lock"  # tabla para state locking
  }
}
```

El parámetro `key` define la ruta del archivo de estado dentro del bucket. Usar una ruta como `proyecto/entorno/terraform.tfstate` permite almacenar múltiples estados en el mismo bucket.

### State Locking con DynamoDB

Cuando Terraform inicia una operación que modifica el estado (`plan`, `apply`, `destroy`), escribe un registro en la tabla DynamoDB con el campo `LockID`. Si otro proceso intenta ejecutar una operación al mismo tiempo, detecta el registro y aborta con un error de bloqueo. Al finalizar la operación, Terraform elimina el registro.

La Partition Key **debe llamarse exactamente `LockID`**: es el nombre que el provider de AWS espera. Cualquier otro nombre hará que el bloqueo no funcione.

### State Locking nativo de S3 (`use_lockfile`)

Desde la versión `~> 5.0` del provider de AWS, el backend `s3` soporta locking nativo mediante el parámetro `use_lockfile = true`. En lugar de usar DynamoDB, Terraform escribe un archivo `.tflock` junto al `.tfstate` dentro del mismo bucket. Si el archivo de bloqueo ya existe cuando otro proceso intenta operar, Terraform aborta con un error de bloqueo.

```hcl
terraform {
  backend "s3" {
    bucket       = "mi-bucket-de-estado"
    key          = "global/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true   # crea mi-bucket/global/terraform.tfstate.tflock
  }
}
```

Comparado con DynamoDB:

| Aspecto | DynamoDB (`dynamodb_table`) | Nativo S3 (`use_lockfile`) |
|---|---|---|
| Infraestructura extra | Tabla DynamoDB | Ninguna |
| Coste | Lecturas/escrituras DynamoDB | Operaciones PUT/DELETE S3 (mínimo) |
| Disponibilidad | Requiere que DynamoDB esté accesible | Solo requiere el bucket |
| Madurez | Estándar desde hace años | Introducido en provider `~> 5.0` |
| Recomendado para | Equipos grandes, entornos críticos | Proyectos personales o equipos pequeños |

### Migración de estado local a remoto

Cuando añades un bloque `backend` a un proyecto que ya tiene estado local, `terraform init` detecta el cambio y ofrece migrar el estado:

```
Initializing the backend...
Do you want to copy existing state to the new backend?
  Pre-existing state was found while migrating the previous "local" backend to the
  newly configured "s3" backend. No existing state was found in the newly configured
  "s3" backend. Do you want to copy this state to the new backend?

  Enter a value: yes
```

Tras confirmar, el archivo `terraform.tfstate` local queda vacío y el estado vive en S3.

---

## Estructura del Laboratorio

```
lab07/
├── aws/
│   ├── providers.tf   # Bloque terraform{} y provider{}
│   ├── variables.tf   # Nombre del bucket, tabla y región
│   ├── main.tf        # Bucket S3 + DynamoDB (locking clásico) y bucket S3 (locking nativo)
│   └── outputs.tf     # Bloques backend listos para copiar (ambas variantes)
├── localstack/
│   ├── providers.tf   # Endpoints s3 y dynamodb apuntando a LocalStack
│   ├── variables.tf   # Valores por defecto para entorno local
│   ├── main.tf        # Idéntico al de aws/
│   └── outputs.tf     # Nombres de recursos creados
└── workload/          # Proyecto de aplicación compartido (AWS real y LocalStack)
    ├── providers.tf           # Provider parametrizado con variables
    ├── variables.tf           # Variables de recursos y de configuración del provider
    ├── main.tf                # Bucket S3 de aplicación de ejemplo
    ├── outputs.tf
    ├── aws.tfvars             # Valores para AWS real
    ├── localstack.tfvars      # Valores para LocalStack
    ├── aws.s3.tfbackend       # Backend config parcial para AWS S3
    └── localstack.s3.tfbackend # Backend config completo para LocalStack S3
```

---

## 1. Despliegue en LocalStack

LocalStack soporta S3 y DynamoDB completamente. La única diferencia respecto a AWS real es la configuración del provider con endpoints locales. El bloque `backend "s3"` también puede apuntar a LocalStack para simular la migración de estado en local.

### 1.1 Diferencias en `localstack/providers.tf`

```hcl
provider "aws" {
  region                      = "us-east-1"
  access_key                  = "test"
  secret_key                  = "test"
  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true

  endpoints {
    s3       = "http://localhost.localstack.cloud:4566"
    dynamodb = "http://localhost.localstack.cloud:4566"
  }
}
```

### 1.2 Despliegue

Asegúrate de que LocalStack esté en ejecución:

```bash
localstack status
```

Desde el directorio `lab07/localstack/`:

```bash
terraform fmt
terraform init
terraform plan
terraform apply
```

### 1.3 Verificación

```bash
aws --profile localstack s3 ls
aws --profile localstack dynamodb list-tables
aws --profile localstack dynamodb describe-table --table-name terraform-state-lock
```

### 1.4 Simular la Migración de Estado en LocalStack

El mismo directorio `workload/` funciona con LocalStack usando `localstack.tfvars`.

**Paso 1** — Despliega el workload con estado local apuntando a LocalStack:

```bash
# Desde lab07/workload/
terraform init
terraform apply -var-file=localstack.tfvars
```

**Paso 2** — Añade `backend "s3" {}` al bloque `terraform {}` de `workload/providers.tf` (igual que en la variante AWS real). Luego migra al backend remoto simulado en LocalStack S3. El archivo `localstack.s3.tfbackend` incluye todos los parámetros de conexión ya configurados:

```bash
terraform init -backend-config=localstack.s3.tfbackend
# Do you want to copy existing state to the new backend? yes
```

> Si vienes de haber usado el backend de AWS real en el mismo directorio, usa `-reconfigure` en lugar de dejar que Terraform intente migrar el estado entre backends de distintos entornos:
> ```bash
> terraform init -reconfigure -backend-config=localstack.s3.tfbackend
> ```

### 1.5 Destruir los Recursos

**Paso 1** — Migra el estado del workload de vuelta al backend local:

```bash
# Desde lab07/workload/
terraform init -migrate-state
# Do you want to copy existing state to the new backend? yes
```

**Paso 2** — Destruye los recursos del workload:

```bash
terraform destroy -var-file=localstack.tfvars
```

**Paso 3** — Destruye la infraestructura de soporte:

```bash
# Desde lab07/localstack/
terraform destroy
```

---

## 2. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| Bucket S3 | Nombre globalmente único | Nombre local, sin restricción de unicidad global |
| Versionado S3 | Historial real de versiones del estado | Soportado |
| Public Access Block | Protección real contra exposición pública | Soportado |
| Cifrado AES-256 | Cifrado real en reposo | Simulado |
| DynamoDB state locking | Bloqueo real con `ConditionalCheckFailedException` | Soportado |
| Locking nativo S3 (`use_lockfile`) | Soportado desde provider `~> 5.0` | Soportado |
| Bloque `backend "s3"` | Configuración estándar | Requiere parámetros adicionales de endpoint |

---

## 3. Buenas Prácticas

- **Usa una `key` diferente por proyecto y entorno.** Una convención habitual es `{proyecto}/{entorno}/terraform.tfstate`, por ejemplo `vpc/prod/terraform.tfstate`. Esto permite usar un único bucket para toda la organización.
- **Nunca almacenes el bucket de estado en el mismo proyecto que gestiona ese bucket.** Si el estado del bucket se corrompe, perderías la capacidad de gestionarlo con Terraform. Crea la infraestructura de soporte en un proyecto separado con estado local o en otro backend.
- **Activa S3 Versioning antes de empezar a usar el bucket como backend.** Una vez que el estado existe en S3, el versionado garantiza que puedes recuperar cualquier versión anterior ante un `apply` erróneo.
- **El bloque `backend` no acepta variables de Terraform.** Si necesitas parametrizar el backend (por ejemplo, para múltiples entornos), usa `-backend-config` en la línea de comandos o un archivo `.tfbackend`:
  ```bash
  terraform init -backend-config="bucket=terraform-state-prod"
  ```
- **Elige `use_lockfile` para proyectos simples, DynamoDB para entornos críticos.** El locking nativo de S3 elimina la dependencia de DynamoDB y reduce costos, pero DynamoDB ofrece garantías de consistencia más fuertes y es el estándar en organizaciones con múltiples equipos.
- **Protege el bucket con una política de bucket restrictiva.** Solo los roles IAM de CI/CD y los administradores de infraestructura deben tener acceso de escritura al bucket de estado.

---

## 4. Recursos Adicionales

- [Backend S3 - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/backend/s3)
- [State Locking](https://developer.hashicorp.com/terraform/language/state/locking)
- [Parámetro `use_lockfile` en el backend S3](https://developer.hashicorp.com/terraform/language/backend/s3#use_lockfile)
- [Recurso aws_s3_bucket](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket)
- [Recurso aws_dynamodb_table](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dynamodb_table)
- [Recurso aws_s3_bucket_versioning](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning)
- [Recurso aws_s3_bucket_public_access_block](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block)
