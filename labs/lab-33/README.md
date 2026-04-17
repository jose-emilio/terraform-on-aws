# Laboratorio 33: El Data Lake Blindado: S3 con Seguridad y Ciclo de Vida

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 8 — Almacenamiento y Bases de Datos con Terraform](../../modulos/modulo-08/README.md)


## Visión general

En este laboratorio implementarás un bucket S3 de nivel empresarial que cubre privacidad, cifrado, resiliencia y ahorro automático de costes. Aprenderás a bloquear el acceso público con los cuatro controles de `aws_s3_bucket_public_access_block`, a cifrar con una **CMK propia** activando el **Bucket Key** para reducir un 99% las llamadas a KMS, a habilitar el **versionado** como escudo contra ransomware y errores humanos, a configurar un **ciclo de vida** que mueve datos a Glacier a los 90 días y los elimina al año, y a restringir el acceso mediante un **VPC Gateway Endpoint** con una bucket policy que deniega todo tráfico que no provenga del endpoint.

Toda la configuración del bucket se encapsula en un **módulo local reutilizable** (`modules/secure-bucket`), de forma que puede aplicarse a cualquier bucket del proyecto con un único bloque `module`.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Crear un módulo local Terraform con variables, recursos y outputs propios, e invocarlo desde el módulo raíz
- Aplicar `aws_s3_bucket_public_access_block` con los cuatro controles activos y entender qué bloquea cada uno
- Configurar cifrado SSE-KMS con `aws_kms_key` (CMK propia) y activar `bucket_key_enabled = true` para reducir el coste de llamadas a KMS
- Habilitar `aws_s3_bucket_versioning` y entender por qué las versiones protegen contra ransomware y borrados accidentales
- Definir una `aws_s3_bucket_lifecycle_configuration` con transición a Glacier y expiración para versiones actuales y no actuales
- Crear un `aws_vpc_endpoint` de tipo Gateway para S3 y asociar una bucket policy con la condición `aws:sourceVpce` que restringe el acceso al endpoint

## Requisitos Previos

- Terraform >= 1.5 instalado
- Laboratorio 2 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir
- Perfil AWS con permisos sobre S3, KMS, EC2 (VPC) e IAM
- LocalStack en ejecución (para la sección de LocalStack)

---

## Conceptos Clave

### Módulo local: encapsulación de controles de seguridad

Un módulo local agrupa recursos relacionados bajo una interfaz clara (variables + outputs). En este laboratorio, `modules/secure-bucket` encapsula los seis recursos de seguridad del bucket. El módulo raíz (`main.tf`) lo invoca con un bloque `module`, pasando únicamente los parámetros que varían:

```hcl
module "datalake" {
  source = "./modules/secure-bucket"

  bucket_name     = local.bucket_name
  project         = var.project
  tags            = local.tags
  vpc_endpoint_id = aws_vpc_endpoint.s3.id
  transition_days = var.transition_days
  expiration_days = var.expiration_days
}
```

El módulo puede reutilizarse para crear un segundo bucket (por ejemplo, `logs`) añadiendo otro bloque `module` con distintos valores, sin duplicar código.

### Bloqueo de acceso público: cuatro controles

`aws_s3_bucket_public_access_block` aplica cuatro controles independientes:

| Control | Qué bloquea |
|---|---|
| `block_public_acls` | Rechaza `PutBucketAcl` y `PutObjectAcl` que otorguen acceso público |
| `ignore_public_acls` | Ignora ACLs públicas ya existentes en el bucket |
| `block_public_policy` | Rechaza `PutBucketPolicy` si la política concede acceso público |
| `restrict_public_buckets` | Bloquea el acceso anónimo aunque la política lo permita |

Los cuatro activos en conjunto garantizan que ningún objeto sea accesible públicamente, incluso si se aplica una ACL o política errónea.

### SSE-KMS con Customer Managed Key y Bucket Key

