# Laboratorio 48 — Fundamentos FinOps: Tags, Budgets y Spot Instances

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 11 — Observabilidad, Tagging y FinOps](../../modulos/modulo-11/README.md)


## Visión general

En este laboratorio construirás los cimientos de una **estrategia FinOps** completa sobre
AWS: desde el etiquetado automático de todos los recursos hasta la alerta preventiva de
presupuesto y la optimización del coste de cómputo mediante instancias Spot.

La arquitectura tiene cuatro capas:

1. **Etiquetado automático**: el bloque `default_tags` en el provider de AWS inyecta las
   etiquetas `Environment`, `Project`, `ManagedBy` y `CostCenter` en cada recurso de la
   cuenta sin escribir una sola línea de tags repetida.
2. **Naming centralizado**: un módulo Terraform propio genera nombres con el patrón
   `{app}-{env}-{component}-{resource}` (ej: `myapp-prd-compute-asg`), garantizando
   coherencia en la consola AWS, alertas y scripts de automatización.
3. **Control presupuestario**: `aws_budgets_budget` con alerta preventiva `FORECASTED`
   envía una notificación SNS cuando la predicción de gasto del mes supera el 85% del
   límite, permitiendo actuar antes de exceder el presupuesto.
4. **Cómputo optimizado**: un Auto Scaling Group con `mixed_instances_policy` combina
   una base garantizada de instancias On-Demand con capacidad Spot de hasta un 90% de
   descuento para el resto, diversificando en cuatro tipos de instancia para minimizar
   el riesgo de interrupción.

## Objetivos

- Comprender el bloque `default_tags` del provider AWS y cómo elimina la repetición de etiquetas
- Identificar la regla de precedencia entre `default_tags` y tags definidas en el recurso
- Diseñar y consumir un módulo de naming propio con convención `{app}-{env}-{component}-{resource}`
- Entender el patrón `for_each` para instanciar el módulo de naming una vez por recurso
- Aprovisionar un presupuesto `COST` mensual en AWS Budgets con notificación SNS
- Distinguir entre alertas `FORECASTED` (preventivas) y `ACTUAL` (reactivas) en Budgets
- Desplegar un Auto Scaling Group con `mixed_instances_policy` que combina On-Demand y Spot
- Comprender los parámetros `on_demand_base_capacity` y `on_demand_percentage_above_base_capacity`
- Elegir la estrategia de asignación Spot adecuada (`capacity-optimized` vs `lowest-price`)
- Calcular el ahorro real del modelo On-Demand + Spot respecto a On-Demand puro

## Requisitos previos

- Laboratorio 02 completado (bucket S3 para el backend de Terraform)
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.9 instalado

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGION="us-east-1"
```

## Arquitectura

```
  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  Provider AWS — default_tags                                                │
  │  ┌──────────────────────────────────────────────────────────────────────┐   │
  │  │  Environment = "prd"   Project = "lab48"                             │   │
  │  │  ManagedBy = "terraform"   CostCenter = "engineering"                │   │
  │  │  ↓ inyectadas automáticamente en TODOS los recursos de la cuenta     │   │
  │  └──────────────────────────────────────────────────────────────────────┘   │
  └─────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  Módulo de Naming  modules/naming                                           │
  │  ┌───────────────────────────────────────────────────────────────────────┐  │
  │  │  Patrón: {app}-{env}-{component}-{resource}                           │  │
  │  │  myapp-prd-network-vpc    myapp-prd-network-igw                       │  │
  │  │  myapp-prd-compute-asg    myapp-prd-compute-lt                        │  │
  │  │  myapp-prd-finops-budget  myapp-prd-finops-sns                        │  │
  │  └───────────────────────────────────────────────────────────────────────┘  │
  └─────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  VPC  10.48.0.0/16                                                          │
  │                                                                             │
  │  ┌─────────────────────────┐   ┌─────────────────────────┐                  │
  │  │  Subred pública AZ-a    │   │  Subred pública AZ-b    │                  │
  │  │  10.48.0.0/24           │   │  10.48.1.0/24           │                  │
  │  │                         │   │                         │                  │
  │  │  ┌──────────────────┐   │   │  ┌──────────────────┐   │                  │
  │  │  │  EC2 On-Demand   │   │   │  │  EC2 On-Demand   │   │                  │
  │  │  │  t3.small        │   │   │  │  t3.small        │   │                  │
  │  │  └──────────────────┘   │   │  └──────────────────┘   │                  │
  │  │  ┌──────────────────┐   │   │  ┌──────────────────┐   │                  │
  │  │  │  EC2 Spot        │   │   │  │  EC2 Spot        │   │                  │
  │  │  │  t3.small        │   │   │  │  t3.small        │   │                  │
  │  │  │  (interrumpible) │   │   │  │  (interrumpible) │   │                  │
  │  │  └──────────────────┘   │   │  └──────────────────┘   │                  │
  │  └─────────────────────────┘   └─────────────────────────┘                  │
  │                                                                             │
  └─────────────────────────────────┬───────────────────────────────────────────┘
                                    │ Internet Gateway
                                    ▼
                              Internet

  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  Auto Scaling Group  myapp-prd-compute-asg                                  │
  │  min=1 · max=4 · desired=4                                                  │
  │                                                                             │
  │  Mixed Instances Policy                                                     │
  │  ├── On-Demand base: 1 instancia (garantizada, no interrumpible)            │
  │  ├── Adicionales: 30% On-Demand / 70% Spot                                  │
  │  ├── Spot pool: t3.small, t3a.small, t3.medium, t3a.medium                  │
  │  └── Estrategia: capacity-optimized (máxima disponibilidad Spot)            │
  │                                                                             │
  │  Launch Template: Amazon Linux 2023 · gp3 20GB · IMDSv2 · SSM               │
  └─────────────────────────────────────────────────────────────────────────────┘

  ┌─────────────────────────────────────────────────────────────────────────────┐
  │  AWS Budgets  myapp-prd-finops-budget                                       │
  │  Límite: $20/mes  ·  Tipo: COST  ·  Periodo: MONTHLY                        │
  │                                                                             │
  │  Alerta 1 (FORECASTED, 85%):  predicción > $17 → SNS publish                │
  │  Alerta 2 (ACTUAL, 100%):     gasto real > $20  → SNS publish               │
  │       │                                                                     │
  │       ▼                                                                     │
  │  SNS Topic  myapp-prd-finops-sns                                            │
  │  └── Subscripción email (opcional)                                          │
  └─────────────────────────────────────────────────────────────────────────────┘
```

## Conceptos clave

### default_tags en el provider de AWS

El bloque `default_tags` es una funcionalidad del provider de AWS para Terraform que
permite definir un conjunto de etiquetas que se aplican **automáticamente a todos los
recursos** gestionados por ese provider, sin necesidad de declararlas en cada bloque
`resource`.

**El problema que resuelve:**

Sin `default_tags`, en un proyecto con 50 recursos tendrías que repetir las mismas
etiquetas en cada uno:

```hcl
# Sin default_tags: repetición masiva (anti-patrón)
resource "aws_vpc" "main" {
  ...
  tags = {
    Environment = "prd"   # repetido 50 veces
    Project     = "lab48" # repetido 50 veces
    ManagedBy   = "terraform" # repetido 50 veces
  }
}

resource "aws_subnet" "public" {
  ...
  tags = {
    Environment = "prd"   # repetido 50 veces
    Project     = "lab48" # repetido 50 veces
    ManagedBy   = "terraform" # repetido 50 veces
    Name = "..."
  }
}
```

**La solución con `default_tags`:**

```hcl
# providers.tf — se define UNA sola vez
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
    }
  }
}

# Los recursos solo definen sus tags únicas
resource "aws_vpc" "main" {
  ...
  tags = { Name = "myapp-prd-network-vpc" }  # solo la tag Name
}
```

**Regla de precedencia (merge + override):**

Si un recurso define una tag con la misma clave que `default_tags`, la del recurso
tiene prioridad (gana la más específica):

```hcl
default_tags { tags = { Environment = "prd" } }

resource "aws_instance" "canary" {
  tags = { Environment = "stg" }  # sobreescribe "prd" solo para este recurso
}
# Resultado: Environment = "stg" (la del recurso gana)
```

Esto es útil para recursos de staging o canary en un proyecto mayoritariamente de producción.

**Limitaciones importantes:**

- `default_tags` NO funciona con todos los recursos. Algunos recursos de AWS (como
  `aws_autoscaling_group` con sus tags de propagación a instancias) necesitan que las
  tags se definan explícitamente.
- Los data sources no reciben `default_tags` (no crean recursos, solo los leen).
- Los recursos de IAM inline (políticas inline de roles) tampoco.

**Impacto en FinOps:**

Con todas las tags aplicadas automáticamente, AWS Cost Explorer puede segmentar el
gasto por `Project`, `Environment` o `CostCenter` con cero esfuerzo adicional. La
consistencia de etiquetas es la base de cualquier estrategia de showback o chargeback.

### Módulo de naming centralizado

Un módulo de naming es un módulo Terraform local que encapsula la lógica de construcción
de nombres de recursos. En lugar de que cada equipo o recurso siga su propia convención,
un único módulo es la fuente de verdad.

**Patrón de este laboratorio:**

```
{app}-{env}-{component}-{resource}
```

| Segmento | Descripción | Ejemplo |
|----------|-------------|---------|
| `app` | Nombre corto de la aplicación | `myapp`, `billing`, `auth` |
| `env` | Entorno de dos/tres letras | `dev`, `stg`, `prd` |
| `component` | Subsistema funcional | `network`, `compute`, `data`, `api` |
| `resource` | Tipo de recurso AWS abreviado | `vpc`, `alb`, `asg`, `rds`, `sg` |

Ejemplos de nombres generados:

```
myapp-prd-network-vpc     → VPC de producción
myapp-prd-compute-asg     → ASG de producción
myapp-prd-compute-lt      → Launch Template de producción
myapp-stg-data-rds        → Base de datos de staging
myapp-dev-api-alb         → ALB de desarrollo
```

**Ventajas del módulo:**

1. **Consistencia**: todos los nombres siguen el mismo patrón independientemente del
   ingeniero que cree el recurso.
2. **Búsqueda**: en la consola AWS puedes escribir `myapp-prd` y filtrar todos los
   recursos de producción de esa aplicación.
3. **Automatización**: scripts de billing, alertas de CloudWatch y tareas de limpieza
   pueden parsear el nombre para determinar el entorno y el componente.
4. **Mantenimiento**: si la empresa decide cambiar la convención de nombres (por ejemplo,
   añadir la región), se modifica en un solo lugar — el módulo — y `terraform apply`
   actualiza todos los nombres.
5. **Validación**: el módulo puede incluir `validation` blocks para rechazar valores
   inválidos (espacios, mayúsculas, caracteres especiales) antes del plan.

**Cómo se consume con `for_each`:**

```hcl
module "naming" {
  source = "./modules/naming"

