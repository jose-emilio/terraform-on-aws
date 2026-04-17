# Sección 6 — Seguridad en el Pipeline de Terraform

> [← Sección anterior](./05_seguridad_avanzada.md) | [Volver al índice →](./README.md)

---

## 6.1 DevSecOps: El Blindaje del Pipeline de IaC

La seguridad tradicional valida en producción — cuando el coste de corrección ya es máximo. **DevSecOps** integra la seguridad en cada fase del ciclo de vida de Terraform, reduciendo el coste de corrección drásticamente:

```
Código    →   Plan     →   Apply    →   Runtime
SAST          PaC           OIDC         GuardDuty
Checkov       Sentinel       Sin secretos  Security Hub
Trivy         OPA

Coste:  x1        x10        x50         x100
```

> Detectar un error de seguridad en el código cuesta x1. En staging cuesta x10. En producción cuesta x100. Cada commit debe pasar por OIDC + SAST + PaC + FinOps antes de llegar a producción.

---

## 6.2 Seguridad del State: Los Tres Pilares

El archivo `terraform.tfstate` es el mapa completo de tu infraestructura. Su protección requiere tres pilares:

| Pilar | Implementación |
|-------|---------------|
| **Cifrado (KMS)** | `encrypt = true` en backend S3. KMS key dedicada para el state. Cifrado en reposo y en tránsito. Rotación automática |
| **Acceso (IAM)** | Política IAM restrictiva al bucket. Solo el pipeline tiene acceso. MFA Delete habilitado |
| **Auditoría (Logs)** | S3 Access Logs habilitados. CloudTrail para operaciones API. Alertas en acceso no autorizado. Versionado S3 para rollback |

**Código: Backend S3 Hardened**

```hcl
terraform {
  backend "s3" {
    bucket     = "mi-empresa-terraform-state"
    key        = "prod/networking/terraform.tfstate"
    region     = "us-east-1"
    encrypt    = true
    kms_key_id = "arn:aws:kms:us-east-1:123456:key/abc-123"
    use_lockfile = true
  }
}
```

---

## 6.3 OIDC: Autenticación sin Secretos en CI/CD

> ⚠️ **PELIGRO:** Inyectar `AWS_ACCESS_KEY_ID` y `AWS_SECRET_ACCESS_KEY` como secretos del repositorio crea credenciales permanentes que pueden ser robadas, filtradas o reutilizadas indefinidamente.

| Anti-patrón (Access Keys) | Solución (OIDC) |
|--------------------------|----------------|
| Credenciales de larga duración | Tokens efímeros (15 min - 1 hora) |
| Almacenadas en secretos del repo | Sin secretos almacenados |
| Si se filtran: acceso total | Rotación automática por diseño |
| Requieren rotación manual | Auditables vía CloudTrail |
| Vector de ataque principal en CI/CD | Estándar de la industria (JWT) |

**Flujo de autenticación OIDC:**
```
1. GitHub Action → Genera JWT con claims del repo y branch
2. AWS STS       → Valida JWT contra OIDC Provider registrado
3. Trust Policy  → Verifica subject: repo, branch, environment
4. Credenciales  → Emite tokens temporales (15 min - 1h)
```

**Código: Workflow de GitHub Actions con OIDC**

```yaml
# .github/workflows/deploy.yml
name: Deploy Infrastructure
on:
  push:
    branches: [main]

permissions:
  id-token: write    # Requerido para OIDC
  contents: read

jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: arn:aws:iam::123456:role/gh-deploy
          aws-region: us-east-1
          # Sin AWS_ACCESS_KEY_ID ni SECRET en ningún sitio
```

---

## 6.4 Checkov: Escaneo Preventivo de IaC

Checkov escanea código Terraform contra más de **1000 políticas de seguridad predefinidas** antes de ejecutar `terraform apply`:

| Categoría | Ejemplos |
|-----------|---------|
| **Recursos expuestos** | S3 buckets públicos, Security Groups abiertos, RDS sin cifrado |
| **Mejores prácticas** | Logging deshabilitado, backups sin configurar, tags obligatorios ausentes |
| **Compliance** | CIS Benchmarks, SOC2/HIPAA, PCI-DSS, NIST 800-53 |