Con `sse_algorithm = "aws:kms"` y una CMK propia, cada objeto se cifra con una **Data Encryption Key** (DEK) generada por KMS. La CMK cifra la DEK — nunca el objeto directamente.

**Bucket Key** (`bucket_key_enabled = true`) cambia este modelo: S3 genera una Bucket Key derivada de la CMK y la almacena en el bucket. Las llamadas a KMS se hacen solo para obtener o renovar la Bucket Key, no por objeto. Resultado: hasta un 99% menos de llamadas a KMS, con el consiguiente ahorro en costes y reducción de latencia.

```hcl
rule {
  bucket_key_enabled = true
  apply_server_side_encryption_by_default {
    sse_algorithm     = "aws:kms"
    kms_master_key_id = aws_kms_key.s3.arn
  }
}
```

### Versionado: protección contra ransomware y errores humanos

Con versionado habilitado, S3 preserva todas las versiones de cada objeto. Un ataque de ransomware (que cifra y sobreescribe los objetos) crea nuevas versiones con el contenido cifrado, pero las versiones originales permanecen intactas y recuperables. Un borrado accidental crea un "delete marker" — la versión anterior se restaura eliminando el marker.

```hcl
resource "aws_s3_bucket_versioning" "main" {
  bucket = aws_s3_bucket.main.id
  versioning_configuration {
    status = "Enabled"
  }
}
```

### Ciclo de vida: FinOps automático

`aws_s3_bucket_lifecycle_configuration` define reglas que AWS aplica automáticamente. La regla de este laboratorio actúa sobre todos los objetos (`filter {}`) y sobre sus versiones no actuales:

```hcl
transition {
  days          = 90    # versión actual → Glacier tras 90 días
  storage_class = "GLACIER"
}

expiration {
  days = 365            # versión actual → eliminada tras 365 días
}

noncurrent_version_transition {
  noncurrent_days = 90  # versiones antiguas → Glacier
  storage_class   = "GLACIER"
}

noncurrent_version_expiration {
  noncurrent_days = 365 # versiones antiguas → eliminadas
}
```

Glacier Flexible Retrieval cuesta ~$0.004/GB/mes frente a ~$0.023/GB/mes de S3 Standard — un ahorro del 83% para datos de acceso infrecuente.

### VPC Gateway Endpoint y bucket policy con sourceVpce

Un Gateway Endpoint de S3 es **gratuito** (a diferencia del Interface Endpoint). Inyecta una ruta en la route table de la subred para que el tráfico S3 no salga a internet. Su ID puede usarse en la bucket policy como condición:

```hcl
Condition = {
  StringNotEquals = {
    "aws:sourceVpce" = "vpce-xxxxxxxxxxxxxxxxx"
  }
}
```

Con `Effect = "Deny"` y esta condición, cualquier petición que no provenga del endpoint es denegada, incluso si el principal tiene permisos IAM suficientes. Es la forma más efectiva de garantizar que solo el tráfico interno de la VPC pueda acceder a los datos.

> **Nota**: la bucket policy de este laboratorio incluye una excepción para la cuenta raíz (`arn:aws:iam::ACCOUNT_ID:root`) que permite a Terraform gestionar el bucket desde fuera de la VPC. En producción, sustituye esta excepción por el ARN específico del rol de despliegue y elimina el acceso desde fuera de la VPC una vez completada la configuración inicial.

---

## Estructura del proyecto

