# Laboratorio 22 — Refactorización Avanzada de S3 (De Monolítico a Modular)

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 6 — Módulos de Terraform](../../modulos/modulo-06/README.md)


## Visión general

Transformar un recurso S3 "hardcoded" en un componente flexible y profesional mediante un **módulo reutilizable**. Aplicar buenas prácticas de modularización: tríada estándar (`main.tf`, `variables.tf`, `outputs.tf`), combinación inteligente de etiquetas con `merge()`, protección contra destrucción accidental con `lifecycle`, e invocación múltiple desde el Root Module con diferentes configuraciones.

## Conceptos clave

| Concepto | Descripción |
|---|---|
| **Módulo Terraform** | Contenedor reutilizable de recursos. Cualquier directorio con archivos `.tf` es un módulo. El Root Module llama a Child Modules con el bloque `module {}` |
| **Root Module** | El directorio donde ejecutas `terraform apply`. Orquesta la infraestructura llamando a módulos hijos y pasando variables |
| **Tríada estándar** | Convención de organizar cada módulo con tres archivos: `main.tf` (recursos), `variables.tf` (entradas) y `outputs.tf` (salidas) |
| **`merge()`** | Función de Terraform que combina dos o más mapas. Las claves del mapa posterior sobreescriben las del anterior. Ideal para combinar etiquetas globales con específicas |
| **`locals`** | Bloque que define valores intermedios calculados. Útil para construir mapas de tags, nombres compuestos o valores derivados que se usan en múltiples recursos |
| **`lifecycle`** | Meta-argumento que controla el comportamiento del ciclo de vida de un recurso. `prevent_destroy = true` impide que `terraform destroy` elimine el recurso |
| **Bloqueo de acceso público** | `aws_s3_bucket_public_access_block` con las cuatro opciones en `true` garantiza que ningún objeto del bucket sea accesible públicamente, incluso si alguien añade una policy permisiva |

## Comparativa: Monolítico vs. Modular

| Aspecto | Enfoque monolítico | Enfoque modular |
|---|---|---|
| Reutilización | Copiar y pegar bloques | Invocar el módulo con `source = "..."` |
| Consistencia | Fácil divergencia entre recursos | Una sola definición, múltiples instancias |
| Mantenimiento | Cambiar en N sitios | Cambiar una vez, se propaga |
| Etiquetado | Tags duplicados o inconsistentes | `merge()` centralizado en el módulo |
| Protección | Olvidar `lifecycle` en alguna copia | Incluido por defecto en el módulo |
| Testing | Difícil de probar aislado | Se puede testear el módulo por separado |

## Prerrequisitos

- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.5

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
echo "Bucket: $BUCKET"
```

## Estructura del proyecto

```
lab22/
├── README.md                          <- Esta guía
├── aws/
│   ├── providers.tf                   <- Backend S3 parcial
│   ├── variables.tf                   <- Variables: región, proyecto, entorno
│   ├── main.tf                        <- Root Module: invoca s3-bucket 2 veces
│   ├── outputs.tf                     <- ARN y nombres de ambos buckets
│   ├── aws.s3.tfbackend               <- Parámetros del backend (sin bucket)
│   └── modules/
│       └── s3-bucket/
│           ├── main.tf                <- Bucket + versionado + bloqueo público + lifecycle
│           ├── variables.tf           <- Entradas: nombre, versionado, tags, force_destroy
│           └── outputs.tf             <- Salidas: id, arn, domain_name
└── localstack/
    ├── README.md                      <- Guía específica para LocalStack
    ├── providers.tf
    ├── variables.tf
    ├── main.tf                        <- Root Module adaptado a LocalStack
    ├── outputs.tf
    ├── localstack.s3.tfbackend        <- Backend completo para LocalStack
    └── modules/
        └── s3-bucket/
            ├── main.tf               <- Módulo sin prevent_destroy (LocalStack)
            ├── variables.tf
            └── outputs.tf
```

## 1. Análisis del código

### 1.1 El problema: enfoque monolítico

Antes de modularizar, el código típico para crear dos buckets S3 se ve así:

```hcl
# ❌ Enfoque monolítico — código duplicado, tags inconsistentes, sin protección

