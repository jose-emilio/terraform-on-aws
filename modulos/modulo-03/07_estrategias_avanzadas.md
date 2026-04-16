# Sección 7 — Estrategias Avanzadas de State

> [← Sección anterior](./06_workspaces.md) | [Volver al índice →](./README.md)

---

## 7.1 El Anti-Patrón: El State Monolítico

Muchos proyectos comienzan con un único archivo `terraform.tfstate` que gestiona toda la infraestructura: redes, bases de datos, servidores, balanceadores. Al principio es cómodo. A medida que la infraestructura crece, se convierte en el mayor riesgo del proyecto.

**Los tres problemas del State monolítico:**

| Problema | Impacto |
|---------|---------|
| **Blast Radius Gigante** | Un error en `apply` afecta TODA la infraestructura. Cambiar una etiqueta en un Security Group puede romper accidentalmente la red |
| **Lentitud en Plan/Apply** | Refresh de cientos de recursos hace que `terraform plan` tarde minutos. El feedback loop de CI/CD se destruye |
| **Bloqueos entre Equipos** | Solo 1 `apply` simultáneo por lock. El equipo de Apps espera al equipo de Redes. Cola de deploys en producción |

La solución es dividir: **State Splitting por capas** (Layering).

---

## 7.2 Patrones de State por Capa (Layering)

El principio es simple: cada capa de infraestructura tiene su propio State, aislado de las demás. Las capas se organizan por frecuencia de cambio:

```
Capa 3: Compute
EC2, EKS, Lambda, ECS   ← Cambia a diario

Capa 2: Data
RDS, S3, DynamoDB        ← Cambia semanalmente

Capa 1: Networking
VPC, Subnets, IGW, TGW  ← Cambia raramente
```

Estructura en S3:
```
s3://mi-empresa-tfstate/
├── networking/terraform.tfstate    ← Capa 1
├── data/terraform.tfstate          ← Capa 2
└── compute/terraform.tfstate       ← Capa 3
```

**Beneficios del Layering:**
- Blast radius limitado a cada capa — un error en Compute no toca Networking
- `plan`/`apply` rápido: pocos recursos por State
- Equipos trabajan en paralelo sin bloqueos de lock
- Permisos IAM granulares por capa (el equipo de Apps no puede tocar VPCs)
- Ciclos de vida independientes: Networking se modifica mensualmente, Compute diariamente

---

## 7.3 Comunicación entre States: `terraform_remote_state`

Las capas necesitan comunicarse: Compute necesita el `vpc_id` que creó Networking. Para esto existe el data source `terraform_remote_state` — permite que un proyecto lea los outputs de otro State en **solo lectura**, sin acoplamiento físico:

**Proyecto A (Networking) — expone outputs:**
```hcl
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
  tags       = { Name = "prod-vpc" }
}

resource "aws_subnet" "app" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "10.0.1.0/24"
}

output "vpc_id" {
  value = aws_vpc.main.id
}

output "subnet_id" {
  value = aws_subnet.app.id
}
```

**Proyecto B (Compute) — consume outputs:**
```hcl
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "mi-empresa-tfstate"
    key    = "networking/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_instance" "app" {
  subnet_id = data.terraform_remote_state.network.outputs.subnet_id  # Subnet ID, no VPC ID
  ami       = "ami-0abcdef1234567890"
}

# Proyecto B lee subnet_id sin acceso de escritura al State de Networking
# → desacoplamiento total ✓
```

**Cómo funciona:**
1. El Proyecto A declara `outputs` en su State (`vpc_id`, `subnet_ids`, `sg_ids`)
2. El Proyecto B usa `data.terraform_remote_state.net.outputs.vpc_id` para consumirlos
3. El acceso es de solo lectura — B no puede modificar el State de A

> **Alternativa moderna:** Para nuevos proyectos, considera data sources dedicados (`data "aws_vpc" {}`) o HCP Terraform run triggers en lugar de `terraform_remote_state`. Son más desacoplados y no requieren acceso al bucket S3 de otro equipo.

---

## 7.4 Disaster Recovery del State

El State es el activo más crítico de tu infraestructura como código. Sin él, Terraform no sabe qué recursos existen — perderlo equivale a perder el control total.

**Escenarios de desastre reales:**
- Corrupción del JSON por un `apply` fallido en mitad de la ejecución
- Borrado accidental del bucket S3 (sin MFA Delete activo)
- Pérdida de llaves KMS de cifrado
- `terraform state rm` ejecutado por error en producción
- Merge conflict en un State local compartido por email

**Estrategia Backup 3-2-1:**

```
3 copias del State en todo momento
2 medios distintos (S3 + exportación periódica)
1 copia en otra región AWS (Cross-Region Replication)

+ Versionado S3 habilitado siempre
+ MFA Delete en bucket de producción
```

**Acciones de recuperación por escenario:**

| Escenario | Recuperación |
|-----------|-------------|
| Apply corrupto sobreescribe State | Restaurar versión anterior desde S3 Versioning |
| State borrado accidentalmente | `terraform import` para re-adoptar recurso a recurso |
| Necesitas ver cambios exactos | `terraform state pull/push` + `diff` manual |
| Validar coherencia post-recuperación | `terraform plan` (debe mostrar "No changes") |

---

## 7.5 Auditoría de Cambios con Versionado S3

El versionado S3 no es solo para recuperación — es también una herramienta de auditoría forense. Puedes ver exactamente qué cambió entre dos versiones del State:

```bash
# Listar todas las versiones del State
$ aws s3api list-object-versions \
    --bucket "mi-empresa-tfstate" \
    --prefix "prod/terraform.tfstate" \
    --query "Versions[*].[VersionId,LastModified,Size]"

# Descargar versión de ayer
$ aws s3api get-object \
    --bucket "mi-empresa-tfstate" \
    --key "prod/terraform.tfstate" \
    --version-id "abc123" state-ayer.json

# Descargar versión de hoy
$ aws s3api get-object \
    --bucket "mi-empresa-tfstate" \
    --key "prod/terraform.tfstate" \
    --version-id "def456" state-hoy.json

# Comparar los cambios entre versiones
$ terraform show -json state-ayer.json > ayer.txt
$ terraform show -json state-hoy.json > hoy.txt
$ diff --color ayer.txt hoy.txt   # Identifica el delta exacto
```

> **Consejo:** Automatiza este proceso con un cron job que archive versiones del State cada 6 horas en un bucket separado de auditoría.

---

## 7.6 Drift Detection: Cuando la Realidad Diverge

El **drift** ocurre cuando la infraestructura real difiere del código. Cambios manuales en la consola AWS, scripts ad-hoc o intervenciones de emergencia crean divergencia silenciosa:

```
Código (.tf)           State (.tfstate)        Realidad (AWS Console)
Security Group:    =   Security Group:    ≠   Security Group:
ingress: 443           ingress: 443            ingress: 443, 22, 3389
                                               ← Puertos 22 y 3389 añadidos manualmente
```

**Cómo detecta Terraform el Drift:**
1. `terraform plan` ejecuta un refresh automático
2. Consulta la API de AWS para cada recurso gestionado
3. Compara la realidad actual vs. el State almacenado
4. Muestra `~` (update) para los recursos con drift

**Por qué es crítico detectarlo:**
- Cambios no documentados en producción sin trazabilidad
- El próximo `apply` puede revertir hotfixes manuales necesarios
- Auditoría de compliance pierde trazabilidad de quién cambió qué
- Ejecuta planes periódicos como política del equipo

---

## 7.7 Reconciliación: Volviendo al Desired State

Cuando detectas drift, debes decidir: ¿el código manda o la realidad manda? La respuesta depende del contexto y el impacto en producción:

**Opción A: El Código Manda**
```
Ejecutar terraform apply → sobrescribe el cambio manual
y restaura el estado declarado en los archivos .tf

✓ Úsala cuando:
  ▸ El cambio manual fue un error
  ▸ La config del código es la correcta
  ▸ No hay tráfico activo afectado

⚠ Riesgo: puede causar downtime si el cambio manual
  era un hotfix necesario que aún no se ha documentado
```

**Opción B: La Realidad Manda**
```
Actualizar el código .tf para reflejar el cambio manual
y alinear el código con la infraestructura real

✓ Úsala cuando:
  ▸ El cambio manual fue un hotfix válido y probado
  ▸ Revertir causaría interrupción de servicio
  ▸ El equipo ha validado el cambio como correcto

⚠ Riesgo: legitimar cambios ad-hoc como práctica habitual
  erosiona la disciplina de IaC y la trazabilidad
```

> **Regla de oro:** Siempre haz `terraform plan` antes de `apply`. Revisa el diff. Nunca ejecutes `apply` a ciegas.

---

## 7.8 Drift Detection Nativo en la Nube

Las plataformas modernas eliminan la necesidad de ejecutar planes manuales periódicamente. Vigilan la infraestructura 24/7 y alertan en tiempo real:

| Plataforma | Capacidad |
|-----------|-----------|
| **HCP Terraform: Health Assessments** | Drift detection automático — configurable: diario, semanal o por hora. Alerta vía webhook, Slack o email. Muestra diff exacto en la UI |
| **AWS Control Tower: Drift Detection** | Detecta cambios en guardrails de AWS. Monitorea OUs, SCPs y cuentas. Integración con AWS Config Rules. Notificación via SNS |
| **Continuous Validation (TF 1.5+)** | Bloque `check {}` en HCL. Postconditions evaluadas en cada plan. Assertions personalizadas por recurso |

**Hacia AIOps:** Las plataformas más avanzadas ya ofrecen correlación automática de cambios, predicción de impacto antes del apply, auto-remediación de drift trivial y dashboards unificados multi-cloud.

---

## 7.9 Resumen: El State como Activo Estratégico

> *"Divide y vencerás, pero audita para reinar."*

La evolución natural de cualquier proyecto Terraform maduro:

```
1. State Monolítico       → Un archivo para todo: máximo riesgo
2. State Splitting        → Segmentación por capas aisladas
3. Remote State           → Comunicación read-only entre capas
4. DR + Auditoría         → Backup 3-2-1 y forense con versionado
5. Drift Detection        → Vigilancia continua y auto-remediación
```

**Conclusiones clave:**

| Práctica | Implementación |
|----------|---------------|
| Divide el State | Por capas: Networking → Data → Compute (blast radius mínimo) |
| Comunica las capas | Via `terraform_remote_state` (solo lectura, sin acoplamiento directo) |
| Protege el State | Backup 3-2-1 + Versionado S3 + MFA Delete |
| Detecta el drift | Planes periódicos o Health Assessments nativos de la plataforma |

El State no es un detalle técnico — es el **corazón operacional** de tu infraestructura como código. Merece el mismo nivel de atención que el código de aplicación, la misma disciplina en backups que una base de datos de producción, y la misma rigurosidad en auditoría que un sistema financiero.

---

> **[← Volver al índice del Módulo 3](./README.md)**