**Código: Integración en GitHub Actions**

```bash
# Ejecución local
$ pip install checkov
$ checkov -d . --framework terraform

# Con salida JUnit para CI
$ checkov -d . --output junitxml > results.xml
```

```yaml
# Paso en GitHub Actions
- name: Run Checkov
  uses: bridgecrewio/checkov-action@master
  with:
    directory: .
    framework: terraform
    output_format: sarif
    soft_fail: false           # Pipeline falla si hay errores CRITICAL
    skip_check: CKV_AWS_18    # Excluir reglas con justificación documentada
```

---

## 6.5 Trivy config: Análisis Estático de IaC

Trivy analiza estáticamente archivos `.tf` para detectar configuraciones inseguras en AWS, Azure y GCP con **tiempos de ejecución inferiores a 1 segundo**:

**Características:**
- Binario único, sin dependencias
- Ejecución en milisegundos
- Soporte nativo de módulos y resolución de variables
- Reglas personalizadas en YAML/JSON
- Salida SARIF para GitHub Code Scanning

**Niveles de severidad:**
- `CRITICAL`: Exposición pública directa
- `HIGH`: Cifrado ausente o IAM abierto
- `MEDIUM`: Logging no habilitado
- `LOW`: Tags o descripciones faltantes

```bash
# Escaneo básico de IaC
$ trivy config .

# Filtrar por severidad
$ trivy config --severity HIGH,CRITICAL .

# Excluir checks específicos
$ trivy config --skip-check AVD-AWS-0086 .

# Salida SARIF para GitHub Code Scanning
$ trivy config --format sarif --output results.sarif .

# En CI: falla si hay issues CRITICAL o HIGH
$ trivy config --severity HIGH,CRITICAL --exit-code 1 .
```

---

## 6.6 Trivy: El Escáner Universal

Trivy (Aqua Security) consolida el escaneo de **contenedores, filesystems, repositorios git y archivos de IaC** en una sola herramienta:

| Target | Descripción |
|--------|------------|
| Contenedores | Vulnerabilidades en imágenes Docker y registros OCI |
| Filesystem | Dependencias inseguras en `package.json`, `go.mod` |
| IaC (Terraform) | Misconfiguraciones en `.tf` (reglas heredadas de tfsec) |
| Secretos | Claves API, passwords y tokens en el código fuente |

```bash
$ trivy config .                          # Escanear IaC
$ trivy image mi-app:latest               # Escanear contenedor
$ trivy fs --scanners vuln,secret .       # Filesystem + secretos
$ trivy config --severity HIGH,CRITICAL . # Solo severidad alta
```

---

## 6.7 Políticas como Código: Sentinel vs. OPA

Para una capa de gobernanza que va más allá del escáner estático, necesitas Policies as Code (PaC):

| Aspecto | Sentinel (HashiCorp) | OPA (Open Policy Agent) |
|---------|---------------------|------------------------|
| Ecosistema | Nativo de HCP Terraform/Enterprise | Estándar CNCF Graduated |
| Lenguaje | Sentinel (propio) | Rego (declarativo) |
| Integración | Directa con el plan de TF | Evalúa JSON del `terraform plan` |
| Niveles | Advisory, Soft Mandatory, Hard Mandatory | Pass/Fail configurable |
| Ideal para | Equipos que usan HCP Terraform | Multi-cloud, K8s, pipelines propios |

**Sentinel — niveles de enforcement:**
- **Advisory:** Informa pero permite continuar. Para recomendaciones.
- **Soft Mandatory:** Bloquea por defecto. Un admin puede aprobar excepciones.
- **Hard Mandatory:** Bloquea sin excepción. Para reglas de seguridad críticas.

**Código: Regla Sentinel para Restringir Regiones**

```python
# restrict-ec2-region.sentinel
import "tfplan/v2" as tfplan

allowed_regions = ["us-east-1", "us-west-2"]

ec2_instances = filter tfplan.resource_changes as _, rc {
  rc.type is "aws_instance" and
  rc.change.actions contains "create"
}

validate_region = rule {
  all ec2_instances as _, instance {
    instance.change.after.availability_zone in allowed_regions
  }
}

main = rule { validate_region }
```