resource "aws_s3_bucket" "logs" {
  bucket = "mi-proyecto-logs-123456789012"
  tags = {
    Name        = "mi-proyecto-logs"
    Environment = "lab"
    Project     = "mi-proyecto"
  }
}

resource "aws_s3_bucket" "data" {
  bucket = "mi-proyecto-data-123456789012"
  tags = {
    Name        = "mi-proyecto-data"
    Env         = "lab"          # <-- inconsistencia: "Env" vs "Environment"
    Project     = "mi-proyecto"
    # Falta ManagedBy = "terraform"
  }
}
```

Problemas evidentes:
- **Tags inconsistentes**: un bucket usa `Environment`, otro `Env`
- **Sin protección**: ningún `lifecycle` previene la destrucción accidental del bucket de datos críticos
- **Sin bloqueo público**: el bucket queda expuesto si alguien añade una policy permisiva
- **Sin versionado**: no hay forma de recuperar objetos eliminados accidentalmente
- **Copia-pega**: cada nuevo bucket requiere duplicar y adaptar todo el bloque

### 1.2 La solución: módulo `s3-bucket`

#### Estructura del módulo

```
modules/s3-bucket/
├── main.tf         <- Recursos: bucket, versionado, bloqueo público, lifecycle
├── variables.tf    <- Entradas: bucket_name, enable_versioning, tags, force_destroy
└── outputs.tf      <- Salidas: bucket_id, bucket_arn, bucket_domain_name
```

#### Variables del módulo (`variables.tf`)

```hcl
variable "bucket_name" {
  type        = string
  description = "Nombre del bucket S3. Debe ser globalmente único"
}

variable "enable_versioning" {
  type        = bool
  description = "Habilitar versionado en el bucket"
  default     = true
}

variable "force_destroy" {
  type        = bool
  description = "Permitir destruir el bucket aunque contenga objetos"
  default     = false
}

variable "tags" {
  type        = map(string)
  description = "Etiquetas adicionales que se combinan con las etiquetas por defecto del módulo"
  default     = {}
}
```

Puntos clave:
- `bucket_name` no tiene `default` → es **obligatorio** al invocar el módulo
- `enable_versioning` tiene `default = true` → activo por defecto (buena práctica)
- `force_destroy` tiene `default = false` → protección por defecto contra eliminación de objetos
- `tags` es un mapa abierto → el Root Module puede pasar cualquier etiqueta

#### Lógica de tags con `merge()` (`main.tf`)

```hcl
locals {
  default_tags = {
    ManagedBy = "terraform"
    Module    = "s3-bucket"
  }

  effective_tags = merge(local.default_tags, var.tags)
}
```

La función `merge()` opera en cascada:

```
default_tags:     { ManagedBy = "terraform", Module = "s3-bucket" }
      +
var.tags:         { Environment = "lab", Project = "lab22", Purpose = "logs" }
      =
effective_tags:   { ManagedBy = "terraform", Module = "s3-bucket",
                    Environment = "lab", Project = "lab22", Purpose = "logs" }
```

Si `var.tags` contiene una clave que ya existe en `default_tags`, el valor de `var.tags` gana (el mapa posterior tiene prioridad). Esto permite que el Root Module sobreescriba valores por defecto cuando sea necesario.

Luego, al crear el bucket, se aplica un segundo `merge()` para añadir el tag `Name`:

```hcl
resource "aws_s3_bucket" "this" {
  bucket        = var.bucket_name
  force_destroy = var.force_destroy

  tags = merge(local.effective_tags, {
    Name = var.bucket_name
  })

  lifecycle {
    prevent_destroy = true
  }
}
```

#### Control de destrucción: `lifecycle`

```hcl
lifecycle {
  prevent_destroy = true
}
```

Con `prevent_destroy = true`, Terraform **rechaza** cualquier plan que intente destruir el bucket:

```
Error: Instance cannot be destroyed
  on modules/s3-bucket/main.tf line XX:
  Resource module.data_bucket.aws_s3_bucket.this has lifecycle.prevent_destroy
  set, but the plan calls for this resource to be destroyed.
