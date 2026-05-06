# Laboratorio 23 — Diseño de Interfaz Robusta y "Fail-Safe"

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 6 — Módulos de Terraform](../../modulos/modulo-06/README.md)


## Visión general

Crear módulos que validen los datos antes de intentar crear infraestructura en AWS. Aplicar cuatro técnicas de diseño defensivo dentro de módulos reutilizables: validación con regex para nombres de bucket, tipos complejos (`object`) para configuración de base de datos, variables sensibles para contraseñas, y postcondiciones que verifican el estado real del recurso creado.

## Conceptos clave

| Concepto | Descripción |
|---|---|
| **`validation`** | Bloque dentro de una variable que define reglas de validación. Si la condición es `false`, Terraform rechaza el valor **antes** de crear ningún recurso, ahorrando tiempo y evitando estados inconsistentes |
| **`can()` + `regex()`** | `can()` envuelve una expresión que podría fallar y devuelve `true`/`false`. Combinada con `regex()`, permite validar patrones como prefijos, formatos de nombre, o estructuras de CIDR |
| **`object({})`** | Tipo compuesto que define una estructura con campos tipados. Permite agrupar configuraciones relacionadas en una sola variable en vez de tener decenas de variables sueltas |
| **`optional(type, default)`** | Marca un campo de un `object` como opcional con un valor por defecto. Disponible desde Terraform 1.3. Reduce la carga del usuario al invocar el módulo |
| **`sensitive = true`** | Marca una variable para que su valor no aparezca en la salida de `terraform plan` ni `terraform apply`. El valor **sí** se almacena en el archivo de estado — por eso el estado debe estar cifrado |
| **`postcondition`** | Bloque dentro de `lifecycle` que valida el estado **después** de crear o actualizar un recurso. Usa `self` para referenciar los atributos reales del recurso. Ideal para validaciones que dependen de datos calculados por AWS |
| **`precondition`** | Similar a `postcondition`, pero se evalúa **antes** de crear el recurso. Útil para validar relaciones entre variables o datos externos |

## Comparativa: Donde validar

| Mecanismo | Cuándo se evalúa | Tiene acceso a | Caso de uso |
|---|---|---|---|
| `validation` en variable | Al asignar el valor | Solo la propia variable | Formato, rango, patrón de un solo campo |
| `precondition` en recurso | Antes del plan/apply | Variables, data sources, otros recursos | Relaciones entre múltiples valores |
| `postcondition` en recurso | Después del apply | `self` (atributos reales del recurso) | Verificar lo que AWS realmente asignó |
| `check` block (Terraform 1.5+) | Después del apply | Todo | Validaciones no bloqueantes (warnings) |

## Prerrequisitos

- Laboratorio 02 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.10 (necesario para `use_lockfile` en el backend S3)

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
echo "Bucket: $BUCKET"
```

## Estructura del proyecto

```
lab-23/
├── README.md                                <- Esta guía
├── arch/
│   └── diagrama.svg                         <- Diagrama de la arquitectura del lab
├── aws/
│   ├── providers.tf                         <- Backend S3 parcial
│   ├── variables.tf                         <- Variables del Root Module
│   ├── main.tf                              <- Root Module: invoca 3 módulos
│   ├── outputs.tf                           <- Outputs delegados a los módulos
│   ├── aws.s3.tfbackend                     <- Parámetros del backend (sin bucket)
│   └── modules/
│       ├── validated-bucket/                <- Módulo S3 con regex en el nombre
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       ├── db-config/                       <- Módulo DB con object, sensitive y SSM
│       │   ├── main.tf
│       │   ├── variables.tf
│       │   └── outputs.tf
│       └── safe-network/                    <- Módulo VPC con postcondition RFC 1918
│           ├── main.tf
│           ├── variables.tf
│           └── outputs.tf
└── localstack/
    ├── README.md                            <- Guía específica para LocalStack
    ├── providers.tf
    ├── variables.tf
    ├── main.tf                              <- Root Module adaptado
    ├── outputs.tf
    ├── localstack.s3.tfbackend
    └── modules/                             <- Mismos módulos adaptados
        ├── validated-bucket/
        ├── db-config/
        └── safe-network/