```
lab33/
├── aws/
│   ├── aws.s3.tfbackend      # Parámetros del backend S3 (sin bucket)
│   ├── providers.tf          # Backend S3, Terraform >= 1.5, provider AWS
│   ├── variables.tf          # region, project, transition_days, expiration_days
│   ├── main.tf               # VPC, subred, route table, VPC endpoint, módulo
│   ├── outputs.tf            # bucket_name, kms_key_arn, vpc_endpoint_id...
│   └── modules/
│       └── secure-bucket/
│           ├── variables.tf  # bucket_name, vpc_endpoint_id, transition/expiration_days
│           ├── main.tf       # KMS, bucket, public access block, SSE, versioning,
│           │                 # lifecycle, bucket policy
│           └── outputs.tf    # bucket_id, bucket_arn, kms_key_arn, kms_alias
└── localstack/
    ├── providers.tf          # Endpoints LocalStack (s3, kms, ec2, iam, sts)
    ├── variables.tf          # project = "lab33-local"
    ├── main.tf               # VPC, VPC endpoint, módulo
    ├── outputs.tf
    ├── README.md             # Limitaciones + comandos awslocal
    └── modules/
        └── secure-bucket/    # Misma interfaz; anotaciones de limitaciones LocalStack
```

> **Nota**: `function.zip` y `layer.zip` son artefactos generados durante el plan/apply. No los versiones en Git — añádelos a `.gitignore`.

---

## 1. Despliegue en AWS Real

### 1.1 Arquitectura

```
┌──────────────────────────────────────────────────────────────────────────────┐
│  VPC: lab33-vpc (10.29.0.0/16)                                               │
│                                                                              │
│  ┌────────────────────────────┐                                              │
│  │ Subred privada             │                                              │
│  │ 10.29.1.0/24 · us-east-1a │────── Route Table ──────────────────────────► │
│  └────────────────────────────┘                  VPC Gateway Endpoint S3     │
└─────────────────────────────────────────────────────────│────────────────────┘
                                                          │
                          ┌───────────────────────────────▼────────────────────┐
                          │  Módulo secure-bucket                              │
                          │                                                    │
                          │  aws_kms_key (CMK, rotación anual)                 │
                          │  aws_kms_alias  alias/lab33-datalake               │
                          │                                                    │
                          │  aws_s3_bucket  lab33-datalake-<ACCOUNT_ID>        │
                          │  ├── public_access_block  (4 controles activos)    │
                          │  ├── encryption  SSE-KMS + Bucket Key              │
                          │  ├── versioning  Enabled                           │
                          │  ├── lifecycle → Glacier(90d) → Delete(365d)       │
                          │  └── policy      Deny si aws:sourceVpce ≠ endpoint │
                          └────────────────────────────────────────────────────┘

  data "aws_caller_identity" → Account ID → nombre del bucket (único global)
  module "datalake"          → invoca modules/secure-bucket con los parámetros
```

### 1.2 Módulo secure-bucket

El módulo recibe el ID del endpoint como variable y lo inyecta en la bucket policy:

```hcl
# modules/secure-bucket/main.tf (fragmento)
resource "aws_s3_bucket_policy" "main" {
  bucket     = aws_s3_bucket.main.id
  depends_on = [aws_s3_bucket_public_access_block.main]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyNonVPCEndpoint"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [aws_s3_bucket.main.arn, "${aws_s3_bucket.main.arn}/*"]
      Condition = {
        StringNotEquals = { "aws:sourceVpce" = var.vpc_endpoint_id }
        ArnNotLike      = { "aws:PrincipalArn" = local.account_root_arn }
      }
    }]
  })
}
```

El módulo raíz crea el endpoint y se lo pasa al módulo:

```hcl
# main.tf
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.main.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private.id]
}

module "datalake" {
  source          = "./modules/secure-bucket"
  vpc_endpoint_id = aws_vpc_endpoint.s3.id
  # ...
}
```

### 1.3 Inicialización y despliegue

```bash
export BUCKET="terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"

# Desde lab33/aws/
terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform plan
terraform apply
```

Al finalizar, los outputs mostrarán:

```
bucket_arn           = "arn:aws:s3:::lab33-datalake-123456789012"
bucket_name          = "lab33-datalake-123456789012"
kms_alias            = "alias/lab33-datalake"
kms_key_arn          = "arn:aws:kms:us-east-1:123456789012:key/..."
vpc_endpoint_id      = "vpce-0abc123..."
vpc_id               = "vpc-0abc123..."
```

