# Laboratorio 14 — Automatización de Secretos "Zero-Touch"

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 4 — Seguridad e IAM con Terraform](../../modulos/modulo-04/README.md)


## Visión general

Las credenciales estáticas en variables de entorno, ficheros de configuración o
parámetros de CI/CD son el vector de filtración más frecuente en sistemas cloud.
Este laboratorio implementa un flujo **Zero-Touch** donde la contraseña de la
base de datos se genera, se almacena cifrada y se inyecta directamente en RDS —
todo en una única ejecución de Terraform, sin que el operador la vea ni la
introduzca en ningún momento.

## Objetivos

- Generar contraseñas de alta entropía con `random_password` sin exponerlas en variables de entrada.
- Almacenar credenciales en Secrets Manager en formato JSON con cifrado de una CMK KMS propia.
- Inyectar la contraseña directamente en `aws_db_instance` mediante referencia a `random_password.result`.
- Aplicar la misma CMK como raíz de confianza en tres capas: Secrets Manager, RDS y el backend S3.
- Comprender por qué el estado de Terraform requiere hardening específico.

## Requisitos previos

- Terraform ≥ 1.5 instalado.
- AWS CLI configurado con perfil `default`.
- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado.

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
```

## Arquitectura

```
                         terraform apply
                              │
              ┌───────────────▼────────────────────┐
              │         random_password            │
              │    genera 32 chars (entropía OS)   │
              │    nunca aparece en plan/logs      │
              └───────┬───────────────┬────────────┘
                      │               │
         ┌────────────▼─────┐  ┌──────▼───────────────────┐
         │  Secrets Manager │  │    aws_db_instance       │
         │  secret_version  │  │    password = result     │
         │  jsonencode({    │  │    (inyección directa)   │
         │    user, pass,   │  └──────────────────────────┘
         │    host, port... │
         │  })              │
         └────────┬─────────┘
                  │ cifrado con
         ┌────────▼─────────────────────────────────┐
         │              KMS CMK                     │
         │   alias/lab14-secrets                    │
         │   enable_key_rotation = true             │
         │                                          │
         │   Cifra tres capas:                      │
         │   ├── Secrets Manager (secret_string)    │
         │   ├── RDS (almacenamiento en disco)      │
         │   └── Backend S3 (.tfstate)              │
         └──────────────────────────────────────────┘
```

## Conceptos clave

| Concepto | Descripción |
|----------|-------------|
| `random_password` | Genera contraseñas con entropía del CSPRNG del SO; el valor nunca aparece en `terraform plan` ni en logs |
| AWS Secrets Manager | Almacena y rota secretos cifrados con KMS; registra cada acceso en CloudTrail |
| `aws_secretsmanager_secret_version` | Almacena el valor del secreto; `secret_string` acepta JSON para empaquetar múltiples campos |
| Inyección directa | `random_password.db.result` como `password` en `aws_db_instance` — sin variables intermedias |
| CMK (Customer Managed Key) | A diferencia de `aws/service`, permite policy granular, rotación anual y auditoría independiente |
| Hardening del backend | Configurar `kms_key_id` en el backend S3 protege el `.tfstate`, que contiene la contraseña en texto plano |
| `recovery_window_in_days = 0` | Elimina el secreto inmediatamente al destruir; evita colisiones de nombre entre despliegues |

### Por qué no `var.db_password`

Si la contraseña fuera una variable de entrada, aparecería en texto plano en los
logs de CI/CD, en el historial de shell y potencialmente en pull requests. El
modelo Zero-Touch elimina ese vector: la contraseña se genera internamente en
Terraform y solo vive en el estado cifrado y en Secrets Manager.

### El estado de Terraform y el riesgo oculto

`random_password.db.result` se almacena en texto plano en el `.tfstate`. Esto
hace que el hardening del backend con KMS sea imprescindible: sin él, cualquier
persona con acceso de lectura al bucket S3 puede leer la contraseña directamente
del fichero de estado.

### Secreto en formato JSON

Almacenar el secreto como JSON es la práctica estándar de AWS por tres razones:

1. Las aplicaciones consumen una sola llamada a `GetSecretValue` y obtienen todos los datos de conexión.
2. Los SDKs de AWS incluyen utilidades para parsear este formato directamente.
3. Los blueprints de rotación de Secrets Manager esperan el formato `{"username": "...", "password": "..."}`.

## Estructura del proyecto

```
lab14/
├── README.md
├── aws/
│   ├── providers.tf           # Provider AWS ~> 6.0 + random + backend S3
│   ├── variables.tf           # region, project_name, environment, vpc_cidr, db_name, db_username
│   ├── main.tf                # KMS, random_password, Secrets Manager, VPC, RDS
│   ├── outputs.tf             # ARNs, endpoint RDS, alias KMS, secret name
│   └── aws.s3.tfbackend       # key = "lab14/terraform.tfstate"
└── localstack/
    ├── README.md              # Guía de despliegue en LocalStack
    ├── providers.tf
    ├── variables.tf
    ├── main.tf
    ├── outputs.tf
    └── localstack.s3.tfbackend