```

Esto protege buckets de datos críticos contra:
- Un `terraform destroy` accidental
- Eliminar el bloque `module` del código sin pensar en las consecuencias
- Cambiar un parámetro que fuerza la recreación del recurso (como el nombre del bucket)

> **Importante:** `prevent_destroy` no acepta variables — debe ser un literal `true` o `false`. Esta es una limitación intencional de Terraform para evitar que la protección dependa de un valor dinámico que podría cambiar.

#### Bloqueo de acceso público

```hcl
resource "aws_s3_bucket_public_access_block" "this" {
  bucket = aws_s3_bucket.this.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
```

Las cuatro opciones en `true` crean una defensa en profundidad:

| Opción | Protege contra |
|---|---|
| `block_public_acls` | Subir objetos con ACL pública |
| `block_public_policy` | Aplicar bucket policies que concedan acceso público |
| `ignore_public_acls` | ACLs públicas existentes (las ignora) |
| `restrict_public_buckets` | Acceso público a través de cross-account policies |

### 1.3 Root Module — Invocación múltiple

```hcl
locals {
  account_id = data.aws_caller_identity.current.account_id

  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
  }
}
```

El Root Module define `common_tags` que se pasan a ambos módulos. Cada invocación añade tags específicas:

```hcl
# Bucket de logs: sin versionado, destruible
module "logs_bucket" {
  source = "./modules/s3-bucket"

  bucket_name       = "${var.project_name}-logs-${local.account_id}"
  enable_versioning = false
  force_destroy     = true

  tags = merge(local.common_tags, {
    Purpose            = "logs"
    DataClassification = "internal"
  })
}

# Bucket de datos: con versionado, NO destruible
module "data_bucket" {
  source = "./modules/s3-bucket"

  bucket_name       = "${var.project_name}-data-${local.account_id}"
  enable_versioning = true
  force_destroy     = false

  tags = merge(local.common_tags, {
    Purpose            = "data"
    DataClassification = "confidential"
  })
}
```

La cascada completa de tags para el bucket de datos:

```
Módulo default_tags:   { ManagedBy = "terraform", Module = "s3-bucket" }
      +
Root common_tags:      { Environment = "lab", ManagedBy = "terraform", Project = "lab22" }
  + específicas:       { Purpose = "data", DataClassification = "confidential" }
      +
Bucket Name:           { Name = "lab22-data-123456789012" }
      =
Tags finales:          { ManagedBy = "terraform", Module = "s3-bucket",
                         Environment = "lab", Project = "lab22",
                         Purpose = "data", DataClassification = "confidential",
                         Name = "lab22-data-123456789012" }
```

Nota que `ManagedBy` aparece en `default_tags` y en `common_tags` con el mismo valor. Si tuvieran valores diferentes, el de `common_tags` ganaría (último merge tiene prioridad).

### 1.4 Diferencias entre ambas instancias

| Parámetro | `logs_bucket` | `data_bucket` |
|---|---|---|
| Versionado | Desactivado | Activado |
| `force_destroy` | `true` (se puede vaciar y destruir) | `false` (protegido) |
| `Purpose` | `logs` | `data` |
| `DataClassification` | `internal` | `confidential` |
| Caso de uso | Logs temporales, rotables | Datos críticos del negocio |

Ambos buckets comparten: bloqueo de acceso público, tags de proyecto, y protección `prevent_destroy`.

---

## 2. Despliegue

```bash
cd labs/lab22/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform apply
```

Terraform creará 6 recursos:
- 2 × `aws_s3_bucket` (logs y data)
- 2 × `aws_s3_bucket_versioning` (uno Enabled, otro Suspended)
- 2 × `aws_s3_bucket_public_access_block`

```bash
terraform output
# logs_bucket_id  = "lab22-logs-123456789012"
# logs_bucket_arn = "arn:aws:s3:::lab22-logs-123456789012"
# data_bucket_id  = "lab22-data-123456789012"
# data_bucket_arn = "arn:aws:s3:::lab22-data-123456789012"
```

---

## Verificación final

### 3.1 Verificar los buckets creados

```bash
LOGS_BUCKET=$(terraform output -raw logs_bucket_id)
DATA_BUCKET=$(terraform output -raw data_bucket_id)

# Listar ambos buckets
aws s3 ls | grep lab18
# 2026-xx-xx lab22-logs-123456789012
# 2026-xx-xx lab22-data-123456789012
```

### 3.2 Verificar etiquetas

```bash
# Tags del bucket de logs
aws s3api get-bucket-tagging \
  --bucket $LOGS_BUCKET \
  --query 'TagSet[].{Key: Key, Value: Value}' \
  --output table
