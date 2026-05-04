# Laboratorio 24 — Composición de Módulos Públicos con Estándares Corporativos

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 6 — Módulos de Terraform](../../modulos/modulo-06/README.md)


## Visión general

Crear un módulo "wrapper" que orqueste módulos públicos del Terraform Registry (VPC y RDS), inyectando estándares de seguridad obligatorios que los equipos de desarrollo **no pueden desactivar**. Encadenar los outputs del módulo de VPC como inputs del módulo de RDS. Usar bloques `moved {}` para renombrar recursos internos sin destruir infraestructura.

## Conceptos clave

| Concepto | Descripción |
|---|---|
| **Módulo wrapper** | Módulo que encapsula otros módulos (públicos o privados) añadiendo políticas corporativas. El equipo de plataforma lo mantiene; los equipos de producto lo consumen |
| **Terraform Registry** | Repositorio público de módulos reutilizables. Los módulos oficiales de AWS (`terraform-aws-modules/*`) son los más usados y están mantenidos por la comunidad |
| **Composición de módulos** | Patrón de invocar múltiples módulos dentro de otro módulo, conectando sus outputs e inputs para crear una arquitectura completa |
| **Encadenamiento de outputs** | Pasar la salida de un módulo como entrada de otro: `module.vpc.private_subnets` → `module.rds.subnet_ids` |
| **Parámetros hardcoded** | Valores fijados dentro del wrapper que el usuario no puede sobreescribir. Garantizan cumplimiento de políticas sin depender de la disciplina del equipo |
| **`moved {}`** | Bloque que indica a Terraform que un recurso fue renombrado, no eliminado. Evita destruir y recrear infraestructura al refactorizar código |
| **`manage_master_user_password`** | Característica de RDS que genera y rota automáticamente la contraseña maestra en Secrets Manager, eliminando la necesidad de gestionarla manualmente |

## Comparativa: Módulo directo vs. Wrapper corporativo

| Aspecto | Módulo público directo | Wrapper corporativo |
|---|---|---|
| Cifrado | El equipo decide (puede olvidarlo) | `storage_encrypted = true` siempre |
| Acceso público | El equipo decide | `publicly_accessible = false` siempre |
| Protección borrado | El equipo decide | `deletion_protection = true` siempre |
| Networking | El equipo configura VPC, subredes, SG | Todo incluido y conectado |
| Complejidad para el usuario | Alta (muchos parámetros) | Baja (solo motor, clase, nombre) |
| Flexibilidad | Total | Limitada por diseño |
| Auditoría | Revisar cada equipo | Revisar un solo módulo |

## Prerrequisitos

- lab-02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado (usado como backend de tfstate)
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.10 (necesario para `use_lockfile` en el backend S3; los bloques `moved {}` requieren ≥ 1.1, así que ya está cubierto)

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
echo "Bucket: $BUCKET"
```

> **⚠️ Aviso de coste — desglose mensual aproximado en `us-east-1`:**
>
> | Componente | Tarifa | Coste/mes |
> |---|---|---:|
> | RDS `db.t4g.micro` (Single-AZ) | ~$0,016/h × 720 h | ~$11,50 |
> | RDS storage 20 GB gp3 | ~$0,115/GB-mes | ~$2,30 |
> | RDS backups (retention 7d, ≤storage gratis) | $0 hasta 100% storage | ~$0 |
> | NAT Gateway (single, no por AZ) | ~$0,045/h × 720 h | ~$32 |
> | Elastic IP del NAT | ~$0,005/h × 720 h | ~$3,60 |
> | Secrets Manager (gestionado por RDS) | ~$0,40/secreto-mes | ~$0,40 |
>
> **Total base ≈ 50 USD/mes** sin contar tráfico procesado por NAT (~$0,045/GB) ni transferencia de datos. Si dejas el lab corriendo, la factura sube rápido. **Ejecuta `terraform destroy` (sección 8) en cuanto termines la práctica** — recuerda que primero hay que desactivar `deletion_protection`.

## Estructura del proyecto

```
lab-24/
├── README.md                                <- Esta guía
├── aws/
│   ├── providers.tf                         <- Backend S3 parcial
│   ├── variables.tf                         <- Variables del Root Module
│   ├── main.tf                              <- Invocación del wrapper
│   ├── outputs.tf                           <- Outputs delegados al wrapper
│   ├── aws.s3.tfbackend                     <- Parámetros del backend
│   └── modules/
│       └── corporate-rds/                   <- El wrapper corporativo
│           ├── main.tf                      <- VPC + SG + RDS (módulos públicos)
│           ├── variables.tf                 <- Interfaz simplificada
│           └── outputs.tf                   <- VPC, RDS, compliance
└── localstack/
    └── README.md                            <- Explicación (RDS no disponible)
