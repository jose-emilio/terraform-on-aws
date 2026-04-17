# Laboratorio 13 — Cifrado Transversal con KMS y Jerarquía de Llaves

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 4 — Seguridad e IAM con Terraform](../../modulos/modulo-04/README.md)


## Visión general

Las llaves de cifrado son la raíz de confianza de cualquier arquitectura segura.
Este laboratorio implementa una **Customer Managed Key (CMK)** en AWS KMS y la
utiliza como llave maestra compartida para cifrar datos en reposo en dos servicios:
un volumen EBS y un bucket S3. La Key Policy separa explícitamente a los
administradores de la llave (que gestionan su ciclo de vida) de las aplicaciones
(que solo pueden cifrar y descifrar datos).

## Objetivos

- Crear una CMK con rotación automática anual.
- Asignar un alias como capa de indirección para facilitar la sustitución de la llave.
- Diseñar una Key Policy con tres roles segregados: root, administradores y usuarios.
- Forzar el cifrado SSE-KMS en un bucket S3 mediante política de bucket.
- Cifrar un volumen EBS con la CMK personalizada en lugar de la llave gestionada por el servicio.

## Requisitos previos

- Terraform ≥ 1.5 instalado.
- AWS CLI configurado con perfil `default`.
- Permisos IAM sobre KMS, S3 y EC2 (EBS).
- Bucket de estado creado en el lab02.

## Arquitectura

```
                    ┌───────────────── KMS ─────────────────────────┐
                    │                                               │
                    │  aws_kms_key "main"                           │
                    │    enable_key_rotation = true (anual)         │
                    │    deletion_window     = 7 días               │
                    │    Key Policy:                                │
                    │      Root account  → kms:*                    │
                    │      Administradores → gestión ciclo de vida  │
                    │      Usuarios finales → Encrypt / Decrypt     │
                    │                                               │
                    │  aws_kms_alias "main"                         │
                    │    alias/lab13-main ──► Key ID (UUID)         │
                    │                                               │
                    └──────────┬──────────────────┬─────────────────┘
                               │                  │
                    ┌──── EBS ─▼──────┐  ┌── S3 ──▼─────────────────┐
                    │                 │  │                          │
                    │ aws_ebs_volume  │  │ aws_s3_bucket            │
                    │  type  = gp3    │  │  SSE-KMS → alias/lab13   │
                    │  encrypted      │  │  bucket_key_enabled      │
                    │  kms_key_id     │  │  Bucket Policy:          │
                    │  = alias ARN    │  │    DenyNonKMSUploads     │
                    │                 │  │    DenyWrongKMSKey       │
                    └─────────────────┘  └──────────────────────────┘
```

## Conceptos clave

### Customer Managed Key vs llave gestionada por servicio

| Característica | CMK | aws/ebs, aws/s3 |
|----------------|-----|-----------------|
| Control de Key Policy | Total | Ninguno |
| Rotación configurable | Sí (`enable_key_rotation`) | AWS gestiona |
| Auditoría en CloudTrail | Cada uso registrado | Limitada |
| Compartir entre servicios | Sí | No (una por servicio) |
| Coste | ~1 $/mes + uso | Sin cargo extra |

### Key Policy — tres roles segregados

La segregación es el principio central de este laboratorio. Evita que un administrador de infraestructura pueda leer datos cifrados de producción:

```
Root account   → kms:* (recuperación de emergencia)
Administradores → gestión del ciclo de vida (sin Encrypt/Decrypt)
Usuarios finales → Encrypt, Decrypt, GenerateDataKey (sin gestión)
```

Sin el statement de root, si se elimina accidentalmente al último administrador la llave queda **irrecuperable** — AWS no puede restaurar el acceso.

### Alias — capa de indirección

```
Código/Configuración
       │
       ▼
alias/lab13-main  ──apunta──►  Key ID: abc123...
                               (puede cambiar sin tocar el código)
```

Al rotar o sustituir la CMK, basta con actualizar el target del alias. Todo lo que referencie `alias/lab13-main` seguirá funcionando.

### Bucket Key — reducción de coste KMS

Con `bucket_key_enabled = true`, S3 genera una llave de datos temporal a nivel de bucket. Solo se llama a KMS una vez por llave de bucket (no por objeto), reduciendo el coste de KMS hasta un **99%** en buckets con muchos objetos.

### Cifrado forzoso en S3 — Bucket Policy

La configuración SSE por defecto no impide subir objetos sin cifrado si el cliente lo omite explícitamente. La Bucket Policy añade dos `Deny` explícitos:

1. `DenyNonKMSUploads`: bloquea objetos subidos sin `x-amz-server-side-encryption: aws:kms`.
2. `DenyWrongKMSKey`: bloquea objetos cifrados con una CMK diferente a la del laboratorio.

