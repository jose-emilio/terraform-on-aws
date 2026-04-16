# Laboratorio 12 — Gestión de Identidades y Acceso Seguro para EC2

[← Módulo 4 — Seguridad e IAM con Terraform](../../modulos/modulo-04/README.md)


## Visión general

Las credenciales estáticas (Access Key ID + Secret Access Key) son el vector de compromiso más frecuente en AWS. Este laboratorio elimina ese riesgo implementando el ciclo completo de identidad temporal para instancias EC2:

1. Un **grupo IAM** y un **usuario** modelan los accesos del equipo de desarrollo.
2. Un **rol IAM** con una **Trust Policy** delega la identidad exclusivamente al servicio EC2.
3. Un **Instance Profile** actúa como contenedor que une el rol con la instancia.
4. La instancia obtiene **credenciales temporales automáticas** sin intervención humana.

## Objetivos

- Comprender la diferencia entre usuarios, grupos y roles en IAM.
- Entender por qué la Trust Policy controla QUIÉN puede asumir un rol.
- Implementar `aws_iam_instance_profile` como puente entre un rol IAM y EC2.
- Verificar que las credenciales temporales se inyectan vía IMDSv2.
- Practicar el acceso sin SSH usando SSM Session Manager.

## Requisitos previos

- Terraform ≥ 1.5 instalado.
- AWS CLI configurado con perfil `default`.
- Plugin SSM para la AWS CLI: `aws ssm start-session` disponible.
- Bucket de estado creado en el lab02.

## Arquitectura

```
                    ┌──────────────────── IAM ─────────────────────┐
                    │                                              │
                    │  aws_iam_group "developers"                  │
                    │    └── Política: EC2 + IAM read-only         │
                    │          │ (membresía)                       │
                    │  aws_iam_user "dev-01"                       │
                    │                                              │
                    │  aws_iam_role "ec2-role"                     │
                    │    Trust Policy → ec2.amazonaws.com          │
                    │    ├── AmazonSSMManagedInstanceCore          │
                    │    └── AmazonEC2ReadOnlyAccess               │
                    │          │ (contenedor)                      │
                    │  aws_iam_instance_profile "ec2-profile"      │
                    │                                              │
                    └──────────────────┬───────────────────────────┘
                                       │ asociado a
                    ┌───── EC2 ────────▼───────────────────────────┐
                    │                                              │
                    │   aws_instance "app" (t4g.micro, AL2023)     │
                    │   Sin clave SSH — acceso exclusivo por SSM   │
                    │   IMDSv2 obligatorio (http_tokens=required)  │
                    │                                              │
                    │   IMDS (169.254.169.254)                     │
                    │     └──► STS ──► Credenciales temporales     │
                    │           (AccessKeyId / Token / Expiration) │
                    │                                              │
                    └──────────────────────────────────────────────┘
```

## Conceptos clave

### Usuarios, Grupos y Roles — ¿cuándo usar cada uno?

| Entidad | Representa | Credenciales | Caso de uso |
|---------|------------|--------------|-------------|
| `aws_iam_user` | Persona o sistema externo | Estáticas (Access Keys) | CI/CD externos a AWS, personas |
| `aws_iam_group` | Colección de usuarios | — | Gestión centralizada de permisos |
| `aws_iam_role` | Identidad asumible temporalmente | Temporales (STS) | Servicios AWS, cuentas cruzadas |

### Trust Policy — ¿quién puede asumir el rol?

La Trust Policy es la parte más importante de un rol. Responde a: **"¿Quién tiene permiso para solicitar credenciales temporales para este rol?"**

```json
{
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "ec2.amazonaws.com" },
    "Action": "sts:AssumeRole"
  }]
}
```

Con `Principal = "ec2.amazonaws.com"` solo el servicio EC2 puede asumir el rol. Ni un usuario humano ni otro servicio de AWS puede hacerlo sin modificar esta política.