```

## Análisis del código

### Arquitectura del laboratorio

![Root Module orquesta 3 módulos con tres técnicas distintas de validación: validation, object+sensitive, postcondition](arch/diagrama.svg)

Cada módulo encapsula una técnica de validación diferente. El Root Module los orquesta pasando variables y etiquetas comunes:

- **`safe-network`** — `lifecycle.postcondition` con regex RFC 1918 sobre `self.cidr_block` (validación **después** del create, sobre el atributo real que devolvió AWS).
- **`validated-bucket`** — `validation` en la variable `bucket_name` con `can(regex(...))` que exige el prefijo `empresa-` (validación **antes** del plan, sin tocar la API de AWS).
- **`db-config`** — `variable "db_config"` de tipo `object({})` con `optional(...)` para campos con default + `db_password` marcada como `sensitive` (oculta en logs / plan / apply pero sí en state).

### Módulo `validated-bucket` — Regex en la interfaz del módulo

```hcl
# modules/validated-bucket/variables.tf

variable "bucket_name" {
  type        = string
  description = "Nombre del bucket S3. Debe comenzar con el prefijo corporativo 'empresa-'"

  validation {
    condition     = can(regex("^empresa-[a-z0-9][a-z0-9.-]{1,53}[a-z0-9]$", var.bucket_name))
    error_message = "El nombre del bucket debe comenzar con 'empresa-', contener solo minúsculas, números, puntos y guiones, y tener entre 11 y 63 caracteres en total."
  }
}
```

Desglose de la regex `^empresa-[a-z0-9][a-z0-9.-]{1,53}[a-z0-9]$`:

| Parte | Caracteres | Significado |
|---|---:|---|
| `^empresa-` | 8 | Debe empezar con el prefijo corporativo `empresa-` |
| `[a-z0-9]` | 1 | Primer carácter del sufijo: letra minúscula o número (no punto ni guión al inicio) |
| `[a-z0-9.-]{1,53}` | 1–53 | Cuerpo: letras, números, puntos o guiones |
| `[a-z0-9]$` | 1 | Último carácter: letra minúscula o número (no punto ni guión al final) |
| **Total** | **11–63** | Ajustado al límite de naming de S3 (3–63 chars). |

La función `can()` envuelve `regex()` para que devuelva `true`/`false` en vez de lanzar un error si la regex no coincide. Sin `can()`, una regex que no coincide haría fallar Terraform con un error críptico en lugar del `error_message` personalizado.

**¿Qué pasa si el nombre es inválido?**

```bash
terraform apply -var='bucket_name=MiBucket' -var='db_password=MiPassword123Seguro'
# Error: Invalid value for variable
#   El nombre del bucket debe comenzar con 'empresa-', contener solo
#   minúsculas, números, puntos y guiones, y tener entre 11 y 63 caracteres
#   en total.
```

Terraform rechaza el valor **antes** de contactar con AWS. No se crea ningún recurso, no se gasta dinero, no hay estado inconsistente.

La validación está **dentro del módulo**, no en el Root Module. Esto significa que cualquier equipo que reutilice `validated-bucket` obtendrá la validación gratis, sin necesidad de recordar añadirla.

### Módulo `db-config` — Tipos complejos y secretos

#### Variable `object` con campos opcionales

```hcl
# modules/db-config/variables.tf

variable "db_config" {
  type = object({
    engine            = string
    engine_version    = string
    instance_class    = string
    allocated_storage = number
    port              = optional(number, 3306)
    multi_az          = optional(bool, false)
    backup_retention_days = optional(number, 7)
  })
  ...
}
```

| Campo | Tipo | ¿Obligatorio? | Default |
|---|---|---|---|
| `engine` | `string` | Sí | — |
| `engine_version` | `string` | Sí | — |
| `instance_class` | `string` | Sí | — |
| `allocated_storage` | `number` | Sí | — |
| `port` | `number` | No | `3306` |
| `multi_az` | `bool` | No | `false` |
| `backup_retention_days` | `number` | No | `7` |

`optional(number, 3306)` significa: "si el usuario no proporciona este campo, usa `3306`". El Root Module solo necesita especificar lo esencial:

```hcl
# Mínimo requerido (los opcionales usan sus defaults)
db_config = {
  engine            = "mysql"
  engine_version    = "8.0"
  instance_class    = "db.t4g.micro"
  allocated_storage = 20
}
```

**Validaciones múltiples en la misma variable:**

```hcl
validation {
  condition     = contains(["mysql", "postgres", "mariadb"], var.db_config.engine)
  error_message = "El motor de base de datos debe ser uno de: mysql, postgres, mariadb."
}