## Estructura del proyecto

```
lab13/
├── README.md
├── aws/
│   ├── providers.tf       # Provider AWS ~> 6.0 + backend S3
│   ├── variables.tf       # region, project, admin_principal_arns, app_principal_arns, ebs_volume_size_gb
│   ├── main.tf            # CMK, alias, Key Policy, EBS, S3
│   ├── outputs.tf         # ARNs, IDs y comandos de verificación
│   └── aws.s3.tfbackend   # key = "lab13/terraform.tfstate"
└── localstack/
    ├── README.md          # Guía de despliegue en LocalStack
    ├── providers.tf
    ├── variables.tf
    ├── main.tf            # CMK, alias, S3 (sin EBS ni bucket policy)
    └── outputs.tf
```

## Despliegue en AWS real

```bash
cd labs/lab13/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"

terraform plan
terraform apply
```

> Por defecto, `admin_principal_arns` está vacío y Terraform asigna el caller
> actual como administrador. Para añadir más administradores o usuarios finales:
>
> ```bash
> terraform apply \
>   -var='admin_principal_arns=["arn:aws:iam::123456789012:user/alice"]' \
>   -var='app_principal_arns=["arn:aws:iam::123456789012:role/my-app"]'
> ```

## Despliegue en LocalStack

Consulta [localstack/README.md](localstack/README.md) para instrucciones de
despliegue local con LocalStack y sus limitaciones respecto a AWS real.

## Verificación final

### 1. Confirmar la CMK y su rotación

```bash
KEY_ID=$(terraform output -raw cmk_key_id)

# Metadatos de la llave
aws kms describe-key --key-id $KEY_ID \
  --query 'KeyMetadata.{KeyId:KeyId,Enabled:Enabled,KeyState:KeyState,Description:Description}'

# Rotación automática habilitada
aws kms get-key-rotation-status --key-id $KEY_ID
# Esperado: { "KeyRotationEnabled": true }
```

### 2. Confirmar el alias

```bash
aws kms list-aliases --key-id $KEY_ID \
  --query 'Aliases[].AliasName'
# Esperado: ["alias/lab13-main"]
```

### 3. Verificar la Key Policy y la segregación

```bash
aws kms get-key-policy --key-id $KEY_ID --policy-name default \
  --query Policy --output text | python3 -m json.tool
```

Confirmar que aparecen los tres Sid: `EnableRootAccess`, `AllowKeyAdministration`, `AllowAWSServicesViaGrants`.

### 4. Comprobar el cifrado del volumen EBS

```bash
aws ec2 describe-volumes \
  --volume-ids $(terraform output -raw ebs_volume_id) \
  --query 'Volumes[0].{Encrypted:Encrypted,KmsKeyId:KmsKeyId,VolumeType:VolumeType}'
# Esperado: Encrypted = true, KmsKeyId contiene el ARN de la CMK
```

### 5. Comprobar el cifrado del bucket S3

```bash
aws s3api get-bucket-encryption --bucket $(terraform output -raw s3_bucket_name)
# Esperado: SSEAlgorithm = "aws:kms", KMSMasterKeyID = ARN de la CMK
```

### 6. Prueba de cifrado y descifrado con la CMK

```bash
ALIAS="alias/lab13-main"

# Cifrar texto plano
# --cli-binary-format raw-in-base64-out: la CLI v2 acepta texto plano directamente
CIPHER=$(aws kms encrypt \
  --key-id $ALIAS \
  --plaintext "hola-lab13" \
  --cli-binary-format raw-in-base64-out \
  --query CiphertextBlob --output text)

echo "CiphertextBlob: $CIPHER"

# Descifrar (round-trip)
# $CIPHER ya es base64 — decrypt no necesita --cli-binary-format
# La salida Plaintext también llega en base64, de ahí el | base64 -d
aws kms decrypt \
  --ciphertext-blob "$CIPHER" \
  --query Plaintext --output text | base64 -d
# Esperado: hola-lab13
```

### 7. Prueba de cifrado forzoso en S3

```bash
BUCKET=$(terraform output -raw s3_bucket_name)

# Subida correcta: con SSE-KMS y la CMK del lab
echo "dato-secreto" | aws s3 cp - s3://$BUCKET/correcto.txt \
  --sse aws:kms --sse-kms-key-id alias/lab13-main
# Esperado: upload OK

# Subida bloqueada: sin cifrado
echo "dato-en-claro" | aws s3 cp - s3://$BUCKET/bloqueado.txt
# Esperado: upload failed ... An error occurred (AccessDenied) ... with an explicit deny in a resource-based policy
```

### 8. Verificar el cabecera de cifrado en el objeto subido

