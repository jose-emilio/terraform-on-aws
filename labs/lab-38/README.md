# Laboratorio 38 — Ingeniería de Datos y Resiliencia con Lifecycle

[← Módulo 9 — Terraform Avanzado](../../modulos/modulo-09/README.md)


## Visión general

Las configuraciones de red reales no son listas planas de recursos: son
estructuras jerarquicas (entornos → VPCs → subredes) con etiquetas que
combinan políticas corporativas y especificaciones de departamento. Gestionar
esta complejidad con `count` o con múltiples bloques `resource` duplicados
produce codigo fragil y dificil de mantener.

Este laboratorio introduce siete herramientas de Terraform que, combinadas,
permiten gestionar esa complejidad de forma declarativa y robusta:

1. **Flatten Pattern**: transforma un mapa anidado (VPCs con subredes) en
   una lista plana apta para `for_each`, eliminando la necesidad de bloques
   resource duplicados por VPC.

2. **`merge()`**: fusiona etiquetas corporativas globales con etiquetas
   especificas de departamento en cada recurso, sin repetir codigo.

3. **`optional()`**: permite definir variables con atributos opcionales y
   valores por defecto, haciendo las configuraciones flexibles sin sacrificar
   el tipado estricto.

4. **`precondition` / `postcondition`**: validan invariantes en tiempo de
   ejecución — la precondición aborta el plan si la AZ elegida no está
   autorizada; la postcondición verifica que la instancia tiene IP pública
   tras el apply.

5. **`try()` / `can()`**: acceso seguro a valores que pueden ser nulos o
   estructuras que pueden no existir, sin abortar el plan con errores de
   tipo o atributo nulo.

6. **`check {}`**: healthcheck post-apply que verifica que las subredes
   publicas tienen ruta a Internet, emitiendo advertencia sin bloquear
   el despliegue.

7. **`lifecycle { ignore_changes }`**: protege las tags de VPCs y subredes
   frente a modificaciones automaticas de AWS Organizations, EKS y otras
   herramientas de gobernanza.

## Objetivos

- Implementar el Flatten Pattern con `flatten()` y expresiones `for` anidadas
  para transformar `map(map(object))` en `map(object)` apto para `for_each`.
- Usar `merge()` para combinar etiquetas corporativas y de departamento sin
  duplicar codigo.
- Definir una variable con atributos `optional()` con valores por defecto.
- Escribir una `precondition` que valide la zona de disponibilidad antes del
  plan y produzca un mensaje de error descriptivo.
- Escribir una `postcondition` que verifique la asignacion de IP publica
  tras el apply usando `self`.
- Usar `try()` para acceso defensivo a valores opcionales y `can()` para
  centralizar logica condicional en locals.
- Implementar un bloque `check {}` con data source interno para verificar
  la conectividad de red post-apply.
- Configurar `lifecycle { ignore_changes }` para proteger tags gestionadas
  por herramientas externas a Terraform.
- Entender cuando usar cada mecanismo de validación y por qué son complementarios.

## Requisitos previos

- Terraform >= 1.5 instalado.
- AWS CLI configurado con perfil `default`.
- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado
  habilitado.

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
```

## Arquitectura

```
var.vpc_config (mapa anidado)
┌─────────────────────────────────────────────────────┐
│  "networking"                                       │
│    cidr: 10.39.0.0/16                               │
│    subnets:                                         │
│      "public-a"   10.39.1.0/24  us-east-1a  public  │
│      "public-b"   10.39.2.0/24  us-east-1b  public  │
│      "private-a"  10.39.10.0/24 us-east-1a  private │
│  "data"                                             │
│    cidr: 10.40.0.0/16                               │
│    subnets:                                         │
│      "db-a"       10.40.1.0/24  us-east-1a  private │
│      "db-b"       10.40.2.0/24  us-east-1b  private │
└─────────────────────────────────────────────────────┘
          │
          │  Flatten Pattern (locals.tf)
          ▼
local.subnets_map (mapa plano — 5 entradas)
┌─────────────────────────────────────────────────────┐
│  "networking/public-a"  → { cidr, az, public, ... } │
│  "networking/public-b"  → { cidr, az, public, ... } │
│  "networking/private-a" → { cidr, az, public, ... } │
│  "data/db-a"            → { cidr, az, public, ... } │
│  "data/db-b"            → { cidr, az, public, ... } │
└─────────────────────────────────────────────────────┘
          │
          │  for_each + merge() de etiquetas
          ▼
┌─────────────────────────────────────────────────────┐
│  aws_vpc.this["networking"]                         │
│  aws_vpc.this["data"]                               │
│                                                     │
│  aws_subnet.this["networking/public-a"]  ───────────┤
│  aws_subnet.this["networking/public-b"]             │◄── merge():
│  aws_subnet.this["networking/private-a"]            │    tags corporativas
│  aws_subnet.this["data/db-a"]                       │    + tags departamento
│  aws_subnet.this["data/db-b"]            ───────────┤
│                                                     │
│  aws_internet_gateway.this["networking"]            │
└─────────────────────────────────────────────────────┘

Instancia de monitoreo (cuando monitoring_config.enabled = true):
┌────────────────────────────────────────────────────────────────┐
│  aws_instance.monitoring[0]                                    │
│    subnet: networking/public-a                                 │
│                                                                │
│  lifecycle {                                                   │
│    precondition  → AZ en allowed_azs?  (falla en PLAN)         │
│    postcondition → public_ip asignada? (falla en APPLY)        │
│  }                                                             │
│                                                                │
│  opcional (si alarm_email != null):                            │
│    aws_sns_topic + aws_sns_topic_subscription + cw_alarm       │
└────────────────────────────────────────────────────────────────┘
```

## Conceptos clave

### Flatten Pattern

El problema de iterar sobre estructuras anidadas:

```hcl
variable "vpc_config" {
  type = map(object({
    cidr_block = string
    subnets    = map(object({ ... }))  # mapa dentro de mapa
  }))
}

