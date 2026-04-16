# Sección 2 — Expresiones Avanzadas y Lifecycle

> [← Volver al índice](./README.md) | [Siguiente →](./03_providers_avanzados.md)

---

## 1. HCL como Lenguaje de Ingeniería

HCL no es solo configuración estática. Con expresiones `for`, `locals`, `try/can`, `optional()` y validaciones `lifecycle`, se convierte en un lenguaje capaz de generar infraestructura dinámica, genérica y reutilizable a escala empresarial.

> **El profesor explica:** "La diferencia entre un archivo Terraform de 50 líneas con duplicación y uno de 80 líneas completamente genérico está en saber usar `for`, `locals` y `merge`. El objetivo es escribir código que un nuevo miembro del equipo pueda entender y modificar sin romper nada — no impresionar con ingenio, sino eliminar repetición."

**Herramientas del arsenal avanzado:**

| Herramienta | Propósito |
|-------------|-----------|
| `for` | Transformar y filtrar colecciones |
| `locals` | Cálculos intermedios DRY |
| `flatten()` | Aplanar estructuras anidadas para `for_each` |
| `merge()` | Combinar mapas (base + overrides) |
| `try()` / `can()` | Manejo robusto de valores opcionales |
| `optional()` | Variables flexibles con defaults |
| `precondition` / `postcondition` | Validaciones en runtime |

---

## 2. Expresiones `for` — Transformar Datos

Las expresiones `for` convierten listas y mapas en nuevas colecciones. Sintaxis: `[for x in list : expr]` para listas, `{for k, v in map : k => expr}` para mapas.

```hcl
variable "subnets" {
  type = list(object({
    id   = string
    name = string
    tier = string  # "public" o "private"
  }))
}

locals {
  # Lista → Lista (filtrado con if)
  public_subnets = [
    for s in var.subnets : s.id
    if s.tier == "public"
  ]

  # Lista → Mapa (nombre => id)
  subnet_map = {
    for s in var.subnets : s.name => s.id
  }

  # Mapa → Lista de valores
  subnet_ids = [for k, v in var.subnet_map : v]

  # Transformar: ARNs desde nombres de buckets
  bucket_arns = [
    for name in var.bucket_names :
    "arn:aws:s3:::${name}"
  ]
}
```

**Casos de uso principales:**
- Filtrar recursos por atributo (`tier == "private"`).
- Convertir listas a mapas para `for_each`.
- Generar ARNs, names o tags a partir de variables.

---

## 3. `locals` — El Motor del Principio DRY

Los `locals` son variables internas del módulo que almacenan cálculos intermedios. Centralizan lógica que de otro modo se repetiría en múltiples recursos.

```hcl
locals {
  # Prefijo estándar para todos los recursos
  name_prefix = "${var.project}-${var.environment}"

  # Tags obligatorios de empresa
  common_tags = {
    Project     = var.project_name
    Environment = terraform.workspace
    ManagedBy   = "Terraform"
    Team        = var.team
    CostCenter  = var.cost_center
  }

  # Configuración que varía por entorno
  env_config = {
    dev = {
      ami           = "ami-0dev1234567890ab"
      instance_type = "t3.micro"
      disk_size     = 20
    }
    prod = {
      ami           = "ami-0prod987654321ab"
      instance_type = "m5.large"
      disk_size     = 100
    }
  }

  # Selección automática por workspace
  config = local.env_config[terraform.workspace]
}

resource "aws_instance" "app" {
  ami           = local.config.ami
  instance_type = local.config.instance_type

  tags = merge(local.common_tags, {
    Name = "${local.name_prefix}-app"
    Role = "application"
  })
}
```

**Patrón `env_config[terraform.workspace]`:** Un solo archivo HCL sirve a todos los entornos. No necesitas múltiples `.tfvars` para dev/staging/prod.

---

## 4. Flatten Pattern — De Anidado a `for_each`

`for_each` necesita un mapa plano o un set. Cuando los datos son anidados (un mapa con listas de valores), `flatten()` convierte la estructura en una lista plana.