### 1.4 Verificar el sistema

**Paso 1** — Verifica los cuatro controles de acceso público:

```bash
BUCKET=$(terraform output -raw bucket_name)

aws s3api get-public-access-block --bucket "$BUCKET" \
  --query 'PublicAccessBlockConfiguration'
```

Los cuatro valores deben ser `true`.

**Paso 2** — Verifica el cifrado SSE-KMS y Bucket Key:

```bash
aws s3api get-bucket-encryption --bucket "$BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules[0]'
```

Busca `"SSEAlgorithm": "aws:kms"` y `"BucketKeyEnabled": true`.

**Paso 3** — Verifica el versionado:

```bash
aws s3api get-bucket-versioning --bucket "$BUCKET"
```

Debe mostrar `"Status": "Enabled"`.

**Paso 4** — Verifica la lifecycle configuration:

```bash
aws s3api get-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --query 'Rules[0].{ID:ID,Estado:Status,Transicion:Transitions[0],Expiracion:Expiration}'
```

**Paso 5** — Verifica la CMK y su rotación:

```bash
KMS_ARN=$(terraform output -raw kms_key_arn)

aws kms describe-key --key-id "$KMS_ARN" \
  --query 'KeyMetadata.{KeyId:KeyId,Estado:KeyState,Rotacion:KeyRotationStatus}'

# La rotación debe estar habilitada
aws kms get-key-rotation-status --key-id "$KMS_ARN"
```

**Paso 6** — Verifica el VPC Endpoint y su ruta inyectada:

```bash
aws ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$(terraform output -raw vpc_endpoint_id)" \
  --query 'VpcEndpoints[0].{ID:VpcEndpointId,Estado:State,Tipo:VpcEndpointType,RouteTables:RouteTableIds}'
```

**Paso 7** — Sube un objeto y verifica el cifrado aplicado:

```bash
echo "datos de prueba" > /tmp/test.txt
aws s3 cp /tmp/test.txt s3://"$BUCKET"/test.txt

# Verifica que el objeto está cifrado con la CMK
aws s3api head-object --bucket "$BUCKET" --key test.txt \
  --query '{ServerSideEncryption:ServerSideEncryption,KMSKeyId:SSEKMSKeyId}'
```

**Paso 8** — Verifica el versionado subiendo el mismo objeto dos veces:

```bash
echo "version 2" > /tmp/test.txt
aws s3 cp /tmp/test.txt s3://"$BUCKET"/test.txt

# Lista las versiones — deben aparecer 2 versiones de test.txt
aws s3api list-object-versions --bucket "$BUCKET" \
  --query 'Versions[*].{Key:Key,VersionId:VersionId,Latest:IsLatest}' --output table
```

**Paso 9** — Verifica la bucket policy:

```bash
aws s3api get-bucket-policy --bucket "$BUCKET" \
  --query Policy --output text | python3 -m json.tool
```

Confirma que el `Statement` tiene `Effect: Deny`, `aws:sourceVpce` con el ID del endpoint y `ArnNotLike` con el ARN raíz de la cuenta.

---

> **Antes de comenzar los retos**, verifica que `get-bucket-encryption` muestra `BucketKeyEnabled: true` y que `list-object-versions` devuelve dos versiones de `test.txt`.

## 2. Reto 1: S3 Access Logging

El bucket de datos no registra quién accede a sus objetos. Añadir **S3 Access Logging** crea un log por cada petición HTTP recibida — imprescindible en entornos regulados (PCI-DSS, HIPAA) para detectar accesos no autorizados.

### Requisitos

1. Crea un segundo bucket (`${var.project}-logs-<ACCOUNT_ID>`) para almacenar los logs. Este bucket debe tener:
   - `aws_s3_bucket_public_access_block` con los cuatro controles activos.
   - Cifrado SSE-S3 (`AES256`) — no es necesario KMS para el bucket de logs.