```

## Despliegue en AWS real

### Paso 1 — Despliegue inicial (backend sin KMS)

En el primer despliegue la CMK aún no existe, por lo que el backend usa SSE-S3:

```bash
cd labs/lab-14/aws

# Si no tienes la variable inicializada de la sección de requisitos previos:
export BUCKET="terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform apply
```

> La instancia RDS puede tardar 5-10 minutos en estar disponible.

### Paso 2 — Hardening del backend con KMS

Una vez desplegada la infraestructura, protege el estado de Terraform con la CMK:

```bash
KMS_ARN=$(terraform output -raw kms_key_arn)
```

Edita `aws.s3.tfbackend` y añade/descomenta:

```hcl
kms_key_id = "<pega aquí el valor de KMS_ARN>"
```

Migra el estado al nuevo cifrado:

```bash
terraform init \
  -reconfigure \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"
```

A partir de este momento el `.tfstate` solo puede leerse con permisos `kms:Decrypt` sobre la CMK.

## Despliegue en LocalStack

Consulta [localstack/README.md](localstack/README.md) para instrucciones de
despliegue local con LocalStack y sus limitaciones respecto a AWS real.

## Verificación final

### 1. Comprobar la CMK y su rotación

```bash
aws kms describe-key --key-id alias/lab14-secrets \
  --query 'KeyMetadata.{KeyId:KeyId,KeyState:KeyState,Description:Description}'

aws kms get-key-rotation-status \
  --key-id $(terraform output -raw kms_key_arn)
# Esperado: { "KeyRotationEnabled": true }
# Nota: get-key-rotation-status no acepta alias, requiere Key ID (UUID) o ARN
```

### 2. Recuperar el secreto generado

```bash
aws secretsmanager get-secret-value \
  --secret-id $(terraform output -raw secret_name) \
  --query SecretString --output text | python3 -m json.tool
```

Resultado esperado:

```json
{
    "username": "dbadmin",
    "password": "K#3mP!...(32 chars)...",
    "engine": "mysql",
    "host": "lab14-db.xxxx.us-east-1.rds.amazonaws.com",
    "port": 3306,
    "dbname": "appdb"
}
```

La contraseña es visible al recuperar el secreto con permisos adecuados, pero
nunca apareció en ninguna variable de entrada ni en la salida de Terraform.

### 3. Verificar el cifrado del secreto con la CMK

```bash
aws secretsmanager describe-secret \
  --secret-id $(terraform output -raw secret_name) \
  --query '{Name:Name,KmsKeyId:KmsKeyId,RotationEnabled:RotationEnabled}'