```bash
aws s3api head-object --bucket $BUCKET --key correcto.txt \
  --query '{SSEAlgorithm:ServerSideEncryption,KMSKeyId:SSEKMSKeyId}'
# Esperado: SSEAlgorithm = "aws:kms", KMSKeyId = ARN de la CMK
```

## Retos

### Reto 1 — Segunda CMK para un entorno separado

Crea una segunda CMK (`aws_kms_key.secondary`) y su alias (`alias/lab13-staging`)
para representar el entorno de staging. La política de bucket debe actualizarse
para permitir objetos cifrados con **cualquiera de las dos CMKs**.

**Pistas:**
- Necesitarás una segunda `aws_kms_key` y `aws_kms_alias`.
- La condición `DenyWrongKMSKey` en la Bucket Policy deberá usar `ForAllValues:StringNotEquals` con una lista de ARNs permitidos.

#### Prueba

```bash
# La segunda CMK debe existir con alias propio
aws kms list-aliases | grep lab13

# Subir con la segunda CMK debe ser permitido
echo "dato-staging" | aws s3 cp - s3://$(terraform output -raw s3_bucket_name)/staging.txt \
  --sse aws:kms --sse-kms-key-id alias/lab13-staging
# Esperado: upload OK

# Subir sin cifrado sigue bloqueado
echo "dato" | aws s3 cp - s3://$(terraform output -raw s3_bucket_name)/sin-cifrar.txt
# Esperado: AccessDenied
```

### Reto 2 — Snapshot de EBS cifrado con la misma CMK

Crea un `aws_ebs_snapshot` del volumen EBS del laboratorio. El snapshot debe
heredar el cifrado de la CMK del laboratorio (no la llave por defecto).

```hcl
resource "aws_ebs_snapshot" "main" {
  # completar...
}
```

#### Prueba

```bash
SNAPSHOT_ID=$(terraform output -raw ebs_snapshot_id)

# El snapshot debe estar cifrado con la CMK del lab
aws ec2 describe-snapshots --snapshot-ids $SNAPSHOT_ID \
  --query 'Snapshots[0].{Encrypted:Encrypted,KmsKeyId:KmsKeyId,State:State}'
# Esperado: Encrypted = true, KmsKeyId = ARN de la CMK, State = "completed"
```

## Soluciones

<details>
<summary>Reto 1 — Segunda CMK y Bucket Policy actualizada</summary>

**Por qué se necesita una segunda CMK y no solo un segundo alias**

Un alias es simplemente un puntero a una CMK. Si apuntáramos dos alias a la
misma CMK, revocar el acceso a staging requeriría revocar también el acceso a
producción. Con dos CMKs independientes se puede deshabilitar, rotar o borrar
una sin afectar a la otra.

**Por qué cambia la condición de la Bucket Policy**

La política original usa `StringNotEqualsIfExists` con un único ARN:
si la llave del objeto no coincide con ese ARN, se deniega. Con dos CMKs
válidas no basta con ese operador — necesitamos `ForAllValues:StringNotEquals`
para evaluar que el ARN proporcionado **no está en ninguna de las posiciones**
de la lista permitida. Si el ARN coincide con cualquiera de los dos, la condición
no se cumple y el `Deny` no se aplica.

```
ForAllValues:StringNotEquals  →  niega si el valor NO está en la lista
                               →  permite si el valor SÍ está en la lista
```

**Código a añadir en `main.tf`:**

```hcl
# Segunda CMK para el entorno de staging.
# Reutiliza el mismo data source de Key Policy (data.aws_iam_policy_document.cmk_policy)
# porque los administradores y el acceso root son los mismos en ambos entornos.
resource "aws_kms_key" "secondary" {
  description             = "CMK de staging del lab13"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.cmk_policy.json

  tags = merge(local.tags, { Name = "${var.project}-cmk-staging" })
}

# Alias independiente: alias/lab13-staging apunta a la CMK de staging.
# Si en el futuro se sustituye la CMK de staging, basta con actualizar
# target_key_id aquí sin tocar ninguna otra referencia.
resource "aws_kms_alias" "secondary" {
  name          = "alias/${var.project}-staging"
  target_key_id = aws_kms_key.secondary.key_id
}

# Bucket Policy actualizada: permite objetos cifrados con cualquiera de las dos CMKs.
# Se reemplaza el recurso aws_s3_bucket_policy existente (mismo nombre de recurso).
resource "aws_s3_bucket_policy" "enforce_kms" {
  bucket = aws_s3_bucket.main.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Primer guard: el objeto debe venir con cabecera SSE-KMS.
        # StringNotEqualsIfExists ignora la condición si la cabecera no existe,
        # pero el segundo guard atrapa ese caso al verificar el Key ID.
        Sid       = "DenyNonKMSUploads"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.main.arn}/*"
        Condition = {
          StringNotEqualsIfExists = {
            "s3:x-amz-server-side-encryption" = "aws:kms"
          }
        }
      },
      {
        # Segundo guard: el Key ID debe ser uno de los dos ARNs permitidos.
        # ForAllValues:StringNotEquals evalúa cada valor de la clave de condición
        # contra la lista; si ninguno coincide, el Deny se activa.
        Sid       = "DenyWrongKMSKey"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.main.arn}/*"
        Condition = {
          "ForAllValues:StringNotEquals" = {
            "s3:x-amz-server-side-encryption-aws-kms-key-id" = [
              aws_kms_key.main.arn,
              aws_kms_key.secondary.arn,
            ]
          }
        }
      }
    ]
  })
}
```