2. Añade un `aws_s3_bucket_logging` al bucket principal que apunte al bucket de logs con `target_prefix = "access-logs/"`.
3. Añade un output `log_bucket_name` con el nombre del bucket de logs.

### Criterios de éxito

- `aws s3api get-bucket-logging --bucket "$BUCKET"` muestra el bucket de destino y el prefijo.
- Tras subir un objeto al bucket principal, aparecen logs en `s3://LOGS_BUCKET/access-logs/` (puede tardar hasta 1 hora en AWS real).
- Puedes explicar por qué el bucket de logs debe ser un bucket separado y no el mismo bucket principal.

[Ver solución →](#4-solución-de-los-retos)

---

## 3. Reto 2: S3 Object Lock en modo GOVERNANCE

El versionado protege contra borrados accidentales, pero un administrador con permisos suficientes puede borrar versiones individuales. **Object Lock** añade protección WORM (Write Once Read Many): una vez bloqueado, ningún usuario — ni siquiera el root de la cuenta — puede borrar el objeto antes de que expire el periodo de retención.

### Requisitos

1. Object Lock solo puede habilitarse al crear el bucket y no puede añadirse después. Por eso **no es posible reutilizar el bucket principal** creado por el módulo `secure-bucket` — debes crear un **nuevo bucket independiente** con `object_lock_enabled = true` en `aws_s3_bucket`.
2. Configura `aws_s3_bucket_object_lock_configuration` con:
   - `rule.default_retention.mode = "GOVERNANCE"` (permite que usuarios con permiso `s3:BypassGovernanceRetention` eliminen objetos bajo circunstancias especiales).
   - `rule.default_retention.days = 7` (7 días de retención por defecto).
3. Añade un output `object_lock_bucket_name` con el nombre del nuevo bucket.

### Criterios de éxito

- `aws s3api get-object-lock-configuration --bucket "$OBJECT_LOCK_BUCKET"` muestra `ObjectLockEnabled: Enabled` con `Mode: GOVERNANCE` y `Days: 7`.
- Sube un objeto al bucket. Intenta borrarlo sin el permiso `BypassGovernanceRetention` — debe fallar con `AccessDenied`.
- Puedes explicar la diferencia entre `GOVERNANCE` (bypasseable con permiso especial) y `COMPLIANCE` (nadie puede borrar, ni root).

[Ver solución →](#4-solución-de-los-retos)

---

## 4. Solución de los Retos

> Intenta resolver los retos antes de leer esta sección.

### Solución Reto 1 — S3 Access Logging

El bucket de logs y el recurso `aws_s3_bucket_logging` se añaden en el **módulo raíz** (`aws/main.tf`), no dentro de `modules/secure-bucket`. El módulo `secure-bucket` encapsula los controles de un único bucket; el bucket de logs es un recurso independiente que coexiste con él. La referencia al bucket principal se obtiene a través del output `module.datalake.bucket_id`.

Añade en `aws/main.tf`:

```hcl
locals {
  log_bucket_name = "${var.project}-logs-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket" "logs" {
  bucket = local.log_bucket_name
  tags   = local.tags
}

resource "aws_s3_bucket_public_access_block" "logs" {
  bucket                  = aws_s3_bucket.logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "logs" {
  bucket = aws_s3_bucket.logs.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_logging" "main" {
  bucket        = module.datalake.bucket_id
  target_bucket = aws_s3_bucket.logs.id
  target_prefix = "access-logs/"
}
```

Añade en `aws/outputs.tf`:

```hcl
output "log_bucket_name" {
  description = "Nombre del bucket de logs de acceso S3"
  value       = aws_s3_bucket.logs.id
}
```

Verifica:

```bash
terraform apply

# 1. Confirma que el logging está configurado en el bucket principal
BUCKET=$(terraform output -raw bucket_name)
LOGS=$(terraform output -raw log_bucket_name)

aws s3api get-bucket-logging \
  --bucket "$BUCKET" \
  --query 'LoggingEnabled'
# Debe mostrar: {"TargetBucket": "...-logs-...", "TargetPrefix": "access-logs/"}

# 2. Genera actividad en el bucket principal para producir logs
aws s3 cp /etc/hostname s3://"$BUCKET"/test-logging.txt
aws s3 ls s3://"$BUCKET"/
aws s3api get-object --bucket "$BUCKET" --key test-logging.txt /tmp/downloaded.txt

# 3. Espera unos minutos (S3 Access Logging puede tardar entre 1 y 60 minutos
#    en entregar los primeros registros; no es en tiempo real).
sleep 120

# 4. Lista los logs entregados en el bucket de destino
aws s3 ls s3://"$LOGS"/access-logs/ --recursive
# Deben aparecer objetos con nombres del tipo:
#   access-logs/2024-01-15-12-34-56-ABCDEF1234567890

# 5. Descarga y examina un log
LOG_KEY=$(aws s3 ls s3://"$LOGS"/access-logs/ --recursive \
  | sort | tail -1 | awk '{print $4}')

aws s3 cp s3://"$LOGS"/"$LOG_KEY" /tmp/access.log
cat /tmp/access.log
# Cada línea contiene: fecha, bucket, IP, solicitante, operación, clave, código HTTP, etc.
# Ejemplo de línea:
#   510547572113 lab33-datalake-... [15/Jan/2024:12:34:56 +0000] 1.2.3.4
#   arn:aws:iam::...:user/joseemilio REST.PUT.OBJECT test-logging.txt
#   "PUT /test-logging.txt HTTP/1.1" 200 - 8 8 12 11 ...
```

> **Nota**: En AWS real los logs pueden tardar hasta una hora. Si tras 15 minutos no aparece nada, verifica que el bucket de logs existe y que `get-bucket-logging` muestra la configuración correcta.

El bucket de logs debe ser **separado** del bucket principal porque si ambos fueran el mismo, cada log generaría a su vez un evento de escritura que generaría otro log — un bucle infinito que crearía millones de objetos y facturas elevadas.

### Solución Reto 2 — S3 Object Lock en modo GOVERNANCE

El bucket WORM y sus recursos asociados van en el **módulo raíz** (`aws/main.tf`), no dentro de `modules/secure-bucket`. Hay dos razones:

1. `object_lock_enabled = true` debe estar presente **en el momento de crear el bucket** — no es una configuración que se pueda añadir después. Añadirlo al módulo `secure-bucket` obligaría a recrear el bucket principal existente, destruyendo todos sus datos.
2. El bucket WORM tiene un propósito distinto al data lake principal. Meterlo en el mismo módulo mezclaría responsabilidades y añadiría parámetros opcionales que complican la interfaz del módulo sin beneficio real.

Añade en `aws/main.tf`:

```hcl
resource "aws_s3_bucket" "worm" {
  bucket              = "${var.project}-worm-${data.aws_caller_identity.current.account_id}"
  object_lock_enabled = true
  tags                = local.tags
}

resource "aws_s3_bucket_public_access_block" "worm" {
  bucket                  = aws_s3_bucket.worm.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "worm" {
  bucket = aws_s3_bucket.worm.id
  versioning_configuration {
    status = "Enabled"  # Object Lock requiere versionado
  }
}

resource "aws_s3_bucket_object_lock_configuration" "worm" {
  bucket = aws_s3_bucket.worm.id

  rule {
    default_retention {
      mode = "GOVERNANCE"
      days = 7
    }
  }
}
```

Añade en `aws/outputs.tf`:

```hcl
output "object_lock_bucket_name" {
  description = "Nombre del bucket con Object Lock en modo GOVERNANCE"
  value       = aws_s3_bucket.worm.id
}
```

Verifica:

```bash
terraform apply

WORM_BUCKET=$(terraform output -raw object_lock_bucket_name)

aws s3api get-object-lock-configuration --bucket "$WORM_BUCKET"

# Sube un objeto e intenta borrarlo inmediatamente
echo "dato protegido" | aws s3 cp - s3://"$WORM_BUCKET"/locked.txt

VERSION_ID=$(aws s3api list-object-versions \
  --bucket "$WORM_BUCKET" --prefix locked.txt \
  --query 'Versions[0].VersionId' --output text)

# Intento de borrado — falla con AccessDenied en modo GOVERNANCE
aws s3api delete-object \
  --bucket "$WORM_BUCKET" \
  --key locked.txt \
  --version-id "$VERSION_ID"

# Para borrar el objeto en modo GOVERNANCE es necesario:
#   1. Tener el permiso s3:BypassGovernanceRetention en la política IAM del usuario.
#   2. Enviar el header x-amz-bypass-governance-retention: true.
# La AWS CLI lo hace con el flag --bypass-governance-retention.

# Borrar la versión actual con bypass
aws s3api delete-object \
  --bucket "$WORM_BUCKET" \
  --key locked.txt \
  --version-id "$VERSION_ID" \
  --bypass-governance-retention

# Si hay delete markers u otras versiones, listarlas y borrarlas todas
aws s3api list-object-versions \
  --bucket "$WORM_BUCKET" \
  --prefix locked.txt \
  --query '{Versions: Versions[*].{Key:Key,VersionId:VersionId}, DeleteMarkers: DeleteMarkers[*].{Key:Key,VersionId:VersionId}}'

# Para borrar todas las versiones y delete markers con bypass, itera
# sobre cada VersionId con delete-object (singular) en lugar de usar
# delete-objects (plural), que puede causar MalformedXML al convertir
# el payload JSON a XML internamente.
```

**GOVERNANCE vs COMPLIANCE**: en modo `GOVERNANCE`, un usuario con el permiso `s3:BypassGovernanceRetention` puede borrar el objeto enviando el header `x-amz-bypass-governance-retention: true`. En modo `COMPLIANCE`, nadie puede borrar el objeto antes de que expire la retención — ni el root de la cuenta. Para datos con requisitos regulatorios estrictos (registros financieros, historiales médicos) se usa `COMPLIANCE`.

---

## Verificación final

```bash
# Confirmar que el acceso publico esta bloqueado
aws s3api get-public-access-block \
  --bucket $(terraform output -raw bucket_name) \
  --query 'PublicAccessBlockConfiguration'

# Verificar cifrado con CMK y Bucket Key
aws s3api get-bucket-encryption \
  --bucket $(terraform output -raw bucket_name) \
  --query 'ServerSideEncryptionConfiguration.Rules[0]'

# Comprobar que el versionado esta habilitado
aws s3api get-bucket-versioning \
  --bucket $(terraform output -raw bucket_name) \
  --query 'Status'
# Esperado: "Enabled"

# Verificar el VPC Gateway Endpoint creado
aws ec2 describe-vpc-endpoints \
  --filters "Name=service-name,Values=com.amazonaws.us-east-1.s3" \
  --query 'VpcEndpoints[*].{ID:VpcEndpointId,State:State}' \
  --output table
```

---

## 5. Limpieza

```bash
# Vaciar el bucket antes de destruir (requiere borrar las versiones)
BUCKET=$(terraform output -raw bucket_name)

aws s3api delete-objects \
  --bucket "$BUCKET" \
  --delete "$(aws s3api list-object-versions \
    --bucket "$BUCKET" \
    --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
    --output json)"

# Destruir la infraestructura
# Desde lab33/aws/
terraform destroy
```

> **Importante**: la CMK tiene un `deletion_window_in_days = 7`. Tras el `terraform destroy`, la clave quedará en estado `PendingDeletion` durante 7 días antes de ser eliminada definitivamente. Durante ese periodo no se puede usar para cifrar ni descifrar.

---

## 6. LocalStack

Los recursos S3 (bucket, public access block, versionado, lifecycle) y KMS se crean correctamente en LocalStack Community. La condición `aws:sourceVpce` de la bucket policy no se evalúa realmente — el bucket es accesible sin restricción de endpoint.

Consulta [localstack/README.md](localstack/README.md) para instrucciones detalladas y tabla de limitaciones.

---

## 7. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| `aws_s3_bucket_public_access_block` | Bloqueo real de ACLs y políticas públicas | Configuración aceptada y verificable |
| SSE-KMS + Bucket Key | Cifrado real; Bucket Key reduce llamadas KMS ~99% | Configuración aceptada; sin cifrado real |
| Versionado | Versiones inmutables preservadas en S3 | Versiones creadas correctamente |
| Lifecycle (→Glacier, →Delete) | AWS mueve automáticamente las clases de almacenamiento | Reglas aceptadas; sin transición real |
| VPC Gateway Endpoint | Ruta inyectada en route table; tráfico S3 nunca sale a internet | Recurso creado; sin enrutamiento real |
| Bucket policy (`aws:sourceVpce`) | Deniega efectivamente el acceso fuera del endpoint | Política aceptada; condición no evaluada |
| CMK + rotación anual | Rotación real del material criptográfico | Clave creada; sin rotación real |
| Módulo `secure-bucket` | Todos los recursos funcionan | Todos los recursos se crean sin error |

---

## Buenas prácticas aplicadas

- **Un módulo por conjunto de controles de seguridad**: encapsular todos los recursos de seguridad del bucket en un módulo evita olvidar aplicar alguno (por ejemplo, el `public_access_block`) al crear un nuevo bucket. El módulo actúa como lista de comprobación en código.
- **`enable_key_rotation = true` siempre en CMKs**: la rotación automática anual del material criptográfico es gratuita, no cambia el ARN de la clave y es una buena práctica de seguridad requerida por la mayoría de frameworks de cumplimiento.
- **`depends_on` en el lifecycle hacia el versionado**: S3 puede devolver un error si la lifecycle rule se aplica antes de que el versionado esté activo. El `depends_on` garantiza el orden correcto.
- **`depends_on` en la bucket policy hacia el public access block**: `block_public_policy = true` rechaza políticas que concedan acceso público; si la policy se aplica antes del block, puede fallar con un error inesperado.
- **Bucket de logs separado**: el bucket de destino de S3 Access Logging nunca debe ser el mismo que el bucket origen — generaría un bucle infinito de logs.
- **Gateway Endpoint es gratuito**: a diferencia del Interface Endpoint (que cobra por hora de ENI y por GB procesado), el Gateway Endpoint de S3 y DynamoDB no tiene coste. Úsalo siempre que haya tráfico S3 desde una VPC.
- **Excepción de la bucket policy en producción**: la excepción para la cuenta raíz que incluye este laboratorio es solo para facilitar la gestión desde Terraform. En producción, reemplázala por el ARN específico del rol de despliegue de CI/CD y ejecuta Terraform desde un runner dentro de la VPC o con acceso vía VPC endpoint.

---

## Recursos

- [AWS — S3 Block Public Access](https://docs.aws.amazon.com/AmazonS3/latest/userguide/access-control-block-public-access.html)
- [AWS — SSE-KMS y Bucket Key](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-key.html)
- [AWS — S3 Versioning](https://docs.aws.amazon.com/AmazonS3/latest/userguide/Versioning.html)
- [AWS — S3 Lifecycle Configuration](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lifecycle-mgmt.html)
- [AWS — VPC Gateway Endpoint para S3](https://docs.aws.amazon.com/vpc/latest/privatelink/vpc-endpoints-s3.html)
- [AWS — S3 Object Lock](https://docs.aws.amazon.com/AmazonS3/latest/userguide/object-lock.html)
- [Terraform — aws_s3_bucket_public_access_block](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_public_access_block)
- [Terraform — aws_s3_bucket_lifecycle_configuration](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/s3_bucket_lifecycle_configuration)
- [Terraform — aws_vpc_endpoint](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_endpoint)
