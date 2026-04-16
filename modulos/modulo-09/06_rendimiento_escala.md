# Sección 6 — Rendimiento y Optimización

> [← Volver al índice](./README.md)

---

## 1. El Problema de Escala en Terraform

A medida que la infraestructura crece — de 50 recursos a 500, o de 500 a 5,000 — el tiempo de `plan` y `apply` se degrada. Cada recurso requiere una llamada API al provider para sincronizar el state. El grafo de dependencias crece. Los pipelines de CI/CD se vuelven lentos.

> **El profesor explica:** "He visto proyectos donde `terraform plan` tardaba 25 minutos. El equipo dejaba de hacer `plan` regularmente porque era frustrante esperar. Y sin `plan`, la confianza se pierde. La optimización de Terraform no es un lujo — es una condición para que el proceso funcione. Un `plan` en 90 segundos se hace con frecuencia. Uno de 25 minutos, casi nunca."

**Cuellos de botella principales:**

| Cuello de botella | Causa | Solución |
|-------------------|-------|---------|
| Refresh del state | N llamadas API (una por recurso) | `-refresh=false` cuando es seguro |
| Grafo de dependencias | `depends_on` excesivo | Usar referencias directas |
| Rate limiting | Demasiadas llamadas paralelas | Reducir `-parallelism` |
| `terraform init` lento | Descarga repetida de providers | Plugin cache + mirror |
| State monolítico | 500+ recursos en un state | State splitting |

---

## 2. Grafo de Dependencias — Maximizar Paralelismo

Terraform construye un DAG (Directed Acyclic Graph) de recursos. Los nodos sin dependencias mutuas se procesan en paralelo. Cada `depends_on` innecesario reduce el paralelismo.

```hcl
# ❌ Mal: depends_on fuerza orden secuencial innecesario
resource "aws_instance" "web" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"

  depends_on = [aws_iam_role.ec2_role]   # Si ya hay referencia directa, esto es redundante
}

# ✅ Bien: referencia directa — Terraform infiere la dependencia
resource "aws_instance" "web" {
  ami                  = data.aws_ami.ubuntu.id
  instance_type        = "t3.micro"
  iam_instance_profile = aws_iam_instance_profile.web.name  # Dependencia implícita
}
```

**Regla:** Usa `depends_on` solo cuando no puedes hacer referencia directa al recurso (ej: módulos que crean recursos que otro módulo necesita sin que haya referencia directa entre ellos).

---

## 3. `-parallelism` — Control de Concurrencia

El flag `-parallelism` controla el número máximo de operaciones concurrentes. El valor por defecto es 10.

```bash
# Despliegue rápido de microservicios (recursos independientes)
terraform apply -parallelism=30

# Reducir por rate limiting de AWS (RequestLimitExceeded)
terraform apply -parallelism=5

# Configurar globalmente via variable de entorno
export TF_CLI_ARGS_apply="-parallelism=30"
export TF_CLI_ARGS_plan="-parallelism=30"

# Destroy rápido con alta concurrencia
terraform destroy -parallelism=30

# En CI/CD: configurable por entorno
PARALLELISM=${TERRAFORM_PARALLELISM:-10}
terraform apply -parallelism=$PARALLELISM
```

**Valores recomendados por provider:**

| Provider | Recomendado | Máximo seguro | Límite |
|----------|-------------|---------------|--------|
| AWS | 20 | 25 | RequestLimitExceeded |
| GCP | 30 | 40 | Generalmente permisivo |
| Azure | 10-15 | 15 | Límites más estrictos |
| Cuenta compartida | 5 | 10 | Cuota compartida |

---

## 4. `-target` — Operaciones Quirúrgicas

`-target` limita plan/apply a recursos o módulos específicos. Es un antipatrón para uso diario — pero un salvavidas en emergencias.

```bash
# Aplicar solo en el módulo de base de datos
terraform plan -target=module.database

# Aplicar solo un recurso específico
terraform apply -target=aws_db_instance.production

# Múltiples targets en un solo comando
terraform apply \
  -target=module.networking \
  -target=module.database

# Destroy quirúrgico de un recurso problemático
terraform destroy -target=aws_instance.broken_node

# Target con for_each (recurso indexado)
terraform apply -target='aws_instance.web["prod"]'
```

**Cuándo usar `-target` (legítimo):**
- Emergencias: corregir drift en un recurso sin tocar el resto.
- Debugging: aislar problemas en un apply complejo.
- Despliegues incrementales controlados durante una migración.

