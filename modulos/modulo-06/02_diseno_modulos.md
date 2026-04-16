# Sección 2 — Diseño de Módulos Reutilizables

> [← Sección anterior](./01_fundamentos_modulos.md) | [Siguiente →](./03_fuentes_versionado.md)

---

## 2.1 La Filosofía: Abstracción y Encapsulación

Un módulo bien diseñado es una **API de infraestructura**. Igual que una función en programación oculta su implementación y expone solo lo necesario, un módulo oculta los 15+ recursos internos de una VPC y expone solo los parámetros que realmente importan al consumidor.

```
Sin módulo:  El desarrollador debe conocer y gestionar aws_vpc,
             aws_subnet, aws_route_table, aws_internet_gateway...
             15 recursos, 200 líneas de código.

Con módulo:  module "vpc" { vpc_cidr = "10.0.0.0/16" }
             2 líneas. El resto es un detalle de implementación.
```

El consumidor ve:
- `vpc_id = module.vpc.id` — el output exportado
- No ve los 15 recursos internos

---

## 2.2 La Interfaz: Convenciones de Naming y Tipos

Las variables son el **contrato** de tu módulo. Un contrato mal definido causa confusión, errores y módulos que nadie quiere usar.

```hcl
# ❌ EVITAR: Nombres vagos y tipos poco expresivos
variable "x" {
  type = string
}
variable "data" {
  type = map(any)   # ¿Qué contiene? ¿Qué keys?
}

# ✅ CORRECTO: Nombres descriptivos y tipos complejos
variable "vpc_cidr_block" {
  type        = string
  description = "CIDR block for the VPC (ej. 10.0.0.0/16)"
}

variable "db_config" {
  type = object({
    engine   = string
    version  = string
    size_gb  = number
  })
  description = "Configuración del motor de base de datos"
}
```

Los tipos `object({})` son especialmente valiosos: fuerzan que el consumidor pase exactamente los campos esperados con los tipos correctos. Si pasa un campo extra, Terraform lo rechaza. Si falta uno, también.

---

## 2.3 Flexibilidad: Variables con Defaults Inteligentes

El principio es: **el módulo debe funcionar de inmediato con cero configuración, pero permitir personalización avanzada**.

Los defaults deben ser las **mejores prácticas de la industria**, no valores arbitrarios:

```hcl
# modules/vpc/variables.tf
variable "vpc_cidr" {
  type        = string
  description = "CIDR block para la VPC"
  default     = "10.0.0.0/16"   # Un valor sensato para empezar
}

variable "enable_dns_hostnames" {
  type    = bool
  default = true   # La mejor práctica ES habilitarlo; el default lo refleja
}

variable "environment" {
  type    = string
  # Sin default → OBLIGATORIO. El consumidor debe especificarlo.
  # Terraform fallará en el plan si no se proporciona.
}
```

La ausencia de `default` convierte una variable en obligatoria. Úsalo para los parámetros que cambian entre entornos (`environment`, `vpc_cidr`) y defaults para los que tienen un valor universalmente correcto.

---

## 2.4 Robustez: Validación de Inputs (Fail Fast)

El principio de **Fail Fast**: es mejor fallar inmediatamente con un mensaje claro que permitir que un valor incorrecto cree infraestructura que luego hay que destruir.

Los bloques `validation` se evalúan durante `terraform plan` — antes de tocar ningún recurso real:

```hcl
# Validación 1: Lista permitida con contains()
variable "environment" {
  type = string
  validation {
    condition     = contains(["dev", "stg", "prod"], var.environment)
    error_message = "El entorno debe ser: dev, stg o prod."
  }
}

# Validación 2: Formato CIDR con can()
variable "vpc_cidr" {
  type = string
  validation {
    condition     = can(cidrhost(var.vpc_cidr, 0))
    error_message = "Debe ser un CIDR válido (ej. 10.0.0.0/16)."
  }
}

# Validación 3: Tipos de instancia permitidos
variable "instance_type" {
  type = string
  validation {
    condition     = contains(["t3.micro", "t3.small", "t3.medium"], var.instance_type)
    error_message = "Solo se permiten t3.micro, t3.small o t3.medium."
  }
}
```

`can()` es una función especial: intenta ejecutar una expresión y devuelve `true` si tiene éxito o `false` si lanza un error. Es perfecta para validar formatos (CIDRs, ARNs, URLs) sin expresiones regulares complicadas.