  for_each = {
    vpc = { component = "network", resource = "vpc" }
    asg = { component = "compute", resource = "asg" }
    lt  = { component = "compute", resource = "lt"  }
  }

  app       = var.app_name
  env       = var.environment
  component = each.value.component
  resource  = each.value.resource
}

# Uso en un recurso:
resource "aws_vpc" "main" {
  ...
  tags = { Name = module.naming["vpc"].name }
}
```

El `for_each` crea una instancia del módulo por cada clave del mapa. Cada instancia
es independiente y genera su propio nombre. El resultado es un mapa de módulos
indexado por la clave del `for_each`.

**Output del módulo:**

| Output | Valor | Uso |
|--------|-------|-----|
| `name` | `myapp-prd-compute-asg` | Nombre completo del recurso |
| `prefix` | `myapp-prd-compute` | Prefijo para recursos relacionados |
| `tags` | `{Component="compute", App="myapp"}` | Tags adicionales recomendadas |

### AWS Budgets

AWS Budgets es el servicio de control presupuestario de AWS. Permite definir umbrales
de gasto y recibir notificaciones cuando el gasto real o la predicción de cierre del
mes se aproximan o superan esos umbrales.

**Tipos de presupuesto:**

| Tipo | Qué monitoriza | Caso de uso |
|------|----------------|-------------|
| `COST` | Gasto en USD | Control del presupuesto general o por etiqueta |
| `USAGE` | Unidades de uso (GB, horas, etc.) | Controlar el uso de un servicio específico |
| `RI_UTILIZATION` | Utilización de Reserved Instances | Detectar RIs infrautilizadas |
| `RI_COVERAGE` | Porcentaje de horas cubiertas por RIs | Aumentar el uso de RIs |
| `SAVINGS_PLANS_UTILIZATION` | Utilización de Savings Plans | Similar a RI_UTILIZATION |

**Tipos de notificación — la diferencia fundamental:**

```
Mes en curso: 1 ── 5 ── 10 ── 15 ── 20 ── 25 ── 31
              │              │              │
              │     Mitad del mes          │
              │     Gasto: $9              │
              │     Predicción: $18        │
              │                           │
              │   FORECASTED 85% de $20   │    ACTUAL 100% de $20
              │   = $17 → ALERTA (día 15)│    = $20 → ALERTA (día ~27)
```

- **`FORECASTED`**: AWS analiza tu tasa de gasto actual y extrapola hasta fin de mes.
  Si a mitad de mes llevas $9 gastados, la predicción es $18. Con un límite de $20 y
  umbral al 85% ($17), la alerta `FORECASTED` se dispara porque $18 > $17. Recibes
  el aviso **con días de margen** para reducir el uso.

- **`ACTUAL`**: se dispara cuando el gasto real (no la predicción) supera el umbral.
  Para el umbral al 100% de $20, la alerta llegaría cuando ya hayas gastado $20 — el
  mes prácticamente ha terminado. Útil como "última línea de defensa", pero no preventiva.

**La estrategia preventiva FinOps combina ambas:**

```
Alerta 1: FORECASTED a 85% → "Vas a exceder el presupuesto, actúa ahora"
Alerta 2: ACTUAL a 100%    → "Ya lo has excedido, necesitas contención inmediata"
```

**Política del topic SNS:**

AWS Budgets es un servicio externo que necesita permiso explícito para publicar en el
topic SNS. Sin la política correcta, el presupuesto se crea pero las notificaciones
fallan silenciosamente. La condición `aws:SourceArn` vincula el permiso al ARN del
presupuesto de tu cuenta, evitando que otros presupuestos de otras cuentas (en entornos
AWS Organizations) publiquen en tu topic.

**Nota sobre datos históricos:**

AWS Budgets necesita datos históricos para construir predicciones `FORECASTED` fiables.
En cuentas nuevas o con gasto muy irregular, las predicciones pueden ser imprecisas
durante los primeros meses. La alerta `ACTUAL` al 100% es más fiable en esos casos.

### Auto Scaling Group con Mixed Instances Policy

Un Auto Scaling Group (ASG) con `mixed_instances_policy` es la forma más eficiente de
escalar cómputo en AWS combinando fiabilidad y coste óptimo.

**¿Qué son las Spot Instances?**

Las Spot Instances son capacidad sobrante del parque de servidores de AWS que se ofrece
con descuentos de hasta el 90% respecto al precio On-Demand. El coste varía en tiempo
real según la oferta y demanda de cada tipo de instancia en cada zona de disponibilidad.
La contrapartida: AWS puede recuperar una instancia Spot con solo **2 minutos de aviso**.

**Precio comparativo (us-east-1, t3.small):**

| Tipo | Precio/hora | Precio/mes (720h) | Descuento |
|------|-------------|-------------------|-----------|
| On-Demand | ~$0.0208 | ~$15.0 | — |
| Spot (promedio) | ~$0.0062 | ~$4.5 | ~70% |
| Spot (mínimo histórico) | ~$0.0021 | ~$1.5 | ~90% |

**¿Cuándo son adecuadas las Spot Instances?**

- Cargas de trabajo tolerantes a fallos (sin estado, idempotentes)
- Servidores web con balanceador de carga (si una instancia cae, el ALB redirige)
- Procesamiento batch (si se interrumpe, se reinicia el job)
- Entornos de desarrollo y staging (la interrupción tiene bajo impacto)

**Anatomía de la `mixed_instances_policy`:**

```hcl
mixed_instances_policy {
  instances_distribution {
    on_demand_base_capacity                  = 1   # siempre 1 On-Demand
    on_demand_percentage_above_base_capacity = 30  # 30% On-Demand, 70% Spot para el resto
    spot_allocation_strategy                 = "capacity-optimized"
  }

  launch_template {
    launch_template_specification { ... }

    override { instance_type = "t3.small"  }  # pool Spot
    override { instance_type = "t3a.small" }  # pool Spot
    override { instance_type = "t3.medium" }  # pool Spot
    override { instance_type = "t3a.medium"}  # pool Spot
  }
}
```

**Cálculo de la distribución con desired=2:**

```
1 instancia On-Demand (base garantizada)
+
1 instancia adicional (30% On-Demand = 0.3 → AWS redondea HACIA ARRIBA → 1 On-Demand)
= 2 On-Demand + 0 Spot
```

AWS redondea siempre hacia arriba el número de instancias On-Demand adicionales, por lo
que con una sola instancia por encima de la base cualquier porcentaje > 0% resulta en
On-Demand. Para ver instancias Spot con `pct=30` se necesita desired ≥ 3.

Con desired=4:
```
1 instancia On-Demand (base)
+
3 instancias adicionales:
  - 30% de 3 = 0.9 → redondea hacia arriba a 1 On-Demand
  - 2 Spot
= 2 On-Demand + 2 Spot
```

**Estrategias de asignación Spot:**

| Estrategia | Comportamiento | Cuándo usarla |
|-----------|----------------|---------------|
| `capacity-optimized` | AWS elige el pool con más capacidad disponible | Preferida: minimiza interrupciones |
| `capacity-optimized-prioritized` | Como la anterior, pero respeta el orden de los overrides | Cuando tienes preferencia de tipo de instancia |
| `lowest-price` | AWS elige el pool más barato en ese momento | Cuando el coste importa más que la estabilidad |
| `price-capacity-optimized` | Equilibrio entre precio y disponibilidad | Buena alternativa a `capacity-optimized` |

**Por qué diversificar tipos de instancia en el pool Spot:**

Si defines solo `t3.small` y AWS interrumpe las instancias Spot de `t3.small` en
`us-east-1a` (porque necesita recuperar esa capacidad), el ASG no puede lanzar
reemplazos Spot. Con cuatro tipos en el pool (`t3.small`, `t3a.small`, `t3.medium`,
`t3a.medium`), el ASG tiene tres alternativas más y la probabilidad de quedarse sin
capacidad Spot cae drásticamente.

**Launch Template vs Launch Configuration:**

Los Launch Configurations están deprecados desde 2023. Los Launch Templates son su
reemplazo con versionado, soporte para `mixed_instances_policy` y más opciones de
configuración. En cualquier proyecto nuevo, siempre usa Launch Templates.

**IMDSv2 en el Launch Template:**

`http_tokens = "required"` activa IMDSv2 (Instance Metadata Service v2). IMDSv2 usa un
token de sesión de corta duración para acceder a los metadatos de la instancia
(`http://169.254.169.254/latest/meta-data/`). Sin IMDSv2, una vulnerabilidad SSRF en
la aplicación permite a un atacante robar las credenciales del rol IAM de la instancia
con una simple petición HTTP. IMDSv2 es obligatorio en entornos de producción y una
buena práctica desde el día uno.

## Estructura

```
lab48/
└── aws/                             Infraestructura del laboratorio
    ├── providers.tf                 Provider AWS ~6.0 con default_tags, backend S3
    ├── variables.tf                 Variables: región, app, entorno, budget, ASG
    ├── main.tf                      Data sources (cuenta, región, AMI), instancias módulo naming
    ├── modules/
    │   └── naming/                  Módulo de naming centralizado
    │       ├── variables.tf         Inputs: app, env, component, resource
    │       ├── main.tf              Lógica de composición del nombre
    │       └── outputs.tf           Outputs: name, prefix, tags
    ├── network.tf                   VPC, IGW, subredes públicas en 2 AZs, route tables
    ├── budget.tf                    SNS topic + política + AWS Budgets (FORECASTED + ACTUAL)
    ├── asg.tf                       IAM role SSM, Security Group, Launch Template, ASG Mixed
    ├── outputs.tf                   IDs, nombres generados, ARNs
    └── aws.s3.tfbackend             Configuración parcial del backend S3
```

## Paso 1 — Desplegar la infraestructura

```bash
cd labs/lab48/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=terraform-state-labs-${ACCOUNT_ID}" \
  -backend-config="region=${REGION}"

terraform plan
terraform apply
```

El apply crea aproximadamente 20 recursos en este orden:
1. Módulo de naming (local, no crea recursos en AWS — solo calcula nombres)
2. VPC, Internet Gateway, subredes públicas, route tables y asociaciones
3. IAM role, policy attachment e instance profile para SSM
4. Security Group de las instancias del ASG
5. Launch Template
6. Auto Scaling Group con Mixed Instances Policy (lanza 4 instancias EC2)
7. SNS topic y política del topic
8. AWS Budgets budget

> **Tiempos de espera tras el apply:**
> - **1-3 min** — instancias EC2 del ASG en estado `running`
> - **1-5 min** — instancias registradas en SSM (SSM Manager Agent necesita conectarse)
> - **Inmediato** — presupuesto activo (las alertas FORECASTED pueden tardar 24h en
>   dispararse si no hay suficiente historial de gasto en la cuenta)

Guarda los outputs para los pasos siguientes:

```bash
ASG_NAME=$(terraform output -raw asg_name)
BUDGET_NAME=$(terraform output -raw budget_name)
SNS_ARN=$(terraform output -raw sns_topic_arn)
LT_ID=$(terraform output -raw launch_template_id)
AMI_ID=$(terraform output -raw ami_id)
VPC_ID=$(terraform output -raw vpc_id)
```

Para ver los nombres generados por el módulo de naming:

```bash
terraform output -json naming_examples
```

Salida esperada (similar):

```json
{
  "asg": "myapp-prd-compute-asg",
  "budget": "myapp-prd-finops-budget",
  "lt": "myapp-prd-compute-lt",
  "sg_asg": "myapp-prd-compute-sg",
  "sns_budget": "myapp-prd-finops-sns",
  "subnet_a": "myapp-prd-network-snpuba",
  "subnet_b": "myapp-prd-network-snpubb",
  "vpc": "myapp-prd-network-vpc"
}
```

---

## Paso 2 — Verificar el etiquetado automático (default_tags)

### Comprobar las tags de la VPC

```bash
aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags' \
  --output table
```

Salida esperada:

```
------------------------------------------
|              DescribeVpcs              |
+--------------+-------------------------+
|      Key     |          Value          |
+--------------+-------------------------+
|  Environment |  prd                    |
|  Project     |  lab48                  |
|  CostCenter  |  engineering            |
|  Name        |  myapp-prd-network-vpc  |
|  ManagedBy   |  terraform              |
+--------------+-------------------------+
```

Observa que la VPC tiene **5 etiquetas**, pero en [network.tf](aws/network.tf) solo se
define la tag `Name`. Las otras cuatro (`CostCenter`, `Environment`, `ManagedBy`,
`Project`) las ha inyectado automáticamente el bloque `default_tags` del provider.

### Comprobar las tags de una instancia EC2

Obtén el ID de una instancia del ASG y verifica sus tags:

```bash
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' \
  --output text)

aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].Tags' \
  --output table
```

Salida esperada (similar):

```
---------------------------------------------------------------------------------
|                               DescribeInstances                               |
+--------------------------------+----------------------------------------------+
|               Key              |                    Value                     |
+--------------------------------+----------------------------------------------+
|  aws:ec2launchtemplate:id      |  lt-0xxxxxxxxxxxx                            |
|  Name                          |  myapp-prd-compute-instance                  |
|  Component                     |  compute                                     |
|  aws:ec2:fleet-id              |  fleet-xxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx      |
|  aws:autoscaling:groupName     |  myapp-prd-compute-asg                       |
|  aws:ec2launchtemplate:version |  1                                           |
+--------------------------------+----------------------------------------------+
```

Las instancias lanzadas por el ASG reciben las tags definidas en los bloques `tag {
propagate_at_launch = true }` del ASG (`Name`, `Component`), más las tags `aws:*`
que AWS añade automáticamente para rastrear el origen de la instancia
(launch template, fleet, ASG).

> **Importante — `default_tags` no se propaga a instancias del ASG**: el bloque
> `default_tags` del provider aplica etiquetas a los recursos que Terraform crea
> directamente mediante la API. Las instancias EC2 de un ASG las lanza el servicio
> AWS Auto Scaling, no Terraform, por lo que `default_tags` **no llega** a ellas.
> Para que las instancias del ASG hereden `Environment`, `Project`, etc., hay que
> declararlas explícitamente como bloques `tag { propagate_at_launch = true }` en el
> recurso `aws_autoscaling_group`. El Reto 1 cubre exactamente este punto.

### Verificar la regla de precedencia

El módulo de naming añade tags `App` y `Component` a través de `module.naming["asg"].tags`.
Si un recurso define explícitamente la misma clave que `default_tags`, verifiquemos que
la del recurso tiene precedencia.

```bash
# La VPC tiene una sola tag explícita (Name). Verifica que default_tags no la sobreescribe
aws ec2 describe-vpcs \
  --filters "Name=tag:Name,Values=myapp-prd-network-vpc" \
  --query 'Vpcs[0].{VpcId:VpcId,CIDR:CidrBlock}' \
  --output table
```

Salida esperada:

```
-------------------------------------------
|              DescribeVpcs               |
+---------------+-------------------------+
|     CIDR      |          VpcId          |
+---------------+-------------------------+
|  10.48.0.0/16 |  vpc-0xxxxxxxxxxxx      |
+---------------+-------------------------+
```

Terraform resuelve el merge internamente: las tags del bloque `tags = {}` del recurso
toman precedencia sobre las de `default_tags` si tienen la misma clave. En este caso,
`Name = "myapp-prd-network-vpc"` del recurso sobreescribiría un eventual `Name` de
`default_tags`, pero como `default_tags` no define `Name`, no hay conflicto.

### Contar recursos sin etiquetas (validación FinOps)

En proyectos reales es útil detectar recursos que Terraform gestiona directamente
(VPC, subredes, security groups, etc.) y confirmar que `default_tags` los ha etiquetado:

```bash
# Verifica que la VPC, subredes y SG tienen la tag Project (recursos creados directamente por Terraform)
for RESOURCE_ID in \
  $(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=myapp-prd-*" --query 'Vpcs[].VpcId' --output text) \
  $(aws ec2 describe-subnets --filters "Name=tag:Name,Values=myapp-prd-*" --query 'Subnets[].SubnetId' --output text) \
  $(aws ec2 describe-security-groups --filters "Name=tag:Name,Values=myapp-prd-*" --query 'SecurityGroups[].GroupId' --output text); do
  TAG=$(aws ec2 describe-tags \
    --filters "Name=resource-id,Values=$RESOURCE_ID" "Name=key,Values=Project" \
    --query 'Tags[0].Value' --output text)
  echo "$RESOURCE_ID → Project=$TAG"
done
```

Salida esperada:

```
vpc-0xxxxxxxxxxxx    → Project=lab48
subnet-0xxxxxxxxxxxx → Project=lab48
subnet-0xxxxxxxxxxxx → Project=lab48
sg-0xxxxxxxxxxxx     → Project=lab48
```

> Las instancias del ASG **no tendrán** la tag `Project` a menos que se añadan
> bloques `tag { propagate_at_launch = true }` explícitos en el ASG (ver Reto 1).

---

## Paso 3 — Explorar el módulo de naming

### Ver la estructura del módulo

```bash
cat labs/lab48/aws/modules/naming/main.tf
```

El módulo es deliberadamente simple: su única responsabilidad es componer el nombre.
No crea recursos, no llama a la API de AWS. Es un módulo de transformación pura.

### Verificar que los nombres siguen el patrón

```bash
# Compara los nombres de los recursos desplegados con el patrón esperado
echo "=== VPC ==="
aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags[?Key==`Name`].Value' \
  --output text

echo "=== Security Group ==="
SG_ID=$(aws ec2 describe-security-groups \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[?GroupName!=`default`].GroupId' \
  --output text)
aws ec2 describe-security-groups \
  --group-ids "$SG_ID" \
  --query 'SecurityGroups[0].{Nombre:GroupName,Descripcion:Description}' \
  --output table

echo "=== Auto Scaling Group ==="
echo "$ASG_NAME"

echo "=== Budget ==="
echo "$BUDGET_NAME"
```

Salida esperada:

```
=== VPC ===
myapp-prd-network-vpc

=== Security Group ===
-------------------------------------------------------------------------------------------
|              DescribeSecurityGroups                                                     |
+-----------+-----------------------------------------------------------------------------+
|  Descripcion |  SG de instancias del ASG myapp-prd-compute-asg. Solo trafico de salida. |
|  Nombre      |  myapp-prd-compute-sg                                                    |
+-----------+-----------------------------------------------------------------------------+

=== Auto Scaling Group ===
myapp-prd-compute-asg

=== Budget ===
myapp-prd-finops-budget
```

Todos los nombres siguen el patrón `{app}-{env}-{component}-{resource}`, confirmando
que el módulo funciona correctamente.

### Simular un cambio de convención de nombres

Una de las ventajas del módulo es que cambios en la convención se propagan a todos los
recursos. Por ejemplo, si la empresa decide añadir la región al patrón:

```hcl
# modules/naming/main.tf — cambio hipotético
locals {
  name = "${var.app}-${var.env}-${var.region}-${var.component}-${var.resource}"
}
```

Con un solo cambio en el módulo, `terraform plan` mostraría que **todos los recursos**
necesitan actualizar su tag `Name`. Sin el módulo, habría que editar decenas de archivos.

> **Nota**: este es un ejercicio mental, no lo apliques en este laboratorio ya que el
> módulo actual no acepta `region` como variable.

---

## Paso 4 — Verificar el presupuesto y las alertas

### Comprobar que el presupuesto existe

```bash
aws budgets describe-budgets \
  --account-id "$ACCOUNT_ID" \
  --query 'Budgets[?BudgetName==`'"$BUDGET_NAME"'`].{
    Nombre:BudgetName,
    Tipo:BudgetType,
    LimiteUSD:BudgetLimit.Amount,
    Periodo:TimeUnit
  }' \
  --output table
```

Salida esperada:

```
-------------------------------------------------------------
|                      DescribeBudgets                      |
+-----------+---------------------------+----------+--------+
| LimiteUSD |          Nombre           | Periodo  | Tipo   |
+-----------+---------------------------+----------+--------+
|  20.0     |  myapp-prd-finops-budget  |  MONTHLY |  COST  |
+-----------+---------------------------+----------+--------+
```

### Verificar las notificaciones configuradas

```bash
aws budgets describe-notifications-for-budget \
  --account-id "$ACCOUNT_ID" \
  --budget-name "$BUDGET_NAME" \
  --query 'Notifications[].{
    Tipo:NotificationType,
    Umbral:Threshold,
    TipoUmbral:ThresholdType,
    Comparacion:ComparisonOperator
  }' \
  --output table
```

Salida esperada:

```
---------------------------------------------------------------------------
|                    DescribeNotificationsForBudget                       |
+--------------+--------------------+------------+------------------------+
| Comparacion  |  Tipo              | Umbral     | TipoUmbral             |
+--------------+--------------------+------------+------------------------+
|  GREATER_THAN|  FORECASTED        |  85.0      |  PERCENTAGE            |
|  GREATER_THAN|  ACTUAL            |  100.0     |  PERCENTAGE            |
+--------------+--------------------+------------+------------------------+
```

Dos alertas configuradas: la preventiva `FORECASTED` al 85% y la reactiva `ACTUAL`
al 100%. El sistema enviará una notificación SNS en cuanto se supere cualquiera de
los dos umbrales.

### Verificar los suscriptores de cada alerta