# INCORRECTO: for_each sobre el mapa externo crea VPCs, no subredes
resource "aws_subnet" "this" {
  for_each = var.vpc_config   # ← itera sobre VPCs, no sobre subredes
}
```

La solución es aplanar la estructura antes de iterar:

```hcl
locals {
  # Paso 1: flatten de lista de listas → lista plana
  subnets_flat = flatten([
    for vpc_key, vpc in var.vpc_config : [      # for externo: VPCs
      for subnet_key, subnet in vpc.subnets : { # for interno: subredes
        key      = "${vpc_key}/${subnet_key}"   # clave compuesta unica
        vpc_key  = vpc_key
        cidr     = subnet.cidr_block
        # ... resto de atributos
      }
    ]
  ])

  # Paso 2: lista → mapa (for_each requiere mapa, no lista)
  subnets_map = {
    for s in local.subnets_flat : s.key => s
  }
}

# CORRECTO: for_each sobre el mapa plano crea una subred por entrada
resource "aws_subnet" "this" {
  for_each = local.subnets_map
  cidr_block = each.value.cidr
  vpc_id     = aws_vpc.this[each.value.vpc_key].id
}
```

**Por que clave compuesta**: usar `"vpc_key/subnet_key"` como clave garantiza
unicidad global (dos VPCs pueden tener una subred llamada `"public-a"`) y
produce direcciones de estado semanticas y estables:
`aws_subnet.this["networking/public-a"]`.

### `merge()` para etiquetas por capas

```hcl
tags = merge(
  # Capa 1 — etiquetas de departamento (menor prioridad)
  {
    Department  = subnet.department_tags.department
    BillingCode = subnet.department_tags.billing_code
  },
  # Capa 2 — etiquetas de identificacion (mayor prioridad)
  # Si BillingCode aparece en ambas capas, gana la ultima
  {
    Name = "${var.project}-${each.key}"
  }
)
```

`merge()` acepta cualquier numero de mapas y da **prioridad al ultimo
argumento** en caso de colision de claves. Las etiquetas corporativas
(ManagedBy, Project, Environment) llegan automáticamente a todos los
recursos via `default_tags` del provider, sin necesidad de incluirlas
en cada `merge()`.

### `optional()` en tipos de objeto

Sin `optional()`, todos los atributos de un `object` son obligatorios:

```hcl
# SIN optional(): el operador debe especificar todos los campos
variable "monitoring_config" {
  type = object({
    enabled       = bool
    instance_type = string   # obligatorio — error si se omite
    alarm_email   = string   # obligatorio — error si se omite
  })
}

# CON optional(): solo 'enabled' es obligatorio
variable "monitoring_config" {
  type = object({
    enabled       = bool
    instance_type = optional(string, "t4g.micro")  # default si se omite
    alarm_email   = optional(string, null)          # null si se omite
  })
}

# Ahora el operador puede especificar solo lo que necesita:
monitoring_config = {
  enabled = true
  # instance_type usa "t4g.micro" por defecto
  # alarm_email es null — no se creara alarma
}
```

### `precondition`: validación antes del plan

```hcl
resource "aws_instance" "monitoring" {
  lifecycle {
    precondition {
      condition     = contains(var.allowed_azs, var.chosen_az)
      error_message = "La AZ '${var.chosen_az}' no esta autorizada."
    }
  }
}
```

- Se evalua durante `terraform plan`, antes de crear el recurso.
- Si falla, **el plan se aborta** con el mensaje de error definido.
- No tiene acceso a `self` — el recurso aun no existe.
- Util para validar configuraciones que si fueran incorrectas causarian
  un error críptico de AWS o un recurso mal configurado.

### `postcondition`: verificacion despues del apply

```hcl
resource "aws_instance" "monitoring" {
  lifecycle {
    postcondition {
      condition     = self.public_ip != null && self.public_ip != ""
      error_message = "La instancia ${self.id} no tiene IP publica."
    }
  }
}
```

- Se evalua durante `terraform apply`, despues de crear o actualizar el recurso.
- Si falla, **el apply se aborta** y el recurso queda marcado como tainted.
- Tiene acceso completo a `self` — todos los atributos del recurso creado.
- Útil para verificar invariantes que AWS debería garantizar pero que quieres
  comprobar explicitamente (IP asignada, ARN no vacio, estado `available`...).

### Diferencia entre `precondition`, `postcondition` y `variable validation`

| Mecanismo | Cuando se evalua | Acceso a `self` | Si falla |
|---|---|---|---|
| `variable validation` | Al parsear la variable | No | Error antes del plan |
| `precondition` | Durante `plan` | No | Plan abortado |
| `postcondition` | Durante `apply` | Si | Apply abortado, recurso tainted |
| `check {}` | Al final del apply | No (usa data source) | Advertencia, no aborta |

### `try()` y `can()` — acceso defensivo a valores opcionales

Cuando navegas estructuras anidadas con valores opcionales, un atributo `null`
o un indice inexistente produce un error que aborta el plan. `try()` y `can()`
permiten manejar esos casos sin codigo defensivo verboso:

```hcl
# SIN try(): si alarm_email es null, esto falla con "attempt to call null"
count = var.monitoring_config.alarm_email != null ? 1 : 0