# KmsKeyId debe apuntar a alias/lab14-secrets, no a aws/secretsmanager
```

### 4. Verificar el cifrado del volumen RDS

```bash
aws rds describe-db-instances \
  --db-instance-identifier lab14-db \
  --query 'DBInstances[0].{Status:DBInstanceStatus,Encrypted:StorageEncrypted,KmsKeyId:KmsKeyId}'
# Esperado: Encrypted = true, KmsKeyId = ARN de la CMK
```

### 5. Verificar el hardening del backend S3

```bash
aws s3api head-object \
  --bucket "$BUCKET" \
  --key "lab14/terraform.tfstate" \
  --query '{SSE:ServerSideEncryption,KMSKeyId:SSEKMSKeyId}'
# Esperado: SSE = "aws:kms", KMSKeyId = ARN de la CMK (no "aws/s3")
```

### 6. Confirmar que la contraseña no es visible en el plan

```bash
terraform plan
```

Busca `password = (sensitive value)` en la sección de `aws_db_instance.main`.
El operador nunca ve la contraseña en texto plano, ni en el plan ni en los logs.

### 7. Consumo del secreto desde una aplicación

Las aplicaciones deben recuperar el secreto en tiempo de ejecución, no en tiempo
de despliegue. Ejemplo con Python:

```python
import boto3, json

def get_db_credentials(secret_name: str) -> dict:
    client = boto3.client("secretsmanager", region_name="us-east-1")
    response = client.get_secret_value(SecretId=secret_name)
    return json.loads(response["SecretString"])

creds = get_db_credentials("lab14/rds/master-credentials")
connection_string = (
    f"mysql+pymysql://{creds['username']}:{creds['password']}"
    f"@{creds['host']}:{creds['port']}/{creds['dbname']}"
)
```

La aplicación obtiene las credenciales directamente de Secrets Manager en cada
arranque. La contraseña nunca se persiste en variables de entorno ni en archivos
de configuración.

## Retos

### Reto 1 — Rol de aplicación con acceso exclusivo al secreto

El flujo Zero-Touch garantiza que la contraseña no pasa por variables del
operador, pero actualmente cualquier principal IAM con permisos
`secretsmanager:GetSecretValue` puede leer el secreto.

Cierra ese acceso implementando dos recursos:

1. Un **rol IAM** (`aws_iam_role`) que represente a la aplicación que necesita
   las credenciales de la base de datos, con una política inline que le permita
   llamar a `GetSecretValue` sobre el secreto.

2. Una **política de recurso** (`aws_secretsmanager_secret_policy`) sobre el
   secreto que deniegue `GetSecretValue` a cualquier principal que no sea ese
   rol de aplicación.

```hcl
# Rol de la aplicación — completar la Trust Policy y la política inline
resource "aws_iam_role" "app" {
  name = "${var.project_name}-app-role"
  # ...
}

resource "aws_iam_role_policy" "app_read_secret" {
  name = "${var.project_name}-read-secret"
  role = aws_iam_role.app.id
  # ...
}

# Política de recurso — completar el Statement de denegación
resource "aws_secretsmanager_secret_policy" "db" {
  secret_arn = aws_secretsmanager_secret.db.arn
  policy = jsonencode({
    # ...
  })
}
```

**Pistas:**
- La Trust Policy del rol debe permitir que alguien lo asuma. Usa
  `ec2.amazonaws.com` como principal (simula que es el rol de una instancia).
- La política inline necesita `secretsmanager:GetSecretValue` y
  `secretsmanager:DescribeSecret` sobre el ARN exacto del secreto.
- La política de recurso debe tener un `Deny` con `StringNotLike` sobre
  `aws:PrincipalArn` apuntando al ARN del rol de aplicación.

#### Prueba

```bash
SECRET=$(terraform output -raw secret_name)

# 1. Confirmar que el rol de aplicación existe
aws iam get-role --role-name lab14-app-role \
  --query 'Role.{RoleName:RoleName,Arn:Arn}'

