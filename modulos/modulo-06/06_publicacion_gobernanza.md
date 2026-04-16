# Sección 6 — Documentación, Publicación y Gobernanza

> [← Sección anterior](./05_testing_modulos.md) | [Volver al índice →](./README.md)

---

## 6.1 Documentación: El Rostro de tu Infraestructura

> "Un módulo sin documentación es un módulo que nadie usará."

La documentación no es un extra de último momento — es la **interfaz humana** de tu infraestructura. Sin documentación, cualquier ingeniero que encuentre tu módulo tiene que leer todo el código para entender qué hace, qué parámetros acepta y qué devuelve. Con documentación, puede empezar a usarlo en 5 minutos.

Tres beneficios concretos:
- **Onboarding rápido:** nuevos miembros del equipo adoptan el módulo en minutos, no semanas
- **Mantenibilidad:** el contexto se preserva. Quien herede el código entenderá el diseño sin hacer arqueología
- **Confianza:** un README completo es la mejor señal de calidad profesional

---

## 6.2 `terraform-docs`: Automatización Total

Escribir documentación manualmente es tedioso y se desactualiza rápidamente. `terraform-docs` extrae automáticamente variables, outputs, providers y recursos del código HCL y genera un README:

```bash
# Generar tabla Markdown con todas las variables y outputs
$ terraform-docs markdown table ./modules/vpc

# Inyectar en un README.md existente (entre marcadores específicos)
$ terraform-docs markdown table --output-file README.md .

# Salidas disponibles
# markdown (tablas para GitHub/GitLab)
# json      (para portales internos o APIs)
# asciidoc  (para Confluence o wikis)
```

Instalación: `brew install terraform-docs` (macOS) | `choco install terraform-docs` (Windows)

---

## 6.3 Configuración: El Archivo `.terraform-docs.yml`

Para personalizar exactamente qué secciones incluir y cómo ordenarlas:

```yaml
# .terraform-docs.yml — Configuración del generador de docs
formatter: "markdown table"
header-from: "main.tf"   # Usa el comentario al inicio de main.tf como cabecera

sections:
  show:
    - header
    - inputs
    - outputs
    - providers
    - requirements

output:
  file: "README.md"
  mode: "inject"   # "inject" actualiza entre marcadores; "replace" sobreescribe todo

sort:
  enabled: true
  by: "required"   # Variables obligatorias primero (más importante para el usuario)
```

---

## 6.4 Estructura de un README.md Profesional

Un README de módulo de calidad tiene esta estructura:

```markdown
# terraform-aws-vpc

Módulo para crear una VPC multi-AZ en AWS con subredes públicas y privadas.

## Requisitos
- Terraform >= 1.5
- AWS Provider >= 5.0

## Uso
```hcl
module "vpc" {
  source  = "mi-org/vpc/aws"
  version = "~> 2.0"

  vpc_cidr    = "10.0.0.0/16"
  environment = "prod"
}
```

## Inputs
<!-- BEGIN_TF_DOCS -->
| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| vpc_cidr | CIDR block de la VPC | string | "10.0.0.0/16" | no |
| environment | Entorno (dev/stg/prod) | string | n/a | yes |
<!-- END_TF_DOCS -->
```

Los marcadores `<!-- BEGIN_TF_DOCS -->` y `<!-- END_TF_DOCS -->` son donde `terraform-docs` inyecta automáticamente las tablas. El resto del README lo escribes manualmente una sola vez.

---

## 6.5 La Carpeta `/examples/`: Documentación Viva

Los ejemplos en código son más valiosos que cualquier descripción textual porque son **ejecutables** — el usuario los copia, ajusta los valores y tiene infraestructura funcionando en minutos:

```
modules/vpc/
├── main.tf
├── variables.tf
├── outputs.tf
├── README.md
└── examples/
    ├── basic/          ← Mínimo viable: el 80% de los casos de uso
    │   ├── main.tf
    │   └── outputs.tf
    └── advanced/       ← Todas las features: multi-AZ, VPN, tags custom
        ├── main.tf
        └── outputs.tf
```