```

Debe mostrar las etiquetas combinadas: `ManagedBy=terraform`, `Module=s3-bucket`, `Environment=lab`, `Project=lab22`, `Purpose=logs`, `DataClassification=internal`, `Name=lab22-logs-...`.

```bash
# Tags del bucket de datos
aws s3api get-bucket-tagging \
  --bucket $DATA_BUCKET \
  --query 'TagSet[].{Key: Key, Value: Value}' \
  --output table
```

Debe mostrar `Purpose=data` y `DataClassification=confidential` en lugar de los valores del bucket de logs.

### 3.3 Verificar versionado

```bash
# Logs: versionado desactivado
aws s3api get-bucket-versioning --bucket $LOGS_BUCKET
# { "Status": "Suspended" }

# Data: versionado activado
aws s3api get-bucket-versioning --bucket $DATA_BUCKET
# { "Status": "Enabled" }
```

### 3.4 Verificar bloqueo de acceso público

```bash
aws s3api get-public-access-block --bucket $DATA_BUCKET \
  --query 'PublicAccessBlockConfiguration'
# {
#   "BlockPublicAcls": true,
#   "IgnorePublicAcls": true,
#   "BlockPublicPolicy": true,
#   "RestrictPublicBuckets": true
# }
```

### 3.5 Verificar protección contra destrucción

```bash
# Intentar destruir — debe fallar por prevent_destroy
terraform destroy
# Error: Instance cannot be destroyed
```

Terraform se negará a destruir los buckets porque el módulo tiene `prevent_destroy = true`. Este es el comportamiento esperado.

---

## 4. Reto: Añadir regla de ciclo de vida para expiración de logs

**Situación**: El equipo de operaciones quiere que los objetos del bucket de logs se eliminen automáticamente después de 90 días para reducir costes de almacenamiento. El bucket de datos debe retener los objetos indefinidamente.

**Tu objetivo**:

1. Añadir una variable `expiration_days` al módulo `s3-bucket` con valor por defecto `0` (desactivado)
2. Crear un recurso `aws_s3_bucket_lifecycle_configuration` dentro del módulo que aplique una regla de expiración **solo cuando** `expiration_days > 0`
3. En el Root Module, pasar `expiration_days = 90` al bucket de logs y no pasarlo al de datos (usará el default de 0)
4. Verificar con AWS CLI que la regla solo existe en el bucket de logs

**Pistas**:
- Usa un bloque `dynamic` o `count` para crear la regla condicionalmente
- El recurso `aws_s3_bucket_lifecycle_configuration` necesita un bloque `rule` con `expiration { days = ... }` y `status = "Enabled"`
- `filter {}` vacío aplica la regla a todos los objetos del bucket
- Verifica con: `aws s3api get-bucket-lifecycle-configuration --bucket <bucket>`

La solución está en la [sección 5](#5-solución-del-reto).

---

## 5. Solución del Reto

### Paso 1: Nueva variable en `modules/s3-bucket/variables.tf`

```hcl
variable "expiration_days" {
  type        = number
  description = "Días tras los cuales los objetos expiran automáticamente. 0 = desactivado"
  default     = 0
}
```

### Paso 2: Recurso condicional en `modules/s3-bucket/main.tf`

```hcl
resource "aws_s3_bucket_lifecycle_configuration" "this" {
  count  = var.expiration_days > 0 ? 1 : 0
  bucket = aws_s3_bucket.this.id

  rule {
    id     = "auto-expire"
    status = "Enabled"

    filter {}

    expiration {
      days = var.expiration_days
    }
  }
}
```

`count = var.expiration_days > 0 ? 1 : 0` crea el recurso solo cuando se especifica un valor mayor que 0. Si `expiration_days` es 0 (default), el recurso no se crea en absoluto.

### Paso 3: Invocar desde el Root Module

```hcl
module "logs_bucket" {
  source = "./modules/s3-bucket"

  bucket_name       = "${var.project_name}-logs-${local.account_id}"
  enable_versioning = false
  force_destroy     = true
  expiration_days   = 90

  tags = merge(local.common_tags, {
    Purpose            = "logs"
    DataClassification = "internal"
  })
}