---

## 2.5 Contrato de Salida: Qué Exponer en los Outputs

Un módulo es una caja negra. Los outputs son la única ventana al exterior. Exponer demasiado viola el encapsulamiento; exponer demasiado poco obliga a duplicar lógica fuera del módulo.

```hcl
# modules/vpc/outputs.tf

# ✅ Exponer: IDs y ARNs que otros módulos necesitarán
output "vpc_id" {
  description = "El ID de la VPC creada"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "IDs de las subredes privadas (para RDS, ECS, etc.)"
  value       = aws_subnet.private[*].id
}

output "nat_gateway_ip" {
  description = "IP pública del NAT Gateway (para whitelisting)"
  value       = aws_eip.nat.public_ip
}

# ❌ NO exponer: Detalles de implementación interna
# output "route_table_association_ids" { ... }  # Nadie fuera del módulo necesita esto
```

Regla práctica: expón lo que un módulo vecino necesita para conectarse a tu módulo. No expongas detalles internos de implementación que nadie debería necesitar.

**Datos sensibles:** si un output contiene contraseñas o tokens, márcalo con `sensitive = true`:

```hcl
output "db_password" {
  description = "Contraseña generada del administrador de BD"
  value       = random_password.db.result
  sensitive   = true   # Oculta el valor en los logs del plan/apply
}
```

---

## 2.6 Módulos Opinados vs. Módulos Flexibles

Esta es una decisión de diseño fundamental con consecuencias en toda la organización:

| | Módulo Opinado | Módulo Flexible |
|--|---------------|-----------------|
| Filosofía | Fuerza estándares de seguridad y compliance | Expone máxima configurabilidad |
| Variables expuestas | Pocas (las que importan al consumidor) | Muchas (casi todas las del recurso) |
| Cifrado | Siempre activado (hardcoded) | Configurable |
| Tags corporativos | Obligatorios (hardcoded) | Opcionales |
| Ideal para | Equipos de plataforma, gobernanza corporativa | Registry público, equipos con alta autonomía |

```hcl
# Módulo opinado: el equipo de plataforma fuerza estándares
resource "aws_s3_bucket" "this" {
  bucket = var.bucket_name
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  bucket = aws_s3_bucket.this.id
  # Cifrado SIEMPRE activo — el consumidor no puede desactivarlo
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "aws:kms"
    }
  }
}
```

**Mejor práctica:** usa módulos opinados internamente para garantizar compliance, y envuelve módulos flexibles del Registry con el patrón Wrapper.

---

## 2.7 El Patrón Wrapper: Aprovecha el Ecosistema sin Perder el Control

El patrón más poderoso en la gestión de módulos: **envuelve un módulo público dentro de un módulo corporativo** que inyecta los estándares de tu organización.

```hcl
# modules/wrapper-vpc/main.tf — Tu módulo corporativo

module "vpc" {
  # Módulo externo del Registry: tiene 150+ variables, es muy flexible
  source  = "terraform-aws-modules/vpc/aws"
  version = "5.1.0"

  # ↓ El usuario elige estos parámetros
  cidr = var.vpc_cidr
  name = var.project_name
  azs  = var.availability_zones

  # ↓ FIJOS: estándares corporativos que el consumidor NO puede cambiar
  enable_dns_hostnames = true
  enable_flow_log      = true         # Logging obligatorio
  flow_log_destination = var.log_bucket_arn
  tags                 = merge(var.tags, local.mandatory_tags)
}

locals {
  mandatory_tags = {
    ManagedBy   = "terraform"
    CostCenter  = var.cost_center
    Environment = var.environment
  }
}
```

El equipo de desarrollo usa `wrapper-vpc` y no puede desactivar el logging ni los tags obligatorios. Pero sigue teniendo libertad para el CIDR, el nombre y las AZs.

---

## 2.8 Composición: Orquestando Módulos en Capas

Los módulos más potentes son los que **orquestan** módulos más pequeños. Un módulo `networking` puede estar compuesto de módulos `vpc`, `subnets` y `route_tables`:

```hcl
# modules/networking/main.tf

module "vpc" {
  source   = "./vpc"
  vpc_cidr = var.vpc_cidr
}

# El output de VPC alimenta el input de Subnets
module "subnets" {
  source = "./subnets"
  vpc_id = module.vpc.vpc_id    # ← Conexión entre módulos
}

# Ambos outputs alimentan el módulo de rutas
module "route_tables" {
  source     = "./route_tables"
  vpc_id     = module.vpc.vpc_id
  subnet_ids = module.subnets.ids
}
```