# 2. Confirmar que el rol tiene la política inline que permite leer el secreto
aws iam get-role-policy \
  --role-name lab14-app-role \
  --policy-name lab14-read-secret \
  --query 'PolicyDocument.Statement[0].{Effect:Effect,Action:Action,Resource:Resource}'
# Esperado: Effect "Allow", Action incluye secretsmanager:GetSecretValue,
#           Resource = ARN exacto del secreto

# 3. Verificar el contenido de la resource policy del secreto
aws secretsmanager get-resource-policy \
  --secret-id "$SECRET" \
  --query ResourcePolicy --output text | python3 -m json.tool
# Esperado: Statement con Deny y condición StringNotLike sobre el rol de app

# 4. Verificación end-to-end: tu usuario actual NO es el rol de app, así que
#    la resource policy debe denegarte el acceso al secreto. Es la prueba
#    definitiva de que el control funciona.
aws secretsmanager get-secret-value --secret-id "$SECRET" 2>&1 | head -3
# Esperado: AccessDeniedException ... explicit deny in a resource-based policy
```

## Soluciones

<details>
<summary>Reto 1 — Rol de aplicación con acceso exclusivo al secreto</summary>

**Por qué dos capas: política inline + política de recurso**

La política inline en el rol concede el permiso desde el lado del principal
("el rol puede hacer X"). La política de recurso en el secreto deniega desde
el lado del recurso ("solo este rol puede acceder aquí"). Usadas juntas crean
una lista blanca bidireccional: para leer el secreto hay que ser el rol correcto
Y el secreto tiene que permitirlo explícitamente.

**Por qué `StringNotLike` y no `StringNotEquals` en la política de recurso**

Cuando un rol es asumido, el ARN de sesión tiene la forma
`arn:aws:sts::123456789012:assumed-role/lab14-app-role/session-name`, que es
distinto al ARN del rol `arn:aws:iam::123456789012:role/lab14-app-role`.
`StringNotEquals` rechazaría las sesiones asumidas aunque vengan del rol
correcto. Con `StringNotLike` y el wildcard `*` al final se cubren todas las
sesiones del rol sin importar el nombre de sesión.

**Código completo a añadir en `main.tf`**

```hcl
# Rol IAM que representa a la aplicación consumidora del secreto.
# Trust Policy: ec2.amazonaws.com puede asumir el rol (simula una instancia EC2).
resource "aws_iam_role" "app" {
  name        = "${var.project_name}-app-role"
  description = "Rol de la aplicacion - unico principal autorizado a leer el secreto de RDS"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEC2Assume"
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = merge(local.common_tags, { Name = "${var.project_name}-app-role" })
}

# Política inline: el rol puede leer y describir el secreto de RDS.
# Se limita al ARN exacto del secreto — principio de mínimo privilegio.
resource "aws_iam_role_policy" "app_read_secret" {
  name = "${var.project_name}-read-secret"
  role = aws_iam_role.app.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "ReadRDSSecret"
      Effect = "Allow"
      Action = [
        "secretsmanager:GetSecretValue",
        "secretsmanager:DescribeSecret",
      ]
      Resource = aws_secretsmanager_secret.db.arn
    }]
  })
}

# Política de recurso: deniega GetSecretValue a cualquier principal
# que no sea el rol de aplicación. El Deny explícito tiene precedencia
# sobre cualquier Allow en las políticas de identidad de otros principals.
resource "aws_secretsmanager_secret_policy" "db" {
  secret_arn = aws_secretsmanager_secret.db.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyAllExceptAppRole"
      Effect    = "Deny"
      Principal = { AWS = "*" }
      Action    = "secretsmanager:GetSecretValue"
      Resource  = aws_secretsmanager_secret.db.arn
      Condition = {
        StringNotLike = {
          # El wildcard cubre tanto el ARN del rol como el ARN de las sesiones
          # asumidas: arn:aws:sts::...:assumed-role/lab14-app-role/*
          "aws:PrincipalArn" = "${aws_iam_role.app.arn}"
        }
      }
    }]
  })
}
```

**Output necesario para la prueba**

Añade en `outputs.tf`:

```hcl
output "app_role_arn" {
  description = "ARN del rol IAM de la aplicacion"
  value       = aws_iam_role.app.arn
}