# CON try(): si la expresion falla por cualquier razon, devuelve el fallback
alarm_email = try(var.monitoring_config.alarm_email, null)

# can(): devuelve true/false si la expresion es evaluable sin error
# Util para centralizar logica condicional en locals
monitoring_alarm_enabled = (
  var.monitoring_config.enabled &&
  can(var.monitoring_config.alarm_email) &&
  var.monitoring_config.alarm_email != null
)
```

**¿Cuándo usar cada uno?**:

| Función | Devuelve | Caso de uso típico |
|---|---|---|
| `try(expr, fallback)` | El valor o el fallback | Acceso a atributos opcionales o potencialmente nulos |
| `can(expr)` | `true` / `false` | Condiciones en `count`, `for_each` o `if` dentro de `for` |

> **Advertencia**: `try()` silencia **cualquier** error, no solo los de tipo
> nulo. Usarlo con expresiones complejas puede ocultar errores reales de logica.
> Prefiere `try()` en expresiones simples de acceso a atributos.

### `check {}` — healthcheck post-apply no bloqueante

A diferencia de `postcondition` (que falla el apply si la condición no se
cumple), `check {}` emite una advertencia y deja que el apply termine.
Es el mecanismo correcto para verificar invariantes que no debes considerar
errores fatales pero si quieres monitorizar:

```hcl
check "public_subnet_has_internet_route" {
  # Data source interno — se evalua al final del apply
  data "aws_route_table" "check" {
    subnet_id = aws_subnet.this["networking/public-a"].id
  }

  assert {
    condition = anytrue([
      for route in data.aws_route_table.check.routes :
      route.cidr_block == "0.0.0.0/0" && route.gateway_id != null
    ])
    error_message = "La subred publica no tiene ruta a Internet."
  }
}
```

Cuando el assert falla, el apply produce:

```
╷
│ Warning: Check block assertion failed
│
│   check.public_subnet_has_internet_route
│
│ La subred publica no tiene ruta a Internet.
╵
```

### `lifecycle { ignore_changes }` — protección frente a drift externo

Las herramientas de gobernanza de AWS (Organizations, Security Hub, EKS,
CloudFormation StackSets) añaden tags automáticamente a los recursos. Sin
`ignore_changes`, Terraform las detecta como drift en el siguiente plan y
las elimina, rompiendo las políticas corporativas:

```hcl
resource "aws_subnet" "this" {
  # ...
  lifecycle {
    # Ignorar tags individuales sin ignorar el bloque tags completo.
    # Si ignoras tags["*"] o todo el bloque tags, Terraform dejaria de
    # detectar cambios legitimos en las tags que tu gestionas.
    ignore_changes = [
      tags["CreatedBy"],                          # anadida por AWS Organizations
      tags["aws:cloudformation:stack-name"],       # anadida por CloudFormation
      tags["kubernetes.io/role/elb"],              # anadida por EKS
    ]
  }
}
```

**Regla practica**: ignora solo las tags cuya clave conoces y que sabes que
son gestionadas externamente. No uses `ignore_changes = [tags]` (bloque
completo) porque ocultaria cualquier cambio en las tags que si gestionas.

## Estructura del proyecto

```
lab38/
├── aws/
│   ├── providers.tf        # Terraform >= 1.5 + default_tags corporativas
│   ├── variables.tf        # vpc_config (mapa anidado), monitoring_config (optional)
│   ├── locals.tf           # Flatten Pattern + merge() + try() + can()
│   ├── main.tf             # VPCs, subredes, route tables, instancia, check {}
│   ├── outputs.tf          # IDs, claves del flatten, tags fusionadas, billing codes
│   └── aws.s3.tfbackend    # Backend S3
└── README.md
```

---

## Despliegue en AWS real

### Paso 1 — Inicializar y desplegar

```bash
cd labs/lab38/aws

export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=${BUCKET}"

terraform plan
terraform apply
```

El apply crea **9 recursos**:
- 2 VPCs (`networking`, `data`)
- 5 subredes (3 en `networking`, 2 en `data`) — generadas por el Flatten Pattern
- 1 Internet Gateway para el VPC `networking` (tiene subredes publicas)
- 1 Security Group para la instancia de monitoreo
- 1 Security Group Egress Rule
- 1 instancia EC2 de monitoreo

---

## Paso 2 — Inspeccionar el resultado del Flatten Pattern

```bash
# Ver las claves compuestas generadas por el flatten
terraform output flattened_subnets_keys
# Esperado:
# tolist([
#   "data/db-a",
#   "data/db-b",
#   "networking/private-a",
#   "networking/public-a",
#   "networking/public-b",
# ])

# Ver el total de subredes creadas desde el mapa anidado
terraform output flattened_subnets_count
# Esperado: 5

# Ver los IDs de subredes agrupados por VPC
terraform output subnets_by_vpc
```

---

## Paso 3 — Inspeccionar las etiquetas fusionadas con `merge()`

```bash
# Ver las etiquetas de una subred de muestra
terraform output sample_subnet_tags
# Esperado (sin las etiquetas corporativas que llegan via default_tags):
# {
#   "BillingCode" = "NET-001"
#   "Department"  = "networking"
#   "Name"        = "lab38-networking/public-a"
#   "Team"        = "net-ops"
#   "Tier"        = "public"
# }

# Verificar en AWS que las etiquetas corporativas (default_tags) tambien estan
PRIMARY_SUBNET=$(terraform output -json subnet_ids | jq -r '.["networking/public-a"]')
aws ec2 describe-subnets \
  --subnet-ids "${PRIMARY_SUBNET}" \
  --query "Subnets[0].Tags" \
  --output table