validation {
  condition     = var.db_config.allocated_storage >= 20 && var.db_config.allocated_storage <= 1000
  error_message = "El almacenamiento debe estar entre 20 y 1000 GB."
}
```

Terraform evalúa todos los bloques `validation` y reporta **todos** los errores a la vez, no solo el primero.

#### Variable sensible — `db_password`

```hcl
variable "db_password" {
  type        = string
  sensitive   = true

  validation {
    condition     = length(var.db_password) >= 12
    error_message = "La contraseña debe tener al menos 12 caracteres."
  }

  validation {
    condition     = can(regex("[A-Z]", var.db_password))
    error_message = "La contraseña debe contener al menos una letra mayúscula (A-Z)."
  }

  validation {
    condition     = can(regex("[a-z]", var.db_password))
    error_message = "La contraseña debe contener al menos una letra minúscula (a-z)."
  }

  validation {
    condition     = can(regex("[0-9]", var.db_password))
    error_message = "La contraseña debe contener al menos un dígito (0-9)."
  }
}
```

> **Por qué cuatro `validation` separadas y no una compuesta:** Terraform evalúa **todos** los bloques `validation` y reporta cada error que falla. Si fusionáramos las cuatro reglas en una sola condición (`length(...) >= 12 && can(regex(...))[A-Z] && ...`), un fallo solo daría un mensaje genérico ("la contraseña no cumple los requisitos") y el alumno tendría que adivinar **qué** falta. Con bloques separados, el output dice exactamente "falta una letra mayúscula" o "es demasiado corta" — y si fallan varias reglas a la vez, las muestra todas.

**¿Qué hace `sensitive = true`?**

| Aspecto | Sin `sensitive` | Con `sensitive = true` |
|---|---|---|
| `terraform plan` | Muestra el valor en texto plano | Muestra `(sensitive value)` |
| `terraform apply` | Muestra el valor en texto plano | Muestra `(sensitive value)` |
| `terraform output` | Muestra el valor | Error: requiere `-json` o `-raw` |
| Archivo de estado | Texto plano | **Texto plano (idéntico — `sensitive` NO cifra)** |
| Logs de CI/CD | Visible | Oculto |

> **Advertencia crítica:** `sensitive = true` oculta el valor de la **interfaz**, pero **no lo cifra** en el archivo de estado (`terraform.tfstate`). Por eso el backend S3 debe tener `encrypt = true` y el acceso al bucket debe estar restringido con IAM.

El módulo almacena la contraseña en AWS Secrets Manager:

```hcl
resource "aws_secretsmanager_secret_version" "db_password" {
  secret_id     = aws_secretsmanager_secret.db_password.id
  secret_string = var.db_password
}
```

Y la configuración se desestructura en SSM Parameter Store:

```hcl
resource "aws_ssm_parameter" "db_engine" {
  name  = "/${var.project_name}/db/engine"
  value = var.db_config.engine      # Accede al campo 'engine' del objeto
}

resource "aws_ssm_parameter" "db_config_json" {
  name  = "/${var.project_name}/db/config"
  value = jsonencode(var.db_config)  # Serializa el objeto completo a JSON
}
```

### Módulo `safe-network` — Postcondición RFC 1918

```hcl
# modules/safe-network/main.tf

resource "aws_vpc" "this" {
  cidr_block = var.vpc_cidr
  ...

  lifecycle {
    postcondition {
      condition = anytrue([
        can(regex("^10\\.", self.cidr_block)),
        can(regex("^172\\.(1[6-9]|2[0-9]|3[01])\\.", self.cidr_block)),
        can(regex("^192\\.168\\.", self.cidr_block)),
      ])
      error_message = "El CIDR ${self.cidr_block} no es un rango privado RFC 1918."
    }
  }
}
```

**¿Por qué postcondition y no validation?**

- `validation` solo accede a la propia variable → podría validar `var.vpc_cidr`
- `postcondition` accede a `self` → valida el CIDR **real** que AWS asignó al recurso

En este caso, el CIDR proviene directamente de la variable, pero en escenarios reales AWS podría modificar o normalizar valores. La postcondición garantiza que el **resultado real** cumple los requisitos, no solo la intención.

**Rangos RFC 1918 (IPs privadas):**

| Rango | CIDR | Regex |
|---|---|---|
| Clase A | `10.0.0.0/8` | `^10\\.` |
| Clase B | `172.16.0.0/12` | `^172\.(1[6-9]\|2[0-9]\|3[01])\.` |
| Clase C | `192.168.0.0/16` | `^192\.168\.` |

`anytrue()` devuelve `true` si **cualquiera** de las regex coincide. Si el CIDR es `52.0.0.0/16` (IP pública), ninguna regex coincide y la postcondición falla:

```
Error: Resource postcondition failed
  on modules/safe-network/main.tf line XX:
  El CIDR 52.0.0.0/16 no es un rango privado RFC 1918.