```bash
for NOTIFICATION_TYPE in FORECASTED ACTUAL; do
  echo "=== Suscriptores de la alerta $NOTIFICATION_TYPE ==="
  aws budgets describe-subscribers-for-notification \
    --account-id "$ACCOUNT_ID" \
    --budget-name "$BUDGET_NAME" \
    --notification "NotificationType=${NOTIFICATION_TYPE},ComparisonOperator=GREATER_THAN,Threshold=$([ "$NOTIFICATION_TYPE" = "FORECASTED" ] && echo "85" || echo "100"),ThresholdType=PERCENTAGE" \
    --query 'Subscribers[].{Tipo:SubscriptionType,Endpoint:Address}' \
    --output table
done
```

Salida esperada (con email configurado):

```
=== Suscriptores de la alerta FORECASTED ===
---------------------------------------------------------------------
|                DescribeSubscribersForNotification                 |
+-----------------------------------------------------------+-------+
|                         Endpoint                          | Tipo  |
+-----------------------------------------------------------+-------+
|  arn:aws:sns:us-east-1:<account-id>:myapp-prd-finops-sns  |  SNS  |
+-----------------------------------------------------------+-------+
=== Suscriptores de la alerta ACTUAL ===
---------------------------------------------------------------------
|                DescribeSubscribersForNotification                 |
+-----------------------------------------------------------+-------+
|                         Endpoint                          | Tipo  |
+-----------------------------------------------------------+-------+
|  arn:aws:sns:us-east-1:<account-id>:myapp-prd-finops-sns  |  SNS  |
+-----------------------------------------------------------+-------+
```

Ambas alertas publican al mismo topic SNS. Desde ese topic puedes suscribir múltiples
destinatarios (emails, webhooks de Slack, funciones Lambda) sin modificar el budget.

### Comprobar el gasto actual del mes

```bash
# Gasto real acumulado en el mes en curso, excluyendo créditos AWS
# El filtro NOT + RECORD_TYPE=Credit descarta los créditos promocionales o de soporte
# que AWS aplica a la cuenta, mostrando solo el gasto real de los servicios.
aws ce get-cost-and-usage \
  --time-period "Start=$(date +%Y-%m-01),End=$(date +%Y-%m-%d)" \
  --granularity MONTHLY \
  --metrics "BlendedCost" \
  --filter '{"Not": {"Dimensions": {"Key": "RECORD_TYPE", "Values": ["Credit"]}}}' \
  --query 'ResultsByTime[0].Total.BlendedCost.{Gasto:Amount,Moneda:Unit}' \
  --output table
```

Salida esperada (similar):

```
-------------------------------
|       GetCostAndUsage       |
+---------+-------------------+
|  Gasto  |      Moneda       |
+---------+-------------------+
|  3.42   |  USD              |
+---------+-------------------+
```

Con un presupuesto de $20, un gasto de $3.42 a mitad de mes proyecta ~$7 al cierre
(por debajo del umbral de $17 = 85% de $20). La alerta `FORECASTED` no se dispararía.

### Verificar la política del topic SNS

```bash
aws sns get-topic-attributes \
  --topic-arn "$SNS_ARN" \
  --query 'Attributes.Policy' \
  --output text | python3 -m json.tool
```

Salida esperada (similar):

```json
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowBudgetsToPublish",
            "Effect": "Allow",
            "Principal": {
                "Service": "budgets.amazonaws.com"
            },
            "Action": "SNS:Publish",
            "Resource": "arn:aws:sns:us-east-1:<account-id>:myapp-prd-finops-sns",
            "Condition": {
                "ArnLike": {
                    "aws:SourceArn": "arn:aws:budgets::<account-id>:*"
                }
            }
        }
    ]
}
```

La condición `ArnLike` con `aws:SourceArn` restringe que solo los presupuestos de
**esta cuenta** puedan publicar en el topic. En entornos con AWS Organizations donde
múltiples cuentas comparten recursos, esta condición previene que presupuestos de
otras cuentas publiquen en tu topic.

---

## Paso 5 — Explorar el ASG con Mixed Instances Policy

### Verificar la configuración del Auto Scaling Group

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].{
    Nombre:AutoScalingGroupName,
    Min:MinSize,
    Max:MaxSize,
    Deseado:DesiredCapacity,
    AZs:AvailabilityZones,
    Estado:Status
  }' \
  --output table
```

Salida esperada:

```
--------------------------------------------------------------
|                  DescribeAutoScalingGroups                 |
+---------+---------+------+------+--------------------------+
| Deseado | Estado  | Max  | Min  |         Nombre           |
+---------+---------+------+------+--------------------------+
|  4      |  None   |  4   |  1   |  myapp-prd-compute-asg   |
+---------+---------+------+------+--------------------------+
||                            AZs                           ||
|+----------------------------------------------------------+|
||  us-east-1a                                              ||
||  us-east-1b                                              ||
|+----------------------------------------------------------+|
```

### Verificar la Mixed Instances Policy

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].MixedInstancesPolicy.{
    BaseOnDemand:InstancesDistribution.OnDemandBaseCapacity,
    PctOnDemandAdicional:InstancesDistribution.OnDemandPercentageAboveBaseCapacity,
    EstrategiaSpot:InstancesDistribution.SpotAllocationStrategy,
    TiposInstancia:LaunchTemplate.Overrides[].InstanceType
  }' \
  --output table
```

Salida esperada:

```
----------------------------------------------------------------
|                   DescribeAutoScalingGroups                  |
+--------------+----------------------+------------------------+
| BaseOnDemand |   EstrategiaSpot     | PctOnDemandAdicional   |
+--------------+----------------------+------------------------+
|  1           |  capacity-optimized  |  30                    |
+--------------+----------------------+------------------------+
||                       TiposInstancia                       ||
|+------------------------------------------------------------+|
||  t3.small                                                  ||
||  t3a.small                                                 ||
||  t3.medium                                                 ||
||  t3a.medium                                                ||
|+------------------------------------------------------------+|
```

Confirma que la política tiene:
- **BaseOnDemand: 1** → la primera instancia es siempre On-Demand
- **PctOnDemandAdicional: 30** → 30% On-Demand, 70% Spot para las adicionales
- **EstrategiaSpot: capacity-optimized** → AWS elige los pools con más disponibilidad
- **4 tipos** en el pool Spot para máxima flexibilidad

### Verificar las instancias del ASG y su tipo (On-Demand vs Spot)

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[].{
    ID:InstanceId,
    Tipo:InstanceType,
    AZ:AvailabilityZone,
    Estado:LifecycleState,
    Salud:HealthStatus
  }' \
  --output table
```

Salida esperada (similar):

```
---------------------------------------------------------------------------
|                        DescribeAutoScalingGroups                        |
+------------+------------+-----------------------+----------+------------+
|     AZ     |  Estado    |          ID           |  Salud   |   Tipo     |
+------------+------------+-----------------------+----------+------------+
|  us-east-1b|  InService |  i-0xxxxxxxxxxxx      |  Healthy |  t3.small  |
|  us-east-1b|  InService |  i-0xxxxxxxxxxxx      |  Healthy |  t3.small  |
|  us-east-1a|  InService |  i-0xxxxxxxxxxxx      |  Healthy |  t3.small  |
|  us-east-1a|  InService |  i-0xxxxxxxxxxxx      |  Healthy |  t3.small  |
+------------+------------+-----------------------+----------+------------+
```

Las instancias se distribuyen en distintas AZs para alta disponibilidad. La API del
ASG no expone si cada instancia es On-Demand o Spot — ese campo (`InstanceLifecycle`)
solo está disponible a través de `ec2 describe-instances`. El siguiente paso lo verifica.

### Verificar el tipo de lifecycle (On-Demand vs Spot) para cada instancia

```bash
for INSTANCE_ID in $(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[].InstanceId' \
  --output text); do
  echo "=== Instancia: $INSTANCE_ID ==="
  aws ec2 describe-instances \
    --instance-ids "$INSTANCE_ID" \
    --query 'Reservations[0].Instances[0].{
      Tipo:InstanceType,
      AZ:Placement.AvailabilityZone,
      Lifecycle:InstanceLifecycle,
      Estado:State.Name
    }' \
    --output table
done
```

Salida esperada (similar):

```
=== Instancia: i-0xxxxxxxxxxxx ===
----------------------------------------------------
|                 DescribeInstances                |
+-------------+----------+-------------+-----------+
|     AZ      | Estado   |  Lifecycle  |   Tipo    |
+-------------+----------+-------------+-----------+
|  us-east-1b |  running |  None       |  t3.small |
+-------------+----------+-------------+-----------+
=== Instancia: i-0xxxxxxxxxxxx ===
----------------------------------------------------
|                 DescribeInstances                |
+-------------+----------+-------------+-----------+
|     AZ      | Estado   |  Lifecycle  |   Tipo    |
+-------------+----------+-------------+-----------+
|  us-east-1b |  running |  spot       |  t3.small |
+-------------+----------+-------------+-----------+
=== Instancia: i-0xxxxxxxxxxxx ===
----------------------------------------------------
|                 DescribeInstances                |
+-------------+----------+-------------+-----------+
|     AZ      | Estado   |  Lifecycle  |   Tipo    |
+-------------+----------+-------------+-----------+
|  us-east-1a |  running |  None       |  t3.small |
+-------------+----------+-------------+-----------+
=== Instancia: i-0xxxxxxxxxxxx ===
----------------------------------------------------
|                 DescribeInstances                |
+-------------+----------+-------------+-----------+
|     AZ      | Estado   |  Lifecycle  |   Tipo    |
+-------------+----------+-------------+-----------+
|  us-east-1a |  running |  spot       |  t3.small |
+-------------+----------+-------------+-----------+
```

`Lifecycle: None` indica instancia On-Demand. `Lifecycle: spot` indica instancia Spot.
Con los parámetros del laboratorio (base=1, pct_adicional=30, desired=4) la distribución
es **2 On-Demand + 2 Spot**: 1 base On-Demand + 30% de las 3 adicionales = 0.9 → redondea
a 1 On-Demand adicional + 2 Spot. El ASG distribuye las instancias equitativamente entre
las dos AZs disponibles, con una instancia de cada tipo por zona.

### Verificar el Launch Template

```bash
aws ec2 describe-launch-template-versions \
  --launch-template-id "$LT_ID" \
  --versions '$Latest' \
  --query 'LaunchTemplateVersions[0].LaunchTemplateData.{
    AMI:ImageId,
    IMDSv2:MetadataOptions.HttpTokens,
    VolumenTipo:BlockDeviceMappings[0].Ebs.VolumeType,
    VolumenGB:BlockDeviceMappings[0].Ebs.VolumeSize,
    Cifrado:BlockDeviceMappings[0].Ebs.Encrypted
  }' \
  --output table