# Las columnas ManagedBy, Project, Environment, CostCenter, Owner
# deben aparecer aunque no las hayas declarado en el bloque tags del recurso
```

---

## Paso 4 — Verificar la postcondition: IP publica asignada

```bash
# Ver la IP publica verificada por la postcondition
terraform output monitoring_public_ip
# Si el valor es null o vacio, la postcondition habria abortado el apply

# Verificar en AWS que la instancia tiene la IP
INSTANCE_ID=$(terraform output -raw monitoring_instance_id)
aws ec2 describe-instances \
  --instance-ids "${INSTANCE_ID}" \
  --query "Reservations[0].Instances[0].PublicIpAddress" \
  --output text
```

---

## Paso 5 — Disparar la precondition con una AZ no autorizada

Pasa un valor de `monitoring_config` con una AZ fuera de la lista autorizada
directamente en la linea de comandos, sin modificar `variables.tf`:

```bash
terraform plan -var='monitoring_config={"enabled":true,"availability_zone":"us-east-1d"}'
```

Terraform debe fallar durante el plan con el mensaje descriptivo:

```
╷
│ Error: Resource precondition failed
│
│   on main.tf line XX, in resource "aws_instance" "monitoring":
│    XX:       condition = contains(var.monitoring_config.allowed_azs, ...)
│
│ La zona de disponibilidad 'us-east-1d' no esta en la lista de zonas
│ autorizadas para este entorno: ["us-east-1a","us-east-1b","us-east-1c"].
│ Actualiza monitoring_config.availability_zone con un valor permitido.
╵
```

Observa que **ningun recurso se crea ni se destruye** — el plan se aborta
antes de intentar cualquier cambio. Restaura el valor original antes de
continuar.

---

## Paso 6 — Activar la alarma de CPU con `optional()` y verificar `can()`

Demuestra el atributo `optional(string, null)`: añade un email para activar
el SNS topic y la alarma de CloudWatch sin modificar ninguna otra parte del
codigo:

```bash
terraform plan -var='monitoring_config={"enabled":true,"alarm_email":"alertas@example.com"}'
# Debe mostrar 3 recursos nuevos: sns_topic + sns_subscription + cw_alarm

terraform apply -var='monitoring_config={"enabled":true,"alarm_email":"alertas@example.com"}'
```

Verifica que `local.monitoring_alarm_enabled` (calculado con `can()`) refleja
correctamente el estado:

```bash
terraform output monitoring_alarm_enabled
# Esperado: true
```

Limpia los 3 recursos de alerta antes de los retos volviendo al valor por
defecto (sin `alarm_email`):

```bash
terraform apply
# Esperado: 3 recursos destruidos (sns_topic, sns_subscription, cw_alarm)

terraform output monitoring_alarm_enabled
# Esperado: false
```

---

## Paso 7 — Verificar `try()` con los codigos de facturacion

`try()` extrae el `billing_code` de cada subred de forma defensiva. Inspecciona
el output para confirmar que todos tienen valor (en este lab siempre lo tienen,
pero el `try()` garantiza que el plan no fallaria si alguna subred heredada
no tuviera ese campo):

```bash
terraform output subnet_billing_codes
# Esperado:
# {
#   "data/db-a"            = "DAT-001"
#   "data/db-b"            = "DAT-001"
#   "networking/private-a" = "NET-002"
#   "networking/public-a"  = "NET-001"
#   "networking/public-b"  = "NET-001"
# }
```

Para ver `try()` en accion con un valor ausente, abre la consola de Terraform
(`terraform console`) y evalua una expresion que fallaria sin `try()`:

```bash
terraform console
```

```hcl
# Dentro del console:

# SIN try() — falla si el atributo no existe:
null.foo
# Error: Attempt to get attribute from null value

# CON try() — devuelve el fallback:
try(null.foo, "UNTAGGED")
# "UNTAGGED"

# can() — booleano de evaluabilidad:
can(null.foo)
# false

can("valor-real")
# true
```

---

## Paso 8 — Observar el bloque `check {}` en accion

El bloque `check "public_subnet_has_internet_route"` se evalua al final de
cada apply. En condiciones normales debería pasar:

```bash
terraform apply
# Al final del apply, si la ruta existe:
# Apply complete! Resources: X added, 0 changed, 0 destroyed.
# (sin advertencias de check)
```

El escenario idoneo para `check {}` es detectar **drift externo**: alguien
elimina una ruta manualmente en AWS sin pasar por Terraform. En ese caso el
data source del check lee el estado real de AWS tal como esta, y el `assert`
se evalua contra esa realidad.

Simula el drift eliminando la ruta directamente desde AWS CLI:

```bash
# Obtener el ID de la route table publica del VPC networking
RT_ID=$(terraform output -json public_route_table_ids | jq -r '.networking')

# Eliminar la ruta 0.0.0.0/0 manualmente (simula accion de un operador)
aws ec2 delete-route \
  --route-table-id "$RT_ID" \
  --destination-cidr-block "0.0.0.0/0"