Este patrón de composición permite construir sistemas complejos a partir de piezas simples, cada una con su propia responsabilidad y su propio ciclo de vida.

---

## 2.9 Arquitectura Limpia: `required_providers` sin `provider`

> ⚠️ **NUNCA incluyas un bloque `provider` con credenciales dentro de un Child Module.**

Si un módulo incluye `provider "aws" { region = "us-east-1" }`, el módulo fuerza una región, no es portable y puede causar errores al destruirlo. Lo correcto es declarar solo los providers que necesita, sin configurarlos:

```hcl
# ❌ MAL — Módulo que fuerza una región
provider "aws" {
  region = "us-east-1"   # ← No portable, no reutilizable
}

# ✅ BIEN — Módulo que declara su dependencia sin configurarla
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}
```

El Root Module configura el provider. El Child Module simplemente lo usa. Esta separación hace el módulo completamente portátil entre regiones, cuentas y entornos.

---

## 2.10 Refactorización sin Destrucción: El Bloque `moved`

Cuando renombras un recurso dentro de un módulo, Terraform interpreta que el viejo se destruye y uno nuevo se crea — lo que implica downtime en producción. El bloque `moved` (disponible desde v1.1+) evita esto:

```hcl
# ANTES: resource "aws_instance" "server" { ... }
# AHORA: renombramos a "web_server" para mayor claridad

resource "aws_instance" "web_server" {
  ami           = var.ami_id
  instance_type = var.instance_type
}

# El bloque moved indica que es el MISMO recurso con diferente nombre
moved {
  from = aws_instance.server
  to   = aws_instance.web_server
}
```

El resultado de `terraform plan`:
```
# aws_instance.server has moved to aws_instance.web_server
Plan: 0 to add, 0 to change, 0 to destroy.
```

Zero downtime, zero recreación. Solo se actualiza la dirección en el state. `moved` también funciona para mover recursos entre módulos cuando reestructuras el código.

---

## 2.11 Anti-Patrones: God Module y Granularidad Excesiva

Dos extremos que debes evitar:

**God Module (demasiado grande):**

```hcl
# ❌ Un módulo que despliega VPC + EKS + RDS + Lambda + IAM...
# Problemas: plan lento, blast radius enorme, imposible reutilizar partes
```

**Granularidad excesiva (demasiado pequeño):**

```hcl
# ❌ Un módulo por cada recurso individual
module "sg_rule_https"  { ... }
module "sg_rule_http"   { ... }
module "sg_rule_egress" { ... }
# Problemas: overhead absurdo, difícil de orquestar
```

**El equilibrio — Responsabilidad Única:**

Un módulo agrupa recursos que se crean, modifican y destruyen juntos con una responsabilidad clara: VPC (todo lo relacionado con la red base), Base de Datos (instancia + subnet group + parameter group), Cluster EKS.

> **Regla práctica:** si el módulo tiene más de 10 recursos, evalúa si se puede dividir. Si tienes un módulo con un solo recurso, evalúa si justifica el overhead de ser un módulo.

---

## 2.12 Resumen: El Arte del Diseño Modular

| Principio | Implementación |
|-----------|---------------|
| **Encapsular lógica** | Oculta complejidad tras una API simple con tipos complejos y defaults inteligentes |
| **Validar inputs** | Fail fast con bloques `validation` — detecta errores antes de tocar infraestructura |
| **Evolucionar con `moved`** | Refactoriza sin destruir; renombra y mueve recursos con zero downtime |
| **Sin providers internos** | `required_providers` en el módulo, configuración en el Root |
| **Patrón Wrapper** | Envuelve módulos externos con estándares corporativos |
| **Responsabilidad única** | Ni god module ni granularidad excesiva |

> **Principio:** Un módulo bien diseñado es invisible para el consumidor — en el buen sentido. El consumidor no piensa en `aws_vpc` ni en `aws_route_table_association`. Solo piensa en "necesito una red con estas características". El módulo traduce esa intención a infraestructura real.

---

> **Siguiente:** [Sección 3 — Fuentes y Versionado de Módulos →](./03_fuentes_versionado.md)
