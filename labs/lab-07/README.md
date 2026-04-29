# Laboratorio 7: Backend Remoto Profesional en AWS

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 3 — Gestión del Estado (State)](../../modulos/modulo-03/README.md)


## Visión general

En este laboratorio configurarás el backend remoto de Terraform usando el bucket S3 que creaste en el lab02 y una tabla DynamoDB para el bloqueo de estado. Aprenderás a configurar el bloque `backend "s3"` con cifrado y locking vía DynamoDB, y migrarás un estado local existente al nuevo backend remoto.

> El bucket S3 (`terraform-state-labs-<ACCOUNT_ID>`) ya fue creado y configurado en el lab02 con versionado, cifrado AES-256 y bloqueo de acceso público. Este laboratorio **no vuelve a crear el bucket**: lo referencia y añade la tabla DynamoDB para state locking.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Crear una tabla DynamoDB con la Partition Key `LockID` para gestionar el bloqueo de estado
- Configurar el bloque `backend "s3"` con `encrypt = true` y la tabla de DynamoDB
- Ejecutar `terraform init` para migrar un estado local existente al backend remoto
- Entender por qué el state locking es crítico en entornos de equipo

## Requisitos Previos

- Laboratorio 2 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir en AWS

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
lab-07/
├── aws/
│   ├── providers.tf   # Bloque terraform{} y provider{}
│   ├── variables.tf   # Nombre del bucket (lab02), tabla y región
│   ├── main.tf        # Solo tabla DynamoDB (bucket ya existe del lab-02)
│   └── outputs.tf     # Bloque backend listo para copiar
└── workload/          # Proyecto de aplicación que migra de estado local a remoto
    ├── providers.tf       # Bloque terraform{} y provider{}
    ├── variables.tf       # Región y nombre del bucket de aplicación
    ├── main.tf            # Bucket S3 de aplicación de ejemplo
    ├── outputs.tf
    └── aws.s3.tfbackend   # Backend config parcial (bucket se pasa por CLI)
```

---

## 1. Despliegue

### 1.1 Prerrequisito: bucket del lab-02

Verifica que el bucket creado en el lab-02 existe y tiene versionado activo:

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

**`aws/outputs.tf`** — Bloque backend listo para copiar:

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
# Desde lab-07/aws/
terraform fmt
terraform init
terraform plan
terraform apply
```

Al finalizar, el output mostrará el bloque `backend` listo para usar:

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
```

### 1.4 Migrar un Estado Local al Backend Remoto

El directorio `workload/` contiene un proyecto de aplicación que primero se despliega con estado local y luego se migra al backend remoto.

**Paso 1** — Despliega el workload con estado local:

```bash
# Desde lab-07/workload/
export TF_VAR_app_bucket_name=mi-app-lab7-2024   # sustituye por tu nombre único
terraform fmt
terraform init
terraform apply
```

Terraform crea `terraform.tfstate` en el directorio local.

**Paso 2** — Añade el bloque `backend "s3" {}` vacío al bloque `terraform {}` de `workload/providers.tf`:

```hcl
terraform {
  backend "s3" {}   # <-- añadir esta línea
  required_providers { ... }
}
```

Inicializa el backend remoto pasando el archivo `.tfbackend` y el nombre del bucket:

```bash
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"
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

Verifica que la tabla DynamoDB existe y está vacía (no hay locks activos):

```bash
aws dynamodb scan --table-name terraform-state-lock
```

### 1.6 Observar el State Locking en Acción

Abre dos terminales en `lab-07/workload/` y ejecuta `terraform apply` en ambas simultáneamente:

```bash
# Terminal 1
terraform apply

# Terminal 2 (mientras Terminal 1 está en ejecución)
terraform apply
```

La segunda terminal muestra el error de bloqueo emitido por DynamoDB:

```
Error: Error acquiring the state lock

  Error message: ConditionalCheckFailedException
  Lock Info:
    ID:        xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
    Path:      terraform-state-labs-123456789012/lab7-workload/terraform.tfstate
    Operation: OperationTypeApply
    Who:       usuario@maquina
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
ls -la labs/lab-07/workload/terraform.tfstate 2>/dev/null \
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

Primero elimina (o comenta) el bloque `backend "s3" {}` que añadiste en `workload/providers.tf`. Sin esa línea, Terraform vuelve al backend local por defecto y `init -migrate-state` detectará el cambio:

```bash
# Desde lab-07/workload/
terraform init -migrate-state
# Do you want to copy existing state to the new backend? yes
```

**Paso 2** — Destruye los recursos del workload:

```bash
terraform destroy
```

**Paso 3** — Destruye la tabla DynamoDB:

```bash
# Desde lab-07/aws/
terraform destroy -var="bucket_name=$BUCKET"
```

> El bucket `terraform-state-labs-<ACCOUNT_ID>` **no se destruye** aquí. Se usará como backend en el lab10.

---

## Buenas prácticas aplicadas

- **Usa una `key` diferente por proyecto y entorno.** Una convención habitual es `{proyecto}/{entorno}/terraform.tfstate`. Un único bucket puede alojar los estados de toda la organización.
- **Nunca almacenes el bucket de estado en el mismo proyecto que gestiona ese bucket.** Si el estado del bucket se corrompe, perderías la capacidad de gestionarlo con Terraform. Este curso sigue esa práctica: el bucket se crea en el lab02 y se referencia, no se recrea, en lab07 y lab10.
- **El bloque `backend` no acepta variables de Terraform.** Si necesitas parametrizar el backend, usa `-backend-config` en la línea de comandos o un archivo `.tfbackend`.
- **Protege el bucket con una política de bucket restrictiva.** Solo los roles IAM de CI/CD y los administradores de infraestructura deben tener acceso de escritura al bucket de estado.

---

## Recursos

- [Backend S3 - Documentación de Terraform](https://developer.hashicorp.com/terraform/language/backend/s3)
- [State Locking](https://developer.hashicorp.com/terraform/language/state/locking)
- [Recurso aws_dynamodb_table](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/dynamodb_table)
- [Recurso aws_s3_bucket_versioning](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_versioning)