```hcl
# Mapa anidado: VPCs con múltiples subredes
variable "vpcs" {
  default = {
    main = { cidrs = ["10.0.1.0/24", "10.0.2.0/24"] }
    dev  = { cidrs = ["10.1.1.0/24"] }
  }
}

locals {
  # Aplanar: lista de objetos {vpc_name, cidr}
  subnets = flatten([
    for vpc, config in var.vpcs : [
      for cidr in config.cidrs : {
        vpc_name = vpc
        cidr     = cidr
      }
    ]
  ])
}

resource "aws_subnet" "all" {
  # Convertir a mapa con clave única para for_each
  for_each = {
    for s in local.subnets : "${s.vpc_name}-${s.cidr}" => s
  }

  cidr_block = each.value.cidr
  # ...
}
```

**El flujo:**
1. Variable anidada → `flatten()` → lista plana.
2. Lista plana → `{for ...}` → mapa con clave única.
3. Mapa → `for_each` → recursos individuales.

---

## 5. Merge Pattern — Base + Overrides

`merge()` combina múltiples mapas en uno. El último mapa tiene prioridad en caso de conflicto. Ideal para tags: defines una base obligatoria y cada recurso puede añadir los suyos.

```hcl
locals {
  common_tags = {
    Project     = var.project_name
    Environment = terraform.workspace
    ManagedBy   = "Terraform"
    Team        = var.team
  }
}

# merge(): los tags específicos sobrescriben a los comunes si coinciden
resource "aws_instance" "web" {
  ami           = local.config.ami
  instance_type = local.config.instance_type

  tags = merge(local.common_tags, {
    Name = "${var.project_name}-web"
    Role = "webserver"
    # Sobreescribe Team si este recurso pertenece a otro equipo:
    # Team = "frontend"
  })
}

resource "aws_db_instance" "main" {
  # ...
  tags = merge(local.common_tags, {
    Name        = "${var.project_name}-db"
    Role        = "database"
    Backup      = "true"
    Sensitivity = "high"
  })
}
```

---

## 6. `try()` y `can()` — Resiliencia con Valores Opcionales

`try()` evalúa expresiones en orden y retorna la primera que no falle. `can()` retorna `true`/`false` según si la expresión es válida. Permiten módulos robustos que aceptan entradas incompletas.

```hcl
locals {
  # Si var.settings.timeout existe, úsalo; si no, 300
  timeout = try(var.settings.timeout, 300)

  # Acceso seguro a atributos anidados (sin null pointer)
  db_port = try(var.database.port, 5432)

  # Cadena de fallbacks
  region = try(
    var.override_region,
    var.default_region,
    "us-east-1",
  )
}

# can() para validar si una expresión es válida
locals {
  has_custom_dns = can(var.dns_config.zone_id)
}

resource "aws_route53_record" "app" {
  count   = local.has_custom_dns ? 1 : 0
  zone_id = var.dns_config.zone_id
  # ...
}
```

**Cuándo usar cada uno:**
- `try()` — Para obtener un valor con fallback cuando el atributo puede no existir.
- `can()` — Para bifurcar lógica según si una expresión es válida (`count = can(...) ? 1 : 0`).

---

## 7. `optional()` — Variables Flexibles (TF 1.3+)

`optional()` dentro de `type = object({})` permite definir campos que no son obligatorios. Si se omiten, toman `null` o el valor por defecto especificado.

```hcl
variable "servidor" {
  type = object({
    nombre     = string          # Obligatorio
    entorno    = string          # Obligatorio
    puerto     = optional(number, 8080)    # Default: 8080
    monitoring = optional(bool, true)      # Default: true
    tags       = optional(map(string), {}) # Default: mapa vacío
  })
}

# Llamada mínima (solo los obligatorios)
servidor = {
  nombre  = "web-prod"
  entorno = "production"
  # puerto = 8080 (automático)
  # monitoring = true (automático)
}

# Llamada completa (sobreescribir defaults)
servidor = {
  nombre     = "api-prod"
  entorno    = "production"
  puerto     = 3000
  monitoring = false
}
```

**Antes de `optional()`** los módulos tenían que gestionar `null` manualmente con `try()`. Con `optional()` y defaults, el módulo es autoexplicativo.

---

## 8. `precondition` y `postcondition` (TF 1.2+)

Los bloques de validación dentro de `lifecycle` permiten definir reglas que Terraform evalúa durante el plan (`precondition`) o después del apply (`postcondition`).