```

Ejecuta `terraform plan` — el data source del check consulta el estado real
de AWS (ruta eliminada) y el `assert` dispara el mensaje personalizado:

```bash
terraform plan
# Esperado:
# Plan: 0 to add, 1 to change, 0 to destroy.
# ╷
# │ Warning: Check block assertion failed
# │
# │   on main.tf line 320, in check "public_subnet_has_internet_route":
# │  320:     condition = anytrue([
# │  321:       for route in data.aws_route_table.networking_public_a.routes :
# │  322:       route.cidr_block == "0.0.0.0/0" && route.gateway_id != null && route.gateway_id != ""
# │  323:     ])
# │     ├────────────────
# │     │ data.aws_route_table.networking_public_a.routes is empty list of object
# │
# │ La subred 'networking/public-a' no tiene ruta por defecto (0.0.0.0/0)
# │ hacia un Internet Gateway. Las instancias en esta subred no podran
# │ alcanzar Internet. Verifica aws_route_table.public["networking"] y
# │ aws_route_table_association.public["networking/public-a"].
# ╵
# (el plan NO se aborta — el check es solo una advertencia)
```

> Terraform muestra tanto la condición evaluada como el valor que la causa
> (`routes is empty list of object`) y el `error_message` personalizado.
> La route table existe y el data source la encuentra, pero al haber
> eliminado la única ruta gestionada, `routes` queda vacio y `anytrue([])`
> devuelve `false`.

Aplica para restaurar la ruta y verifica que el check vuelve a pasar:

```bash
terraform apply --auto-approve
# Apply complete! Resources: 0 added, 1 changed, 0 destroyed.
# (sin advertencias de check — la ruta esta restaurada)
```

---

## Paso 9 — Simular drift de tags con `ignore_changes`

`ignore_changes` protege los tags que herramientas externas puedan añadir.
Simula que AWS Organizations añade un tag `CreatedBy` a uno de los VPCs:

```bash
VPC_ID=$(terraform output -json vpc_ids | jq -r '.networking')

# Anadir una tag externamente (simula AWS Organizations o Security Hub)
aws ec2 create-tags \
  --resources "${VPC_ID}" \
  --tags Key=CreatedBy,Value=aws-organizations

# Verificar que la tag existe en AWS
aws ec2 describe-tags \
  --filters "Name=resource-id,Values=${VPC_ID}" "Name=key,Values=CreatedBy" \
  --query "Tags[0].Value" \
  --output text
# Esperado: aws-organizations
```

```bash
# Sin ignore_changes, esto devolveria:
# ~ tags = { - "CreatedBy" = "aws-organizations" }  ← Terraform la eliminaria

# CON ignore_changes: Terraform no la ve como drift
terraform plan
# Esperado: No changes. Your infrastructure matches the configuration.
```

La tag `CreatedBy` permanece en AWS intacta aunque no este declarada en el
codigo HCL — exactamente el comportamiento que necesitas cuando convives con
herramientas de gobernanza.

---

## Retos

### Reto 1 — Añadir una nueva VPC con subredes sin modificar el código

El Flatten Pattern debe permitir añadir nuevas VPCs y subredes simplemente
extendiendo la variable `vpc_config`, sin tocar ningun bloque `resource`.

**Objetivo**: añade un tercer VPC `"app"` con dos subredes
(`"app-a"` en `us-east-1a` y `"app-b"` en `us-east-1b`, ambas publicas)
al valor por defecto de `var.vpc_config`.

1. Modifica `variables.tf` para añadir el VPC `"app"` con sus dos subredes.
2. Ejecuta `terraform plan`.
3. Confirma que el plan muestra exactamente los recursos nuevos para `"app"`
   y cero cambios en los recursos existentes de `"networking"` y `"data"`.
4. Aplica y verifica con `terraform output subnets_by_vpc`.

**Lo que debes ver**: `app/app-a` y `app/app-b` en los outputs, junto con
un nuevo Internet Gateway para el VPC `"app"` (tiene subredes publicas).

---

### Reto 2 — Implementar una precondition de solapamiento de CIDR

Las VPCs no pueden tener bloques CIDR solapados si se van a conectar
mediante VPC Peering o Transit Gateway. Actualmente Terraform no valida esto.

**Objetivo**: añade una `precondition` en `aws_vpc.this` que verifique que
ninguno de los CIDRs de `var.vpc_config` se solapa con los demas.

**Pistas**:
- La función `cidrnetmask()` permite inspeccionar un CIDR.
- Para detectar solapamiento entre dos CIDRs puedes comparar si la primera
  IP de uno cae dentro del rango del otro con `cidrhost()`.
- Alternativamente, una validación pragmática es verificar que todos los
  CIDRs son distintos: `length(distinct(values(...))) == length(values(...))`.
  Implementa primero esta versión simple y luego, si quieres, la versión
  con solapamiento real.

---

### Reto 3 — Configuración de monitoreo por entorno con `optional()`

Actualmente `monitoring_config` tiene un único conjunto de valores por
defecto. En un proyecto real, los valores por defecto varian por entorno:
`production` usa `t4g.small` y requiere alarma; `dev` usa `t4g.micro` y
no necesita alarma.

**Objetivo**: define una variable `monitoring_defaults_by_env` de tipo
`map(object({ instance_type, alarm_email }))` y usa `lookup()` y `merge()`
para construir la configuración efectiva de monitoreo fusionando los defaults
del entorno con los valores que el operador haya especificado explicitamente.

```hcl
variable "monitoring_defaults_by_env" {
  type = map(object({
    instance_type = string
    alarm_email   = optional(string, null)
  }))
  default = {
    production = { instance_type = "t4g.small",  alarm_email = "prod-alerts@example.com" }
    staging    = { instance_type = "t4g.micro",  alarm_email = null }
    dev        = { instance_type = "t4g.micro",  alarm_email = null }
  }
}
```

La logica de fusion en `locals.tf`:
```hcl
locals {
  effective_monitoring = merge(
    lookup(var.monitoring_defaults_by_env, var.environment, {}),
    { for k, v in var.monitoring_config : k => v if v != null }
  )
}
```

---

## Soluciones

<details>
<summary>Reto 1 — Añadir una nueva VPC con subredes</summary>

Añade en `variables.tf` dentro del `default` de `vpc_config`:

```hcl
"app" = {
  cidr_block = "10.41.0.0/16"
  subnets = {
    "app-a" = {
      cidr_block        = "10.41.1.0/24"
      availability_zone = "us-east-1a"
      public            = true
      department_tags = {
        department   = "application"
        team         = "app-team"
        billing_code = "APP-001"
      }
    }
    "app-b" = {
      cidr_block        = "10.41.2.0/24"
      availability_zone = "us-east-1b"
      public            = true
      department_tags = {
        department   = "application"
        team         = "app-team"
        billing_code = "APP-001"
      }
    }
  }
}
```

```bash
terraform plan
# Esperado: 4 recursos nuevos
#   aws_vpc.this["app"]
#   aws_subnet.this["app/app-a"]
#   aws_subnet.this["app/app-b"]
#   aws_internet_gateway.this["app"]   ← tiene subredes publicas
#
# 0 cambios en networking y data

