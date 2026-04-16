# Sección 4 — State Avanzado y Drift Management

> [← Volver al índice](./README.md) | [Siguiente →](./05_refactoring.md)

---

## 1. El State de Terraform — La Fuente de Verdad

El state es un archivo JSON que mapea cada recurso en tu configuración `.tf` con su correspondiente recurso real en la nube. Sin state, Terraform no puede saber qué ya existe, qué necesita crearse y qué debe actualizarse.

> **El profesor explica:** "El state es como el inventario de un almacén. Sin él, no sabes qué tienes. Si alguien va directamente al almacén y saca cajas sin anotarlo en el inventario, el sistema pierde la pista. Eso es el drift. Por eso la regla más importante es: todos los cambios de infraestructura pasan por Terraform — nunca por la consola directamente."

**Contenido del state:**
- IDs de los recursos en el provider (instance-id, ARN, etc.).
- Atributos y metadatos actuales del recurso.
- Dependencias entre recursos.
- Outputs y data sources.

**Riesgos del state:**
- Contiene datos sensibles (contraseñas, tokens, IPs privadas).
- **Nunca almacenar en Git sin cifrar.**
- Siempre usar remote backend en producción.
- Habilitar locking para trabajo en equipo.

---

## 2. Remote State Backends — Colaboración y Seguridad

Un remote backend almacena el state en una ubicación compartida con locking y cifrado, en lugar de en el disco local.

```hcl
# Backend S3 con locking nativo (Terraform 1.10+)
terraform {
  backend "s3" {
    bucket       = "mi-terraform-state"
    key          = "prod/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true           # SSE-S3 o SSE-KMS
    use_lockfile = true           # Locking nativo S3 (desde TF 1.10)
  }
}

# Antes de Terraform 1.10: usar DynamoDB para locking
# terraform {
#   backend "s3" {
#     bucket         = "mi-terraform-state"
#     key            = "prod/terraform.tfstate"
#     region         = "us-east-1"
#     encrypt        = true
#     dynamodb_table = "terraform-locks"  # Legacy
#   }
# }
```

**Comparativa de backends:**

| Backend | Locking | Cifrado | Versionado | Mejor para |
|---------|---------|---------|------------|------------|
| S3 + DynamoDB | DynamoDB (legacy) | SSE-S3/KMS | Bucket versioning | AWS, equipos medianos |
| S3 nativo (1.10+) | `use_lockfile = true` | SSE-S3/KMS | Bucket versioning | AWS, simplificado |
| GCS | Automático | Sí | Sí | Google Cloud |
| Azure Blob | Lease de blob | Sí | Sí | Azure |
| HCP Terraform | SaaS, completo | Sí | Sí | Equipos grandes |

---

## 3. State Locking y Seguridad

El locking impide que dos operaciones (`plan`, `apply`, `destroy`) modifiquen el state simultáneamente.

```
┌──────────────────────────────────────────────────────────────┐
│                    State Locking Flow                         │
│                                                              │
│  Dev A: terraform apply                                      │
│    → Adquiere lock                                           │
│    → Modifica state                                          │
│    → Libera lock                                             │
│                                                              │
│  Dev B: terraform apply (simultáneo)                         │
│    → Intenta adquirir lock                                   │
│    → Error: "state is locked by Dev A"                       │
│    → Espera o aborta                                         │
└──────────────────────────────────────────────────────────────┘
```

**Seguridad del state:**

```bash
# Si el lock queda bloqueado (proceso interrumpido):
terraform force-unlock LOCK_ID   # ⚠ Usar con precaución

# Verificar que el bucket tiene:
# - Versionado activado (recuperar versiones anteriores del state)
# - Cifrado en reposo (SSE-KMS recomendado)
# - IAM restrictivo (solo roles de CI/CD y administradores)
# - .gitignore con *.tfstate y .terraform/
```

---

## 4. Comandos `terraform state` — Inspección y Manipulación

```bash
# Listar todos los recursos en el state
$ terraform state list
aws_instance.web
aws_security_group.allow_ssh
module.vpc.aws_vpc.main

# Ver detalle completo de un recurso
$ terraform state show aws_instance.web

# Renombrar recurso en el state (preferir 'moved' block)
$ terraform state mv aws_instance.web aws_instance.server

# Desvincular recurso del state SIN destruirlo
$ terraform state rm aws_instance.legacy

# Descargar una copia del state remoto
$ terraform state pull > terraform.tfstate.backup

# Subir un state modificado (¡extremadamente peligroso!)
$ terraform state push terraform.tfstate.backup

# Importar recurso existente al state
$ terraform import aws_instance.web i-0abc123def
```

> **El profesor advierte:** "`terraform state push` puede destruir tu infraestructura si subes un state incorrecto. Nunca lo uses a menos que sepas exactamente lo que estás haciendo y hayas hecho backup previo. En 10 años de Terraform, he visto más incidentes causados por `state push` que por cualquier otra operación."

---

## 5. ¿Qué es el Drift?

El drift ocurre cuando la infraestructura real diverge de la configuración declarada en Terraform.

```
┌─────────────────────────────────────────────────────────────┐
│                      Drift                                  │
│                                                             │
│  Terraform State:   aws_instance.web → t3.micro            │
│  Realidad AWS:      aws_instance.web → t3.large  ← DRIFT!  │
│                                                             │
│  Causas comunes:                                            │
│  • Cambio manual en la consola cloud                        │
│  • Automatización externa (scripts, Ansible)                │
│  • Auto-scaling y managed services                          │
│  • terraform apply parcial o fallido                        │
└─────────────────────────────────────────────────────────────┘
```