```

### Root Module — Orquestación de módulos

```hcl
# main.tf (Root Module)

locals {
  common_tags = {
    Environment = var.environment
    ManagedBy   = "terraform"
    Project     = var.project_name
  }
}

module "network" {
  source       = "./modules/safe-network"
  vpc_cidr     = var.vpc_cidr
  project_name = var.project_name
  environment  = var.environment
  tags         = local.common_tags
}

module "corporate_bucket" {
  source        = "./modules/validated-bucket"
  bucket_name   = var.bucket_name
  force_destroy = true
  tags = merge(local.common_tags, {
    Purpose = "corporate-data"
  })
}

module "database" {
  source       = "./modules/db-config"
  project_name = var.project_name
  db_config    = var.db_config
  db_password  = var.db_password
  tags         = local.common_tags
}
```

El Root Module es limpio y declarativo: define **qué** quiere (una red segura, un bucket validado, una configuración de DB) y delega el **cómo** a cada módulo. Las validaciones están encapsuladas — el Root Module no necesita saber los detalles de la regex o la postcondición.

---

## Despliegue

```bash
cd labs/lab-23/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"
```

El `apply` requiere dos valores sin default: `bucket_name` y `db_password`:

```bash
terraform apply \
  -var="bucket_name=empresa-lab23-data-${ACCOUNT_ID}" \
  -var='db_password=MiPassword123Seguro'
```

> **Importante — el prefijo `empresa-`:** el módulo `validated-bucket` exige que el nombre empiece por `empresa-` (sección 1.2). Si lo pasas sin el prefijo (`lab23-data-${ACCOUNT_ID}`), Terraform aborta el `apply` antes de crear nada con `Error: Invalid value for variable`. Ese fallo es la prueba operativa de que la validación funciona — pero para el despliegue del lab base usa el nombre con prefijo como se muestra arriba.

Terraform creará **12 recursos** en la versión `aws/`: 1 VPC, 2 subredes privadas, 1 bucket S3 + 1 bloqueo público, 1 `aws_secretsmanager_secret` + 1 `aws_secretsmanager_secret_version`, y 5 `aws_ssm_parameter` (engine, engine-version, instance-class, port y un JSON con toda la config).

> **Nota — versión LocalStack:** sustituye Secrets Manager por un `aws_ssm_parameter` SecureString adicional, así que crea **11 recursos** (1 SSM password + 5 SSM config = 6 SSM en total, más VPC, subnets, bucket y public_access_block).

```bash
terraform output
# vpc_id            = "vpc-0abc..."
# vpc_cidr          = "10.19.0.0/16"
# private_subnet_ids = ["subnet-...", "subnet-..."]
# bucket_id         = "empresa-lab23-data-123456789012"
# bucket_arn        = "arn:aws:s3:::empresa-lab23-data-123456789012"
# db_config_summary = {
#   engine         = "mysql"
#   engine_version = "8.0"
#   instance_class = "db.t4g.micro"
#   port           = 3306
#   multi_az       = false
#   storage_gb     = 20
#   backup_days    = 7
# }
# secret_arn        = "arn:aws:secretsmanager:us-east-1:...:secret:lab23/db-password-AbCdEf"
# ssm_prefix        = "/lab23/db/"
```

Nota que la contraseña **no aparece** en los outputs gracias a `sensitive = true`.

---

## Verificación final

### Probar que las validaciones rechazan valores inválidos

```bash
# Bucket sin prefijo corporativo → debe fallar
terraform plan -var="bucket_name=mi-bucket" -var='db_password=MiPassword123Seguro'
# Error: Invalid value for variable
#   El nombre del bucket debe comenzar con 'empresa-'...

# Motor de DB inválido → debe fallar
terraform plan \
  -var="bucket_name=empresa-test-bucket" \
  -var='db_password=MiPassword123Seguro' \
  -var='db_config={"engine":"oracle","engine_version":"19c","instance_class":"db.m5.large","allocated_storage":50}'