terraform apply
terraform output subnets_by_vpc
# "app" = {
#   "app/app-a" = "subnet-0abc..."
#   "app/app-b" = "subnet-0xyz..."
# }
```

El Flatten Pattern no requirio ningun cambio en el codigo de recursos —
solo en la variable de entrada.

</details>

<details>
<summary>Reto 2 — Precondition de solapamiento de CIDR</summary>

#### Donde añadir la precondition

`aws_vpc.this` ya tiene un bloque `lifecycle` con `ignore_changes`. Añade
la `precondition` dentro de ese mismo bloque, antes de `ignore_changes`:

```hcl
# ANTES — lifecycle solo con ignore_changes
resource "aws_vpc" "this" {
  for_each = local.vpcs_map
  # ...
  lifecycle {
    ignore_changes = [
      tags["CreatedBy"],
      tags["aws:cloudformation:stack-name"],
      tags["aws:organizations:delegated-administrator"],
    ]
  }
}

# DESPUES — precondition añadida dentro del mismo bloque lifecycle
resource "aws_vpc" "this" {
  for_each = local.vpcs_map
  # ...
  lifecycle {
    precondition {
      condition = length(distinct([
        for vpc in var.vpc_config : vpc.cidr_block
      ])) == length(var.vpc_config)
      error_message = <<-EOT
        Dos o mas VPCs tienen el mismo bloque CIDR. Los CIDRs deben ser
        unicos para permitir conectividad futura via VPC Peering o
        Transit Gateway. CIDRs actuales: ${jsonencode([
          for k, v in var.vpc_config : "${k}: ${v.cidr_block}"
        ])}
      EOT
    }

    ignore_changes = [
      tags["CreatedBy"],
      tags["aws:cloudformation:stack-name"],
      tags["aws:organizations:delegated-administrator"],
    ]
  }
}
```

#### Cómo funciona la condición

```hcl
length(distinct([
  for vpc in var.vpc_config : vpc.cidr_block
])) == length(var.vpc_config)
```

Paso a paso con los valores del laboratorio:

| Expresion | Resultado |
|-----------|-----------|
| `[for vpc in var.vpc_config : vpc.cidr_block]` | `["10.39.0.0/16", "10.40.0.0/16"]` |
| `distinct([...])` | `["10.39.0.0/16", "10.40.0.0/16"]` (sin cambios, todos distintos) |
| `length(distinct([...]))` | `2` |
| `length(var.vpc_config)` | `2` |
| `2 == 2` | `true` → precondition pasa |

Si dos VPCs tuviesen el mismo CIDR (`10.39.0.0/16`, `10.39.0.0/16`):

| Expresion | Resultado |
|-----------|-----------|
| `[for vpc in var.vpc_config : vpc.cidr_block]` | `["10.39.0.0/16", "10.39.0.0/16"]` |
| `distinct([...])` | `["10.39.0.0/16"]` (elimina duplicados) |
| `length(distinct([...]))` | `1` |
| `length(var.vpc_config)` | `2` |
| `1 == 2` | `false` → precondition falla |

#### Como probar que funciona

Añade temporalmente una tercera VPC en el `default` de `vpc_config` en
[variables.tf](aws/variables.tf) con el mismo CIDR que `networking`:

```hcl
# Anadir al final del default de vpc_config, dentro del mapa:
"duplicado" = {
  cidr_block = "10.39.0.0/16"   # mismo CIDR que "networking" → debe fallar
  subnets = {
    "test-a" = {
      cidr_block        = "10.39.50.0/24"
      availability_zone = "us-east-1a"
      public            = false
      department_tags = {
        department   = "test"
        team         = "test-team"
        billing_code = "TST-001"
      }
    }
  }
}
```

```bash
terraform plan
# Esperado — el mismo error aparece UNA VEZ POR VPC en el mapa.
# Con networking + data + duplicado (3 VPCs), el error se repite 3 veces.
# Si tambien tienes la VPC "app" del Reto 1, se repite 4 veces:
#
# ╷
# │ Error: Resource precondition failed
# │
# │   on main.tf line 40, in resource "aws_vpc" "this":
# │   40:       condition = length(distinct([
# │   41:         for vpc in var.vpc_config : vpc.cidr_block
# │   42:       ])) == length(var.vpc_config)
# │     ├────────────────
# │     │ var.vpc_config is map of object with 4 elements
# │
# │ Dos o mas VPCs tienen el mismo bloque CIDR. Los CIDRs deben ser
# │ unicos para permitir conectividad futura via VPC Peering o
# │ Transit Gateway. CIDRs actuales: ["app: 10.41.0.0/16","data: 10.40.0.0/16",
# │ "duplicado: 10.39.0.0/16","networking: 10.39.0.0/16"]
# ╵
# ╷
# │ Error: Resource precondition failed
# │   ... (mismo mensaje, instancia diferente del for_each)
# ╵
# ... (repetido una vez por cada VPC en el mapa)
```

> **Por que se repite el error**: `lifecycle { precondition }` pertenece al
> recurso `aws_vpc.this`, que usa `for_each`. Terraform evalua el bloque
> `lifecycle` independientemente para cada instancia del `for_each`
> (`networking`, `data`, `app`, `duplicado`), produciendo un error por cada
> una. La condición es idéntica en todos los casos porque evalúa
> `var.vpc_config` completo — no el VPC actual — por lo que el mensaje se
> repite con el mismo contenido. Es el comportamiento esperado y correcto.

Elimina la VPC `"duplicado"` de `variables.tf` y verifica que el plan
vuelve a pasar sin errores:

```bash
terraform plan
# Esperado: No changes. Your infrastructure matches the configuration.
```

</details>

<details>
<summary>Reto 3 — Configuración de monitoreo por entorno</summary>

Añade en `variables.tf`:

```hcl
variable "monitoring_defaults_by_env" {
  type = map(object({
    instance_type = string
    alarm_email   = optional(string, null)
  }))
  default = {
    production = { instance_type = "t4g.small",  alarm_email = "prod-alerts@example.com" }
    staging    = { instance_type = "t4g.micro",  alarm_email = null }
    dev        = { instance_type = "t4g.micro",  alarm_email = null }
  }
}
```

Añade en `locals.tf`:

```hcl
locals {
  # Los valores del operador sobreescriben los defaults del entorno.
  # Se filtran los null para que no sobreescriban un default valido.
  effective_monitoring = merge(
    lookup(var.monitoring_defaults_by_env, var.environment, {
      instance_type = "t4g.micro"
      alarm_email   = null
    }),
    { for k, v in var.monitoring_config : k => v if v != null }
  )
}
```

Hay dos archivos donde sustituir referencias. El motivo es siempre el mismo:
`var.monitoring_config` contiene solo lo que el operador especificó
explicitamente; `local.effective_monitoring` es el resultado de fusionar
los defaults del entorno con esos valores. Si leemos directamente la
variable, ignoramos los defaults del entorno y el reto no tiene efecto.

---

**[main.tf](aws/main.tf)** — `aws_instance.monitoring`, atributo `instance_type`:

```hcl
# ANTES — lee directamente la variable; si el operador no especifica
# instance_type, usa el default del tipo ("t4g.micro") sin tener en
# cuenta que production deberia arrancar con "t4g.small"
instance_type = var.monitoring_config.instance_type