**Cuándo NO usar `-target` (antipatrón):**
- Como rutina diaria para acelerar deploys.
- Para evitar errores en otros módulos (síntoma de un problema más profundo).
- En pipelines de CI/CD automatizados sin supervisión humana.

> **Terraform te avisa:** Al usar `-target`, muestra el mensaje: "Warning: Applied changes may be incomplete". No ignores esta advertencia.

---

## 5. `-refresh=false` — Saltar Sincronización del State

```bash
# Plan sin consultar la API del provider
terraform plan -refresh=false

# Apply sin refresh previo
terraform apply -refresh=false

# Medir la diferencia de tiempo
time terraform plan                    # Consulta APIs: 5 minutos
time terraform plan -refresh=false    # Sin consulta: 15 segundos
```

**Cuándo es seguro:**
- Inmediatamente después de un `apply` reciente (state es autoritativo).
- Validación rápida de cambios de configuración en el código.
- CI/CD donde plan y apply se ejecutan en la misma sesión.

**Cuándo NO usarlo:**
- Como apply final en producción (no detecta cambios externos).
- Cuando sospecha de drift (cambios manuales en la consola).
- En el primer plan del día o tras largos períodos sin apply.

---

## 6. Plugin Cache y Provider Mirror en CI/CD

```bash
# Configurar cache de plugins via env var
export TF_PLUGIN_CACHE_DIR="$HOME/.terraform.d/plugin-cache"
mkdir -p $TF_PLUGIN_CACHE_DIR

# O via .terraformrc (permanente)
# plugin_cache_dir = "$HOME/.terraform.d/plugin-cache"
# disable_checkpoint = true

# Crear mirror local de providers
terraform providers mirror ./mirror

# .terraformrc para usar mirror local
# provider_installation {
#   filesystem_mirror {
#     path    = "./mirror"
#     include = ["hashicorp/*"]
#   }
# }
```

**En GitHub Actions:**

```yaml
- name: Cache Terraform providers
  uses: actions/cache@v4
  with:
    path: |
      ~/.terraform.d/plugin-cache
    key: ${{ runner.os }}-terraform-${{ hashFiles('**/.terraform.lock.hcl') }}
    restore-keys: |
      ${{ runner.os }}-terraform-

- name: Configure Terraform plugin cache
  run: |
    mkdir -p ~/.terraform.d/plugin-cache
    echo 'plugin_cache_dir = "$HOME/.terraform.d/plugin-cache"' > ~/.terraformrc
```

**Ahorro típico:** `terraform init` pasa de 60-90 segundos a 2-5 segundos cuando los providers están cacheados.

---

## 7. State Splitting — Fragmentación del Monolito

Dividir un state grande en múltiples states pequeños por componente lógico. Los states se comunican vía `terraform_remote_state` o data sources.

```
# Estructura de estados separados
infrastructure/
├── networking/        # VPC, subnets, IGW, NAT GW
│   └── main.tf        # Expone: vpc_id, subnet_ids
├── security/          # IAM, KMS, Security Groups
│   └── main.tf        # Expone: kms_key_arn, sg_ids
├── compute/           # EC2, ASG, Load Balancers
│   └── main.tf        # Consume: vpc_id, subnet_ids
└── database/          # RDS, ElastiCache, DynamoDB
    └── main.tf        # Consume: vpc_id, subnet_ids, sg_ids
```

```hcl
# infrastructure/networking/main.tf
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

output "vpc_id" {
  value = aws_vpc.main.id
}
```

```hcl
# infrastructure/compute/main.tf
data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "my-tf-state"
    key    = "networking/terraform.tfstate"
    region = "us-east-1"
  }
}

resource "aws_instance" "app" {
  # Usar el output del state de networking
  subnet_id = data.terraform_remote_state.network.outputs.private_subnet_ids[0]
}
```

**Beneficios del state splitting:**

| Beneficio | Impacto |
|-----------|---------|
| Plans más rápidos | Solo refresca N recursos en lugar de 500+ |
| Blast radius reducido | Un error en compute no puede destruir networking |
| Equipos independientes | Cada squad gestiona su state sin bloqueos |
| IAM granular | Permisos por componente, no acceso total |

---

## 8. Optimización de CI/CD Pipeline

