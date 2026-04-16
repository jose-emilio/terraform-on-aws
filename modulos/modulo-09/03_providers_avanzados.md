# Sección 3 — Providers Avanzados

> [← Volver al índice](./README.md) | [Siguiente →](./04_drift_reconciliacion.md)

---

## 1. El Provider: El Traductor de la Infraestructura

Un Provider es el plugin que traduce la configuración HCL en llamadas API al servicio de infraestructura. AWS, Azure, GCP, GitHub, Kubernetes, Datadog — cada uno tiene su provider. Terraform descarga y gestiona estos plugins automáticamente durante `terraform init`.

> **El profesor explica:** "Pensar en el provider como un driver de base de datos. El SQL (HCL) que escribes es el mismo, pero el driver (provider) sabe cómo traducirlo a llamadas específicas de MySQL, PostgreSQL o SQLite. Cambiar de proveedor cloud es cambiar el driver — no el lenguaje. Eso es la portabilidad de Terraform."

---

## 2. `required_providers` y Version Constraints

Fijar versiones de providers es tan importante como fijar versiones de dependencias en tu aplicación. Un provider con breaking changes puede romper tu infraestructura en la siguiente ejecución de `terraform init`.

```hcl
terraform {
  required_providers {
    # Provider oficial AWS — permite 5.x, bloquea 6.0
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    # Provider random con rango explícito
    random = {
      source  = "hashicorp/random"
      version = ">= 3.5.0, < 4.0.0"
    }

    # Provider de GitHub (Partner verified)
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  # Versión mínima del CLI de Terraform
  required_version = "~> 1.7"
}
```

**Sintaxis de version constraints:**

| Constraint | Significado |
|------------|-------------|
| `~> 5.0` | `>= 5.0, < 6.0` (MINOR updates, no MAJOR) |
| `~> 5.31` | `>= 5.31, < 5.32` (solo PATCH) |
| `>= 5.0, < 6.0` | Rango explícito equivalente a `~> 5.0` |
| `= 5.31.0` | Versión exacta (no recomendado, rompe CI) |

**Mejor práctica:** Usa `~> major.minor` para permitir patches sin romper por breaking changes.

---

## 3. Alias Multi-Región — Un Provider, Múltiples Configuraciones

`alias` permite declarar el mismo provider con distintas configuraciones (región, credenciales) dentro del mismo proyecto. Un provider sin alias es el "default"; los aliasados son opcionales.

```hcl
# Provider default (us-east-1) — implícito en todos los recursos
provider "aws" {
  region = "us-east-1"
}

# Provider aliasado para Europa
provider "aws" {
  alias  = "paris"
  region = "eu-west-3"
}

# Provider aliasado para réplicas CloudFront (siempre us-east-1)
provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}

# Recurso en la región default (sin declarar provider)
resource "aws_instance" "app_us" {
  ami           = "ami-0abcdef1234567890"
  instance_type = "t3.micro"
}

# Recurso en París (referencia explícita al alias)
resource "aws_instance" "app_eu" {
  provider      = aws.paris   # <- Referencia al alias
  ami           = "ami-0fedcba9876543210"
  instance_type = "t3.micro"
}

# Lambda@Edge: siempre en us-east-1
resource "aws_lambda_function" "edge" {
  provider = aws.us_east_1
  # ...
}
```

**Casos de uso para alias:**
- Disaster Recovery: recursos replicados en región secundaria.
- Arquitecturas globales: contenido cerca del usuario.
- Lambda@Edge: siempre desplegada en `us-east-1`.
- Multi-cuenta: producción vs staging con credenciales distintas.

---

## 4. Providers en Módulos — `configuration_aliases`

Los módulos heredan el provider default automáticamente. Para pasar providers aliasados, el módulo debe declarar qué aliases espera con `configuration_aliases`, y el root module los inyecta con `providers = {}`.

```hcl
# modules/s3-replica/main.tf
terraform {
  required_providers {
    aws = {
      source                = "hashicorp/aws"
      configuration_aliases = [aws.replica]   # Declara que espera este alias
    }
  }
}

resource "aws_s3_bucket" "replica" {
  provider = aws.replica   # Usa el alias inyectado por el root module
  bucket   = "mi-bucket-replica-eu"
}
```

```hcl
# root module: main.tf
module "replica_eu" {
  source = "./modules/s3-replica"

  # Inyectar el alias: aws.replica del módulo = aws.paris del root
  providers = {
    aws.replica = aws.paris
  }
}
```

**Reglas importantes:**
- No definas bloques `provider` dentro de módulos child — solo en el root module.
- El root module controla la configuración real del provider.
- Los módulos solo declaran qué providers y aliases necesitan.

---

## 5. Provider Source — Formatos y Niveles de Confianza

```hcl
terraform {
  required_providers {
    # Official: mantenidos por HashiCorp
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }

    # Partner verified: soporte del proveedor del servicio
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }

    # Community: open-source sin garantía oficial
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = "~> 1.14"
    }
  }
}
```

**Niveles de confianza en el Registry:**

| Nivel | Mantenedor | Garantía |
|-------|-----------|---------|
| Official | HashiCorp | Soporte completo |
| Partner | Empresa del servicio | Verificado, con soporte |
| Community | Terceros | Sin garantía oficial |