**Doble beneficio:** los ejemplos sirven como documentación **y** como tests de integración. `terraform test` puede ejecutarlos para verificar que el módulo funciona end-to-end.

---

## 6.6 Pre-commit Hooks: Documentación en Tiempo Real

El problema de la documentación manual: se desactualiza con cada cambio de variable. Los pre-commit hooks resuelven esto ejecutando `terraform-docs`, `fmt` y `validate` automáticamente antes de cada commit:

```yaml
# .pre-commit-config.yaml
repos:
  - repo: https://github.com/antonbabenko/pre-commit-terraform
    rev: "v1.86.0"
    hooks:
      - id: terraform_fmt       # Formato consistente
      - id: terraform_validate  # Validación de sintaxis
      - id: terraform_docs      # Regenera el README automáticamente
      - id: terraform_trivy     # Seguridad estática
```

```bash
# Instalar pre-commit
$ pip install pre-commit
$ pre-commit install   # Activa los hooks en el repositorio local
```

Ahora, cuando un desarrollador hace commit, los hooks verifican automáticamente el formato, regeneran el README y escanean por vulnerabilidades. Si cualquier verificación falla, el commit se bloquea.

---

## 6.7 Pipeline CI: Auto-commit de Documentación

Para garantizar que el README del repositorio siempre esté actualizado, incluso si alguien olvidó ejecutar el pre-commit hook:

```yaml
# .github/workflows/docs.yml
name: "Auto-update README"
on:
  push:
    branches: [main]

jobs:
  docs:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: terraform-docs/gh-actions@main
        with:
          working-dir: .
          output-file: README.md
          output-method: inject
          git-push: "true"   # Hace commit automático del README actualizado
```

Cada push a `main` regenera automáticamente el README y hace commit del resultado. El README nunca puede desincronizarse del código.

---

## 6.8 Publicación en el Terraform Registry Público

Para publicar un módulo en `registry.terraform.io`:

1. **Repositorio GitHub público** (el Registry solo soporta GitHub)
2. **Nomenclatura obligatoria:** `terraform-<PROVIDER>-<NAME>`
   - Correcto: `terraform-aws-vpc`, `terraform-aws-rds`
   - Incorrecto: `my-vpc-module`, `vpc`
3. **Tags SemVer:** cada release necesita un tag `v<MAJOR>.<MINOR>.<PATCH>`
   - `v1.0.0` → Primera versión estable
   - `v1.1.0` → Nueva variable opcional añadida
   - `v2.0.0` → Cambio incompatible (variable renombrada o eliminada)

Una vez publicado, cualquier usuario puede usar tu módulo con:
```hcl
module "vpc" {
  source  = "mi-org/vpc/aws"
  version = "~> 1.0"
}
```

---

## 6.9 Gobernanza: Registro Privado y Service Catalog

Para organizaciones que necesitan controlar qué módulos están aprobados para uso interno:

**HCP Terraform / Enterprise:**
- Registro privado nativo integrado con UI web
- Control de acceso por equipos (solo el equipo de Platform puede publicar)
- Versionado automático al crear tags de Git
- Policy as Code (Sentinel/OPA) integrado

**Service Catalog (No-Code):**
- Los módulos se exponen como productos de autoservicio
- Los usuarios llenan un formulario en lugar de escribir HCL
- Aprobaciones por workflow antes de provisionar
- Auditoría completa de todos los despliegues
- Ideal para democratizar la infra para equipos no técnicos

---

## 6.10 Alternativa Lean: Registro con S3

Para equipos pequeños sin presupuesto para HCP Terraform Enterprise, S3 con archivos `.zip` versionados es un registro privado funcional de bajo coste:

```bash
# Empaquetar y publicar el módulo
$ zip -r vpc-v1.2.0.zip modules/vpc/
$ aws s3 cp vpc-v1.2.0.zip s3://tf-modules-corp/vpc/v1.2.0.zip
```

```hcl
# Consumir desde HCL
module "vpc" {
  source = "s3::https://tf-modules-corp.s3.amazonaws.com/vpc/v1.2.0.zip"
}
```