# DESPUES — lee el local fusionado; para production obtiene "t4g.small"
# del mapa de defaults aunque el operador no haya escrito nada
instance_type = local.effective_monitoring.instance_type
```

---

**[locals.tf](aws/locals.tf)** — dos locales que acceden a `alarm_email`:

```hcl
# ANTES — monitoring_alarm_email extrae el email directamente de la
# variable; si el operador no puso alarm_email, devuelve null aunque
# el entorno production tenga "prod-alerts@example.com" como default
monitoring_alarm_email = try(var.monitoring_config.alarm_email, null)

# DESPUES — extrae el email del local fusionado; para production
# obtiene "prod-alerts@example.com" aunque el operador no lo haya puesto
monitoring_alarm_email = try(local.effective_monitoring.alarm_email, null)
```

```hcl
# ANTES — can() evalua si var.monitoring_config.alarm_email es accesible;
# si el operador no especifico alarm_email, can() devuelve false y no
# se crea la alarma aunque production deberia tenerla por defecto
monitoring_alarm_enabled = (
  var.monitoring_config.enabled &&
  can(var.monitoring_config.alarm_email) &&
  local.monitoring_alarm_email != null
)

# DESPUES — can() evalua el local fusionado; para production,
# local.effective_monitoring.alarm_email existe y no es null,
# por lo que la alarma se crea automaticamente sin que el operador
# tenga que recordar especificar el email
monitoring_alarm_enabled = (
  var.monitoring_config.enabled &&
  can(local.effective_monitoring.alarm_email) &&
  local.monitoring_alarm_email != null
)
```

---

**[variables.tf](aws/variables.tf)** — `instance_type` en `monitoring_config` debe usar `null` como default, no `"t4g.micro"`:

```hcl
# ANTES — optional(string, "t4g.micro") rellena instance_type con "t4g.micro"
# cuando el operador no lo especifica. Ese valor NO es null, por lo que el
# filtro "if v != null" en effective_monitoring lo incluye en el merge() y
# sobreescribe el default del entorno (t4g.small en production). El entorno
# nunca puede ganar porque la variable siempre aporta un valor no-null.
instance_type = optional(string, "t4g.micro")

# DESPUES — optional(string, null) deja instance_type como null cuando el
# operador no lo especifica. El filtro "if v != null" lo excluye del merge()
# y el default del entorno (t4g.small en production) puede aplicarse.
# Si el operador SI especifica un valor, ese valor no es null y prevalece.
instance_type = optional(string, null)
```

---

**[outputs.tf](aws/outputs.tf)** — `monitoring_instance_type` debe leer el local fusionado, no la variable:

```hcl
# ANTES — muestra el valor de la variable (null ahora, o "t4g.micro" antes);
# no refleja el tipo efectivo con el que se creo la instancia
output "monitoring_instance_type" {
  value = var.monitoring_config.instance_type
}

