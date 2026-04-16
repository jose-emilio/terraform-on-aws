# Sección 5 — Pruebas de Módulos

> [← Sección anterior](./04_registry_publico.md) | [Siguiente →](./06_publicacion_gobernanza.md)

---

> **Nota de versión:** `terraform test` se introdujo en **Terraform 1.6** (GA). Los `mock_provider`, que permiten tests unitarios sin credenciales reales, están disponibles desde **Terraform 1.7**. Los ejemplos de esta sección requieren como mínimo la versión 1.7.

---

## 5.1 Testing de Infraestructura: ¿Por qué?

> "Infrastructure as Code sin tests es solo Infrastructure as Text." — Kief Morris

El testing de infraestructura valida que tu código HCL produce los recursos esperados, con la configuración correcta, antes de tocar entornos reales. Los beneficios son los mismos que en desarrollo de software, pero los costes de los errores son mayores:

- Un Security Group mal configurado en producción puede significar una brecha de seguridad
- Una base de datos sin cifrado puede violar GDPR
- Una instancia de tipo equivocado puede costar diez veces más de lo esperado

**La pirámide de testing para infraestructura:**

```
           Terratest (Go)
         Tests E2E (costosos, lentos, alta fidelidad)
        terraform test - apply
      Tests de integración (crean recursos reales)
     terraform test - plan + Mock Providers
   Tests de unidad (rápidos, sin infraestructura real)
  terraform validate + fmt + trivy/checkov
Tests estáticos (instantáneos, sin credenciales)
```

---

## 5.2 Primera Línea de Defensa: `validate` y `plan`

```bash
# terraform validate — valida sintaxis y consistencia interna
# No necesita credenciales AWS; se ejecuta en milisegundos
$ terraform validate
Success! The configuration is valid.
# ✓ Referencias entre recursos válidas
# ✓ Tipos de variables correctos
# ✓ Bloques validation pasan
# ✓ No requiere credenciales

# terraform plan — compara con el estado real de la infraestructura
# Requiere credenciales; detecta drift de configuración
$ terraform plan
Plan: 3 to add, 1 to change, 0 to destroy.
# ✓ Muestra cambios ANTES de aplicar
# ✓ Verifica permisos y quotas del provider
# ✓ Salida parseable con -json para CI/CD
```

En el pipeline de CI/CD: `validate` en cada commit (sin credenciales), `plan` en cada PR (con credenciales de entorno de staging).

---

## 5.3 Higiene de Código: `terraform fmt --check`

El estilo inconsistente en HCL genera ruido en los code reviews — diffs llenos de cambios de espaciado que ocultan los cambios reales. `terraform fmt` resuelve esto:

```bash
# Auto-corregir formato en todos los subdirectorios
$ terraform fmt -recursive

# Verificar en CI/CD (bloquea el pipeline si hay archivos sin formatear)
$ terraform fmt -check -recursive
# Exit code 1 si hay archivos mal formateados → el PR no puede mergearse
```

Beneficios del formato consistente:
- Elimina discusiones de estilo en code reviews ("usa 2 espacios" "no, 4")
- PRs más limpios — los diffs muestran solo cambios de lógica
- Consistencia automática en todo el equipo sin esfuerzo manual

---

## 5.4 Terraform Test Framework: El Estándar Nativo

Terraform v1.6 introdujo el comando `terraform test` — un framework de testing nativo que escribe tests en **HCL puro**, sin necesidad de Go, Python ni ningún SDK externo:

```bash
$ terraform test
tests/s3_bucket.tftest.hcl... pass
tests/vpc_naming.tftest.hcl... pass
Success! 2 passed, 0 failed.
```

**Características clave:**
- Archivos `.tftest.hcl` con la misma sintaxis que el código de producción
- Soporta tests de tipo `plan` (rápidos, sin infraestructura) y `apply` (fidelidad máxima)
- Mock providers para tests sin credenciales ni costes
- Cleanup automático de recursos creados durante el test

---

## 5.5 Anatomía de un Test: El Archivo `.tftest.hcl`

```
modules/s3-bucket/
├── main.tf
├── variables.tf
├── outputs.tf
└── tests/
    ├── basic.tftest.hcl      ← Tests rápidos con plan
    └── integration.tftest.hcl ← Tests completos con apply
```