```

## 1. Análisis del código

### 1.1 Arquitectura del laboratorio

```
┌──────────────────────────────────────────────────────────────────────┐
│                         Root Module                                  │
│                                                                      │
│  module "corporate_rds" {                                            │
│    source       = "./modules/corporate-rds"                          │
│    db_engine    = "mysql"                                            │
│    db_name      = "appdb"                                            │
│    ...                                                               │
│  }                                                                   │
└──────────────────────────────┬───────────────────────────────────────┘
                               │
                               ▼
┌──────────────────────────────────────────────────────────────────────┐
│                    modules/corporate-rds/ (Wrapper)                  │
│                                                                      │
│  ┌────────────────────────────┐   ┌──────────────────────────────┐   │
│  │ module "vpc"               │   │ module "rds"                 │   │
│  │ terraform-aws-modules/vpc  │──►│ terraform-aws-modules/rds    │   │
│  │                            │   │                              │   │
│  │ vpc_id ─────────────────┐  │   │ storage_encrypted = true ⬅   │   │
│  │ database_subnet_group   │  │   │deletion_protection = true⬅   │   │
│  │ private_subnets_cidr    │  │   │ publicly_accessible = false⬅ │   │
│  └─────────────────────────┤──┘   └──────────────────────────────┘   │
│                            │                                         │
│  ┌─────────────────────────▼──┐   ⬅ = Hardcoded (no overridable)     │
│  │ aws_security_group "rds"   │                                      │
│  │ Ingress: solo desde        │                                      │
│  │ subredes privadas          │                                      │
│  └────────────────────────────┘                                      │
└──────────────────────────────────────────────────────────────────────┘
```

El wrapper contiene tres componentes:
1. **Módulo público VPC**: crea la red completa (VPC, subredes, NAT Gateway, route tables)
2. **Security group**: restringe el acceso a RDS solo desde las subredes privadas
3. **Módulo público RDS**: crea la base de datos con parámetros de seguridad hardcoded

### 1.2 Composición de módulos — VPC del Registry

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr

  azs              = local.azs
  private_subnets  = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, 10 + i)]
  database_subnets = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, 20 + i)]
  public_subnets   = [for i in range(length(local.azs)) : cidrsubnet(var.vpc_cidr, 8, i)]

  enable_nat_gateway                 = true
  single_nat_gateway                 = true
  create_database_subnet_group       = true
  create_database_subnet_route_table = true

  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = local.effective_tags
}
```

Puntos clave:
- `source = "terraform-aws-modules/vpc/aws"` descarga el módulo del Registry público
- `version = "~> 5.0"` permite versiones 5.x pero no 6.0 (semver pessimistic constraint)
- Tres tipos de subredes: **public** (con IGW), **private** (con NAT), **database** (sin salida a Internet)
- `create_database_subnet_group = true` crea automáticamente el subnet group que RDS necesita
- Los CIDRs se calculan con `cidrsubnet()`: públicas en `x.x.0.0/24`, `x.x.1.0/24`; privadas en `x.x.10.0/24`, `x.x.11.0/24`; database en `x.x.20.0/24`, `x.x.21.0/24`

### 1.3 Encadenamiento de outputs — VPC → RDS

```hcl
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  # ...

  # ─── OUTPUTS ENCADENADOS DEL MÓDULO VPC ───
  db_subnet_group_name   = module.vpc.database_subnet_group_name
  vpc_security_group_ids = [aws_security_group.rds.id]
  subnet_ids             = module.vpc.database_subnets
}
```

El flujo de datos:

```
module.vpc.database_subnet_group_name ──► module.rds.db_subnet_group_name
module.vpc.database_subnets           ──► module.rds.subnet_ids
module.vpc.private_subnets_cidr_blocks ──► aws_security_group.rds.ingress.cidr_blocks
                                           ──► module.rds.vpc_security_group_ids
```

Terraform resuelve estas dependencias automáticamente: primero crea la VPC, luego el security group, y finalmente la instancia RDS. No se necesita `depends_on` explícito porque las referencias implican el orden.

### 1.4 Estandarización — Parámetros hardcoded

```hcl
module "rds" {
  # ...

  # ─── PARÁMETROS HARDCODED DE CUMPLIMIENTO ───
  storage_encrypted   = true  # Cifrado en reposo obligatorio
  deletion_protection = true  # Protección contra borrado accidental
  publicly_accessible = false # Sin acceso público NUNCA

  # ─── OPERACIONALES, también hardcoded por política ───
  backup_retention_period = 7    # Snapshots diarios automáticos durante 7 días
  skip_final_snapshot     = true # ⚠ ver nota más abajo
}
```