```

Salida esperada:

```
---------------------------------------------------------------------------
|                    DescribeLaunchTemplateVersions                       |
+------------------------+----------+-----------+------------+------------+
|           AMI          | Cifrado  |  IMDSv2   | VolumenGB  | VolumenTipo|
+------------------------+----------+-----------+------------+------------+
|  ami-0xxxxxxxxxxxx     |  True    |  required |  20        |  gp3       |
+------------------------+----------+-----------+------------+------------+
```

`IMDSv2: required` confirma que IMDSv2 está activo. `Cifrado: True` garantiza que el
volumen raíz está cifrado. El Launch Template no especifica `instance_type`: al usarse
exclusivamente dentro de la `mixed_instances_policy`, los tipos los dictan los bloques
`override` (`t3.small`, `t3a.small`, `t3.medium`, `t3a.medium`), permitiendo que AWS
elija libremente del pool según la estrategia `capacity-optimized`.

### Verificar que las instancias son accesibles vía SSM

```bash
# Las instancias del ASG no heredan default_tags, por lo que no tienen la tag Project.
# Se filtra por aws:autoscaling:groupName, que AWS asigna automáticamente a todas
# las instancias lanzadas por el ASG.
aws ssm describe-instance-information \
  --filters "Key=tag:aws:autoscaling:groupName,Values=${ASG_NAME}" \
  --query 'InstanceInformationList[].{
    ID:InstanceId,
    Plataforma:PlatformType,
    Estado:PingStatus,
    AgentVersion:AgentVersion
  }' \
  --output table
```

Salida esperada (similar, tras 2-5 minutos del apply):

```
-----------------------------------------------------------------
|                  DescribeInstanceInformation                  |
+---------------+---------+-----------------------+-------------+
| AgentVersion  | Estado  |          ID           | Plataforma  |
+---------------+---------+-----------------------+-------------+
|  3.3.4121.0   |  Online |  i-0xxxxxxxxxxxx      |  Linux      |
|  3.3.4121.0   |  Online |  i-0xxxxxxxxxxxx      |  Linux      |
|  3.3.4121.0   |  Online |  i-0xxxxxxxxxxxx      |  Linux      |
|  3.3.4121.0   |  Online |  i-0xxxxxxxxxxxx      |  Linux      |
+---------------+---------+-----------------------+-------------+
```

`Estado: Online` confirma que el SSM Agent se ha registrado correctamente. Puedes
conectarte a cualquier instancia con:

```bash
aws ssm start-session --target "<INSTANCE_ID>"
```

### Calcular el ahorro On-Demand + Spot vs todo On-Demand

> **Nota**: el cálculo siguiente es un **ejemplo ilustrativo** que asume instancias
> On-Demand (`t3.small`) y Spot (`t3a.small`) de tipos distintos para mostrar el rango
> de ahorro típico de una Mixed Instances Policy. No tiene por qué coincidir con los
> tipos exactos que `capacity-optimized` haya elegido en tu despliegue — en el lab
> real todas las instancias pueden ser `t3.small`, con un precio Spot muy similar.
> El objetivo es ilustrar el orden de magnitud del ahorro, no obtener una cifra exacta.

```bash
# Precios aproximados en us-east-1 (April 2026)
OD_PRICE_T3_SMALL=0.0208    # USD/hora On-Demand t3.small
SPOT_PRICE_T3A_SMALL=0.0062 # USD/hora Spot t3a.small (promedio histórico)

echo "=== Proyección mensual (720 horas) con desired=4 ==="
echo ""
echo "Escenario A — Todo On-Demand (sin Mixed Instances Policy):"
echo "  4 instancias x \$0.0208/h x 720h = $(echo "scale=2; 4 * $OD_PRICE_T3_SMALL * 720" | bc) USD"
echo ""
echo "Escenario B — Mixed Instances Policy (2 On-Demand + 2 Spot):"
echo "  2 On-Demand x \$0.0208/h x 720h = $(echo "scale=2; 2 * $OD_PRICE_T3_SMALL * 720" | bc) USD"
echo "  2 Spot      x \$0.0062/h x 720h = $(echo "scale=2; 2 * $SPOT_PRICE_T3A_SMALL * 720" | bc) USD"
TOTAL_MIXED=$(echo "scale=2; (2 * $OD_PRICE_T3_SMALL * 720) + (2 * $SPOT_PRICE_T3A_SMALL * 720)" | bc)
echo "  Total = $TOTAL_MIXED USD"
echo ""
# scale=4 en la division para evitar truncado prematuro antes de multiplicar por 100
AHORRO=$(echo "scale=4; (1 - ($TOTAL_MIXED / (4 * $OD_PRICE_T3_SMALL * 720))) * 100" | bc | xargs printf "%.1f")
echo "Ahorro mensual: $AHORRO%"
```

Salida esperada (aproximada):

```
=== Proyección mensual (720 horas) con desired=4 ===

Escenario A — Todo On-Demand (sin Mixed Instances Policy):
  4 instancias x $0.0208/h x 720h = 59.90 USD

Escenario B — Mixed Instances Policy (2 On-Demand + 2 Spot):
  2 On-Demand x $0.0208/h x 720h = 29.95 USD
  2 Spot      x $0.0062/h x 720h = 8.93 USD
  Total = 38.88 USD

Ahorro mensual: 35.1%
```

Con desired=10 y configuración más agresiva (90% Spot), el ahorro puede llegar al 60-80%.

---

## Verificación final

```bash
echo "=== default_tags en VPC ==="
aws ec2 describe-vpcs \
  --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags[?Key==`Environment` || Key==`Project` || Key==`ManagedBy` || Key==`CostCenter`].[Key,Value]' \
  --output table

echo "=== Nombres generados por el módulo de naming ==="
terraform output -json naming_examples | python3 -m json.tool

echo "=== Presupuesto activo ==="
aws budgets describe-budgets \
  --account-id "$ACCOUNT_ID" \
  --query 'Budgets[?BudgetName==`'"$BUDGET_NAME"'`].{Nombre:BudgetName,Limite:BudgetLimit.Amount,Periodo:TimeUnit}' \
  --output table

echo "=== ASG — instancias activas ==="
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[].{ID:InstanceId,Tipo:InstanceType,AZ:AvailabilityZone,Estado:LifecycleState}' \
  --output table

echo "=== Mix On-Demand vs Spot ==="
SPOT_COUNT=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=${ASG_NAME}" "Name=instance-state-name,Values=running" \
  --query 'length(Reservations[].Instances[?InstanceLifecycle==`spot`])' \
  --output text)
OD_COUNT=$(aws ec2 describe-instances \
  --filters "Name=tag:aws:autoscaling:groupName,Values=${ASG_NAME}" "Name=instance-state-name,Values=running" \
  --query 'length(Reservations[].Instances[?InstanceLifecycle!=`spot`])' \
  --output text)
echo "  On-Demand : $OD_COUNT instancias"
echo "  Spot      : $SPOT_COUNT instancias"
```

---

## Retos

### Reto 1 — Añadir tag de coste por equipo con override de default_tags

El sistema de chargeback de la empresa requiere que los recursos del equipo de
infraestructura tengan la tag `Team = "infra"` y los de aplicación `Team = "backend"`.
Actualmente `default_tags` no incluye la tag `Team`.

**Objetivo**: implementar la tag `Team` de forma que:
- Por defecto todos los recursos tengan `Team = "infra"` (añadirla a `default_tags`)
- El Auto Scaling Group y sus instancias tengan `Team = "backend"` (override local)

1. Añade `Team = var.team` a `default_tags` en `providers.tf`
2. Añade la variable `team` con `default = "infra"` a `variables.tf`
3. En `asg.tf`, añade un bloque `tag` adicional al ASG con `key = "Team"` y
   `value = "backend"` y `propagate_at_launch = true`

Después del apply verifica:
- La VPC tiene `Team = "infra"` (de `default_tags`)
- Las instancias del ASG tienen `Team = "backend"` (override que gana)

```bash
aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags[?Key==`Team`].Value' --output text

INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].Tags[?Key==`Team`].Value' --output text
```

---

### Reto 2 — Política de escalado por CPU con target tracking

El ASG está desplegado pero sin política de escalado: el `desired_capacity` es estático.
En producción el ASG debe crecer cuando la CPU sube y reducirse cuando baja.

**Objetivo**: añadir una política de escalado Target Tracking que mantenga el uso de
CPU en torno al 60% ajustando automáticamente el número de instancias.

1. Crea un `aws_autoscaling_policy` con:
   - `policy_type = "TargetTrackingScaling"`
   - `target_tracking_configuration` con `predefined_metric_type = "ASGAverageCPUUtilization"`
   - `target_value = 60.0` (objetivo de CPU: 60%)
   - `disable_scale_in = false` (permite reducir instancias cuando la CPU baja)

2. Aplica y verifica la política:

```bash
aws autoscaling describe-policies \
  --auto-scaling-group-name "$ASG_NAME" \
  --query 'ScalingPolicies[].{
    Nombre:PolicyName,
    Tipo:PolicyType,
    ObjetivoCPU:TargetTrackingConfiguration.TargetValue
  }' --output table
```

**Pistas:**
- `aws_autoscaling_policy` tiene `autoscaling_group_name` como atributo obligatorio
- Target tracking crea automáticamente alarmas de CloudWatch para el scale-out y scale-in
- Con `disable_scale_in = false`, AWS gestiona las alarmas de reducción automáticamente

---

### Reto 3 — Alerta de presupuesto por etiqueta (tag-based budget)

El presupuesto actual monitoriza el gasto total de la cuenta. En organizaciones con
múltiples proyectos en la misma cuenta, es más útil tener un presupuesto por proyecto.

**Objetivo**: crear un segundo presupuesto `aws_budgets_budget` que filtre el gasto
únicamente de los recursos etiquetados con `Project = "lab48"`.

1. Añade un nuevo recurso `aws_budgets_budget` en `budget.tf` con:
   - `name = "${module.naming["budget"].prefix}-by-tag"`
   - `budget_type = "COST"`, `limit_amount = "10"`, `time_unit = "MONTHLY"`
   - Un bloque `cost_filter` con `name = "TagKeyValue"` y
     `values = ["user:Project$lab48"]` (formato de filtro por tag de Budgets)
   - Una sola notificación: `FORECASTED` al 80% publicando al mismo SNS topic

2. Aplica y verifica que el nuevo presupuesto aparece:

```bash
aws budgets describe-budgets \
  --account-id "$ACCOUNT_ID" \
  --query 'Budgets[].{Nombre:BudgetName,Limite:BudgetLimit.Amount}' \
  --output table