</details>

<details>
<summary>Reto 2 — Snapshot de EBS cifrado</summary>

**Qué hace un snapshot de EBS cifrado**

Un snapshot es una copia puntual del contenido del volumen almacenada en S3
(gestionado internamente por AWS, no en tu bucket). Si el volumen origen está
cifrado, AWS copia también los metadatos de cifrado: el snapshot hereda la misma
CMK automáticamente. No es necesario especificar `kms_key_id` en el snapshot
porque AWS lo infiere del volumen.

El snapshot puede usarse para:
- Restaurar el volumen en caso de pérdida de datos.
- Crear volúmenes en otras zonas de disponibilidad (siempre cifrados con la misma CMK).
- Compartir datos cifrados con otra cuenta de AWS (requiriendo que la cuenta
  destino tenga permisos sobre la CMK mediante una grant).

**Implicación de coste**: los snapshots se facturan por GiB-mes del espacio
diferencial utilizado. Un snapshot de un volumen de 10 GiB vacío ocupa muy poco,
pero conviene destruirlos al terminar el laboratorio.

**Código a añadir en `main.tf`:**

```hcl
# El snapshot hereda encrypted = true y kms_key_id del volumen origen.
# AWS no permite crear un snapshot no cifrado de un volumen cifrado.
resource "aws_ebs_snapshot" "main" {
  volume_id   = aws_ebs_volume.main.id
  description = "Snapshot del volumen EBS del lab13 - cifrado con CMK"

  tags = merge(local.tags, { Name = "${var.project}-snapshot" })
}
```

**Output a añadir en `outputs.tf`:**

```hcl
output "ebs_snapshot_id" {
  description = "ID del snapshot del volumen EBS"
  value       = aws_ebs_snapshot.main.id
}
```

**Por qué `terraform apply` puede tardar varios minutos**

Terraform llama a `ec2:CreateSnapshot` y luego espera a que el estado sea
`completed` antes de continuar. En volúmenes pequeños y vacíos suele tardar
entre 1 y 5 minutos. El progreso se puede monitorizar con:

```bash
aws ec2 describe-snapshots \
  --snapshot-ids $(terraform output -raw ebs_snapshot_id) \
  --query 'Snapshots[0].{State:State,Progress:Progress}'
```

</details>

## Limpieza

```bash
cd labs/lab13/aws
terraform destroy
```

> Los volúmenes EBS y los snapshots tienen coste por hora aunque estén sin adjuntar.
> Destruye los recursos al terminar el laboratorio.

## Buenas prácticas aplicadas

| Práctica | Implementación |
|----------|----------------|
| Root account siempre en Key Policy | Statement `EnableRootAccess` — recuperación ante errores |
| Segregación admin/usuario | Administradores no pueden cifrar/descifrar; usuarios no pueden gestionar la llave |
| Alias como capa de indirección | La sustitución de CMK no requiere cambios en el código |
| Rotación automática | `enable_key_rotation = true` — rotación anual sin interrupciones |
| Bucket Key activado | Reduce coste de KMS hasta un 99% en buckets con alta densidad |
| Cifrado forzoso en S3 | Bucket Policy con `Deny` explícito — ningún objeto puede subirse sin cifrar |
| `deletion_window_in_days = 7` | Ventana mínima — permite cancelar borrados accidentales |

## Recursos

- [AWS KMS — Customer Managed Keys](https://docs.aws.amazon.com/kms/latest/developerguide/concepts.html#customer-cmk)
- [Key Policy — AWS Docs](https://docs.aws.amazon.com/kms/latest/developerguide/key-policies.html)
- [S3 SSE-KMS — AWS Docs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/UsingKMSEncryption.html)
- [EBS Encryption — AWS Docs](https://docs.aws.amazon.com/ebs/latest/userguide/ebs-encryption.html)
- [S3 Bucket Key — AWS Docs](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucket-key.html)
- [aws_kms_key — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_key)
- [aws_kms_alias — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/kms_alias)