**Consecuencias del drift no detectado:**
- Despliegues que fallan inesperadamente.
- Vulnerabilidades de seguridad (reglas SG modificadas manualmente).
- Inconsistencias entre entornos.
- Costos inesperados (instancias más grandes olvidadas).

---

## 6. Detección de Drift

```bash
# 1. Plan con refresh — detecta drift Y propone cambios
$ terraform plan

# 2. Refresh-only — detecta drift SIN proponer cambios
$ terraform plan -refresh-only

# Output cuando hay drift:
# Note: Objects have changed outside of Terraform
# ~ resource "aws_instance" "web" {
#     ~ instance_type = "t3.micro" -> "t3.large"
# }

# 3. Exit code para CI/CD
$ terraform plan -detailed-exitcode
# Exit 0 = sin cambios
# Exit 1 = error
# Exit 2 = drift detectado (hay cambios en el plan)

# 4. Sincronizar state con la realidad (acepta el drift)
$ terraform apply -refresh-only

# 5. Revertir drift (fuerza el estado declarado)
$ terraform apply
```

---

## 7. Drift Detection Automatizado en CI/CD

```yaml
# GitHub Actions — Drift Detection programado
name: Drift Detection

on:
  schedule:
    - cron: '0 8 * * 1-5'  # Lunes a Viernes a las 8AM UTC

jobs:
  detect-drift:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Setup Terraform
        uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: "~1.7"

      - name: Terraform Init
        run: terraform init

      - name: Detect Drift
        id: plan
        run: terraform plan -detailed-exitcode -refresh-only
        continue-on-error: true  # Exit 2 no debe fallar el job

      - name: Notify if Drift Detected
        if: steps.plan.outputs.exitcode == '2'
        run: |
          curl -X POST ${{ secrets.SLACK_WEBHOOK }} \
            -d '{"text": "⚠️ Drift detectado en infraestructura prod!"}'
```

**Herramientas alternativas:**
- **HCP Terraform:** Health Assessments automáticos con dashboard.
- **driftctl:** Detecta recursos no gestionados por Terraform.
- **Spacelift / Scalr / env0:** Plataformas IaC con drift detection integrado.
- **Check blocks:** Validaciones personalizadas en Terraform (TF 1.5+).

---

## 8. Estrategias de Remediación

| Situación | Estrategia | Comando |
|-----------|-----------|---------|
| Cambio manual fue un error | Revertir al estado declarado | `terraform apply` |
| Cambio manual fue intencional y debe persistir | Actualizar el código .tf para reflejarlo | Editar + `terraform apply` |
| Recurso existe pero no está en Terraform | Adoptar con import | `terraform import` o bloque `import` |
| State desincronizado sin drift real | Sincronizar solo el state | `terraform apply -refresh-only` |

---

## 9. `terraform import` y Bloque `import` (TF 1.5+)

### CLI import (legacy)

```bash
# Importar una instancia EC2 existente
$ terraform import aws_instance.web i-0abc123def456

# Requiere que el bloque resource exista en el código
# Solo modifica el state (no genera código .tf)
# Un recurso a la vez
```

### Bloque `import` declarativo (TF 1.5+)

```hcl
# imports.tf — Declarativo, revisable en PR
import {
  to = aws_instance.web
  id = "i-0abc123def456"
}

# Import masivo con for_each (TF 1.7+)
import {
  for_each = var.existing_buckets   # map(string)
  to       = aws_s3_bucket.managed[each.key]
  id       = each.value
}
```

```bash
# Generar HCL automáticamente desde el recurso real
$ terraform plan -generate-config-out=generated.tf

# Revisar y limpiar generated.tf (eliminar computed attributes)
# Verificar plan limpio
$ terraform plan

# Ejecutar el import
$ terraform apply
```

**CLI vs bloque `import`:**

| | `terraform import` CLI | Bloque `import` |
|-|------------------------|-----------------|
| Revisable en PR | No | Sí |
| Auto-genera HCL | No | Sí (`-generate-config-out`) |
| Imports masivos | No | Sí (`for_each`) |
| Requiere resource pre-escrito | Sí | Opcional con `-generate-config-out` |

---

## 10. Best Practices: State y Drift

**State Management:**
- Siempre usar remote backend con locking y cifrado activados.
- Nunca editar el state manualmente — usar `terraform state mv/rm`.
- Segmentar state por entorno/componente para reducir el blast radius.
- Habilitar versionado en el bucket S3 que aloja el state.

**Prevención de Drift:**
- **RBAC estricto:** Minimizar acceso directo a la consola cloud. Solo Terraform modifica infraestructura.
- **CI/CD con drift detection** programado (plan diario + alerta Slack).
- **Infraestructura inmutable:** Reemplazar en vez de mutar (AMIs, containers).
- **Policy-as-code:** Sentinel (HCP Terraform) u OPA para prevenir cambios no conformes.

```
Flujo ideal:
  Código .tf → PR review → merge → terraform apply (CI/CD)
  
  Jamás:
  Consola cloud → cambio manual → "lo documento luego"
```

---

> [← Volver al índice](./README.md) | [Siguiente →](./05_refactoring.md)
