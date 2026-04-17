# Sección 3 — Fuentes y Versionado de Módulos

> [← Sección anterior](./02_diseno_modulos.md) | [Siguiente →](./04_registry_publico.md)

---

## 3.1 ¿De Dónde Viene el Código? El Argumento `source`

Cuando ejecutas `terraform init`, Terraform descarga y cachea el código de cada módulo en `.terraform/modules/`. El argumento `source` determina de dónde viene ese código.

```
terraform init
    ↓
Descarga source (local, git, registry, s3)
    ↓
Cache local → .terraform/modules/
```

Las cuatro categorías principales:

| Tipo | Ejemplo | Cuándo usar |
|------|---------|-------------|
| **Local** | `./modules/vpc` | Desarrollo, prototipos, monorepo |
| **Git** | `git::https://github.com/org/tf.git?ref=v1.2.3` | Estándar corporativo con versionado |
| **Registry** | `terraform-aws-modules/vpc/aws` | Módulos públicos verificados |
| **S3 / GCS** | `s3::https://bucket.s3.amazonaws.com/vpc.zip` | Distribución corporativa privada |

---

## 3.2 Fuentes Locales: Desarrollo y Prototipado

```hcl
# Ruta relativa al directorio actual
module "vpc" {
  source = "./modules/vpc"
}

# Ruta relativa al directorio padre (monorepo multi-proyecto)
module "shared_vpc" {
  source = "../shared/vpc"
}
```

**Ventajas:** los cambios son instantáneos — no necesitas hacer `terraform init` de nuevo al modificar el módulo local. Ideal para desarrollo iterativo.

**Limitación:** acoplamiento al repositorio actual. No puedes reutilizar el módulo desde otro proyecto sin copiar los archivos.

**Estructura de proyecto típica:**

```
proyecto/
├── main.tf            ← Root Module
├── variables.tf
└── modules/           ← Child Modules locales
    ├── vpc/
    └── database/
```

---

## 3.3 Fuentes Git: El Estándar Corporativo

Git es el origen preferido para módulos compartidos entre equipos. La sintaxis admite subcarpetas (`//`) y versiones (`?ref=`):

```hcl
# Repositorio público HTTPS (sin versión → HEAD de main)
module "vpc" {
  source = "git::https://github.com/org/tf-modules.git"
}

# Repositorio privado SSH + subcarpeta específica del monorepo
module "database" {
  source = "git::ssh://git@gitlab.corp.com/infra/modules.git//rds"
  #                                                            ↑↑
  #                               // separa el repo de la subcarpeta
}

# Con etiqueta de versión INMUTABLE (RECOMENDADO para producción)
module "eks" {
  source = "git::https://github.com/org/eks.git?ref=v1.2.3"
  #                                              ↑↑↑↑↑↑↑↑
  #                                    Puede ser tag, branch o SHA de commit
}
```

Soporta GitHub, GitLab, Bitbucket, Azure DevOps y cualquier servidor Git compatible.

---

## 3.4 Control Total: Versionado con `?ref=`

> ⚠️ **NUNCA uses la rama `main` en producción.**

Cada push a `main` cambiaría tu infraestructura en el próximo `terraform init` sin previo aviso. Usa referencias inmutables:

```hcl
# ❌ PELIGROSO: sin ref → HEAD de main, cambia con cada push
source = "git::https://github.com/org/modules.git"

# ❌ PELIGROSO: rama → mutable, cambia con cualquier push
source = "git::https://github.com/org/modules.git?ref=main"

# ✅ SEGURO: tag semántico → inmutable
source = "git::https://github.com/org/modules.git?ref=v1.2.3"

# ✅ MÁXIMA SEGURIDAD: commit SHA → absolutamente inmutable
source = "git::https://github.com/org/modules.git?ref=a3f4e5b7c9d1"
```

**Regla de oro:** en producción, siempre `?ref=vX.Y.Z` con tags semánticos. Los tags y SHAs son inmutables — tu infraestructura no cambia sin tu control explícito.

---

## 3.5 Terraform Registry: El Ecosistema Público y Privado