# data_bucket no pasa expiration_days → usa default = 0 → sin regla
```

### Paso 4: Verificar

```bash
terraform apply

# Bucket de logs: debe tener regla de expiración
aws s3api get-bucket-lifecycle-configuration \
  --bucket $(terraform output -raw logs_bucket_id)
# {
#   "Rules": [{
#     "ID": "auto-expire",
#     "Status": "Enabled",
#     "Expiration": { "Days": 90 },
#     "Filter": {}
#   }]
# }

# Bucket de datos: no debe tener regla
aws s3api get-bucket-lifecycle-configuration \
  --bucket $(terraform output -raw data_bucket_id)
# Error: The lifecycle configuration does not exist
# (esto es correcto — no se creó ninguna regla)
```

---

## 6. Reto 2: Cifrado con SSE-KMS para datos confidenciales

**Situación**: El equipo de seguridad requiere que el bucket de datos críticos use cifrado **SSE-KMS** con una clave gestionada por el cliente (CMK), mientras que el bucket de logs puede usar el cifrado por defecto **SSE-S3** (más económico). El módulo debe soportar ambos escenarios de forma configurable.

**Tu objetivo**:

1. Crear una clave KMS (`aws_kms_key`) en el Root Module, dedicada al cifrado del bucket de datos
2. Añadir una variable `kms_key_arn` al módulo `s3-bucket` con valor por defecto `null` (sin KMS)
3. Crear un recurso `aws_s3_bucket_server_side_encryption_configuration` dentro del módulo que:
   - Use `aws:kms` con la clave proporcionada si `kms_key_arn != null`
   - Use `AES256` (SSE-S3) si `kms_key_arn` es null
4. Pasar la clave KMS solo al bucket de datos
5. Verificar con AWS CLI que cada bucket usa el tipo de cifrado correcto

**Pistas**:
- `aws_kms_key` necesita una `description` y opcionalmente `enable_key_rotation = true`
- El recurso de cifrado usa un bloque `rule { apply_server_side_encryption_by_default { ... } }`
- La clave de `sse_algorithm` es `"aws:kms"` o `"AES256"`
- `kms_master_key_id` solo se necesita cuando `sse_algorithm = "aws:kms"`
- Verifica con: `aws s3api get-bucket-encryption --bucket <bucket>`

La solución está en la [sección 7](#7-solución-del-reto-2).

---

## 7. Solución del Reto 2

### Paso 1: Clave KMS en el Root Module (`main.tf`)

```hcl
resource "aws_kms_key" "data" {
  description         = "Clave KMS para cifrado del bucket de datos - ${var.project_name}"
  enable_key_rotation = true

  tags = merge(local.common_tags, {
    Purpose = "s3-data-encryption"
  })
}

resource "aws_kms_alias" "data" {
  name          = "alias/${var.project_name}-data-key"
  target_key_id = aws_kms_key.data.key_id
}
```

### Paso 2: Nueva variable en `modules/s3-bucket/variables.tf`

```hcl
variable "kms_key_arn" {
  type        = string
  description = "ARN de la clave KMS para cifrado SSE-KMS. null = usar SSE-S3 (AES256)"
  default     = null
}
```

### Paso 3: Recurso de cifrado en `modules/s3-bucket/main.tf`

```hcl
resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = var.kms_key_arn != null ? "aws:kms" : "AES256"
      kms_master_key_id = var.kms_key_arn
    }
    bucket_key_enabled = var.kms_key_arn != null
  }
}
```

`bucket_key_enabled = true` reduce costes de KMS al cachear la clave de datos a nivel de bucket en vez de generar una por cada objeto. Solo tiene sentido con SSE-KMS.

### Paso 4: Invocar desde el Root Module

```hcl
module "data_bucket" {
  source = "./modules/s3-bucket"

  bucket_name       = "${var.project_name}-data-${local.account_id}"
  enable_versioning = true
  force_destroy     = false
  kms_key_arn       = aws_kms_key.data.arn

  tags = merge(local.common_tags, {
    Purpose            = "data"
    DataClassification = "confidential"
  })
}

# logs_bucket no pasa kms_key_arn → usa default = null → SSE-S3 (AES256)
```

### Paso 5: Verificar

```bash
terraform apply