---

## 6.8 OPA: El Estándar Universal con Rego

OPA evalúa archivos JSON (incluyendo `terraform plan -json`) contra políticas en Rego:

```
terraform plan -out=plan.bin
    ↓
terraform show -json plan.bin
    ↓
OPA / Conftest evalúa Rego
    ↓
Pass / Fail → Resultado CI
```

**Código: Política OPA para Denegar S3 sin Cifrado**

```rego
# policy/s3_encryption.rego
package terraform.s3

# Denegar S3 buckets sin cifrado SSE
deny[msg] {
  resource := input.resource_changes[_]
  resource.type == "aws_s3_bucket"
  resource.change.actions[_] == "create"
  not has_sse_config(resource)

  msg := sprintf(
    "S3 bucket '%s' debe tener cifrado SSE habilitado",
    [resource.name]
  )
}

has_sse_config(resource) {
  resource.change.after.server_side_encryption_configuration
}
```

---

## 6.9 Infracost: FinOps Preventivo en el Pipeline

El gasto descontrolado es un riesgo de seguridad operacional. Infracost estima el coste de los cambios de infraestructura **ANTES del apply** y comenta automáticamente en los Pull Requests:

```
Infracost estimate:
Monthly cost will increase by $47.52

aws_instance.web     $24.82/mo
aws_rds_instance.db  $15.20/mo
aws_nat_gateway.nat   $7.50/mo

Previous: $320.00  New: $367.52
✔ Dentro del presupuesto ($500/mo)
```

**Código: Infracost en Pull Request**

```yaml
# .github/workflows/infracost.yml
name: Infracost
on: [pull_request]

jobs:
  infracost:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Setup Infracost
        uses: infracost/actions/setup@v3
        with:
          api-key: ${{ secrets.INFRACOST_API_KEY }}
      - name: Generate diff
        run: infracost diff --path . --format json --out-file /tmp/infracost.json
      - name: Post PR comment
        run: infracost comment github --path /tmp/infracost.json --github-token ${{ secrets.GITHUB_TOKEN }}
```

---

## 6.10 Troubleshooting del Pipeline de Seguridad

| Problema | Causa | Fix |
|---------|-------|-----|
| **Falsos positivos en Checkov/Trivy** | El scanner reporta recursos que son intencionales | Usar `skip_check` con justificación: `#checkov:skip=CKV_AWS_18 "Bucket público intencional para static website"` |
| **Errores de red en OIDC** | Token JWT no aceptado por AWS STS | Verificar: 1) thumbprint del OIDC Provider, 2) `audience = sts.amazonaws.com`, 3) subject coincide con `repo:org/repo:ref:refs/heads/branch` |
| **Conflictos entre políticas OPA y código** | La política Rego rechaza un cambio legítimo | Usar `conftest test` para depurar localmente. Agregar excepciones con `import data.exceptions` |

---

## 6.11 Resumen: El Pipeline de Confianza Cero

```
1. OIDC        →   Autenticación sin secretos estáticos
2. SAST        →   Checkov + Trivy + 1000+ políticas
3. PaC         →   Sentinel/OPA — Enforcement por niveles
4. FinOps      →   Infracost en PR — Presupuestos preventivos
5. Deploy      →   terraform apply seguro
```

| Pilar | Protección |
|-------|-----------|
| **State protegido** | Cifrado KMS + IAM restrictivo + S3 Locking |
| **Sin credenciales** | OIDC Federation + Tokens efímeros + Zero secrets |
| **Escaneo SAST** | Checkov + Trivy — detecta misconfiguraciones antes del deploy |
| **Gobernanza PaC** | Sentinel (TFC) o OPA/Rego — enforcement por nivel |
| **Control costes** | Infracost en PR — FinOps preventivo |

> **Principio final:** La seguridad no es una feature, es una arquitectura. Cada recurso debe nacer seguro por defecto. El pipeline es la última línea de defensa antes de que el código llegue a producción — asegúrate de que sea sólida.

---

> **[← Volver al índice del Módulo 4](./README.md)**