# Error: Invalid value for variable
#   El motor de base de datos debe ser uno de: mysql, postgres, mariadb.

# Contraseña corta → falla la validación de longitud
terraform plan -var="bucket_name=empresa-test-bucket" -var='db_password=corta'
# Error: Invalid value for variable
#   La contraseña debe tener al menos 12 caracteres.

# Contraseña suficientemente larga y con dígito pero sin mayúsculas → falla
# solo la regla de mayúscula:
terraform plan -var="bucket_name=empresa-test-bucket" -var='db_password=todoenlowercase123'
# Error: Invalid value for variable
#   La contraseña debe contener al menos una letra mayúscula (A-Z).

# Contraseña sin dígitos → falla solo la regla del dígito
terraform plan -var="bucket_name=empresa-test-bucket" -var='db_password=PasswordSinNumeros'
# Error: Invalid value for variable
#   La contraseña debe contener al menos un dígito (0-9).
```

Las cuatro reglas (`length`, mayúscula, minúscula, dígito) están en `validation` blocks separados — Terraform reporta **cada** una que falle, así que el alumno ve exactamente qué corregir en lugar de un mensaje genérico.

### Verificar el bucket S3

```bash
BUCKET_NAME=$(terraform output -raw bucket_id)

aws s3api head-bucket --bucket $BUCKET_NAME
# (sin error = el bucket existe)

aws s3api get-bucket-tagging --bucket $BUCKET_NAME \
  --query 'TagSet[].{Key: Key, Value: Value}' --output table
```

### Verificar la configuración en SSM

```bash
SSM_PREFIX=$(terraform output -raw ssm_prefix)

aws ssm get-parameters-by-path \
  --path "$SSM_PREFIX" \
  --query 'Parameters[].{Name: Name, Value: Value}' \
  --output table
```

Debe mostrar los parámetros individuales: engine, engine-version, instance-class, port, y el JSON completo de config.

### Verificar el secreto (sin exponer la contraseña)

```bash
SECRET_ARN=$(terraform output -raw secret_arn)

# Ver metadatos del secreto (sin el valor)
aws secretsmanager describe-secret \
  --secret-id $SECRET_ARN \
  --query '{Name: Name, Description: Description}' \
  --output json

# Recuperar el valor (solo si necesitas verificar)
aws secretsmanager get-secret-value \
  --secret-id $SECRET_ARN \
  --query 'SecretString' \
  --output text
```

### Probar la postcondición RFC 1918

```bash
# CIDR público → la postcondición debe fallar
terraform plan \
  -var="bucket_name=empresa-lab23-data-${ACCOUNT_ID}" \
  -var='db_password=MiPassword123Seguro' \
  -var="vpc_cidr=52.0.0.0/16"