# Bucket de datos: cifrado SSE-KMS
aws s3api get-bucket-encryption \
  --bucket $(terraform output -raw data_bucket_id) \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault'
# {
#   "SSEAlgorithm": "aws:kms",
#   "KMSMasterKeyID": "arn:aws:kms:us-east-1:123456789012:key/..."
# }

# Bucket de logs: cifrado SSE-S3
aws s3api get-bucket-encryption \
  --bucket $(terraform output -raw logs_bucket_id) \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault'
# {
#   "SSEAlgorithm": "AES256"
# }
```

### Reflexión: ¿SSE-S3 o SSE-KMS?

| Aspecto | SSE-S3 (AES256) | SSE-KMS |
|---|---|---|
| Coste | Incluido en S3 | ~$1/mes por clave + $0.03/10K requests |
| Gestión de claves | Automática (AWS) | Controlada (puedes rotar, revocar, auditar) |
| Auditoría | Solo acceso a objetos | Cada uso de la clave aparece en CloudTrail |
| Permisos | Solo permisos S3 | Requiere permisos S3 + KMS |
| Caso de uso | Datos internos, logs | Datos regulados, PII, financieros |

En general: SSE-S3 es suficiente para la mayoría de casos. SSE-KMS es necesario cuando se requiere control granular sobre quién puede descifrar los datos o cuando hay requisitos de compliance que exigen claves gestionadas por el cliente.

---

## 8. Limpieza

Dado que el módulo tiene `prevent_destroy = true`, antes de destruir debes desactivar la protección temporalmente:

### Paso 1: Editar `modules/s3-bucket/main.tf`

Cambiar `prevent_destroy = true` a `prevent_destroy = false`:

```hcl
lifecycle {
  prevent_destroy = false
}
```

### Paso 2: Destruir

```bash
terraform destroy \
  -var="region=us-east-1"
```

### Paso 3: Restaurar la protección

Si vas a seguir usando el módulo, revierte el cambio a `prevent_destroy = true`.

> **Nota:** En producción, este paso manual es **intencional** — obliga a pensar dos veces antes de destruir datos críticos. No destruyas el bucket S3 del lab02.

---

## 9. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

LocalStack emula S3 completamente en Community Edition. La versión localstack usa `prevent_destroy = false` para facilitar la limpieza en entorno local.

---

## Buenas prácticas aplicadas

- **Tríada estándar de módulo (`main.tf`, `variables.tf`, `outputs.tf`)**: separar la declaración de recursos, la interfaz de entrada y la de salida en ficheros independientes facilita la lectura y el mantenimiento del módulo.
- **`merge()` para etiquetado en capas**: combinar tags del módulo con tags del llamador permite que el consumidor añada contexto sin perder los tags obligatorios impuestos por el módulo.
- **`prevent_destroy = true` en buckets de datos**: proteger los buckets de borrado accidental durante un `terraform destroy` mal ejecutado evita pérdida de datos irreversible.
- **Outputs con `value` y `description`**: documentar el propósito de cada output hace que el módulo sea autoexplicativo para los consumidores que solo leen la interfaz.
- **Invocación múltiple del mismo módulo**: usar el mismo módulo para crear el bucket de aplicación y el de logs demuestra la reutilización real y garantiza que ambos tienen los mismos estándares de seguridad.
- **Cifrado por defecto con SSE-KMS opcional**: proporcionar cifrado S3 SSE-S3 por defecto y permitir escalar a SSE-KMS para datos confidenciales hace que el módulo sea útil en todos los entornos sin complicar el caso de uso básico.

---

## Recursos

- [Terraform: Modules Overview](https://developer.hashicorp.com/terraform/language/modules)
- [Terraform: Module Structure](https://developer.hashicorp.com/terraform/language/modules/develop/structure)
- [Terraform: `merge()` function](https://developer.hashicorp.com/terraform/language/functions/merge)
- [Terraform: `lifecycle` meta-argument](https://developer.hashicorp.com/terraform/language/meta-arguments/lifecycle)
- [AWS: S3 Bucket Naming Rules](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html)
- [AWS: S3 Default Encryption](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-encryption.html)
- [AWS: S3 Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)
- [Terraform: `aws_s3_bucket`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket)
- [Terraform: `aws_s3_bucket_lifecycle_configuration`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration)