### Instance Profile — el "conector" EC2 ↔ Rol

EC2 no puede usar un rol IAM directamente. Necesita un `aws_iam_instance_profile` como intermediario:

```
EC2 instance  →  Instance Profile  →  IAM Role  →  Permisos
```

Una instancia solo puede tener **un** Instance Profile (y el profile puede contener **un** rol).

### IMDSv2 y credenciales temporales

Con `http_tokens = "required"`, la instancia exige un token de sesión antes de devolver metadatos:

```bash
# 1. Obtener token (válido 6 horas)
TOKEN=$(curl -s -X PUT http://169.254.169.254/latest/api/token \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 21600")

# 2. Leer nombre del rol
ROLE=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/)

# 3. Leer credenciales temporales del rol
curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/iam/security-credentials/$ROLE
```

El resultado incluye `AccessKeyId`, `SecretAccessKey`, `Token` y `Expiration`. EC2 las renueva automáticamente antes de la expiración.

## Estructura del proyecto

```
lab12/
├── README.md
├── user_data.sh           # Script de verificación (ejecutado al arrancar EC2)
├── aws/
│   ├── providers.tf       # Provider AWS + backend S3
│   ├── variables.tf       # Variables: project, region, instance_type
│   ├── main.tf            # Todos los recursos IAM y EC2
│   ├── outputs.tf         # Outputs: ARNs, IDs, comandos de verificación
│   └── aws.s3.tfbackend   # Configuración del backend remoto
└── localstack/
    ├── README.md          # Guía de despliegue en LocalStack
    ├── providers.tf       # Provider con endpoints LocalStack
    ├── variables.tf
    ├── main.tf
    └── outputs.tf
```

## Despliegue en AWS real

```bash
cd labs/lab12/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"

terraform plan
terraform apply
```

## Despliegue en LocalStack

Consulta [localstack/README.md](localstack/README.md) para instrucciones de
despliegue local con LocalStack y sus limitaciones respecto a AWS real.

## Verificación final

### 1. Confirmar recursos IAM creados

```bash
# Listar los recursos del laboratorio
aws iam get-group --group-name lab12-developers
aws iam get-user --user-name lab12-dev-01
aws iam get-role --role-name lab12-ec2-role
aws iam get-instance-profile --instance-profile-name lab12-ec2-profile
```

### 2. Confirmar que dev-01 pertenece al grupo

```bash
aws iam list-groups-for-user --user-name lab12-dev-01
```

Resultado esperado: `lab12-developers` aparece en la lista.

### 3. Conectarse a la instancia via SSM

```bash
# Obtener el Instance ID del output de Terraform
INSTANCE_ID=$(terraform output -raw instance_id)

# Abrir sesión interactiva sin SSH
aws ssm start-session --target $INSTANCE_ID
```

> La instancia puede tardar 1-2 minutos en estar disponible para SSM
> tras el arranque.

### 4. Leer el log de verificación (dentro de la sesión SSM)

```bash
cat /var/log/lab12-verify.log
```

Resultado esperado:

```
=== Lab 12 — Verificación de Identidad IAM ===
Timestamp: 2025-XX-XXTXX:XX:XXZ

--- [1] Obteniendo token IMDSv2 ---
Token IMDSv2 obtenido correctamente.

--- [2] Nombre del rol IAM en el Instance Profile ---
Rol activo: lab12-ec2-role

--- [3] Credenciales temporales (STS) ---
{
  "Code": "Success",
  "Type": "AWS-HMAC",
  "AccessKeyId": "ASIA...",
  "SecretAccessKey": "...",
  "Token": "...",
  "Expiration": "2025-XX-XXTXX:XX:XXZ",
  "LastUpdated": "..."
}

--- [4] aws sts get-caller-identity ---
{
  "UserId": "AROA...:i-0abc...",
  "Account": "123456789012",
  "Arn": "arn:aws:sts::123456789012:assumed-role/lab12-ec2-role/i-0abc..."
}

--- [5] aws ec2 describe-instances (lectura) ---
Número de reservaciones visibles: 1
```