El Registry de Terraform ofrece sintaxis simplificada para módulos — no necesitas la URL completa:

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  #         ↑↑↑↑↑↑↑↑↑↑↑↑↑↑↑  ↑↑↑  ↑↑↑
  #         Namespace (org)    Nombre Provider
  version = "~> 5.0"
}
```

**Registry Público (`registry.terraform.io`):**
- Miles de módulos validados por la comunidad
- Documentación autogenerada a partir del código
- Versionado semántico integrado
- Badge "Verified" para módulos oficiales de HashiCorp y partners

**Registry Privado (HCP Terraform / Enterprise):**
- Catálogo interno corporativo de módulos aprobados
- Control de acceso por equipos
- Versionado automático por tags de Git
- UI web para descubrir y usar módulos

---

## 3.6 Versionado Semántico (SemVer) para Módulos

Cada número en la versión tiene un significado preciso:

```
    2  .  1  .  3
    ↑     ↑     ↑
  MAJOR MINOR PATCH
```

| Componente | Cuándo incrementar | Ejemplos |
|------------|-------------------|---------|
| **MAJOR** | Breaking changes — la interfaz del módulo cambia de forma incompatible | Eliminar una variable, cambiar tipo de output |
| **MINOR** | Nueva funcionalidad, compatible hacia atrás | Añadir variable opcional, nuevo output disponible |
| **PATCH** | Correcciones de bugs, sin cambios de interfaz | Corregir lógica interna, actualizar documentación |

Como autor de módulos: cualquier cambio que obligue a los consumidores a modificar su código es un MAJOR. Los consumidores deben poder actualizar de `1.2.0` a `1.3.0` sin cambiar nada.

---

## 3.7 Version Constraints: Reglas de Actualización

| Operador | Ejemplo | Comportamiento |
|----------|---------|----------------|
| `=` | `"2.1.0"` | Versión exacta, sin actualizaciones |
| `!=` | `"!= 2.0.0"` | Excluye esa versión específica |
| `>=` | `">= 2.0"` | Cualquier versión >= 2.0 |
| `~>` | `"~> 2.1.0"` | Pesimista: ≥ 2.1.0 y < 2.2.0 |
| `~>` | `"~> 2.1"` | Pesimista: ≥ 2.1.0 y < 3.0.0 |

**El operador `~>` (Pessimistic Constraint) es el más importante.** Permite incrementos en el último número especificado:

```hcl
module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.1.0"   # Acepta 5.1.x automáticamente, nunca 5.2.0
}

# Combinaciones avanzadas
version = ">= 2.0, < 3.0, != 2.5.0"   # Rango + exclusión de versión problemática
```

`~> 5.1.0` significa: recibe automáticamente los parches de bugfix (5.1.1, 5.1.2...) pero nunca una nueva minor version que podría añadir breaking changes.

---

## 3.8 Reproducibilidad: El Lockfile

El archivo `.terraform.lock.hcl` registra la **versión exacta y los hashes criptográficos** de cada provider descargado. Es el equivalente de `package-lock.json` (Node.js) o `Pipfile.lock` (Python).

> **Importante:** A diferencia de `package-lock.json`, el lockfile de Terraform **solo cubre providers, no módulos**. Terraform no recuerda las versiones seleccionadas de módulos remotos entre ejecuciones. Para garantizar reproducibilidad en módulos, usa restricciones de versión exactas (`= x.y.z`) en el argumento `version`.

```hcl
# .terraform.lock.hcl — Autogenerado por terraform init
provider "registry.terraform.io/hashicorp/aws" {
  version     = "6.0.0"
  constraints = "~> 6.0"
  hashes = [
    "h1:abc123...def456==",
    "zh:789ghi...jkl012==",
  ]
}
```

**Reglas de oro:**

| ✅ Hacer | ❌ No hacer |
|---------|-----------|
| Subir al repositorio con `git add .terraform.lock.hcl` | Añadir a `.gitignore` |
| Revisar cambios en Pull Requests | Editar manualmente |
| Actualizar con `terraform init -upgrade` | Borrar para "arreglar" errores |

Si no está en el repositorio, cada miembro del equipo puede tener versiones diferentes de providers, causando comportamientos distintos en el mismo código.

---

## 3.9 El Anti-Patrón: Providers Dentro de Módulos

> ⚠️ **NUNCA incluyas un bloque `provider` dentro de un Child Module.**

Los efectos secundarios son graves: módulos que fuerzan una región (no portables), errores crípticos al destruir recursos, conflictos entre múltiples instancias del mismo módulo.

```hcl
# ❌ Child Module — MAL
provider "aws" {
  region = "us-east-1"   # Fuerza la región para todos los usos del módulo
}
resource "aws_vpc" "this" { ... }