> **Sobre `skip_final_snapshot = true`:** este flag dice a RDS **no crear** un snapshot final cuando se destruye la BD. Es práctico para un laboratorio (la BD es desechable), pero **en producción debería ser `false`** o, mejor, exponerse como variable con default `false` — perder datos al destruir sin querer es irrecuperable. Lo dejamos en `true` aquí solo para que `terraform destroy` funcione sin el paso adicional de proporcionar `final_snapshot_identifier`.

Estos parámetros están **dentro del wrapper**, no expuestos como variables. El equipo de producto que consume el módulo no puede hacer:

```hcl
# ❌ IMPOSIBLE — no existe variable para sobreescribir
module "corporate_rds" {
  source            = "./modules/corporate-rds"
  storage_encrypted = false   # No existe esta variable
}
```

Si alguien intenta pasar `storage_encrypted`, Terraform dará error:

```
Error: Unsupported argument
  An argument named "storage_encrypted" is not expected here.
```

Este es el poder del patrón wrapper: **cumplimiento por diseño**, no por convención.

### 1.5 Contraseña gestionada por RDS

```hcl
manage_master_user_password = true
```

En vez de pasar una contraseña como variable (que acabaría en el estado en texto plano), RDS genera y rota automáticamente la contraseña en Secrets Manager. El ARN del secreto se expone como output:

```hcl
output "db_master_user_secret_arn" {
  value = module.rds.db_instance_master_user_secret_arn
}
```

Las aplicaciones pueden recuperar la contraseña desde Secrets Manager usando el SDK de AWS, sin que ningún humano necesite conocerla.

### 1.6 Root Module — Interfaz simplificada

```hcl
module "corporate_rds" {
  source = "./modules/corporate-rds"

  project_name = var.project_name
  environment  = var.environment

  vpc_cidr          = "10.20.0.0/16"
  db_engine         = "mysql"
  db_engine_version = "8.0"
  db_instance_class = "db.t4g.micro"
  db_name           = "appdb"
  db_username       = "admin"

  tags = local.common_tags
}
```

El equipo de producto solo necesita decidir:
- ¿Qué motor? (`mysql`, `postgres`, `mariadb`)
- ¿Qué tamaño? (`db.t4g.micro`, `db.r6g.large`, etc.)
- ¿Cómo se llama la BD?

Todo lo demás (VPC, subredes, security groups, cifrado, protección, subnet groups) está resuelto por el wrapper. Compare esto con usar los módulos públicos directamente, que requieren decenas de parámetros.

---

## 2. Despliegue

```bash
cd labs/lab-24/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"
```

> **Nota:** `terraform init` descargará los módulos del Registry público (~30 segundos).

```bash
terraform apply
```

Terraform creará ~30 recursos: VPC completa (subredes, route tables, NAT Gateway, IGW), security group, instancia RDS, parameter group, option group, y el secreto con la contraseña.

> **Tiempo estimado:** ~10-15 minutos (la instancia RDS tarda en aprovisionarse).

```bash
terraform output
# vpc_id               = "vpc-0abc..."
# vpc_cidr             = "10.20.0.0/16"
# db_endpoint          = "lab24-db.xxxx.us-east-1.rds.amazonaws.com:3306"
# db_port              = 3306
# db_name              = "appdb"
# db_secret_arn        = "arn:aws:secretsmanager:...:rds!db-..."
# db_storage_encrypted = true
# db_deletion_protection = true
```

---

## 3. Verificación final

### 3.1 Verificar la VPC y subredes

```bash
VPC_ID=$(terraform output -raw vpc_id)

# Subredes por tipo
aws ec2 describe-subnets \
  --filters "Name=vpc-id,Values=$VPC_ID" \
  --query 'Subnets[].{ID: SubnetId, CIDR: CidrBlock, AZ: AvailabilityZone, Name: Tags[?Key==`Name`].Value | [0]}' \
  --output table
```

Debe mostrar 6 subredes: 2 públicas, 2 privadas, 2 de base de datos.

### 3.2 Verificar parámetros de seguridad de RDS

```bash
DB_ID=$(terraform output -raw db_endpoint | cut -d: -f1 | sed 's/.us-east-1.rds.amazonaws.com//')

aws rds describe-db-instances \
  --db-instance-identifier lab24-db \
  --query 'DBInstances[0].{
    Engine: Engine,
    StorageEncrypted: StorageEncrypted,
    DeletionProtection: DeletionProtection,
    PubliclyAccessible: PubliclyAccessible,
    MultiAZ: MultiAZ,
    Endpoint: Endpoint.Address
  }' \
  --output json
```

