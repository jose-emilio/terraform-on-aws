# Laboratorio 7: Backend Remoto Profesional en AWS

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 3 — Gestión del Estado (State)](../../modulos/modulo-03/README.md)


## Visión general

En este laboratorio configurarás el backend remoto de Terraform usando el bucket S3 que creaste en el lab02 y una tabla DynamoDB para el bloqueo de estado. Aprenderás a configurar el bloque `backend "s3"` con cifrado y locking, y migrarás un estado local existente al nuevo backend remoto.

> El bucket S3 (`terraform-state-labs-<ACCOUNT_ID>`) ya fue creado y configurado en el lab02 con versionado, cifrado AES-256 y bloqueo de acceso público. Este laboratorio **no vuelve a crear el bucket**: lo referencia y añade la tabla DynamoDB para state locking.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Crear una tabla DynamoDB con la Partition Key `LockID` para gestionar el bloqueo de estado
- Configurar el bloque `backend "s3"` con `encrypt = true` y la tabla de DynamoDB
- Ejecutar `terraform init` para migrar un estado local existente al backend remoto
- Entender por qué el state locking es crítico en entornos de equipo
- Usar locking nativo de S3 con `use_lockfile = true` como alternativa sin DynamoDB

## Requisitos Previos

- Laboratorio 2 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir en AWS
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
    bucket         = "terraform-state-labs-123456789012"   # bucket creado en lab02
    key            = "lab7-workload/terraform.tfstate"
    region         = "us-east-1"
    encrypt        = true
    dynamodb_table = "terraform-state-lock"
  }
}
```

El parámetro `key` define la ruta del archivo de estado dentro del bucket. Usando rutas como `proyecto/entorno/terraform.tfstate` se pueden almacenar múltiples estados en el mismo bucket.

### State Locking con DynamoDB

Cuando Terraform inicia una operación que modifica el estado (`plan`, `apply`, `destroy`), escribe un registro en la tabla DynamoDB con el campo `LockID`. Si otro proceso intenta ejecutar una operación al mismo tiempo, detecta el registro y aborta con un error de bloqueo. Al finalizar la operación, Terraform elimina el registro.

La Partition Key **debe llamarse exactamente `LockID`**: es el nombre que el provider de AWS espera. Cualquier otro nombre hará que el bloqueo no funcione.

### State Locking nativo de S3 (`use_lockfile`)

Desde la versión `~> 5.0` del provider de AWS, el backend `s3` soporta locking nativo mediante el parámetro `use_lockfile = true`. En lugar de usar DynamoDB, Terraform escribe un archivo `.tflock` junto al `.tfstate` dentro del mismo bucket.

```hcl
terraform {
  backend "s3" {
    bucket       = "terraform-state-labs-123456789012"
    key          = "lab7-workload/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true   # crea terraform-state-labs.../lab7-workload/terraform.tfstate.tflock
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
  Enter a value: yes
```

Tras confirmar, el archivo `terraform.tfstate` local queda vacío y el estado vive en S3.

---

## Estructura del proyecto

```
lab07/
├── aws/
│   ├── providers.tf   # Bloque terraform{} y provider{}
│   ├── variables.tf   # Nombre del bucket (lab02), tabla y región
│   ├── main.tf        # Solo tabla DynamoDB (bucket ya existe del lab02)
│   └── outputs.tf     # Bloques backend listos para copiar
├── localstack/
│   ├── providers.tf   # Endpoints s3 y dynamodb apuntando a LocalStack
│   ├── variables.tf   # Valores por defecto para entorno local
│   ├── main.tf        # Bucket + DynamoDB (LocalStack no persiste entre reinicios)
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

## 1. Despliegue en AWS Real

### 1.1 Prerrequisito: bucket del lab02

Verifica que el bucket creado en el lab02 existe y tiene versionado activo:

```bash
export BUCKET=terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)
aws s3api get-bucket-versioning --bucket $BUCKET
# {"Status": "Enabled"}
```

Si el bucket no existe, vuelve al lab02 y ejecuta `terraform apply` antes de continuar.

### 1.2 Código Terraform

**`aws/main.tf`** — Solo la tabla DynamoDB (el bucket ya existe del lab02):

```hcl
resource "aws_dynamodb_table" "lock" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  tags = {
    ManagedBy = "terraform"
    Purpose   = "terraform-state-lock"
  }
}
```

**`aws/outputs.tf`** — Bloques backend listos para copiar:

```hcl
output "backend_config" {
  value = <<-EOT
    terraform {
      backend "s3" {
        bucket         = "${var.bucket_name}"
        key            = "PROYECTO/terraform.tfstate"
        region         = "us-east-1"
        encrypt        = true
        dynamodb_table = "${aws_dynamodb_table.lock.name}"
      }
    }
  EOT
}
```

### 1.3 Despliegue de la Tabla DynamoDB

```bash
export TF_VAR_bucket_name=$BUCKET
# Desde lab07/aws/
terraform fmt
terraform init
terraform plan
terraform apply
```

Al finalizar, los outputs mostrarán los dos bloques `backend` listos para usar:

```
backend_config = <<EOT
  terraform {
    backend "s3" {
      bucket         = "terraform-state-labs-123456789012"
      key            = "PROYECTO/terraform.tfstate"
      region         = "us-east-1"
      encrypt        = true
      dynamodb_table = "terraform-state-lock"
    }
  }
EOT

backend_config_native_lock = <<EOT
  terraform {
    backend "s3" {
      bucket       = "terraform-state-labs-123456789012"
      key          = "PROYECTO/terraform.tfstate"
      region       = "us-east-1"
      encrypt      = true
      use_lockfile = true
    }
  }
EOT
```

### 1.4 Migrar un Estado Local al Backend Remoto

El directorio `workload/` contiene un proyecto de aplicación compartido entre AWS real y LocalStack.

**Paso 1** — Despliega el workload con estado local:

```bash
# Desde lab07/workload/
export TF_VAR_app_bucket_name=mi-app-lab7-2024   # sustituye por tu nombre único
terraform fmt
terraform init
terraform apply -var-file=aws.tfvars
```

Terraform crea `terraform.tfstate` en el directorio local.

**Paso 2** — Añade el bloque `backend "s3" {}` vacío al bloque `terraform {}` de `workload/providers.tf`:

```hcl
terraform {
  backend "s3" {}   # <-- añadir esta línea
  required_providers { ... }
}
```

**Variante A — con DynamoDB:**

```bash
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"
```

**Variante B — locking nativo de S3 (sin DynamoDB):**

> `aws.s3.tfbackend` incluye `dynamodb_table`, que es incompatible con `use_lockfile`. Para la variante B hay que especificar los parámetros directamente:

```bash
terraform init \
  -backend-config="bucket=$BUCKET" \
  -backend-config="key=lab7-workload/terraform.tfstate" \
  -backend-config="region=us-east-1" \
  -backend-config="encrypt=true" \
  -backend-config="use_lockfile=true"
```

Terraform detectará el cambio de backend y preguntará si deseas migrar el estado existente:

```
Initializing the backend...
Do you want to copy existing state to the new backend?
  Enter a value: yes

Successfully configured the backend "s3"!
```

### 1.5 Verificación

Confirma que el estado se ha subido al bucket:

```bash
aws s3 ls s3://$BUCKET/lab7-workload/
```

Verifica que la tabla DynamoDB existe y está vacía (Variante A):

```bash
aws dynamodb scan --table-name terraform-state-lock
```

### 1.6 Observar el State Locking en Acción

Abre dos terminales en `lab07/workload/` y ejecuta `terraform apply` en ambas simultáneamente:

```bash
# Terminal 1
terraform apply

# Terminal 2 (mientras Terminal 1 está en ejecución)
terraform apply
```

**Con DynamoDB (Variante A)**, la segunda terminal muestra:

```
Error: Error acquiring the state lock

  Error message: ConditionalCheckFailedException
  Lock Info:
    ID:        xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    Path:      terraform-state-labs-123456789012/lab7-workload/terraform.tfstate
    Operation: OperationTypeApply
    Who:       usuario@maquina
```

**Con locking nativo de S3 (Variante B)**, el error referencia el archivo `.tflock`:

```
Error: Error acquiring the state lock

  Error message: state file locked
  Lock Info:
    Path:      terraform-state-labs-123456789012/lab7-workload/terraform.tfstate.tflock
```

---

## Verificación final

```bash
# Verificar que el estado esta en S3
aws s3 ls s3://terraform-state-labs-${ACCOUNT_ID}/lab7-workload/
# Esperado: terraform.tfstate

# Verificar que la tabla DynamoDB de locking existe
aws dynamodb describe-table \
  --table-name terraform-state-lock \
  --query 'Table.{Name:TableName,Status:TableStatus}' \
  --output table

# Verificar que la migracion de backend fue exitosa (no hay state local)
ls -la labs/lab07/workload/terraform.tfstate 2>/dev/null \
  && echo "ADVERTENCIA: state local encontrado" \
  || echo "OK: no hay state local"

# Comprobar que el locking funciona (ver el lock info en la tabla DynamoDB)
aws dynamodb scan \
  --table-name terraform-state-lock \
  --query 'Items' --output json
```

---

## 2. Limpieza

> **Importante:** Destruye primero el workload y migra el estado de vuelta al backend local antes de destruir la tabla DynamoDB. **No destruyas el bucket**: se reutiliza en el lab10.


**Paso 1** — Migra el estado del workload de vuelta al backend local:

```bash
# Desde lab07/workload/
terraform init -migrate-state
# Do you want to copy existing state to the new backend? yes
```

**Paso 2** — Destruye los recursos del workload:

```bash
terraform destroy -var-file=aws.tfvars
```

**Paso 3** — Destruye la tabla DynamoDB:

```bash
# Desde lab07/aws/
terraform destroy -var="bucket_name=$BUCKET"
```

> El bucket `terraform-state-labs-<ACCOUNT_ID>` **no se destruye** aquí. Se usará como backend en el lab10.

```

---

## 3. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

LocalStack soporta S3 y DynamoDB completamente. A diferencia de AWS real, el bucket de estado se crea en el propio laboratorio (LocalStack no persiste entre reinicios del contenedor).

---

## 4. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| Bucket S3 | Creado en lab02, reutilizado aquí | Creado en este laboratorio (no persiste) |
| Tabla DynamoDB | Creada en este laboratorio | Creada en este laboratorio |
| Versionado S3 | Activado desde lab02 | Soportado |
| Cifrado AES-256 | Activado desde lab02 | Simulado |
| DynamoDB state locking | Bloqueo real | Soportado |
| Locking nativo S3 (`use_lockfile`) | Soportado desde provider `~> 5.0` | Soportado |
| `terraform destroy` del bucket | **No — se usa en lab10** | Sí (se perderá al reiniciar LocalStack igualmente) |

---

## Buenas prácticas aplicadas

- **Usa una `key` diferente por proyecto y entorno.** Una convención habitual es `{proyecto}/{entorno}/terraform.tfstate`. Un único bucket puede alojar los estados de toda la organización.
- **Nunca almacenes el bucket de estado en el mismo proyecto que gestiona ese bucket.** Si el estado del bucket se corrompe, perderías la capacidad de gestionarlo con Terraform. Este curso sigue esa práctica: el bucket se crea en el lab02 y se referencia, no se recrea, en lab07 y lab10.
- **El bloque `backend` no acepta variables de Terraform.** Si necesitas parametrizar el backend, usa `-backend-config` en la línea de comandos o un archivo `.tfbackend`.
- **Elige `use_lockfile` para proyectos simples, DynamoDB para entornos críticos.** El locking nativo de S3 elimina la dependencia de DynamoDB y reduce costos, pero DynamoDB ofrece garantías de consistencia más fuertes.
- **Protege el bucket con una política de bucket restrictiva.** Solo los roles IAM de CI/CD y los administradores de infraestructura deben tener acceso de escritura al bucket de estado.

---

## Recursos

- [Backend S3 - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/backend/s3)
- [State Locking](https://developer.hashicorp.com/terraform/language/state/locking)
- [Parámetro `use_lockfile` en el backend S3](https://developer.hashicorp.com/terraform/language/backend/s3#use_lockfile)
- [Recurso aws_dynamodb_table](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dynamodb_table)
- [Recurso aws_s3_bucket_versioning](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning)