```

> **Nota técnica — cuándo se evalúa una `postcondition`:** las postcondiciones se evalúan **después** de crear o actualizar el recurso (durante el apply). Sin embargo, desde Terraform 1.4+ el motor también las evalúa **al final del plan** cuando todos los valores referenciados (`self.*`) son ya conocidos en ese momento — es lo que ocurre aquí, porque `self.cidr_block` viene literalmente de la variable y no requiere creación previa para conocerse. Por eso este caso falla durante el `plan` y no llega al `apply`. En escenarios donde los atributos son **computados por AWS** (por ejemplo, `self.id` de un recurso recién creado), la postcondición solo puede evaluarse durante el `apply`, después de que AWS responda con el valor real.

---

## Retos

### Reto 1 — Precondición que valide el puerto según el motor

**Situación**: El equipo de DBA ha reportado errores de conexión porque los desarrolladores configuran motores de base de datos con puertos incorrectos (por ejemplo, MySQL en el puerto 5432 de PostgreSQL). Quieren que el módulo `db-config` rechace configuraciones donde el puerto no coincida con el motor.

**Tu objetivo**:

1. Añadir una `precondition` en el recurso `aws_ssm_parameter.db_port` del módulo `db-config` que valide la coherencia entre `var.db_config.engine` y `var.db_config.port`
2. Las reglas son:
   - `mysql` o `mariadb` → puerto debe ser `3306`
   - `postgres` → puerto debe ser `5432`
3. Probar con una configuración incoherente (MySQL en puerto 5432) y verificar que Terraform la rechaza
4. Probar con una configuración correcta (PostgreSQL en puerto 5432) y verificar que se acepta

**Pistas**:
- `precondition` va dentro del bloque `lifecycle {}` del recurso
- Puedes usar una expresión condicional: `var.db_config.engine == "postgres" ? 5432 : 3306`
- El `error_message` puede interpolar variables para ser más descriptivo
- Recuerda que `precondition` se evalúa **antes** de crear/actualizar el recurso

### Reto 2 — Variable de tipo `map(object)` para múltiples buckets validados

**Situación**: El equipo de plataforma quiere crear varios buckets corporativos de una sola vez usando el módulo `validated-bucket`, cada uno con su propia configuración. En lugar de duplicar bloques `module`, quieren definir todos los buckets en una sola variable de tipo `map(object)` y usar `for_each` sobre el módulo.

**Tu objetivo**:

1. Añadir una variable `extra_buckets` de tipo `map(object({...}))` en el Root Module con campos: `purpose` (string) y `force_destroy` (optional, bool, default true)
2. Añadir una `validation` que verifique que **todas** las claves del mapa comienzan con el prefijo `empresa-` (ya que serán los nombres de los buckets)
3. Invocar el módulo `validated-bucket` con `for_each` sobre la variable, pasando cada clave como `bucket_name`
4. Probar con un mapa de 2 buckets: `empresa-logs-<ACCOUNT_ID>` y `empresa-backups-<ACCOUNT_ID>`

**Pistas**:
- `alltrue()` combinada con `[for k, v in var.extra_buckets : can(regex("^empresa-", k))]` valida todas las claves
- `for_each = var.extra_buckets` en el bloque `module` itera sobre el mapa
- `each.key` es el nombre del bucket, `each.value` es el objeto con la configuración
- El módulo ya tiene su propia validación de regex, así que la del Root Module es una capa adicional

---

## Soluciones

<details>
<summary><strong>Solución al Reto 1 — Precondición que valide el puerto según el motor</strong></summary>

### Solución al Reto 1 — Precondición que valide el puerto según el motor

#### Paso 1: Precondición en el recurso del módulo

En `modules/db-config/main.tf`:

```hcl
locals {
  # Mapa engine → puerto estandar. Mas legible y escalable que un ternario
  # encadenado: añadir "oracle" = 1521 es trivial.
  default_db_ports = {
    mysql    = 3306
    mariadb  = 3306
    postgres = 5432
  }
}

resource "aws_ssm_parameter" "db_port" {
  name  = "/${var.project_name}/db/port"
  type  = "String"
  value = tostring(var.db_config.port)

  tags = var.tags

  lifecycle {
    precondition {
      condition     = var.db_config.port == local.default_db_ports[var.db_config.engine]
      error_message = "El puerto ${var.db_config.port} no es el estándar para el motor '${var.db_config.engine}'. Esperado: ${local.default_db_ports[var.db_config.engine]} (3306 para mysql/mariadb, 5432 para postgres)."
    }
  }
}
```

> **Alternativa más concisa:** la versión con un mapa `local` es más mantenible que un `if/else` encadenado. Para añadir un nuevo motor (`oracle = 1521`, `mssql = 1433`), basta con extender el mapa — no hay que tocar la condición. La validación con `contains([...], engine)` ya cubrió en `variables.tf` que `engine` esté en la lista permitida, así que el lookup `local.default_db_ports[engine]` es seguro.

#### Paso 2: Probar configuración incoherente

```bash
terraform plan \
  -var="bucket_name=empresa-lab23-data-${ACCOUNT_ID}" \
  -var='db_password=MiPassword123Seguro' \
  -var='db_config={"engine":"mysql","engine_version":"8.0","instance_class":"db.t4g.micro","allocated_storage":20,"port":5432}'
# Error: Resource precondition failed
#   El puerto 5432 no es el estándar para el motor 'mysql'.
#   Usa 3306 para mysql/mariadb o 5432 para postgres.
```

#### Paso 3: Probar configuración correcta

```bash
terraform apply \
  -var="bucket_name=empresa-lab23-data-${ACCOUNT_ID}" \
  -var='db_password=MiPassword123Seguro' \
  -var='db_config={"engine":"postgres","engine_version":"15.4","instance_class":"db.t4g.micro","allocated_storage":20,"port":5432}'
