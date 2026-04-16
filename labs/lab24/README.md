# Laboratorio 24 — Composición de Módulos Públicos con Estándares Corporativos

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

- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.5

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
echo "Bucket: $BUCKET"
```

> **Aviso de coste:** Este laboratorio crea una instancia RDS (`db.t4g.micro`) que tiene coste por hora. Destruye los recursos al finalizar para evitar cargos innecesarios.

## Estructura del proyecto

```
lab24/
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
│  │ vpc_id ─────────────────┐  │   │ storage_encrypted = true ⬅  │   │
│  │ database_subnet_group   │  │   │deletion_protection = true⬅  │   │
│  │ private_subnets_cidr    │  │   │ publicly_accessible = false⬅│   │
│  └─────────────────────────┤──┘   └──────────────────────────────┘   │
│                            │                                         │
│  ┌─────────────────────────▼──┐   ⬅ = Hardcoded (no overridable)    │
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
  storage_encrypted   = true    # Cifrado en reposo obligatorio
  deletion_protection = true    # Protección contra borrado accidental
  publicly_accessible = false   # Sin acceso público NUNCA
}
```

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
cd labs/lab24/aws

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

## Verificación final

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

### Paso 2: Actualizar todas las referencias

```hcl
# Security group
resource "aws_security_group" "rds" {
  vpc_id = module.network.vpc_id            # Antes: module.vpc.vpc_id
  # ...
  ingress {
    cidr_blocks = module.network.private_subnets_cidr_blocks  # Antes: module.vpc...
  }
}

# Módulo RDS
module "rds" {
  # ...
  db_subnet_group_name = module.network.database_subnet_group_name  # Antes: module.vpc...
  subnet_ids           = module.network.database_subnets            # Antes: module.vpc...
}
```

### Paso 3: Actualizar los outputs

En `modules/corporate-rds/outputs.tf`:

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

### Paso 4: Re-inicializar y verificar con plan

Al renombrar un módulo que usa `source` del Registry, Terraform necesita re-registrar el módulo con su nuevo nombre local. Ejecuta `terraform init` antes del plan:

```bash
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform plan
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
  parameter {
    name  = "require_secure_transport"
    value = "1"
  }

  parameter {
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

Dado que el wrapper tiene `deletion_protection = true`, antes de destruir debes desactivarlo:

### Paso 1: Desactivar protección temporalmente

En `modules/corporate-rds/main.tf`, cambiar en el módulo RDS:

```hcl
deletion_protection = false    # Temporalmente para destruir
```

Aplicar el cambio:

```bash
terraform apply
```

### Paso 2: Destruir

```bash
terraform destroy \
  -var="region=us-east-1"
```

### Paso 3: Restaurar la protección

Si vas a seguir usando el wrapper, revierte `deletion_protection = true`.

> **Nota:** En producción, este paso manual es **intencional** — destruir una base de datos requiere una acción deliberada, no un `terraform destroy` accidental. No destruyas el bucket S3 del lab02.

---

## 9. LocalStack

RDS **no está disponible** en LocalStack Community Edition. Este laboratorio requiere una cuenta de AWS real.

Consulta [localstack/README.md](localstack/README.md) para más detalles.

---

## Buenas prácticas aplicadas

- **Módulos wrapper como capa de control corporativo**: el wrapper impone estándares de seguridad (cifrado, deletion protection, backup) que los equipos de desarrollo no pueden desactivar, garantizando cumplimiento sin fricción.
- **Encadenamiento de outputs entre módulos**: pasar `module.vpc.vpc_id` y `module.vpc.private_subnets` como inputs del módulo RDS demuestra el patrón de composición modular, la base de la reutilización en Terraform.
- **`moved {}` para refactorizar sin destruir**: los bloques `moved` permiten renombrar recursos o moverlos entre módulos manteniendo el estado intacto. Son preferibles a `terraform state mv` porque el cambio queda documentado en código.
- **Variables obligatorias sin default**: las variables que no tienen `default` son obligatorias, lo que garantiza que el consumidor del módulo debe pensar conscientemente en cada parámetro crítico.
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