```

**Efecto neto tras aplicar**

```
┌─────────────────────────────────────────────────────────┐
│  aws_secretsmanager_secret "db"                         │
│                                                         │
│  Política de recurso:                                   │
│    Deny GetSecretValue → todos EXCEPTO lab14-app-role   │
│                                                         │
│  ✓ lab14-app-role          → Allow (política inline)    │
│  ✗ cualquier otro usuario  → Deny  (política recurso)   │
│  ✗ cualquier otro rol      → Deny  (política recurso)   │
└─────────────────────────────────────────────────────────┘
```

> **Nota:** después de aplicar, tu usuario de operador también quedará bloqueado
> para `GetSecretValue` (a menos que lo añadas a la condición `StringNotLike`).
> Esto es intencional — demuestra que el Deny de la política de recurso tiene
> precedencia sobre cualquier Allow en las políticas de identidad.

> **Implicación al destruir:** Terraform invoca `GetSecretValue` durante el
> refresh para leer el estado de `aws_secretsmanager_secret_version`. Con la
> resource policy aplicada tu operador queda bloqueado y `terraform destroy`
> falla con `AccessDeniedException`. La sección [Limpieza](#limpieza) documenta
> el workaround.

</details>

## Limpieza

```bash
cd labs/lab-14/aws
terraform destroy
```
> La CMK tiene `deletion_window_in_days = 7`: durante esos 7 días está
> deshabilitada pero no eliminada. Puedes cancelar el borrado con
> `aws kms cancel-key-deletion --key-id <key-id>`.

> **Si aplicaste el Reto 1**, la resource policy del secreto deniega
> `GetSecretValue` a tu operador. Terraform necesita esa acción durante el
> refresh previo al destroy (para leer el estado de `aws_secretsmanager_secret_version`),
> así que el destroy fallará con `AccessDeniedException`. Solución:
>
> ```bash
> # Eliminar la resource policy con la CLI
> aws secretsmanager delete-resource-policy \
>   --secret-id $(terraform output -raw secret_name)
>
> # Refrescar el estado para que Terraform vea que la policy ya no está
> terraform refresh
>
> # Ahora sí, destruir
> terraform destroy
> ```

## Buenas prácticas

| Práctica | Implementación |
|----------|----------------|
| Zero-Touch — sin credenciales en variables de entrada | `random_password.result` inyectado directamente, sin `var.db_password` |
| Sensitive value | `random_password` oculta el valor en `terraform plan` y logs |
| Formato JSON en Secrets Manager | Una sola llamada a `GetSecretValue` devuelve todos los datos de conexión |
| CMK compartida entre servicios | Una sola llave KMS cifra Secrets Manager, RDS y el backend S3 |
| Hardening del backend | `kms_key_id` en el backend S3 protege el `.tfstate` que contiene la contraseña |
| Rotación automática de la CMK | `enable_key_rotation = true` — anual, sin cambio de ARN |

## Recursos

- [random_password — Terraform Registry](https://registry.terraform.io/providers/hashicorp/random/latest/docs/resources/password)
- [Secrets Manager — Buenas prácticas](https://docs.aws.amazon.com/secretsmanager/latest/userguide/best-practices.html)
- [Rotación de secretos para RDS](https://docs.aws.amazon.com/secretsmanager/latest/userguide/rotating-secrets.html)
- [KMS Key Rotation — AWS Docs](https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html)
- [Backend S3 — kms_key_id](https://developer.hashicorp.com/terraform/language/backend/s3#kms_key_id)
- [Sensitive data in Terraform state](https://developer.hashicorp.com/terraform/language/manage-sensitive-data)
- [aws_secretsmanager_secret_version — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/secretsmanager_secret_version)