# Apply complete! Resources: ... added
```

#### Reflexión: ¿validation, precondition o postcondition?

| Escenario | Mecanismo | Razón |
|---|---|---|
| Formato de un solo campo (regex, rango) | `validation` | Solo depende de la propia variable |
| Coherencia entre campos de la misma variable | `validation` | Accede a `var.x.campo_a` y `var.x.campo_b` |
| Coherencia entre diferentes variables | `precondition` | `validation` solo accede a su propia variable |
| Verificar lo que AWS realmente creó | `postcondition` | Solo `self` tiene los valores reales post-apply |
| Advertencia no bloqueante | `check` block | No detiene el apply, solo muestra un warning |

---

</details>

<details>
<summary><strong>Solución al Reto 2 — Variable de tipo `map(object)` para múltiples buckets validados</strong></summary>

### Solución al Reto 2 — Variable de tipo `map(object)` para múltiples buckets validados

#### Paso 1: Variable con validación en el Root Module (`variables.tf`)

```hcl
variable "extra_buckets" {
  type = map(object({
    purpose       = string
    force_destroy = optional(bool, true)
  }))

  description = "Mapa de buckets adicionales. La clave es el nombre (debe empezar con 'empresa-')."
  default     = {}

  validation {
    condition     = alltrue([for k, _ in var.extra_buckets : can(regex("^empresa-", k))])
    error_message = "Todos los nombres de bucket deben comenzar con el prefijo 'empresa-'."
  }
}
```

`alltrue()` evalúa una lista de booleanos y devuelve `true` solo si **todos** son `true`. La comprensión `[for k, _ in var.extra_buckets : ...]` itera sobre las claves del mapa.

#### Paso 2: Módulo con `for_each` en el Root Module (`main.tf`)

```hcl
module "extra_buckets" {
  source   = "./modules/validated-bucket"
  for_each = var.extra_buckets

  bucket_name   = each.key
  force_destroy = each.value.force_destroy

  tags = merge(local.common_tags, {
    Purpose = each.value.purpose
  })
}
```

#### Paso 3: Output en el Root Module (`outputs.tf`)

```hcl
output "extra_bucket_ids" {
  description = "IDs de los buckets adicionales"
  value       = { for k, m in module.extra_buckets : k => m.bucket_id }
}
```

#### Paso 4: Invocar con 2 buckets

`-var` interpreta su valor como **HCL**, no como JSON. La sintaxis correcta para un `map(object)` con claves dinámicas (que contienen `${ACCOUNT_ID}`) es más legible si se pasa por archivo `.tfvars` o se construye con `printf`:

**Opción A — con archivo `extra_buckets.auto.tfvars`** (recomendado):

```hcl
# extra_buckets.auto.tfvars
extra_buckets = {
  "empresa-logs-123456789012"    = { purpose = "logs" }
  "empresa-backups-123456789012" = { purpose = "backups" }
}
```

```bash
terraform apply \
  -var="bucket_name=empresa-lab23-data-${ACCOUNT_ID}" \
  -var='db_password=MiPassword123Seguro'
# (extra_buckets.auto.tfvars se carga automáticamente)
```

**Opción B — inline con `printf`** (útil para CI/CD donde no quieres archivos extra):

```bash
EXTRA_BUCKETS=$(printf '{"empresa-logs-%s"={purpose="logs"},"empresa-backups-%s"={purpose="backups"}}' \
  "$ACCOUNT_ID" "$ACCOUNT_ID")

terraform apply \
  -var="bucket_name=empresa-lab23-data-${ACCOUNT_ID}" \
  -var='db_password=MiPassword123Seguro' \
  -var="extra_buckets=$EXTRA_BUCKETS"
```

> **Nota:** la sintaxis HCL para mapas usa `=` (no `:`), claves entre comillas dobles y valores object con `{ campo = "valor" }`. No mezclar con sintaxis JSON (`":"`) — Terraform rechazará el `-var` con un error de parseo.

#### Paso 5: Verificar

```bash
# Listar todos los buckets empresa-
aws s3 ls | grep empresa

# Verificar tags de cada uno
for BUCKET in $(aws s3 ls | grep empresa | awk '{print $3}'); do
  echo "=== $BUCKET ==="
  aws s3api get-bucket-tagging --bucket $BUCKET \
    --query 'TagSet[?Key==`Purpose`].Value' --output text