```yaml
# GitHub Actions — Jobs paralelos por componente
name: Infrastructure Deploy

jobs:
  networking:
    # Sin dependencias: corre en paralelo
    runs-on: ubuntu-latest
    env:
      TF_PLUGIN_CACHE_DIR: $HOME/.terraform.d/plugin-cache
    steps:
      - run: terraform apply -parallelism=20 -auto-approve
    outputs:
      status: ${{ steps.apply.outcome }}

  iam:
    # Sin dependencias: corre en paralelo con networking
    runs-on: ubuntu-latest
    steps:
      - run: terraform apply -auto-approve

  compute:
    # Depende de networking + iam
    needs: [networking, iam]
    runs-on: ubuntu-latest
    steps:
      - run: terraform apply -parallelism=30 -auto-approve

  database:
    # Depende solo de networking
    needs: [networking]
    runs-on: ubuntu-latest
    steps:
      - run: terraform apply -parallelism=15 -auto-approve
```

**Patrón de pipeline seguro:**

```
PR abierto → terraform plan (sin apply)
PR merged  → terraform apply (solo en main)
Nightly    → terraform plan -refresh-only (drift detection)
```

---

## 9. Profiling y Debugging con `TF_LOG`

```bash
# Logs completos (muy verbosos — solo para debugging crítico)
export TF_LOG=TRACE
export TF_LOG_PATH="terraform.log"
terraform plan

# Solo logs del provider (sin ruido del core)
export TF_LOG_PROVIDER=DEBUG

# Solo logs del core de Terraform (sin ruido del provider)
export TF_LOG_CORE=INFO

# Medir tiempo de plan/apply
time terraform plan -parallelism=20

# Visualizar el grafo de dependencias
terraform graph | dot -Tpng > graph.png

# Contar recursos en el state (para decidir si dividir)
terraform state list | wc -l
```

**Niveles de log:**

| Nivel | Qué incluye | Cuándo usar |
|-------|-------------|-------------|
| `TRACE` | Todas las llamadas HTTP y API | Debugging de providers |
| `DEBUG` | Grafo, resolución de dependencias | Problemas de ordering |
| `INFO` | Operaciones principales | Auditoría general |
| `WARN` | Solo advertencias | Revisión periódica |
| `ERROR` | Solo errores críticos | Producción |

---

## 10. Troubleshooting de Rendimiento

| Síntoma | Causa probable | Solución |
|---------|---------------|---------|
| `RequestLimitExceeded` | `-parallelism` demasiado alto | Reducir a 5, esperar y reintentar |
| `terraform plan` > 10 min | State monolítico o muchos recursos | Fragmentar state, usar `-refresh=false` |
| `terraform init` lento en CI | Sin cache de providers | `TF_PLUGIN_CACHE_DIR` + cachear `.terraform/` |
| OOM en plans grandes | Demasiados recursos paralelos | Dividir componentes, reducir parallelism, aumentar RAM del runner |
| Apply más lento que plan | Muchos `depends_on` secuenciales | Convertir a referencias directas |

---

## 11. Resumen: Técnicas de Optimización

```
┌─────────────────────────────────────────────────────────────┐
│            Guía Rápida de Optimización                      │
├────────────────────────┬────────────────────────────────────┤
│ Plan < 30 recursos     │ Sin optimización necesaria         │
│ Plan 30-300 recursos   │ Plugin cache + parallelism=20      │
│ Plan 300-1000 recursos │ State splitting + refresh=false    │
│ Plan 1000+ recursos    │ Fragmentar en múltiples stacks     │
│                        │ + CI/CD paralelo por componente    │
├────────────────────────┴────────────────────────────────────┤
│  Regla de oro: Si terraform plan > 2 min, dividir el state  │
└─────────────────────────────────────────────────────────────┘
```

**Checklist de optimización:**

- [ ] Reemplazar `depends_on` por referencias directas donde sea posible.
- [ ] Configurar `TF_PLUGIN_CACHE_DIR` en CI/CD.
- [ ] Ajustar `-parallelism` según el provider (AWS: 20, GCP: 30, Azure: 10-15).
- [ ] Dividir state monolítico si supera ~300 recursos o 5 minutos de plan.
- [ ] Implementar jobs paralelos en CI/CD por componente independiente.
- [ ] Usar `-refresh=false` en el plan de CI (apply con refresh completo).
- [ ] Habilitar `TF_LOG=WARN` en CI/CD para reducir ruido en logs.

---

> [← Volver al índice](./README.md)