```hcl
# tests/s3_bucket.tftest.hcl — Test completo para módulo S3

# 1. Variables de prueba (sobreescriben los defaults del módulo)
variables {
  bucket_prefix     = "corp-data-"
  environment       = "testing"
  enable_versioning = true
}

# 2. Provider de pruebas (puede ser mock o real)
provider "aws" {
  region = "us-east-1"
}

# 3. Bloque run con asserts (puede haber múltiples)
run "verifica_prefijo_y_versioning" {
  command = plan   # ← plan: rápido, sin crear recursos

  assert {
    condition     = startswith(output.bucket_name, "corp-data-")
    error_message = "El nombre del bucket debe comenzar con el prefijo corporativo 'corp-data-'"
  }

  assert {
    condition     = output.versioning_enabled == true
    error_message = "El versionado debe estar activo según política corporativa"
  }
}
```

---

## 5.6 Ciclos de Ejecución: Plan vs. Apply en Tests

| | `command = plan` | `command = apply` |
|--|-----------------|-------------------|
| Velocidad | Segundos | Minutos |
| Infraestructura real | No crea nada | Crea y destruye automáticamente |
| Coste AWS | Cero | Genera costes |
| Fidelidad | Valida lógica HCL y expresiones | Valida APIs reales de AWS |
| Cuándo usar | Cada PR, pre-commit | Nightly builds, pre-release |

**Estrategia de dos niveles:**

```hcl
# Test rápido en cada PR
run "valida_logica" {
  command = plan
  assert { condition = startswith(output.bucket_name, "corp-") }
}

# Test de integración para releases
run "valida_en_aws_real" {
  command = apply   # Crea recursos reales en AWS y los destruye al terminar
  assert { condition = output.bucket_arn != "" }
}
```

---

## 5.7 Mock Providers: Tests sin Credenciales ni Costes

> **Versión mínima:** el bloque `mock_provider` fue introducido en **Terraform 1.7**. Para usarlo necesitas `terraform >= 1.7` en el bloque `required_version` de tu configuración.

El bloque `mock_provider` simula respuestas de AWS para validar lógica compleja sin conectar con ningún provider real. Ejecución en milisegundos, sin costes:

```hcl
# tests/unit.tftest.hcl — Tests sin conexión a AWS

mock_provider "aws" {
  alias = "main"
}

run "validate_naming_convention" {
  command   = plan
  providers = { aws = aws.main }

  assert {
    condition     = startswith(output.bucket_name, "corp-")
    error_message = "Todos los buckets deben empezar con el prefijo corporativo 'corp-'"
  }
}
```

Los Mock Providers son perfectos para validar la lógica de naming, los tags, las condiciones y las expresiones del módulo sin necesitar credenciales. El equipo de CI puede ejecutar estos tests en cada commit sin configuración de AWS.

---

## 5.8 Idempotencia: El Test del Segundo Plan

La idempotencia es un principio fundamental de Terraform: ejecutar `apply` dos veces sobre el mismo código debe producir el mismo resultado, y el segundo `plan` debe reportar **cero cambios**.

Si el segundo plan muestra cambios, el recurso está mal diseñado — Terraform lo recrearía en cada apply, potencialmente causando downtime.

```hcl
# Test de idempotencia en .tftest.hcl
run "create" {
  command = apply   # Crea la infraestructura
}

run "idempotent_check" {
  command = plan    # Segundo plan: debe mostrar 0 changes
  assert {
    condition     = true
    error_message = "El módulo no es idempotente: el segundo plan muestra cambios"
  }
}
```

Si `idempotent_check` falla, significa que hay un recurso que siempre parece "diferente" entre plan y apply — un bug de diseño que hay que resolver antes del release.

---

## 5.9 Security Testing: Trivy y Checkov

El análisis estático (SAST) escanea el código HCL sin ejecutarlo y reporta misconfiguraciones de seguridad: Security Groups abiertos, buckets S3 públicos, RDS sin cifrado, etc.

```bash
# Trivy — especializado en IaC, contenedores y dependencias
$ trivy config .

# Checkov (Prisma Cloud) — multi-framework
$ checkov -d . --framework terraform
$ checkov -d . --output junitxml > results.xml   # Para CI/CD
```

```yaml
# .github/workflows/terraform-security.yml
name: Terraform Security Scan
on: [pull_request]

jobs:
  security:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Run Checkov
        uses: bridgecrewio/checkov-action@master
        with:
          directory: modules/
          framework: terraform
          output_format: sarif
          soft_fail: false   # ← Bloquea el PR si hay vulnerabilidades CRITICAL
```