Debe mostrar:
- `StorageEncrypted: true` — hardcoded por el wrapper
- `DeletionProtection: true` — hardcoded por el wrapper
- `PubliclyAccessible: false` — hardcoded por el wrapper

### 3.3 Verificar security group

```bash
SG_ID=$(terraform output -raw security_group_id 2>/dev/null || \
  aws ec2 describe-security-groups \
    --filters "Name=vpc-id,Values=$VPC_ID" "Name=group-name,Values=lab24-rds-*" \
    --query 'SecurityGroups[0].GroupId' --output text)

aws ec2 describe-security-groups \
  --group-ids $SG_ID \
  --query 'SecurityGroups[0].IpPermissions[].{Port: FromPort, CIDR: IpRanges[].CidrIp}' \
  --output json
```

Debe mostrar que el ingreso solo está permitido desde los CIDRs de las subredes privadas (`10.20.10.0/24`, `10.20.11.0/24`).

### 3.4 Verificar la contraseña en Secrets Manager

```bash
SECRET_ARN=$(terraform output -raw db_secret_arn)

# Ver metadatos (sin el valor)
aws secretsmanager describe-secret \
  --secret-id $SECRET_ARN \
  --query '{Name: Name, Description: Description, RotationEnabled: RotationEnabled}'

# Recuperar la contraseña (solo para verificación)
aws secretsmanager get-secret-value \
  --secret-id $SECRET_ARN \
  --query 'SecretString' --output text | jq .
```

La contraseña fue generada automáticamente por RDS — ningún humano la eligió ni la vio durante el despliegue.

---

## 4. Reto: Refactorizacion con `moved {}` — Renombrar sin destruir

**Situación**: El equipo de arquitectura ha decidido renombrar el módulo interno `module.vpc` a `module.network` dentro del wrapper para alinearse con la nomenclatura del resto de módulos corporativos. El cambio debe ser transparente: **la VPC existente no se destruye ni se recrea**.

**Tu objetivo**:

1. Dentro de `modules/corporate-rds/main.tf`, renombrar `module "vpc"` a `module "network"`
2. Actualizar todas las referencias: `module.vpc.xxx` → `module.network.xxx`
3. Añadir un bloque `moved {}` que indique a Terraform que el módulo fue renombrado
4. Ejecutar `terraform plan` y verificar que muestra **0 cambios** (solo el moved)

**Pistas**:
- El bloque `moved {}` tiene `from` y `to` con las direcciones completas del recurso
- Para un módulo: `from = module.vpc` y `to = module.network`
- `terraform plan` debe mostrar algo como: `module.vpc has moved to module.network`
- Si ves recursos marcados para destruir y recrear, algo está mal en las referencias