```

**Pistas:**
- El filtro de etiqueta en Budgets usa el formato `"user:<TagKey>$<TagValue>"`
- El bloque `cost_filter` en Terraform es `cost_filter { name = "..." values = [...] }`
- Budgets puede tardar 24 horas en mostrar datos filtrados por etiqueta en cuentas nuevas

---

### Reto 4 — ABAC: control de acceso a instancias basado en etiquetas

Las etiquetas que el ASG propaga a las instancias (`Component=compute`) no solo sirven
para organizar recursos o imputar costes. Con **ABAC (Attribute-Based Access Control)**
puedes usarlas directamente como condición de acceso en políticas IAM, eliminando la
necesidad de hardcodear ARNs o actualizar políticas cada vez que se lanza una nueva
instancia.

**Objetivo**: crear un rol IAM cuya política permita únicamente detener e iniciar
instancias EC2 etiquetadas con `Component=compute`. Cuando el ASG lance una nueva
instancia, el rol tendrá acceso a ella automáticamente — sin modificar la política.

1. Crea el fichero `aws/abac.tf` con un `aws_iam_policy` que incluya permisos
   `ec2:StopInstances` y `ec2:StartInstances` sobre `Resource = "*"` condicionados a:
   ```json
   "Condition": {
     "StringEquals": { "aws:ResourceTag/Component": "compute" }
   }
   ```
   Añade también `ec2:DescribeInstances` sin condición (es necesario para listar
   instancias y no acepta condiciones de tag a nivel de recurso).

2. En el mismo `abac.tf`, crea un `aws_iam_role` con una trust policy que permita
   a la propia cuenta asumir el rol (`sts:AssumeRole`, principal
   `AWS = arn:aws:iam::<account-id>:root`).

3. Adjunta la política al rol con `aws_iam_role_policy_attachment`.

4. Añade un output `abac_role_arn` en `outputs.tf` con el ARN del rol.

**Verificación:**

```bash
# Obtén el ID de una instancia On-Demand ANTES de asumir el rol.
# Las instancias Spot del ASG usan solicitudes "one-time" y no admiten stop.
# Filtramos con JMESPath las que NO tienen InstanceLifecycle=spot.
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:aws:autoscaling:groupName,Values=$ASG_NAME" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[?InstanceLifecycle!=`spot`].InstanceId | [0]' \
  --output text)

# Asume el rol ABAC
CREDS=$(aws sts assume-role \
  --role-arn "$(terraform output -raw abac_role_arn)" \
  --role-session-name "abac-test" \
  --query 'Credentials.{AK:AccessKeyId,SK:SecretAccessKey,ST:SessionToken}' \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['AK'])")
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['SK'])")
export AWS_SESSION_TOKEN=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['ST'])")

# Debe funcionar: instancia On-Demand con Component=compute
aws ec2 stop-instances --instance-ids "$INSTANCE_ID"
# Esperado: StoppingInstances [...]

# Debe fallar: ec2:CreateTags no está en la política ABAC
aws ec2 create-tags --resources "$INSTANCE_ID" --tags Key=Test,Value=abac
# Esperado: An error occurred (UnauthorizedOperation)

unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

**Pistas:**
- El recurso `aws_iam_role` necesita un output `abac_role_arn` en `outputs.tf`
- `ec2:StopInstances` y `ec2:StartInstances` sí respetan `aws:ResourceTag/*` en las
  condiciones; `ec2:DescribeInstances` no (opera a nivel de cuenta, no de recurso)
- La condición usa `aws:ResourceTag/Component`, no `ec2:ResourceTag/Component` — ambas
  funcionan para EC2, pero `aws:` es el prefijo global recomendado por AWS

---

## Reto 5 — Run Command a escala con SSM

Las instancias del ASG tienen el agente SSM activo gracias al rol IAM con la política
`AmazonSSMManagedInstanceCore`. SSM Run Command permite ejecutar comandos en un
conjunto de instancias usando **targets por tag**, sin abrir puertos SSH ni conocer
las IPs.

**Objetivo:** Crear el fichero `ssm.tf` con el código Terraform proporcionado a
continuación, aplicarlo y verificar los resultados. El documento SSM consulta los
metadatos de cada instancia via IMDSv2 para confirmar la mezcla On-Demand/Spot y
la distribución multi-AZ que genera la Mixed Instances Policy.

**Pasos:**

1. Crea el fichero `aws/ssm.tf` con el contenido siguiente.
2. En `main.tf`, añade la clave `ssm_doc` al `for_each` del módulo de naming.
3. En `outputs.tf`, añade los outputs `ssm_document_name` y `ssm_association_id`.
4. Aplica con `terraform apply` y consulta los resultados con los comandos de verificación.

**`aws/ssm.tf`:**

```hcl
resource "aws_ssm_document" "instance_info" {
  name            = module.naming["ssm_doc"].name
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Consulta IMDSv2 y muestra tipo de instancia, AZ y lifecycle (on-demand/spot)."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "collectInstanceInfo"
        inputs = {
          runCommand = [
            "TOKEN=$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')",
            "INSTANCE_ID=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/instance-id)",
            "INSTANCE_TYPE=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/instance-type)",
            "AZ=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/placement/availability-zone)",
            "LIFECYCLE=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/instance-life-cycle)",
            "printf '%-18s %s\\n' 'InstanceId:'   \"$INSTANCE_ID\"",
            "printf '%-18s %s\\n' 'InstanceType:' \"$INSTANCE_TYPE\"",
            "printf '%-18s %s\\n' 'AZ:'           \"$AZ\"",
            "printf '%-18s %s\\n' 'Lifecycle:'    \"$LIFECYCLE\""
          ]
        }
      }
    ]
  })

  tags = {
    Name = module.naming["ssm_doc"].name
  }
}

resource "aws_ssm_association" "instance_info" {
  name             = aws_ssm_document.instance_info.name
  association_name = module.naming["ssm_doc"].name

  targets {
    key    = "tag:Component"
    values = ["compute"]
  }

  # Repite cada hora para alcanzar instancias nuevas del ASG
  schedule_expression = "rate(1 hour)"

  # Ejecuta inmediatamente al crear/actualizar la asociación
  apply_only_at_cron_interval = false
}
```

Añade también en `main.tf` la clave de naming y en `outputs.tf` los dos outputs:

```hcl
# En el for_each del módulo naming (main.tf)
ssm_doc = { component = "compute", resource = "ssmdoc" }
```

```hcl
# outputs.tf
output "ssm_document_name" {
  description = "Nombre del documento SSM para recopilación de metadatos de instancia."
  value       = aws_ssm_document.instance_info.name
}

output "ssm_association_id" {
  description = "ID de la asociación SSM que ejecuta el documento en las instancias compute."
  value       = aws_ssm_association.instance_info.association_id
}
```

**Verificación:**

```bash
terraform apply

# Obtén el CommandId del run lanzado por la asociación
COMMAND_ID=$(aws ssm list-command-invocations \
  --filter key=DocumentName,value="$(terraform output -raw ssm_document_name)" \
  --query 'CommandInvocations[0].CommandId' --output text | head -1)

# Estado de todas las invocaciones
aws ssm list-command-invocations \
  --command-id "$COMMAND_ID" \
  --query 'CommandInvocations[*].{Instance:InstanceId,Status:Status}' \
  --output table

# Salida de cada instancia
# tr convierte los tabuladores de --output text en saltos de línea para que
# el for procese cada ID por separado
aws ssm list-command-invocations \
  --command-id "$COMMAND_ID" \
  --query 'CommandInvocations[*].InstanceId' --output text \
  | tr '\t' '\n' \
  | while read -r INSTANCE_ID; do
  echo "=== $INSTANCE_ID ==="
  aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' --output text
done
```

Salida esperada (`list-command-invocations`):

```
------------------------------------
|      ListCommandInvocations      |
+----------------------+-----------+
|       Instance       |  Status   |
+----------------------+-----------+
|  i-0xxxxxxxxxxxxxxxxx |  Success  |
|  i-0xxxxxxxxxxxxxxxxx |  Success  |
|  i-0xxxxxxxxxxxxxxxxx |  Success  |
|  i-0xxxxxxxxxxxxxxxxx |  Success  |
+----------------------+-----------+
```

**Pistas:**
- IMDSv2 requiere primero un `PUT` a `/latest/api/token`; sin el token las llamadas
  devuelven `401` porque el Launch Template tiene `http_tokens = "required"`
- `instance-life-cycle` devuelve `on-demand` o `spot` — es el campo clave para
  confirmar que la Mixed Instances Policy está distribuyendo correctamente
- `apply_only_at_cron_interval = false` hace que la asociación se ejecute al crear
  o actualizar el recurso, sin esperar al primer tick del schedule

---

## Soluciones

<details>
<summary><strong>Solución al Reto 1 — Tag Team con override de default_tags</strong></summary>

### Solución al Reto 1 — Tag Team con override

**Por qué las tags del recurso ganan sobre default_tags:**

Terraform aplica un merge entre `default_tags` y las tags del recurso. Si la misma
clave aparece en ambos, el valor del recurso tiene precedencia. Este comportamiento
es intencionado para permitir excepciones a la política de etiquetado global.

**Modificación del provider** → [aws/providers.tf](aws/providers.tf):

```hcl
provider "aws" {
  region = var.region
  default_tags {
    tags = {
      Environment = var.environment
      Project     = var.project
      ManagedBy   = "terraform"
      CostCenter  = var.cost_center
      Team        = var.team        # nuevo
    }
  }
}
```

**Nueva variable** → [aws/variables.tf](aws/variables.tf):

```hcl
variable "team" {
  type        = string
  description = "Equipo propietario de los recursos. Se puede sobreescribir por recurso."
  default     = "infra"
}
```

**Override en el ASG** → [aws/asg.tf](aws/asg.tf):

```hcl
resource "aws_autoscaling_group" "main" {
  ...
  # Este tag sobreescribe el Team="infra" de default_tags solo para el ASG y sus instancias
  tag {
    key                 = "Team"
    value               = "backend"
    propagate_at_launch = true
  }
  ...
}
```

Aplica y verifica:

```bash
terraform apply

# VPC: debe tener Team=infra (de default_tags)
aws ec2 describe-vpcs --vpc-ids "$VPC_ID" \
  --query 'Vpcs[0].Tags[?Key==`Team`].Value' --output text
# Esperado: infra
```

> **`propagate_at_launch` solo afecta a instancias nuevas.** Las instancias que ya
> estaban corriendo cuando se ejecutó el `terraform apply` no reciben la tag `Team`
> retroactivamente. Para verificar el override hay que forzar el reemplazo de las
> instancias con un Instance Refresh:

```bash
aws autoscaling start-instance-refresh \
  --auto-scaling-group-name "$ASG_NAME" \
  --preferences '{"MinHealthyPercentage": 50}'

# Espera a que el refresh complete (estado Successful)
aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name "$ASG_NAME" \
  --query 'InstanceRefreshes[0].{Estado:Status,Porcentaje:PercentageComplete}' \
  --output table
```

Una vez completado el refresh, todas las instancias son nuevas y tienen la tag propagada:

```bash
INSTANCE_ID=$(aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$ASG_NAME" \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' --output text)
aws ec2 describe-instances --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].Tags[?Key==`Team`].Value' --output text
# Esperado: backend
```

El override funciona porque `aws_autoscaling_group` gestiona las tags de la instancia
a través del bloque `tag { propagate_at_launch = true }`, que toma precedencia sobre
las `default_tags` del provider en el contexto de las instancias lanzadas por el ASG.

</details>

---

<details>
<summary><strong>Solución al Reto 2 — Política Target Tracking por CPU</strong></summary>