# DESPUES — muestra el valor efectivo tras fusionar defaults del entorno
# con los valores del operador; refleja lo que realmente se despliega
output "monitoring_instance_type" {
  value = local.effective_monitoring.instance_type
}
```

---

Prueba:

```bash
# Aplica los cambios — la instancia se recrea con el nuevo instance_type
# y se crean SNS topic + alarma porque production tiene alarm_email por defecto
terraform apply --auto-approve
# Esperado en el plan previo al apply:
#   ~ aws_instance.monitoring[0]              (instance_type: t4g.micro -> t4g.small)
#   + aws_sns_topic.monitoring_alerts[0]
#   + aws_sns_topic_subscription.monitoring_email[0]
#   + aws_cloudwatch_metric_alarm.monitoring_cpu[0]

# Verifica el tipo efectivo y que la alarma se activo
terraform output monitoring_instance_type
# Esperado: "t4g.small" (default de produccion)

terraform output monitoring_alarm_enabled
# Esperado: true (production tiene alarm_email = "prod-alerts@example.com")

# Sobreescribir el default del entorno con -var:
terraform apply \
  -var='monitoring_config={"enabled":true,"instance_type":"t4g.medium"}' \
  --auto-approve
terraform output monitoring_instance_type
# Esperado: "t4g.medium" (el operador sobreescribio el default)

terraform output monitoring_alarm_enabled
# Esperado: true (alarm_email sigue siendo "prod-alerts@example.com"
# del default del entorno — el operador no lo sobreescribio)

# Cambiar al entorno dev — distintos defaults sin tocar monitoring_config
terraform apply \
  -var='environment=dev' \
  --auto-approve
# Esperado en el plan previo al apply:
#   ~ aws_instance.monitoring[0]              (instance_type: t4g.medium -> t4g.micro)
#   - aws_sns_topic.monitoring_alerts[0]                         (destruido)
#   - aws_sns_topic_subscription.monitoring_email[0]             (destruido)
#   - aws_cloudwatch_metric_alarm.monitoring_cpu[0]              (destruido)

terraform output monitoring_instance_type
# Esperado: "t4g.micro" (default de dev)

terraform output monitoring_alarm_enabled
# Esperado: false (dev no tiene alarm_email en sus defaults)
```

</details>

---

## Verificación final

```bash
cd labs/lab38/aws

# Verificar que la instancia EC2 está running
aws ec2 describe-instances \
  --filters "Name=tag:Project,Values=lab38" \
  --query 'Reservations[*].Instances[*].{ID:InstanceId,State:State.Name,IP:PublicIpAddress}' \
  --output table

# Verificar que la alarma de CPU está configurada
aws cloudwatch describe-alarms \
  --query 'MetricAlarms[?contains(AlarmName,`lab38`)].{Name:AlarmName,State:StateValue}' \
  --output table

# Verificar los outputs del modulo (tags fusionados, codigos de facturacion)
terraform output -json

# Confirmar que el bloque check {} no lanza UNKNOWN en el plan
terraform plan -detailed-exitcode
echo "Exit code: $? (0=no changes, 1=error, 2=changes pending)"
```

---

## Limpieza

```bash
cd labs/lab38/aws

terraform destroy
```

---

## Buenas prácticas aplicadas

- **Flatten Pattern en `locals.tf`**: separar la transformacion de datos de
  la declaración de recursos hace el código más legible y testeable. Los
  locals son el lugar correcto para la logica de transformacion.
- **Claves compuestas semanticas**: `"networking/public-a"` es mas legible
  y estable que un indice numerico. Ante un `terraform plan`, el operador
  sabe exactamente que subred se va a modificar.
- **`merge()` en capas con precedencia explicita**: organizar las capas de
  menor a mayor prioridad (departamento → identificacion) hace que el codigo
  sea autodocumentado sobre que prevalece en caso de colision.
- **`optional()` con defaults razonables**: los valores por defecto deben
  funcionar correctamente en el caso de uso mas comun. `alarm_email = null`
  es un default correcto porque no crear una alarma es la opción segura;
  en cambio, un `instance_type = null` sería un default incorrecto porque
  causaría un error en el apply.
- **`precondition` para errores de configuración**: una precondición con un
  mensaje descriptivo ahorra al operador la frustración de esperar un apply
  fallido con un error críptico de AWS. La AZ no autorizada es el ejemplo
  tipico: AWS devuelve `InvalidParameterValue` sin contexto; la precondicion
  explica exactamente que esta mal y como corregirlo.
- **`postcondition` para invariantes de AWS**: no todo lo que AWS debe
  garantizar queda capturado en el plan. La postcondicion actua como un test
  de integración mínimo que se ejecuta en cada apply.

---

## Recursos

- [Flatten Pattern — Terraform Docs](https://developer.hashicorp.com/terraform/language/functions/flatten)
- [merge() — Terraform Docs](https://developer.hashicorp.com/terraform/language/functions/merge)
- [optional() en tipos de objeto](https://developer.hashicorp.com/terraform/language/expressions/type-constraints#optional-object-type-attributes)
- [precondition y postcondition](https://developer.hashicorp.com/terraform/language/validate)
- [default_tags en el provider AWS](https://registry.terraform.io/providers/hashicorp/aws/latest/docs#default_tags-configuration-block)