done
```

### Reflexión: doble capa de validación

En esta solución, la validación ocurre en dos niveles:

1. **Root Module** (`extra_buckets` validation): verifica que las claves empiecen con `empresa-` antes de invocar el módulo
2. **Módulo** (`bucket_name` validation): verifica la regex completa del nombre del bucket

¿Es redundante? No necesariamente:
- La validación del Root Module detecta errores temprano y da un mensaje genérico del mapa
- La validación del módulo es más estricta (regex completa) y protege contra invocaciones desde otros Root Modules
- En producción, el módulo puede publicarse en un registry y ser usado por equipos que **no** tienen la validación del Root Module

</details>

---

## Limpieza

```bash
terraform destroy \
  -var="bucket_name=empresa-lab23-data-${ACCOUNT_ID}" \
  -var='db_password=MiPassword123Seguro'
```

> **Nota:** Debes pasar las mismas variables obligatorias (`bucket_name` y `db_password`) en el `destroy` porque Terraform necesita evaluarlas para calcular el plan. El laboratorio sí crea un bucket S3 propio (`empresa-lab23-data-…`) que se destruirá; no destruyas el bucket de tfstate del lab-02 (`terraform-state-labs-<ACCOUNT_ID>`), ya que es un recurso compartido entre laboratorios.

---

## LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

LocalStack emula S3 y SSM Parameter Store en Community. Las validaciones, precondiciones y postcondiciones funcionan idénticamente porque son evaluadas por el motor de Terraform, no por el proveedor. La versión localstack usa SSM SecureString en lugar de Secrets Manager para la contraseña.

---

## Buenas prácticas aplicadas

- **Validación early-fail**: detectar errores en `terraform plan` (antes de cualquier llamada a AWS) es preferible a descubrirlos en mitad de un `terraform apply`. Las validaciones de variables permiten dar mensajes de error claros al desarrollador.
- **Variables sensibles para secretos**: marcar contraseñas como `sensitive = true` evita que aparezcan en el output de `plan`/`apply` y en los logs de CI/CD. **Importante:** `sensitive = true` **NO cifra** el valor en `terraform.tfstate` — el secreto se almacena ahí en texto plano. Por eso es **obligatorio** que el backend cifre el state (`encrypt = true` en S3, KMS para tfstate, o un backend con cifrado en reposo) y que el bucket / repositorio del state esté restringido por IAM. La directiva `sensitive` resuelve la fuga **por output**, no la fuga **por acceso al state**.
- **Postcondiciones para invariantes de estado**: verificar el estado real del recurso después de su creación (por ejemplo, que el bucket tiene public access bloqueado) detecta inconsistencias entre la configuración Terraform y el estado real de AWS.
- **Tipos complejos `object` para configuraciones relacionadas**: agrupar parámetros relacionados en un objeto en lugar de variables individuales previene configuraciones parcialmente incorrectas (por ejemplo, motor de BD y puerto inconsistentes).
- **`can()` para detección de errores sin fallo**: usar `can(regex(..., var.name))` permite evaluar si una expresión produce error sin que el plan falle, útil para validaciones condicionales.
- **`optional()` con defaults en tipos `object`**: proporcionar valores por defecto para atributos opcionales de un objeto hace que el módulo sea más ergonómico sin sacrificar seguridad.

---

## Recursos

- [Terraform: Input Variable Validation](https://developer.hashicorp.com/terraform/language/values/variables#custom-validation-rules)
- [Terraform: Preconditions and Postconditions](https://developer.hashicorp.com/terraform/language/validate)
- [Terraform: Type Constraints — `object`](https://developer.hashicorp.com/terraform/language/expressions/type-constraints#object)
- [Terraform: `optional()` modifier](https://developer.hashicorp.com/terraform/language/expressions/type-constraints#optional-object-type-attributes)
- [Terraform: Sensitive Variables](https://developer.hashicorp.com/terraform/language/values/variables#suppressing-values-in-cli-output)
- [Terraform: `can()` function](https://developer.hashicorp.com/terraform/language/functions/can)
- [Terraform: `regex()` function](https://developer.hashicorp.com/terraform/language/functions/regex)
- [AWS: S3 Bucket Naming Rules](https://docs.aws.amazon.com/AmazonS3/latest/userguide/bucketnamingrules.html)
- [AWS: Secrets Manager](https://docs.aws.amazon.com/secretsmanager/latest/userguide/intro.html)
- [RFC 1918: Address Allocation for Private Internets](https://datatracker.ietf.org/doc/html/rfc1918)