**Ventajas:** bajo coste, sin dependencia de SaaS, control total con IAM.
**Limitaciones:** sin UI de descubrimiento, sin policies integradas, versionado manual.

---

## 6.11 Deprecación: Gestión Ética del Fin de Vida

Retirar una versión de un módulo sin avisar puede romper la infraestructura de todos sus consumidores. El proceso correcto:

```
1. Marcar deprecated
   Añadir deprecation_message en el README
   y en la description de las variables afectadas.
   Publicar nueva versión con la nota de deprecación.

2. Comunicar plazo
   Anunciar ventana de migración (ej: 90 días) vía
   Changelog, canal de Slack del equipo, email.

3. Proveer migración
   Documentar paso a paso cómo migrar con bloque moved.
   Ofrecer soporte durante el período de transición.

4. Archivar repo
   Marcar como archived en GitHub.
   Nunca borrar los tags — las versiones antiguas deben
   seguir siendo descargables para evitar romper infraestructura existente.
```

---

## 6.12 Architecture Decision Records (ADR)

El código dice **qué** hace la infraestructura. Los ADRs documentan el **por qué** — las decisiones de diseño y las alternativas consideradas. Sin ADRs, ese conocimiento se pierde cuando el autor deja el equipo.

```markdown
# docs/adr/001-nat-gateway.md

## Título
ADR-001: Usar NAT Gateway vs NAT Instance

## Contexto
Necesitamos salida a Internet para subredes privadas con alta disponibilidad.
Los candidatos eran NAT Gateway (managed) y NAT Instance (self-managed EC2).

## Decisión
Usamos NAT Gateway por su alta disponibilidad nativa y menor carga operativa.

## Consecuencias
Mayor coste (~$0.045/hora). Aceptable dado el SLA del 99.99% requerido.
La alternativa NAT Instance requeriría HA manual (ASG + failover).

## Estado
Aceptado | Fecha: 2024-01-15 | Autor: Platform Team
```

Los ADRs son especialmente valiosos cuando alguien propone "¿por qué no usamos X?". La respuesta está documentada, con el contexto y las restricciones que llevaron a la decisión original.

---

## 6.13 El Ciclo de Vida Completo del Autor de Módulos

```
1. Escribir  →  Código HCL modular, limpio, con validaciones
       ↓
2. Testear   →  terraform test + trivy + Checkov + Idempotencia
       ↓
3. Documentar → terraform-docs + examples/ + ADRs
       ↓
4. Etiquetar → SemVer tag: v1.0.0, CHANGELOG.md actualizado
       ↓
5. Publicar  → Registry público, privado o S3
       ↓
6. Mantener  → Responder issues, actualizar dependencias
       ↓
7. Deprecar  → Migración guiada, archivo del repositorio
```

---

## 6.14 Resumen: Documentación, Publicación y Gobernanza

| Herramienta / Práctica | Función |
|------------------------|---------|
| `terraform-docs` | Genera README automáticamente desde el código HCL |
| `.terraform-docs.yml` | Personaliza secciones, orden y formato de salida |
| `examples/` | Documentación viva + tests de integración |
| Pre-commit hooks | Garantiza docs y formato actualizados en cada commit |
| GitHub Actions docs.yml | Auto-commit del README en cada push a main |
| Registry público | `terraform-<PROVIDER>-<NAME>` + tags SemVer + GitHub |
| Registry privado (TFC) | Control de acceso + Policy as Code integrado |
| S3 (.zip) | Alternativa lean para equipos pequeños sin SaaS |
| ADRs | Documentan el "por qué" de las decisiones de diseño |
| Deprecación | Comunicar → Migración guiada → Archivar (nunca borrar) |

> **Principio final:** un módulo sin documentación muere en silencio. La documentación, los ejemplos y los tests no son la guinda del pastel — son la diferencia entre un módulo que el equipo adopta con confianza y un módulo que nadie usa porque nadie sabe cómo funciona ni si es seguro. El ciclo completo (escribir → testear → documentar → publicar → deprecar) es lo que convierte un script de Terraform en un producto de infraestructura profesional.

---

> **[← Volver al índice del Módulo 6](./README.md)**