La solución está en la [sección 5](#5-solución-del-reto).

---

## 5. Solución del Reto

### Paso 1: Renombrar el módulo y añadir `moved {}`

En `modules/corporate-rds/main.tf`:

```hcl
# ─── Bloque moved: indica que module.vpc ahora se llama module.network ───
moved {
  from = module.vpc
  to   = module.network
}

# ─── Módulo renombrado ───
module "network" {                           # Antes: module "vpc"
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.project_name}-vpc"
  cidr = var.vpc_cidr
  # ... (mismo contenido)
}
```

### Paso 2: Actualizar todas las referencias en `main.tf`

En `modules/corporate-rds/main.tf` hay **4 referencias** a `module.vpc.*` que hay que cambiar a `module.network.*`. Antes de empezar, lista las que tienes para no dejar ninguna olvidada:

```bash
grep -nE "module\.vpc\." modules/corporate-rds/main.tf
# 90:  vpc_id      = module.vpc.vpc_id
# 96:    cidr_blocks = module.vpc.private_subnets_cidr_blocks
# 164:  db_subnet_group_name   = module.vpc.database_subnet_group_name
# 166:  subnet_ids             = module.vpc.database_subnets
```

**Cambio 1 + 2** — bloque `resource "aws_security_group" "rds"`:

```hcl
resource "aws_security_group" "rds" {
  name_prefix = "${var.project_name}-rds-"
  description = "Acceso a RDS solo desde subredes privadas"
  vpc_id      = module.network.vpc_id          # ← Cambio 1 (antes: module.vpc.vpc_id)

  ingress {
    from_port   = var.db_port
    to_port     = var.db_port
    protocol    = "tcp"
    cidr_blocks = module.network.private_subnets_cidr_blocks  # ← Cambio 2
    description = "Acceso desde subredes privadas"
  }

  # egress, tags, lifecycle (sin cambios — no usan module.vpc.*)
}
```

**Cambio 3 + 4** — bloque `module "rds"`:

```hcl
module "rds" {
  source  = "terraform-aws-modules/rds/aws"
  version = "~> 6.0"

  # ... (parámetros del motor, hardcoded de cumplimiento, etc., sin cambios)

  # ─── OUTPUTS ENCADENADOS DEL MÓDULO VPC ───
  db_subnet_group_name   = module.network.database_subnet_group_name  # ← Cambio 3
  vpc_security_group_ids = [aws_security_group.rds.id]                # (sin cambios — referencia local)
  subnet_ids             = module.network.database_subnets            # ← Cambio 4

  # ... (multi_az, skip_final_snapshot, family, etc., sin cambios)
}
```

**Verificación**: tras los 4 cambios, no debería quedar ninguna referencia a `module.vpc.*` en `main.tf`:

```bash
grep -nE "module\.vpc\." modules/corporate-rds/main.tf
# (sin salida = todas las referencias migradas)
```

> **Nota:** las referencias a `aws_security_group.rds.id`, `var.db_*`, `local.*` y `data.aws_availability_zones` **no cambian** — solo se renombra el módulo VPC, no los demás recursos.

### Paso 3: Actualizar los outputs en `outputs.tf`

En `modules/corporate-rds/outputs.tf` hay **5 referencias** más a `module.vpc.*` que también hay que migrar (los outputs `db_*` apuntan a `module.rds`, no a la VPC, y NO se tocan):

```bash
grep -nE "module\.vpc\." modules/corporate-rds/outputs.tf
# 5:  value       = module.vpc.vpc_id
# 10: value       = module.vpc.vpc_cidr_block
# 15: value       = module.vpc.private_subnets
# 20: value       = module.vpc.database_subnets
# 25: value       = module.vpc.database_subnet_group_name
```

Cambia cada una a `module.network.*`:

```hcl
output "vpc_id" {
  value = module.network.vpc_id            # Antes: module.vpc.vpc_id
}

output "vpc_cidr" {
  value = module.network.vpc_cidr_block    # Antes: module.vpc.vpc_cidr_block
}

output "private_subnet_ids" {
  value = module.network.private_subnets   # Antes: module.vpc.private_subnets
}

output "database_subnet_ids" {
  value = module.network.database_subnets  # Antes: module.vpc.database_subnets
}

output "database_subnet_group_name" {
  value = module.network.database_subnet_group_name  # Antes: module.vpc...
}
```

**Verificación final** — combinada para `main.tf` + `outputs.tf`:

```bash
grep -rnE "module\.vpc\." modules/corporate-rds/
# (sin salida = las 9 referencias totales migradas: 4 en main.tf + 5 en outputs.tf)
```

### Paso 4: Re-ejecutar `terraform init`

Al renombrar un módulo que usa `source` del Registry, Terraform **necesita re-registrar el módulo con su nuevo nombre local**: el código fuente descargado del Registry se cachea en `.terraform/modules/<nombre-local>/`, así que el path cambia de `.terraform/modules/vpc/` a `.terraform/modules/network/`. Si saltas este paso, el siguiente `plan` falla inmediatamente con:

```
Error: Module not installed
  on modules/corporate-rds/main.tf line N:
   N: module "network" {
This module is not yet installed. Run "terraform init" to install all
modules required by this configuration.
```

Ejecuta:

```bash
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"
```

> **`init` es obligatorio aquí.** El cambio que hiciste en Paso 1 (renombrar `module "vpc"` → `module "network"`) toca la **interfaz de carga de módulos**, no solo el código. Sin `init` el plan ni siquiera arranca; con `init` Terraform descarga (o más bien, copia desde la caché) el módulo bajo el nuevo nombre y queda listo para evaluar el `moved {}`.

### Paso 5: Verificar el `moved {}` con `plan`

Ahora sí, comprueba que el rename se traduce en un `moved` y no en una destrucción:

```bash
# Tip opcional: -refresh=false acelera el plan saltándose la consulta a
# AWS para ver si la infraestructura ha cambiado fuera de Terraform.
# Útil cuando solo quieres validar el rename, no diff con AWS.
terraform plan -refresh=false
```

Debe mostrar algo como:

```
  # module.corporate_rds.module.vpc has moved to module.corporate_rds.module.network
    resource "aws_vpc" "this" {
        # (no changes)
    }

  # module.corporate_rds.module.vpc.aws_subnet.private["..."] has moved to
  # module.corporate_rds.module.network.aws_subnet.private["..."]
    resource "aws_subnet" "private" {
        # (no changes)
    }

  # ... (más moves sin cambios)

Plan: 0 to add, 0 to change, 0 to destroy.
```

**Cero destrucciones.** Terraform entiende que los recursos son los mismos, solo con un nombre diferente en el código.

> **⚠️ DETÉNTE antes del apply si ves esto:**
>
> ```
> # module.corporate_rds.module.vpc.aws_vpc.this will be destroyed
> - resource "aws_vpc" "this" { ... }
>
> # module.corporate_rds.module.network.aws_vpc.this will be created
> + resource "aws_vpc" "this" { ... }
>
> Plan: N to add, 0 to change, N to destroy.
> ```
>
> Eso significa que **Terraform no reconoció el rename como un `moved`** y va a destruir y recrear toda la infraestructura (VPC, subnets, NAT GW, RDS — todo). **NO ejecutes `apply`**. Cancela con `Ctrl+C` o responde `no`.
>
> Causas posibles, en orden de probabilidad:
>
> 1. **Falta el bloque `moved {}`** (Paso 1 incompleto). Verifica que existe en `modules/corporate-rds/main.tf`:
>
> 2. **Direcciones del `moved` mal escritas**. Las direcciones son **relativas** al módulo donde está el bloque. Como el `moved {}` vive dentro de `corporate-rds`, debe decir `from = module.vpc` y `to = module.network` — **NO** `module.corporate_rds.module.vpc`. Terraform añade el prefijo `module.corporate_rds.` automáticamente al evaluar.
>
> 3. **Falta `terraform init` tras el rename**. El módulo Registry se cachea bajo el nombre local; sin `init` el path nuevo no existe. Repite el `init` (ver inicio de este Paso 4).
>
> 4. **Quedan referencias huérfanas a `module.vpc.*`**. Aunque Terraform debería avisar con `Reference to undeclared module`, conviene verificar:
>
> Tras corregir lo que aplique, **vuelve a ejecutar `terraform plan`**. Solo cuando veas `has moved to` (no `destroyed`/`created`) está seguro continuar al apply.

### Paso 6: Aplicar y eliminar el bloque `moved {}` después

Una vez que el `plan` muestra solo `has moved to` sin cambios reales, ejecuta el `apply` para que Terraform **persista las nuevas direcciones en el state**:

```bash
terraform apply
# Plan: 0 to add, 0 to change, 0 to destroy.
# (los "moved" se aplican silenciosamente — solo reorganizan el state)
```

Tras este `apply`, el state ya tiene los recursos bajo `module.network.*` y **el bloque `moved {}` ha cumplido su función**. Lo correcto es **eliminarlo** del código:

```hcl
# ELIMINAR de modules/corporate-rds/main.tf:
# moved {
#   from = module.vpc
#   to   = module.network
# }
```

**¿Por qué eliminarlo?** Cuatro razones:

1. **Ya es ruido**: el rename está consolidado en el state, así que el bloque ya no hace nada — Terraform lo evalúa pero no produce efecto.
2. **Confunde al lector**: alguien que abra el código en seis meses verá un `moved {}` apuntando a un `module.vpc` que **no existe** y se preguntará si falta algo o si es código muerto.
3. **Acumulación**: si dejas todos los `moved {}` históricos en el código, en pocos años tendrás decenas inútiles que ofuscan el `main.tf`.
4. **Verificable**: tras eliminar el bloque, un `terraform plan` debe seguir mostrando `Plan: 0 to add, 0 to change, 0 to destroy.` — confirma que el `moved` ya cumplió su papel y se puede borrar sin riesgo.

```bash
# Tras eliminar el moved {} y guardar el archivo:
terraform plan
# Plan: 0 to add, 0 to change, 0 to destroy.   ← OK, el state ya estaba migrado
```

> **Política de equipo recomendada:** mantener el `moved {}` durante **al menos un ciclo de despliegue completo** en todos los entornos (dev → staging → prod) para que cada uno aplique el rename. Una vez el último entorno haya hecho `apply`, abrir un PR de limpieza que elimine el bloque. Documenta la fecha del PR en el commit message para tener trazabilidad.

### Reflexión: ¿cuándo usar `moved {}`?

| Escenario | ¿Usar `moved`? | Alternativa |
|---|---|---|
| Renombrar un módulo | Sí | `terraform state mv` (manual, arriesgado) |
| Renombrar un recurso | Sí | `terraform state mv` |
| Mover recurso a un módulo hijo | Sí | `terraform state mv` |
| Cambiar el `source` de un módulo | No (no aplica) | Recrear o importar |
| Cambiar `for_each` key | Sí (1.7+) | `terraform state mv` por cada recurso |

`moved {}` es preferible a `terraform state mv` porque:
1. Es **declarativo** — queda documentado en el código
2. Es **revisable** — se ve en el PR
3. Es **reproducible** — funciona en todos los entornos (dev, staging, prod)
4. Es **seguro** — `terraform plan` muestra el resultado antes de aplicar

---

## 6. Reto 2: Añadir parameter group con estándares de seguridad

**Situación**: El equipo de seguridad requiere que todas las bases de datos MySQL tengan habilitado `require_secure_transport` (forzar conexiones SSL) y `log_bin_trust_function_creators` desactivado. Estos parámetros deben estar hardcoded en el wrapper, igual que el cifrado y la protección contra borrado.

**Tu objetivo**:

1. Crear un `aws_db_parameter_group` dentro del wrapper con los parámetros de seguridad
2. Pasar el parameter group al módulo RDS usando `parameter_group_name`
3. Desactivar la creación del parameter group interno del módulo RDS (`create_db_parameter_group = false`)
4. Verificar con AWS CLI que los parámetros están aplicados

**Pistas**:
- El `family` del parameter group para MySQL 8.0 es `"mysql8.0"`
- `require_secure_transport = "1"` fuerza SSL
- `log_bin_trust_function_creators = "0"` desactiva la creación de funciones inseguras
- El módulo RDS acepta `parameter_group_name` como input y `create_db_parameter_group = false` para no crear uno interno
- Después de aplicar, verifica con: `aws rds describe-db-parameters --db-parameter-group-name <name> --query 'Parameters[?ParameterName==\`require_secure_transport\`]'`

La solución está en la [sección 7](#7-solución-del-reto-2).

---

## 7. Solución del Reto 2

### Paso 1: Parameter group en el wrapper

En `modules/corporate-rds/main.tf`, añadir antes del módulo RDS:

```hcl
resource "aws_db_parameter_group" "corporate" {
  name_prefix = "${var.project_name}-corporate-"
  family      = "${var.db_engine}${var.db_engine_version}"
  description = "Parámetros de seguridad corporativos para ${var.db_engine}"

  # ─── PARÁMETROS HARDCODED DE SEGURIDAD ───
  # Cada parámetro de RDS se clasifica como "dinámico" o "estático" según
  # si el motor puede aplicarlo en caliente o necesita reinicio:
  #   - dinámico → apply_method = "immediate" (default), se aplica al instante
  #   - estático → apply_method = "pending-reboot" obligatorio, se aplica
  #                en el siguiente reinicio de la BD
  parameter {
    # Dinámico — se aplica de inmediato sin reinicio.
    name  = "require_secure_transport"
    value = "1"
  }

  parameter {
    # Estático — siempre requiere reboot. Si omites apply_method o pones
    # "immediate", terraform apply falla con un error de RDS API.
    name         = "log_bin_trust_function_creators"
    value        = "0"
    apply_method = "pending-reboot"
  }

  tags = merge(local.effective_tags, {
    Name = "${var.project_name}-corporate-pg"
  })

  lifecycle {
    create_before_destroy = true
  }
}
```

### Paso 2: Pasar al módulo RDS

```hcl
module "rds" {
  # ...

  # Parameter group corporativo (en lugar del generado por el módulo)
  create_db_parameter_group = false
  parameter_group_name      = aws_db_parameter_group.corporate.name

  # ...
}
```

### Paso 3: Verificar

```bash
terraform apply

# Listar parámetros del parameter group
PG_NAME=$(aws rds describe-db-instances \
  --db-instance-identifier lab24-db \
  --query 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' \
  --output text)

aws rds describe-db-parameters \
  --db-parameter-group-name $PG_NAME \
  --query 'Parameters[?ParameterName==`require_secure_transport`].{Name: ParameterName, Value: ParameterValue}' \
  --output table
# require_secure_transport = 1

aws rds describe-db-parameters \
  --db-parameter-group-name $PG_NAME \
  --query 'Parameters[?ParameterName==`log_bin_trust_function_creators`].{Name: ParameterName, Value: ParameterValue}' \
  --output table
# log_bin_trust_function_creators = 0
```

### Reflexión: capas de seguridad en el wrapper

Después de los dos retos, el wrapper corporativo impone 6 estándares de seguridad:

| Capa | Estándar | Mecanismo |
|---|---|---|
| Red | Sin acceso público | `publicly_accessible = false` hardcoded |
| Red | Acceso solo desde subredes privadas | Security group en el wrapper |
| Almacenamiento | Cifrado en reposo | `storage_encrypted = true` hardcoded |
| Disponibilidad | Protección contra borrado | `deletion_protection = true` hardcoded |
| Conexión | SSL obligatorio | Parameter group: `require_secure_transport = 1` |
| Credenciales | Contraseña auto-gestionada | `manage_master_user_password = true` |

Ninguno de estos puede ser desactivado por los equipos de producto. Si necesitan una excepción, deben solicitarla al equipo de plataforma, que puede crear una variante del wrapper o añadir un flag controlado.

---

## 8. Limpieza

El wrapper tiene **`deletion_protection = true`** hardcoded ([`modules/corporate-rds/main.tf`](aws/modules/corporate-rds/main.tf), bloque `module "rds"`). Si intentas `terraform destroy` directamente, AWS rechaza la operación con `Cannot delete protected DB instance`. Es **intencional** — borrar una base de datos requiere un paso deliberado, no un `terraform destroy` accidental.

### Paso 1: Desactivar protección temporalmente

Edita `modules/corporate-rds/main.tf` y localiza el bloque `module "rds"`. Cambia la línea:

```hcl
  deletion_protection = true  # Protección contra borrado accidental
```

a:

```hcl
  deletion_protection = false # Temporal: SOLO durante el destroy del lab
```

Aplica el cambio para que AWS desactive la protección en la instancia RDS existente (este `apply` no destruye nada, solo modifica un atributo de la BD):

```bash
terraform apply
# Plan: 0 to add, 1 to change, 0 to destroy.
#   ~ deletion_protection = true -> false
```

### Paso 2: Destruir

```bash
terraform destroy
```

> **Nota:** la destrucción tarda ~5-10 minutos (RDS hace shutdown ordenado).

### Paso 3: Restaurar la protección si vas a redesplegar

Si después de destruir vas a volver a desplegar el lab (o reutilizar el wrapper en otro proyecto), **revierte el cambio** a `deletion_protection = true` en el código. Dejar el wrapper con `false` rompería su contrato corporativo.

> **Nota:** En producción, este paso manual es **intencional** — destruir una base de datos requiere una acción deliberada, no un `terraform destroy` accidental. El laboratorio sí crea recursos propios (VPC, RDS, secret) que se destruyen aquí; no destruyas el bucket de tfstate del lab02 (`terraform-state-labs-<ACCOUNT_ID>`), ya que es un recurso compartido entre laboratorios.

---

## 9. LocalStack

RDS **no está disponible** en LocalStack Community Edition. Este laboratorio requiere una cuenta de AWS real.

Consulta [localstack/README.md](localstack/README.md) para más detalles.

---

## Buenas prácticas aplicadas

- **Módulos wrapper como capa de control corporativo**: el wrapper impone estándares de seguridad (cifrado, deletion protection, backup) que los equipos de desarrollo no pueden desactivar, garantizando cumplimiento sin fricción.
- **Encadenamiento de outputs entre módulos**: pasar `module.vpc.vpc_id` y `module.vpc.private_subnets` como inputs del módulo RDS demuestra el patrón de composición modular, la base de la reutilización en Terraform.
- **`moved {}` para refactorizar sin destruir**: los bloques `moved` permiten renombrar recursos o moverlos entre módulos manteniendo el estado intacto. Son preferibles a `terraform state mv` porque el cambio queda documentado en código.
- **Defaults razonables en el wrapper, obligatorios solo lo crítico**: un wrapper corporativo sirve para **reducir fricción** al consumidor, así que la mayoría de variables (`db_engine`, `db_engine_version`, `db_instance_class`, etc.) tienen defaults sensatos (`mysql 8.0`, `db.t4g.micro`) — el equipo de producto solo decide lo que de verdad varía. Lo único realmente obligatorio (sin `default`) es `project_name`, porque sin nombre no hay aislamiento de recursos. Este patrón es opuesto al de un módulo low-level (donde cada variable suele ser obligatoria para forzar elección consciente): un wrapper opina por defecto y el consumidor solo sobreescribe lo que necesita.
- **`manage_master_user_password = true`**: delegar la gestión de credenciales a Secrets Manager elimina la necesidad de pasar contraseñas como variables de Terraform, que pueden quedar en el estado en texto claro.
- **Módulos del Registry versionados con `~>`**: fijar la versión mínima con el operador pessimistic constraint `~>` permite actualizaciones de patch automáticas pero evita cambios de minor o major inesperados.

---

## Recursos

- [Terraform: Module Composition](https://developer.hashicorp.com/terraform/language/modules/develop/composition)
- [Terraform: `moved` blocks](https://developer.hashicorp.com/terraform/language/modules/develop/refactoring)
- [Terraform Registry: VPC Module](https://registry.terraform.io/modules/terraform-aws-modules/vpc/aws/latest)
- [Terraform Registry: RDS Module](https://registry.terraform.io/modules/terraform-aws-modules/rds/aws/latest)
- [AWS: RDS Encryption](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/Overview.Encryption.html)
- [AWS: RDS Deletion Protection](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_DeleteInstance.html)
- [AWS: Managing Master User Password with Secrets Manager](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/rds-secrets-manager.html)
- [AWS: RDS Parameter Groups](https://docs.aws.amazon.com/AmazonRDS/latest/UserGuide/USER_WorkingWithParamGroups.html)