### Solución al Reto 2 — Política de escalado Target Tracking

**Cómo funciona Target Tracking:**

Target Tracking es la política de escalado más simple de configurar. En lugar de
definir alarmas manualmente, le dices al ASG qué métrica quieres mantener en qué
valor, y AWS crea automáticamente las alarmas de CloudWatch necesarias:

- Alarma de scale-out: cuando la CPU > 60%, añade instancias
- Alarma de scale-in: cuando la CPU < 60% durante suficiente tiempo, elimina instancias

AWS aplica un período de enfriamiento por defecto para evitar oscilaciones (scaling flapping).

**Nueva política** → [aws/asg.tf](aws/asg.tf):

```hcl
resource "aws_autoscaling_policy" "cpu_tracking" {
  name                   = "${module.naming["asg"].prefix}-cpu-tracking"
  autoscaling_group_name = aws_autoscaling_group.main.name
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value     = 60.0
    disable_scale_in = false
  }
}
```

Aplica y verifica:

```bash
terraform apply

aws autoscaling describe-policies \
  --auto-scaling-group-name "$ASG_NAME" \
  --query 'ScalingPolicies[].{
    Nombre:PolicyName,
    Tipo:PolicyType,
    ObjetivoCPU:TargetTrackingConfiguration.TargetValue,
    ScaleIn:TargetTrackingConfiguration.DisableScaleIn
  }' --output table
```

Salida esperada:

```
---------------------------------------------------------------------------------------
|                                  DescribePolicies                                   |
+---------------------------------+--------------+----------+-------------------------+
|             Nombre              | ObjetivoCPU  | ScaleIn  |          Tipo           |
+---------------------------------+--------------+----------+-------------------------+
|  myapp-prd-compute-cpu-tracking |  60.0        |  False   |  TargetTrackingScaling  |
+---------------------------------+--------------+----------+-------------------------+
```

Puedes ver las alarmas creadas automáticamente por Target Tracking:

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "TargetTracking-${ASG_NAME}" \
  --query 'MetricAlarms[].{Nombre:AlarmName,Estado:StateValue,Umbral:Threshold}' \
  --output table
```

Salida esperada (similar):

```
------------------------------------------------------------------------------------------------------------------------
|                                                    DescribeAlarms                                                    |
+-------------------+---------------------------------------------------------------------------------------+----------+
|      Estado       |                                        Nombre                                         | Umbral   |
+-------------------+---------------------------------------------------------------------------------------+----------+
|  INSUFFICIENT_DATA|  TargetTracking-myapp-prd-compute-asg-AlarmHigh-<uuid>                                |  60.0    |
|  ALARM            |  TargetTracking-myapp-prd-compute-asg-AlarmLow-<uuid>                                 |  42.0    |
+-------------------+---------------------------------------------------------------------------------------+----------+
```

AWS crea dos alarmas: `AlarmHigh` dispara el scale-out cuando la CPU supera el 60%
(el objetivo), y `AlarmLow` dispara el scale-in cuando baja del 42% (el 70% del objetivo,
margen que Target Tracking calcula automáticamente). El estado `ALARM` en `AlarmLow`
indica que la CPU está por debajo del umbral de reducción — esperado en instancias sin
carga real. Estas alarmas no deben modificarse manualmente: el ASG las gestiona y elimina
automáticamente.

El scale-in es tan importante para FinOps como el scale-out: reducir el número de
instancias cuando la demanda baja elimina el coste de capacidad ociosa. Combinado con
la Mixed Instances Policy, el ASG no solo elige los tipos más baratos disponibles en
cada momento, sino que también ajusta la cantidad de instancias al mínimo necesario,
maximizando el ahorro sin intervención manual.

</details>

---

<details>
<summary><strong>Solución al Reto 3 — Presupuesto filtrado por etiqueta</strong></summary>

### Solución al Reto 3 — Budget por tag Project

**Cómo funciona el filtro por etiqueta en Budgets:**

AWS Budgets soporta filtrar el gasto por etiquetas de recursos. El formato del valor
del filtro es `"user:<TagKey>$<TagValue>"`. La palabra `user:` indica que es una tag
definida por el usuario (no una tag reservada de AWS como `aws:createdBy`).

**Importante**: para que el filtro por etiqueta funcione, debes activar la función
"User-defined cost allocation tags" en el panel de Billing & Cost Management de AWS.
Sin esta activación, las tags no se incluyen en los datos de Cost Explorer y Budgets
no puede filtrar por ellas.

**Activar el seguimiento de tags** (solo la primera vez, manual en consola):

> AWS Console → Billing & Cost Management → Cost allocation tags →
> pestaña "User-defined" → busca `Project` → marca la casilla → "Activate"

Puede tardar hasta 24 horas en que las tags históricas aparezcan en los datos de coste.

**Nuevo presupuesto** → [aws/budget.tf](aws/budget.tf):

```hcl
resource "aws_budgets_budget" "by_tag" {
  name         = "${module.naming["budget"].prefix}-by-tag"
  budget_type  = "COST"
  limit_amount = "10"
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Filtra solo el gasto de recursos etiquetados con Project=lab48
  cost_filter {
    name   = "TagKeyValue"
    values = ["user:Project$lab48"]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_sns_topic_arns  = [aws_sns_topic.budget_alerts.arn]
  }
}
```

Aplica y verifica:

```bash
terraform apply

aws budgets describe-budgets \
  --account-id "$ACCOUNT_ID" \
  --query 'Budgets[?starts_with(BudgetName, `myapp`)].{
    Nombre:BudgetName,
    Limite:BudgetLimit.Amount,
    Filtros:CostFilters
  }' \
  --output json | python3 -m json.tool
```

Salida esperada (similar):

```json
[
    {
        "Nombre": "myapp-prd-finops-budget",
        "Limite": "20.0",
        "Filtros": null
    },
    {
        "Nombre": "myapp-prd-finops-by-tag",
        "Limite": "10.0",
        "Filtros": {
            "TagKeyValue": [
                "user:Project$lab48"
            ]
        }
    }
]
```

El primer presupuesto monitoriza el gasto total de la cuenta. El segundo solo el gasto
de los recursos etiquetados con `Project=lab48`. Si en la misma cuenta hay otros
proyectos, el presupuesto by-tag permite controlar el gasto de cada proyecto de forma
independiente sin necesidad de cuentas AWS separadas.

</details>

---

<details>
<summary><strong>Solución al Reto 4 — ABAC: control de acceso por etiqueta</strong></summary>

### Solución al Reto 4 — ABAC

**Por qué ABAC escala mejor que las políticas basadas en ARNs:**

Con una política tradicional basada en recursos, tendrías que listar el ARN de cada
instancia que el operador puede gestionar:

```json
"Resource": [
  "arn:aws:ec2:us-east-1:123456789012:instance/i-0359edd6d872281fd",
  "arn:aws:ec2:us-east-1:123456789012:instance/i-0a3b3c19c5fffd938",
  ...
]
```

Cada vez que el ASG lanza una instancia nueva, alguien tendría que actualizar la
política. Con ABAC, la condición `aws:ResourceTag/Component = "compute"` actúa como
un selector dinámico: cualquier instancia que tenga esa etiqueta queda automáticamente
dentro del alcance del rol, sin tocar IAM.

**Nueva política ABAC** → [aws/abac.tf](aws/abac.tf):

```hcl
resource "aws_iam_policy" "abac_compute" {
  name        = "${module.naming["asg"].prefix}-abac-compute"
  description = "Permite detener e iniciar instancias EC2 etiquetadas con Component=compute."

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "ManageComputeInstances"
        Effect   = "Allow"
        Action   = ["ec2:StopInstances", "ec2:StartInstances"]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/Component" = "compute"
          }
        }
      },
      {
        # DescribeInstances no soporta condiciones de tag a nivel de recurso:
        # opera sobre toda la cuenta y devuelve resultados filtrados por la CLI.
        Sid      = "DescribeInstances"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances"]
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role" "abac_operator" {
  name = "${module.naming["asg"].prefix}-abac-operator"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect    = "Allow"
        Principal = { AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root" }
        Action    = "sts:AssumeRole"
      }
    ]
  })

  tags = { Name = "${module.naming["asg"].prefix}-abac-operator" }
}

resource "aws_iam_role_policy_attachment" "abac_compute" {
  role       = aws_iam_role.abac_operator.name
  policy_arn = aws_iam_policy.abac_compute.arn
}
```

**Output** → [aws/outputs.tf](aws/outputs.tf):

```hcl
output "abac_role_arn" {
  description = "ARN del rol IAM ABAC para gestión de instancias compute."
  value       = aws_iam_role.abac_operator.arn
}
```

Aplica y verifica:

```bash
terraform apply

# Obtén el ID de una instancia On-Demand ANTES de asumir el rol.
# Las instancias Spot del ASG usan solicitudes "one-time" y no admiten stop.
# Filtramos con JMESPath las que NO tienen InstanceLifecycle=spot.
INSTANCE_ID=$(aws ec2 describe-instances \
  --filters \
    "Name=tag:aws:autoscaling:groupName,Values=$ASG_NAME" \
    "Name=instance-state-name,Values=running" \
  --query 'Reservations[].Instances[?InstanceLifecycle!=`spot`].InstanceId | [0]' \
  --output text)

# Asume el rol ABAC
CREDS=$(aws sts assume-role \
  --role-arn "$(terraform output -raw abac_role_arn)" \
  --role-session-name "abac-test" \
  --query 'Credentials.{AK:AccessKeyId,SK:SecretAccessKey,ST:SessionToken}' \
  --output json)

export AWS_ACCESS_KEY_ID=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['AK'])")
export AWS_SECRET_ACCESS_KEY=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['SK'])")
export AWS_SESSION_TOKEN=$(echo $CREDS | python3 -c "import sys,json; print(json.load(sys.stdin)['ST'])")

# Prueba 1 — debe funcionar: instancia On-Demand con Component=compute
aws ec2 stop-instances --instance-ids "$INSTANCE_ID"
```

Salida esperada (éxito):

```json
{
    "StoppingInstances": [
        {
            "InstanceId": "i-0xxxxxxxxxxxxxxxxx",
            "CurrentState": {
                "Code": 64,
                "Name": "stopping"
            },
            "PreviousState": {
                "Code": 16,
                "Name": "running"
            }
        }
    ]
}
```

```bash
# Restaura la instancia
aws ec2 start-instances --instance-ids "$INSTANCE_ID"