```hcl
resource "aws_instance" "web" {
  ami           = var.ami_id
  instance_type = var.instance_type

  lifecycle {
    # Evalúa en terraform plan — aborta si falla
    precondition {
      condition     = startswith(var.ami_id, "ami-")
      error_message = "El AMI debe iniciar con 'ami-'. Valor recibido: ${var.ami_id}"
    }

    # Evalúa después de terraform apply
    postcondition {
      condition     = self.public_ip != ""
      error_message = "La instancia debe tener IP pública. Verifica que public_ip_address está habilitado."
    }
  }
}

# Precondición en data source
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]

  lifecycle {
    postcondition {
      condition     = self.architecture == "x86_64"
      error_message = "La AMI seleccionada debe ser x86_64, no ${self.architecture}."
    }
  }
}
```

**`precondition` vs `variable validation`:**

| Herramienta | Evalúa | Accede a |
|-------------|--------|---------|
| `validation` en variable | Al parsear variables | Solo la variable propia |
| `precondition` en lifecycle | Durante `terraform plan` | Otras variables, locals, data sources |
| `postcondition` en lifecycle | Tras `terraform apply` | Atributos del recurso creado (`self`) |

---

## 9. Bloque `moved` — Refactorización Sin Destrucción (TF 1.1+)

```hcl
# Ejemplo 1: Renombrar un recurso
moved {
  from = aws_instance.server
  to   = aws_instance.web_server
}

# Ejemplo 2: Mover a un módulo
moved {
  from = aws_s3_bucket.data
  to   = module.storage.aws_s3_bucket.data
}

# Ejemplo 3: Cross-type (TF 1.9+)
moved {
  from = null_resource.bootstrap
  to   = terraform_data.bootstrap
}
```

**Flujo de trabajo:**
1. Renombrar el recurso en el código `.tf`.
2. Agregar bloque `moved { from, to }`.
3. `terraform plan` — muestra "moved" no "destroy + create".
4. `terraform apply` — ejecutar.
5. Eliminar el bloque `moved` (ya cumplió su función).

---

## 10. `replace_triggered_by` — Dependencias de Reemplazo (TF 1.2+)

Permite que un recurso sea recreado cuando otro recurso o atributo cambia, de forma declarativa.

```hcl
# Patrón recomendado con terraform_data como intermediario
resource "terraform_data" "ami_version" {
  input = var.ami_id   # Almacena el AMI actual
}

resource "aws_instance" "web" {
  ami           = var.ami_id
  instance_type = var.instance_type

  lifecycle {
    # Se recrea cuando el AMI cambia (vía terraform_data)
    replace_triggered_by = [terraform_data.ami_version]
  }
}
```

**Por qué usar `terraform_data` como intermediario:** `replace_triggered_by` acepta referencias a recursos, no a variables directamente. `terraform_data` actúa como wrapper que conecta el cambio en una variable con el trigger de reemplazo.

---

## 11. Resumen: Meta-argumentos `lifecycle`

```hcl
resource "aws_db_instance" "prod" {
  # ...

  lifecycle {
    # Zero-downtime replacements: crea antes de destruir
    create_before_destroy = true

    # Protección contra eliminación accidental
    prevent_destroy = true

    # Ignorar cambios externos (ej: autoscaling modifica desired_capacity)
    ignore_changes = [
      tags["LastUpdated"],
      password,   # Secrets Manager rota la contraseña
    ]

    # Recrear si el AMI de otra instancia cambia
    replace_triggered_by = [terraform_data.ami_tracker]

    # Validación: condition debe ser true para continuar
    precondition {
      condition     = var.environment == "production"
      error_message = "Este módulo solo aplica a producción."
    }
  }
}
```

| Meta-argumento | Uso principal |
|----------------|---------------|
| `create_before_destroy` | Zero-downtime en recreaciones |
| `prevent_destroy` | Proteger RDS, S3, KMS en producción |
| `ignore_changes` | Drift legítimo (autoscaling, secrets rotation) |
| `replace_triggered_by` | Forzar recreación por cambios en otros recursos |
| `precondition` | Validar supuestos antes del plan |
| `postcondition` | Verificar estado resultante tras apply |

---

> [← Volver al índice](./README.md) | [Siguiente →](./03_providers_avanzados.md)