# ✅ Child Module — BIEN
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}
resource "aws_vpc" "this" { ... }   # Hereda el provider del Root Module
```

El Root Module configura el provider. El Child Module solo declara que lo necesita.

---

## 3.10 Inyección de Dependencias: `configuration_aliases`

Cuando un módulo necesita operar en **múltiples regiones o cuentas**, usa `configuration_aliases` para declarar qué instancias de provider necesita, y el Root las inyecta:

```hcl
# modules/s3-replication/main.tf — Declara que necesita dos instancias de AWS
terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      configuration_aliases = [
        aws.source,       # Región origen de la replicación
        aws.destination,  # Región destino
      ]
    }
  }
}

resource "aws_s3_bucket" "source" {
  provider = aws.source   # Usa el provider de origen
  bucket   = var.source_bucket_name
}
```

```hcl
# Root Module — Mapea los aliases al invocar el módulo
provider "aws" {
  region = "us-east-1"
}
provider "aws" {
  alias  = "eu"
  region = "eu-west-1"
}

module "s3_replication" {
  source = "./modules/s3-replication"
  providers = {
    aws.source      = aws       # us-east-1
    aws.destination = aws.eu    # eu-west-1
  }
}
```

---

## 3.11 Monorepo vs. Multirepo: Estrategias de Repositorio

| Estrategia | Pros | Contras | Ideal para |
|-----------|------|---------|-----------|
| **Monorepo** | Refactoring atómico, un CI/CD, fácil descubrimiento | Versionado complejo por subcarpeta, tags globales | Equipos pequeños (<10 módulos) |
| **Multirepo** | Versionado independiente, permisos granulares, compatible con Registry privado | Más repos, cambios cross-módulo = N PRs | Organizaciones grandes con gobernanza estricta |

En monorepo, la subcarpeta se referencia con `//` en el source:

```hcl
# Monorepo: un repo, múltiples módulos
source = "git::https://github.com/org/tf-modules.git//vpc?ref=v1.2.3"
#                                                     ↑↑
#                                    Subcarpeta dentro del repositorio
```

---

## 3.12 Higiene de Módulos: `terraform get`

```bash
# terraform get: descarga módulos sin re-inicializar el entorno completo
$ terraform get          # Descarga módulos nuevos o faltantes
$ terraform get -update  # Re-descarga TODOS los módulos (última versión compatible)

# terraform init: hace todo lo anterior + providers + backend
$ terraform init         # Primera configuración o cambio de backend/provider
$ terraform init -upgrade  # Actualiza providers y módulos a últimas versiones compatibles
```

Usa `terraform get` cuando solo cambió el `source` de un módulo y no necesitas reinicializar todo el entorno.

---

## 3.13 Resumen: Versionado Robusto de Módulos

```
Local       → Desarrollo inmediato, sin versionado
Git + ?ref= → Estándar corporativo con versiones inmutables
Registry    → Ecosistema público con SemVer nativo
S3/GCS      → Distribución corporativa privada sin SaaS
```

| Regla | Motivo |
|-------|--------|
| `?ref=vX.Y.Z` en Git (nunca `main`) | Los tags son inmutables; las ramas no |
| `version = "~> X.Y"` en Registry | Recibe parches automáticos, nunca breaking changes |
| Lockfile en el repositorio | Garantiza que todos usan las mismas versiones exactas |
| `required_providers` sin `provider` | Módulos portables entre regiones y cuentas |

> **Principio:** El versionado de módulos es la diferencia entre una infraestructura controlada y una que cambia de forma impredecible. Un `?ref=main` en producción es una bomba de tiempo: el próximo push del equipo de plataforma puede cambiar tu infraestructura sin que lo hayas aprobado.

---

> **Siguiente:** [Sección 4 — Módulos Públicos AWS en el Registry →](./04_registry_publico.md)