# Prueba 2 — debe fallar: ec2:CreateTags no está en la política ABAC
aws ec2 create-tags --resources "$INSTANCE_ID" --tags Key=Test,Value=abac
```

Salida esperada (denegado):

```
An error occurred (UnauthorizedOperation) when calling the CreateTags operation:
You are not authorized to perform this operation. User: arn:aws:sts::<account-id>:assumed-role/myapp-prd-compute-abac-operator/abac-test
is not authorized to perform: ec2:CreateTags on resource: arn:aws:ec2:us-east-1:<account-id>:instance/<instance-id>
because no identity-based policy allows the ec2:CreateTags action.
```

```bash
# Limpia las credenciales temporales
unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
```

La política no necesita saber qué instancias existen. Cuando el ASG escale y lance
nuevas instancias, estas heredarán `Component=compute` vía `propagate_at_launch` y
el rol ABAC tendrá acceso a ellas inmediatamente, sin ninguna actualización de IAM.

</details>

---

<details>
<summary><strong>Solución al Reto 5 — Run Command a escala con SSM</strong></summary>

### Solución al Reto 5 — Run Command a escala con SSM

**Cómo funciona `aws_ssm_association`:**

`aws_ssm_association` vincula un documento SSM a un conjunto de targets y ejecuta
el documento inmediatamente al crear la asociación (`apply_only_at_cron_interval = false`).
El `schedule_expression` repite la ejecución periódicamente, lo que garantiza que
las instancias nuevas lanzadas por el ASG (scale-out, reemplazo de Spot interrumpida)
también ejecuten el documento sin intervención manual.

**Terraform** → [aws/ssm.tf](aws/ssm.tf):

```hcl
resource "aws_ssm_document" "instance_info" {
  name            = module.naming["ssm_doc"].name
  document_type   = "Command"
  document_format = "JSON"

  content = jsonencode({
    schemaVersion = "2.2"
    description   = "Consulta IMDSv2 y muestra tipo de instancia, AZ y lifecycle."
    mainSteps = [
      {
        action = "aws:runShellScript"
        name   = "collectInstanceInfo"
        inputs = {
          runCommand = [
            "TOKEN=$(curl -s -X PUT 'http://169.254.169.254/latest/api/token' -H 'X-aws-ec2-metadata-token-ttl-seconds: 21600')",
            "INSTANCE_ID=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/instance-id)",
            "INSTANCE_TYPE=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/instance-type)",
            "AZ=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/placement/availability-zone)",
            "LIFECYCLE=$(curl -s -H \"X-aws-ec2-metadata-token: $TOKEN\" http://169.254.169.254/latest/meta-data/instance-life-cycle)",
            "printf '%-18s %s\\n' 'InstanceId:'    \"$INSTANCE_ID\"",
            "printf '%-18s %s\\n' 'InstanceType:'  \"$INSTANCE_TYPE\"",
            "printf '%-18s %s\\n' 'AZ:'            \"$AZ\"",
            "printf '%-18s %s\\n' 'Lifecycle:'     \"$LIFECYCLE\""
          ]
        }
      }
    ]
  })

  tags = {
    Name = module.naming["ssm_doc"].name
  }
}

resource "aws_ssm_association" "instance_info" {
  name             = aws_ssm_document.instance_info.name
  association_name = module.naming["ssm_doc"].name

  targets {
    key    = "tag:Component"
    values = ["compute"]
  }

  schedule_expression         = "rate(1 hour)"
  apply_only_at_cron_interval = false
}
```

Añade en `main.tf` la clave al módulo de naming:

```hcl
ssm_doc = { component = "compute", resource = "ssmdoc" }
```

Añade en `outputs.tf`:

```hcl
output "ssm_document_name" {
  description = "Nombre del documento SSM para recopilación de metadatos de instancia."
  value       = aws_ssm_document.instance_info.name
}

output "ssm_association_id" {
  description = "ID de la asociación SSM que ejecuta el documento en las instancias compute."
  value       = aws_ssm_association.instance_info.association_id
}
```

**Consulta los resultados tras el apply:**

```bash
terraform apply

COMMAND_ID=$(aws ssm list-command-invocations \
  --filter key=DocumentName,value="$(terraform output -raw ssm_document_name)" \
  --query 'CommandInvocations[0].CommandId' --output text | head -1)

aws ssm list-command-invocations \
  --command-id "$COMMAND_ID" \
  --query 'CommandInvocations[*].{Instance:InstanceId,Status:Status}' \
  --output table

for INSTANCE_ID in $(aws ssm list-command-invocations \
  --command-id "$COMMAND_ID" \
  --query 'CommandInvocations[*].InstanceId' --output text); do
  echo "=== $INSTANCE_ID ==="
  aws ssm get-command-invocation \
    --command-id "$COMMAND_ID" \
    --instance-id "$INSTANCE_ID" \
    --query 'StandardOutputContent' --output text
done
```

Salida esperada (`list-command-invocations`):

```
------------------------------------
|      ListCommandInvocations      |
+----------------------+-----------+
|       Instance       |  Status   |
+----------------------+-----------+
|  i-0xxxxxxxxxxxxxxxxx |  Success  |
|  i-0xxxxxxxxxxxxxxxxx |  Success  |
|  i-0xxxxxxxxxxxxxxxxx |  Success  |
|  i-0xxxxxxxxxxxxxxxxx |  Success  |
+----------------------+-----------+
```

Salida esperada (`get-command-invocation` por instancia):

```
=== i-0xxxxxxxxxxxxxxxxx ===
InstanceId:        i-0xxxxxxxxxxxxxxxxx
InstanceType:      t3.small
AZ:                us-east-1a
Lifecycle:         spot

=== i-0xxxxxxxxxxxxxxxxx ===
InstanceId:        i-0xxxxxxxxxxxxxxxxx
InstanceType:      t3.small
AZ:                us-east-1b
Lifecycle:         on-demand

=== i-0xxxxxxxxxxxxxxxxx ===
InstanceId:        i-0xxxxxxxxxxxxxxxxx
InstanceType:      t3.small
AZ:                us-east-1b
Lifecycle:         spot

=== i-0xxxxxxxxxxxxxxxxx ===
InstanceId:        i-0xxxxxxxxxxxxxxxxx
InstanceType:      t3.small
AZ:                us-east-1a
Lifecycle:         on-demand
```

La salida confirma los comportamientos clave del laboratorio:
- **Lifecycle mix:** 2 instancias `on-demand` y 2 `spot` conviviendo en el mismo ASG
- **Multi-AZ:** instancias distribuidas entre `us-east-1a` y `us-east-1b`
- **Tipo uniforme:** en esta ejecución `capacity-optimized` eligió `t3.small` para todos
  los slots disponibles — AWS elige el tipo con mayor capacidad sobrante, y ese día
  `t3.small` era el pool más holgado en ambas AZs

**Por qué `aws_ssm_association` es mejor que `send-command` ad-hoc:**

`send-command` resuelve los targets en el momento del envío. Si el ASG hace scale-out
después, las nuevas instancias no reciben el comando. Con `aws_ssm_association` y
`schedule_expression`, cada nueva instancia que se registre en SSM con
`Component=compute` recibirá el documento automáticamente en el siguiente tick
del schedule, sin ninguna intervención manual.

</details>

---

## Limpieza

```bash
cd labs/lab48/aws

terraform destroy
```

> `terraform destroy` elimina todos los recursos. El Auto Scaling Group termina las
> instancias EC2 antes de eliminarse. El presupuesto de AWS Budgets se elimina
> inmediatamente y las notificaciones dejan de funcionar. El topic SNS se elimina con
> todas sus suscripciones.

---

## Solución de problemas

### El ASG no lanza instancias Spot (todas son On-Demand)

**Causa**: en regiones o tipos de instancia con poca disponibilidad Spot, el ASG puede
recurrir a On-Demand para cumplir la capacidad deseada incluso si la política indica Spot.

**Diagnóstico**:

```bash
# Busca eventos de escalado del ASG para ver errores de capacidad Spot
aws autoscaling describe-scaling-activities \
  --auto-scaling-group-name "$ASG_NAME" \
  --max-items 10 \
  --query 'Activities[].{
    Descripcion:Description,
    Estado:StatusCode,
    Causa:Cause
  }' \
  --output table
```

Si aparece `InsufficientInstanceCapacity` para los tipos Spot, añade más tipos al pool:

```hcl
override { instance_type = "t2.small"  }
override { instance_type = "t2.medium" }
```

**Solución alternativa**: cambia la estrategia a `price-capacity-optimized` que balancea
precio y disponibilidad de forma más agresiva que `capacity-optimized`.

### Las alertas de Budgets no llegan al email

**Causa 1**: la suscripción SNS está en estado `PendingConfirmation`.

```bash
aws sns list-subscriptions-by-topic --topic-arn "$SNS_ARN" \
  --query 'Subscriptions[].{Protocolo:Protocol,Endpoint:Endpoint,Estado:SubscriptionArn}' \
  --output table
```

Si `Estado` muestra el ARN, la suscripción está confirmada. Si muestra
`PendingConfirmation`, busca el email de confirmación de AWS SNS y confírmalo.

**Causa 2**: la política del topic SNS no permite que Budgets publique.

```bash
# Verifica que la política existe y tiene el Statement correcto
aws sns get-topic-attributes --topic-arn "$SNS_ARN" \
  --query 'Attributes.Policy' --output text
```

Si el resultado es una política vacía o sin el `AllowBudgetsToPublish` Statement,
ejecuta `terraform apply` para restaurar la política.

**Causa 3**: en cuentas nuevas, Budgets puede tardar 24-48 horas en tener suficientes
datos históricos para generar predicciones `FORECASTED`. Las alertas `ACTUAL` funcionan
desde el primer día.

### El módulo de naming devuelve un error de validación

**Causa**: uno de los inputs (`app`, `env`, `component`, `resource`) contiene caracteres
no permitidos por las validaciones del módulo (mayúsculas, guiones, caracteres especiales).

```
Error: Invalid value for variable
  on modules/naming/variables.tf line X:
  The value must match: "^[a-z0-9]+$"
```

**Solución**: usa solo letras minúsculas y números. Para separar palabras compuestas,
omite el separador en el valor de `component` o `resource` (ej: `"snpuba"` en lugar
de `"sn-pub-a"`). El guión ya está en el patrón del nombre generado por el módulo.

### Las instancias no aparecen en SSM Session Manager

**Causa 1**: las instancias aún no han completado el arranque. El SSM Agent necesita
2-5 minutos para registrarse en el servicio SSM.

**Causa 2**: las instancias no tienen acceso a internet para llegar al endpoint de SSM.
Verifica que las subredes tienen una route table con una ruta `0.0.0.0/0` hacia el IGW.

```bash
aws ec2 describe-route-tables \
  --filters "Name=vpc-id,Values=${VPC_ID}" \
  --query 'RouteTables[].Routes[?DestinationCidrBlock==`0.0.0.0/0`].{Destino:GatewayId,CIDR:DestinationCidrBlock}' \
  --output table
```

**Causa 3**: el rol IAM no tiene la política `AmazonSSMManagedInstanceCore`. Verifica:

```bash
aws iam list-attached-role-policies \
  --role-name "$(terraform output -json naming_examples | python3 -c "import sys,json; print(json.load(sys.stdin))")" \
  --query 'AttachedPolicies[].PolicyName' --output table
```