Ambas herramientas son gratuitas, open-source y se integran fácilmente en GitHub Actions, GitLab CI y Jenkins.

---

## 5.10 FinOps Testing: Infracost en el Pull Request

Infracost estima el impacto económico de cada cambio de infraestructura directamente en el Pull Request, antes de que alguien haga `apply`:

```
💰 Monthly cost estimate
────────────────────────────────────────
Project: infra/production

+ aws_db_instance.main          +$185/mo    ← Nueva BD añadida
~ aws_instance.web              +$65/mo     ← Upgrade de t3.medium a m5.large

────────────────────────────────────────
TOTAL:  $1,245/mo → $1,495/mo  (+$250/mo)
```

Los revisores del PR pueden ver inmediatamente si el cambio implica un coste mensual de $250 más antes de aprobarlo. Sin Infracost, esa información solo se descubriría después del apply.

---

## 5.11 Terratest: Testing de Integración con Go

Terratest es la herramienta estándar para tests de integración End-to-End — despliega infraestructura real, ejecuta validaciones (HTTP, SSH, consultas a APIs) y destruye todo al terminar:

```go
// test/vpc_test.go — Test de integración con Terratest
func TestVpcModule(t *testing.T) {
    terraformOptions := &terraform.Options{
        TerraformDir: "../modules/vpc",
        Vars: map[string]interface{}{
            "vpc_cidr":     "10.0.0.0/16",
            "environment":  "test",
        },
    }

    // Destroy automático al terminar el test (incluso si falla)
    defer terraform.Destroy(t, terraformOptions)

    terraform.InitAndApply(t, terraformOptions)

    // Validaciones sobre la infraestructura real
    vpcId := terraform.Output(t, terraformOptions, "vpc_id")
    assert.NotEmpty(t, vpcId, "El VPC ID no debe estar vacío")
}
```

```bash
# Ejecutar con timeout extendido (la infra tarda en crearse)
$ go test -v -timeout 30m ./test/...
```

Terratest es más expresivo para tests complejos (verificar que un endpoint HTTP responde correctamente, que una instancia es accesible por SSH, que un bucket S3 tiene el versionado activo via la SDK de AWS). Para validaciones simples de lógica HCL, `terraform test` es más apropiado.

---

## 5.12 Buenas Prácticas: Test-Driven Infrastructure

| Tipo de test | Herramienta | Cuándo | Velocidad |
|-------------|-------------|--------|-----------|
| Estático | `terraform validate`, `fmt` | Cada commit | Segundos |
| Seguridad | Trivy, Checkov | Cada PR | Segundos |
| Unidad HCL | `terraform test` (plan + mock) | Cada PR | Segundos-minutos |
| Integración | `terraform test` (apply) | Nightly | Minutos |
| E2E | Terratest | Pre-release | 10-30 minutos |

```
Reglas de oro:
✓ Tests nativos primero (terraform test): rápidos, sin coste, sin infraestructura
✓ Seguridad automatizada (Checkov/Trivy) en cada PR — zero trust
✓ Idempotencia obligatoria: el segundo plan debe mostrar 0 cambios
✓ Cleanup automático: defer destroy en Terratest; nunca dejes recursos huérfanos
✓ FinOps en el PR: Infracost para visibilidad de coste antes del apply
```

---

## 5.13 Resumen: La Pirámide de Calidad

```
Test Estático    → terraform validate + fmt + trivy/checkov
    ↑                (sin credenciales, segundos, cada commit)
Test de Unidad   → terraform test + mock_provider
    ↑                (lógica HCL, sin infraestructura, cada PR)
Test Integración → terraform test + apply
    ↑                (recursos reales, nightly)
Test E2E         → Terratest
                     (validación completa, pre-release)
```

> **Principio:** La infraestructura que no tiene tests es infraestructura que no puedes refactorizar con confianza. Cada módulo debe tener al menos tests de validación (plan + asserts) para sus invariantes más importantes. Los tests de seguridad estática (Checkov/Trivy) deben ser no negociables en el pipeline de cualquier equipo.

---

> **Siguiente:** [Sección 6 — Documentación, Publicación y Gobernanza →](./06_publicacion_gobernanza.md)