**Al evaluar un provider community:** revisa descargas mensuales, frecuencia de commits, issues abiertos/cerrados, y si tiene tests.

---

## 6. Plugin Cache y Network Mirror

Para entornos air-gapped o CI/CD con muchas ejecuciones, configurar cache y mirrors evita descargas repetidas del Registry público.

### Plugin Cache (desarrollo local)

```bash
# Via variable de entorno
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
mkdir -p $TF_PLUGIN_CACHE_DIR
```

```hcl
# .terraformrc (configuración permanente)
plugin_cache_dir   = "$HOME/.terraform.d/plugin-cache"
disable_checkpoint = true  # No consultar updates de Terraform
```

### Network Mirror (corporativo / air-gapped)

```hcl
# .terraformrc — Usar mirror de red corporativo
provider_installation {
  network_mirror {
    url = "https://terraform.empresa.com/v1/providers/"
  }
  direct {
    # Fallback al registry público si no está en el mirror
    exclude = ["registry.terraform.io/hashicorp/*"]
  }
}

# Alternativa: filesystem mirror para entornos sin Internet
provider_installation {
  filesystem_mirror {
    path    = "/opt/terraform/providers"
    include = ["hashicorp/*"]
  }
}
```

**Crear un mirror local:**
```bash
terraform providers mirror ./mirror
```

---

## 7. Dependency Lock File — Reproducibilidad

`.terraform.lock.hcl` registra las versiones exactas y hashes criptográficos de los providers instalados. Garantiza que todos los miembros del equipo (y CI/CD) usen exactamente las mismas versiones.

```hcl
# .terraform.lock.hcl (generado automáticamente — NO editar manualmente)
provider "registry.terraform.io/hashicorp/aws" {
  version     = "5.82.2"
  constraints = "~> 5.0"
  hashes = [
    "h1:abc123...xyz789=",   # Hash del binario instalado
    "zh:def456...uvw012=",   # Hash del zip descargado
  ]
}
```

**Comandos esenciales:**

```bash
# Generar hashes para múltiples plataformas (CI/CD + dev local)
terraform providers lock \
  -platform=linux_amd64 \
  -platform=darwin_amd64 \
  -platform=darwin_arm64

# Actualizar providers a versiones más nuevas (dentro de constraints)
terraform init -upgrade

# Ver providers instalados y sus versiones
terraform version
```

**Regla:** Incluir `.terraform.lock.hcl` en Git — excluir `.terraform/` (contiene los binarios).

---

## 8. Multi-Provider — Gestionar Múltiples Servicios

```hcl
provider "aws" {
  region = "us-east-1"
}

provider "github" {
  token = var.github_token
  owner = "mi-organizacion"
}

provider "cloudflare" {
  api_token = var.cf_token
}

# Recursos de múltiples providers en el mismo proyecto
resource "aws_s3_bucket" "artifacts" {
  bucket = "my-app-artifacts"
}

resource "github_repository" "app" {
  name       = "my-application"
  visibility = "private"
}

resource "cloudflare_record" "app" {
  zone_id = var.cf_zone_id
  name    = "api"
  value   = aws_lb.main.dns_name
  type    = "CNAME"
}
```

---

## 9. Custom Provider — Terraform Plugin Framework

Para APIs internas sin provider oficial, el Terraform Plugin Framework (Go) permite crear providers personalizados.

```hcl
# Uso de un provider personalizado desde registry privado
terraform {
  required_providers {
    internal = {
      source  = "app.terraform.io/miempresa/internal"
      version = "~> 1.0"
    }
  }
}

provider "internal" {
  api_url = "https://api.miempresa.com"
  token   = var.internal_token
}

resource "internal_service" "api" {
  name        = "payment-gateway"
  environment = "production"
}
```

**Cuándo crear un provider propio:**
- API interna sin provider oficial en el Registry.
- Lógica de negocio específica de la empresa.
- Integración con CMDB, ITSM o sistemas de aprobación propios.

---

## 10. Troubleshooting y Best Practices

**Errores frecuentes:**

| Error | Causa | Solución |
|-------|-------|---------|
| `Failed to query available provider packages` | Sin conectividad al Registry | Verificar proxy, usar mirror |
| `Incompatible provider version` | Lock file desactualizado | `terraform init -upgrade` |
| `Provider produced inconsistent result` | Bug en el provider | `ignore_changes` temporal + reportar issue |
| `Error configuring Terraform AWS Provider` | Credenciales incorrectas | Verificar `aws configure` o env vars |

**Best Practices:**

1. **Versionar siempre** — `~> major.minor` en `required_providers`.
2. **Commit del lock file** — `.terraform.lock.hcl` en Git.
3. **Alias para multi-región** — No duplicar bloques provider, usar alias.
4. **Credenciales externas** — Nunca hardcodear tokens en `.tf`. Usar env vars o Secrets Manager.
5. **Mirror en CI/CD** — `TF_PLUGIN_CACHE_DIR` o network mirror para acelerar pipelines.
6. **No providers en módulos child** — El root module es el único que configura providers.

---

> [← Volver al índice](./README.md) | [Siguiente →](./04_drift_reconciliacion.md)