Observaciones clave:
- El `Arn` confirma que la instancia opera con el rol `lab12-ec2-role`.
- El `UserId` tiene formato `AROA...:i-0...` (rol asumido + ID de sesión).
- Las credenciales incluyen un `Token` de sesión — son temporales.

### 5. Verificar la Trust Policy del rol

```bash
aws iam get-role --role-name lab12-ec2-role \
  --query 'Role.AssumeRolePolicyDocument' --output json
```

Confirma que `Principal.Service = "ec2.amazonaws.com"`.

### 6. Verificar membresía del grupo desde tu terminal local

```bash
aws iam list-groups-for-user --user-name lab12-dev-01 \
  --query 'Groups[].GroupName'
```

## Retos

### Reto 1 — Política inline en el rol EC2

Añade al rol EC2 una **política inline** (`aws_iam_role_policy`) que permita
únicamente `s3:ListAllMyBuckets` con `Resource = "*"`. Las políticas inline son
específicas del rol y no pueden compartirse con otros roles.

**Recurso a añadir en `main.tf`:**

```hcl
resource "aws_iam_role_policy" "ec2_s3_list" {
  # completar...
}
```

#### Prueba

Tras ejecutar `terraform apply`, abre una sesión SSM en la instancia y verifica:

```bash
# 1. Confirmar que la política inline existe en el rol
aws iam list-role-policies --role-name lab12-ec2-role \
  --query 'PolicyNames'
# Esperado: ["lab12-ec2-s3-list"]

# 2. Listar buckets S3 desde la instancia (usa las credenciales temporales del rol)
aws s3 ls
# Esperado: listado de buckets sin error de autorización

# 3. Confirmar que la acción está explícitamente permitida
aws iam simulate-principal-policy \
  --policy-source-arn $(aws iam get-role --role-name lab12-ec2-role --query 'Role.Arn' --output text) \
  --action-names s3:ListAllMyBuckets \
  --query 'EvaluationResults[].EvalDecision'
# Esperado: ["allowed"]
```

### Reto 2 — Permissions Boundary sobre el rol EC2

Los **Permission Boundaries** limitan el máximo de permisos que un rol puede
tener, independientemente de las políticas adjuntas. Son el mecanismo para
evitar escalada de privilegios en entornos con múltiples equipos.

Crea una política gestionada que permita únicamente `s3:*`, `ec2:Describe*` y
las acciones necesarias para SSM, y asígnala como `permissions_boundary` del
rol EC2.

```hcl
resource "aws_iam_policy" "boundary" {
  name = "${var.project}-ec2-boundary"
  # ...
}

resource "aws_iam_role" "ec2" {
  # ... (añadir)
  permissions_boundary = aws_iam_policy.boundary.arn
}
```

> El Permissions Boundary no concede permisos: solo establece el techo.
> El permiso efectivo es la intersección entre las políticas adjuntas y el boundary.

#### Prueba

Tras ejecutar `terraform apply`, verifica desde tu terminal local y desde la instancia:

```bash
# 1. Confirmar que el boundary está asignado al rol
aws iam get-role --role-name lab12-ec2-role \
  --query 'Role.PermissionsBoundary.PermissionsBoundaryArn' --output text
# Esperado: arn:aws:iam::<ACCOUNT_ID>:policy/lab12-ec2-boundary

# 2. Comprobar que sts:GetCallerIdentity sigue funcionando (dentro del boundary)
# Ejecutar desde la sesión SSM en la instancia:
aws sts get-caller-identity
# Esperado: JSON con UserId, Account y Arn del rol asumido

# 3. Simular el efecto del boundary sobre una acción permitida
aws iam simulate-principal-policy \
  --policy-source-arn $(aws iam get-role --role-name lab12-ec2-role --query 'Role.Arn' --output text) \
  --action-names ec2:DescribeInstances \
  --query 'EvaluationResults[].EvalDecision'
# Esperado: ["allowed"]  (acción dentro del boundary Y de las políticas adjuntas)

# 4. Simular el efecto del boundary sobre una acción fuera de él
aws iam simulate-principal-policy \
  --policy-source-arn $(aws iam get-role --role-name lab12-ec2-role --query 'Role.Arn' --output text) \
  --action-names iam:CreateUser \
  --query 'EvaluationResults[].EvalDecision'
# Esperado: ["implicitDeny"]  (bloqueada por el boundary aunque hubiera política que la concediera)
```

## Soluciones

<details>
<summary>Reto 1 — Política inline S3 ListAllMyBuckets</summary>

```hcl
resource "aws_iam_role_policy" "ec2_s3_list" {
  name = "${var.project}-ec2-s3-list"
  role = aws_iam_role.ec2.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "S3ListBuckets"
      Effect   = "Allow"
      Action   = "s3:ListAllMyBuckets"
      Resource = "*"
    }]
  })
}
```

</details>

<details>
<summary>Reto 2 — Permissions Boundary</summary>

```hcl
resource "aws_iam_policy" "boundary" {
  name        = "${var.project}-ec2-boundary"
  description = "Techo de permisos para el rol EC2 del lab12"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "AllowS3"
        Effect   = "Allow"
        Action   = "s3:*"
        Resource = "*"
      },
      {
        Sid      = "AllowEC2Describe"
        Effect   = "Allow"
        Action   = ["ec2:Describe*", "ec2:Get*"]
        Resource = "*"
      },
      {
        Sid      = "AllowSTS"
        Effect   = "Allow"
        Action   = "sts:GetCallerIdentity"
        Resource = "*"
      },
      {
        Sid    = "AllowSSM"
        Effect = "Allow"
        Action = [
          "ssm:UpdateInstanceInformation",
          "ssmmessages:*",
          "ec2messages:*"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project}-ec2-role"
  path               = "/"
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json
  description        = "Rol para instancias EC2 del lab12"
  permissions_boundary = aws_iam_policy.boundary.arn   # <-- añadido

  tags = merge(local.tags, { Name = "${var.project}-ec2-role" })
}
```

</details>

## Limpieza

```bash
cd labs/lab12/aws
terraform destroy
```

> Terraform eliminará primero las políticas y membresías antes de intentar
> borrar el usuario (gracias a `force_destroy = true`).

## Buenas prácticas aplicadas

| Práctica | Implementación |
|----------|----------------|
| Sin credenciales estáticas | Rol IAM + Instance Profile en lugar de Access Keys |
| Principio de mínimo privilegio | El grupo solo tiene lectura; el rol solo lo que necesita |
| IMDSv2 obligatorio | `http_tokens = "required"` bloquea ataques SSRF |
| Sin acceso SSH | SSM Session Manager — sin puertos abiertos ni claves |
| No crear Access Keys en Terraform | El usuario se crea sin credenciales adjuntas |
| Trust Policy explícita | `data "aws_iam_policy_document"` valida la sintaxis |

## Recursos

- [IAM Roles — AWS Docs](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles.html)
- [Instance Profiles — AWS Docs](https://docs.aws.amazon.com/IAM/latest/UserGuide/id_roles_use_switch-role-ec2_instance-profiles.html)
- [IMDSv2 — AWS Docs](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/configuring-instance-metadata-service.html)
- [SSM Session Manager — AWS Docs](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html)
- [Permissions Boundaries — AWS Docs](https://docs.aws.amazon.com/IAM/latest/UserGuide/access_policies_boundaries.html)
- [aws_iam_role — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_role)
- [aws_iam_instance_profile — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/iam_instance_profile)
