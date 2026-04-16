# Sección 6 — Meta-argumentos y Bloques Dinámicos

> [← Sección anterior](./05_funciones.md) | [← Volver al índice](./README.md)

---

## 6.1 Introducción a los Meta-argumentos

Hasta ahora hemos definido recursos con sus atributos físicos: el tipo de instancia, el CIDR de la VPC, el nombre del bucket. Pero existe otra dimensión de configuración: cómo Terraform gestiona la **existencia, cantidad y ciclo de vida** de esos recursos dentro del grafo de dependencias.

Los **meta-argumentos** son parámetros especiales que Terraform entiende en cualquier bloque `resource`, independientemente del provider. No describen propiedades de infraestructura — describen cómo Terraform debe comportarse al gestionar ese recurso.

| Meta-argumento | Función principal |
|---------------|-------------------|
| `count` | Crear N instancias del mismo recurso |
| `for_each` | Crear recursos desde un mapa o set con identidad por clave |
| `depends_on` | Forzar orden de ejecución explícito cuando Terraform no detecta la dependencia |
| `lifecycle` | Personalizar create, update y destroy — proteger recursos críticos |
| `provider` | Asignar un provider alternativo (multi-región, multi-cuenta) |

---

## 6.2 Escalabilidad Básica: `count` y `count.index`

`count` acepta un entero y crea esa cantidad de instancias del recurso. El iterador automático `count.index` empieza en 0 y permite diferenciar cada recurso:

```hcl
# Crear 3 subredes con count
resource "aws_subnet" "main" {
  count = 3

  vpc_id     = aws_vpc.main.id
  cidr_block = cidrsubnet(var.vpc_cidr, 8, count.index)
  # count.index = 0 → "10.0.0.0/24"
  # count.index = 1 → "10.0.1.0/24"
  # count.index = 2 → "10.0.2.0/24"

  tags = {
    Name = "subnet-${count.index}"
  }
}

# Referencia a un recurso específico por índice
# aws_subnet.main[0]  → primera subred
# aws_subnet.main[1]  → segunda subred
# aws_subnet.main[*]  → todas (con splat)
```

`count` es ideal para recursos que son **idénticos entre sí** y donde el orden numérico tiene sentido. Como veremos, tiene una limitación importante cuando los recursos necesitan identidades estables.

---

## 6.3 Caso Real: Recursos Condicionales con `count`

Uno de los patrones más utilizados en producción: usar `count` con un ternario para **activar o desactivar** un recurso completo según una variable booleana:

```hcl
# variables.tf — control on/off
variable "deploy_bastion" {
  type        = bool
  default     = false   # dev = false (ahorro de costes), prod = true
  description = "Desplegar el Bastion Host de acceso SSH"
}

# main.tf — el recurso existe o no existe según la variable
resource "aws_instance" "bastion" {
  count         = var.deploy_bastion ? 1 : 0
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"

  tags = { Name = "bastion-host" }
}

# deploy_bastion=false → 0 instancias → NO se crea → AHORRO
# deploy_bastion=true  → 1 instancia  → SE crea   → acceso SSH disponible
```

Este patrón permite tener el código de producción en el mismo repositorio que el de desarrollo, sin duplicación, activando características caras solo cuando son necesarias.

---

## 6.4 Iteración Avanzada: `for_each`

A diferencia de `count` que identifica cada recurso por un índice numérico, `for_each` identifica cada recurso por una **clave única**. Acepta mapas y sets de strings:

```hcl
# Set de strings — cada elemento es la clave
variable "usuarios" {
  default = toset(["alice", "bob", "carol"])
}

resource "aws_iam_user" "team" {
  for_each = var.usuarios
  name     = each.key
}

# Terraform crea:
# aws_iam_user.team["alice"]
# aws_iam_user.team["bob"]
# aws_iam_user.team["carol"]
```

### Ventajas críticas sobre `count`

| Aspecto | `count` | `for_each` |
|---------|---------|-----------|
| Identificador | Índice numérico `[0]`, `[1]`... | Clave única `["alice"]`... |
| Eliminar elemento | Recrea los que siguen (índices se desplazan) | Solo elimina ese elemento |
| Configuración individual | Difícil | Natural con `each.value` |
| Estabilidad en producción | Frágil | Estable |

> **Regla:** Usa `for_each` siempre que sea posible. La identidad por clave es estable — eliminar `alice` no afecta a `bob` ni a `carol`.

---

## 6.5 Acceso a Datos: `each.key` y `each.value`

Dentro del bloque `for_each`, dos objetos dan acceso al elemento actual:

```hcl
# Mapa complejo con múltiples atributos por usuario
variable "equipo" {
  default = {
    alice = { departamento = "ingenieria",  rol = "admin" }
    bob   = { departamento = "finanzas",    rol = "readonly" }
    carol = { departamento = "operaciones", rol = "dev" }
  }
}

resource "aws_iam_user" "team" {
  for_each = var.equipo

  name = each.key   # "alice", "bob", "carol"

  tags = {
    Department = each.value.departamento   # atributo del objeto
    Role       = each.value.rol
    CostCenter = each.value.departamento
  }
}
```

`each.key` es la clave del mapa (o el valor del set). `each.value` es el valor asociado — puede ser un string simple o un objeto complejo con sus propios atributos accesibles por notación de punto.

---

## 6.6 Decisión Crítica: ¿`count` o `for_each`?

Elige según la naturaleza de los recursos y la estabilidad requerida:

| Situación | Usa |
|-----------|-----|
| Recursos idénticos, número fijo | `count` |
| Patrón condicional (existe o no existe) | `count` con ternario `? 1 : 0` |
| Recursos con configuración individual | `for_each` |
| Recursos que pueden eliminarse selectivamente | `for_each` |
| Entornos de producción con cambios frecuentes | `for_each` ⭐ |

La razón técnica detrás de preferir `for_each` es la estabilidad del state: si tienes 5 instancias con `count` y eliminas la tercera (`[2]`), Terraform recrea las instancias `[3]` y `[4]` porque sus índices cambian. Con `for_each`, eliminar `"carol"` no afecta a `"alice"` ni `"bob"`.

---

## 6.7 Orden de Ejecución: `depends_on`

Terraform infiere el orden de creación automáticamente a través de las referencias entre recursos. Pero hay situaciones donde existe una dependencia operacional que no se refleja en los atributos del código — Terraform no puede detectarla. En esos casos, `depends_on` fuerza el orden explícitamente:

```hcl
resource "aws_iam_policy" "s3_access" {
  name   = "s3-access"
  policy = file("policy.json")
}

resource "aws_instance" "app" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.medium"

  # La instancia no referencia ningún atributo de la policy,
  # pero operacionalmente necesita que exista antes de arrancar
  depends_on = [aws_iam_policy.s3_access]
}
```

### Caso real: NAT Gateway con tabla de rutas

```hcl
resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public.id
}

resource "aws_route" "private_internet" {
  route_table_id         = aws_route_table.private.id
  destination_cidr_block = "0.0.0.0/0"
  nat_gateway_id         = aws_nat_gateway.main.id

  # El NAT Gateway tarda en estar Available tras crearse.
  # Sin depends_on: error intermitente "NatGatewayNotFound"
  depends_on = [aws_nat_gateway.main]
}
```

> **Advertencia:** Usa `depends_on` solo como último recurso. Si puedes pasar un atributo de un recurso a otro, Terraform infiere la dependencia automáticamente y es más eficiente y claro.

---

## 6.8 Control del Ciclo de Vida: `lifecycle {}`

El bloque `lifecycle` permite personalizar cómo Terraform crea, actualiza y destruye recursos. Controla el comportamiento sin modificar la infraestructura subyacente:

```hcl
resource "tipo" "nombre" {
  # configuración normal...

  lifecycle {
    create_before_destroy = true    # Crear nuevo antes de destruir el viejo
    prevent_destroy       = true    # Bloquear destrucción accidental
    ignore_changes        = [tags]  # Ignorar cambios externos específicos
    replace_triggered_by  = [...]   # Forzar recreación por dependencia externa
  }
}
```

---

## 6.9 Zero-Downtime: `create_before_destroy`

Por defecto, cuando un recurso debe recrearse (por ejemplo, al cambiar la AMI de una instancia), Terraform destruye el viejo primero y luego crea el nuevo. Esto implica **tiempo de inactividad**.

Con `create_before_destroy = true`, el orden se invierte: crea el nuevo recurso, verifica que esté operativo y solo entonces destruye el viejo:

```hcl
resource "aws_instance" "web" {
  ami           = var.ami_id
  instance_type = "t3.micro"

  lifecycle {
    create_before_destroy = true
  }
}
# Flujo: Nuevo disponible → Redirigir tráfico → Destruir viejo
# Ideal para: instancias EC2, ALBs, Auto Scaling Groups
```

---

## 6.10 Protección Total: `prevent_destroy`

Si cualquier plan intenta destruir un recurso marcado con `prevent_destroy = true`, Terraform aborta con un error explícito. Es la primera línea de defensa contra borrados accidentales de recursos críticos:

```hcl
resource "aws_db_instance" "produccion" {
  engine         = "postgres"
  instance_class = "db.r5.large"

  lifecycle {
    prevent_destroy = true
  }
}

# Si alguien ejecuta terraform destroy:
# Error: Instance cannot be destroyed
# Resource aws_db_instance.produccion has lifecycle.prevent_destroy
# set to true.
```

Aplícalo a: bases de datos de producción, buckets S3 con datos críticos, claves KMS, certificados ACM.

---

## 6.11 Tolerancia al Ruido: `ignore_changes`

Evita que Terraform detecte como **drift** los cambios realizados fuera del código — por ejemplo, tags añadidos manualmente desde la consola de AWS o la AMI actualizada por un Auto Scaling Group:

```hcl
resource "aws_instance" "web" {
  ami           = var.ami_id
  instance_type = "t3.micro"

  lifecycle {
    ignore_changes = [
      tags,   # Ignora cambios de tags (el equipo de FinOps los gestiona manualmente)
      ami     # Ignora cambios de AMI (el ASG puede actualizarla)
    ]
  }
}

# También acepta: ignore_changes = all
# Ignora TODOS los cambios externos al recurso
```

---

## 6.12 Reemplazo Inteligente: `replace_triggered_by`

Fuerza la recreación de un recurso cuando otro recurso externo cambia, aunque no compartan atributos directos:

```hcl
# Trigger: se recrea cada vez que cambia la versión de la aplicación
# terraform_data es el sustituto moderno de null_resource (Terraform 1.4+, sin provider externo)
resource "terraform_data" "deploy_trigger" {
  input = var.app_version
}

# El servicio ECS se recrea cuando el trigger detecta un cambio de versión
resource "aws_ecs_service" "app" {
  name            = "mi-app"
  task_definition = var.task_definition_arn

  lifecycle {
    replace_triggered_by = [
      terraform_data.deploy_trigger   # Observa este recurso
    ]
  }
}
# var.app_version cambia → terraform_data se recrea → ECS service: destroy + create
```

---

## 6.13 Guardias: `precondition` y `postcondition`

Las guardias validan la infraestructura automáticamente en puntos clave del ciclo de vida:

```hcl
resource "aws_instance" "web" {
  ami           = var.ami_id
  instance_type = var.instance_type

  lifecycle {
    # precondition — valida ANTES de crear/modificar
    precondition {
      condition     = var.env != "prod" || var.instance_type == "t3.large"
      error_message = "En producción se requiere instance_type = t3.large"
    }

    # postcondition — verifica DESPUÉS de crear
    postcondition {
      condition     = self.instance_state == "running"
      error_message = "La instancia no arrancó correctamente"
    }
  }
}
```

---

## 6.14 Selección de Provider: `alias` y Multi-región

El meta-argumento `provider` asigna un provider alternativo a un recurso específico. Combinado con el argumento `alias`, permite desplegar en múltiples regiones o cuentas desde un mismo proyecto:

```hcl
# Provider principal — región primaria
provider "aws" {
  region = "eu-west-1"
}

# Provider con alias — región de Disaster Recovery
provider "aws" {
  alias  = "us_backup"
  region = "us-east-1"
}

# Recurso en la región principal (implícito)
resource "aws_s3_bucket" "primary" {
  bucket = "datos-primarios-euwest1"
}

# Recurso en la región de DR (explícito con provider)
resource "aws_s3_bucket" "disaster_recovery" {
  provider = aws.us_backup   # ← apunta al provider con alias
  bucket   = "datos-dr-useast1"
}
```

> **Consejo Pro:** Para Disaster Recovery completo, combina `provider alias` con replicación cross-region de S3, RDS y DynamoDB. Cada recurso DR apunta al provider de backup.

---

## 6.15 Bloques `dynamic`: Configuración Condicional

El bloque `dynamic` genera **sub-bloques repetitivos** automáticamente a partir de una colección. Evita escribir manualmente diez bloques de `ingress` en un Security Group:

```hcl
variable "puertos" {
  default = [80, 443, 8080]
}

resource "aws_security_group" "web" {
  name = "web-sg"

  dynamic "ingress" {
    for_each = var.puertos
    content {
      from_port   = ingress.value
      to_port     = ingress.value
      protocol    = "tcp"
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
}
```

Estructura del bloque `dynamic`:
1. `dynamic "nombre_bloque"` — nombre del sub-bloque que se generará
2. `for_each` — la colección a iterar
3. `content {}` — los atributos de cada bloque generado

---

## 6.16 Iteradores Personalizados en `dynamic`

Por defecto, `dynamic` usa el nombre del bloque como iterador (`ingress.value`). Con `iterator` puedes asignar un alias más descriptivo:

```hcl
variable "reglas_ingress" {
  default = [
    { port = 80,  protocolo = "tcp", desc = "HTTP"  },
    { port = 443, protocolo = "tcp", desc = "HTTPS" },
    { port = 22,  protocolo = "tcp", desc = "SSH"   },
  ]
}

resource "aws_security_group" "firewall" {
  dynamic "ingress" {
    for_each = var.reglas_ingress
    iterator = rule   # ← alias descriptivo en lugar de "ingress"

    content {
      from_port   = rule.value.port
      to_port     = rule.value.port
      protocol    = rule.value.protocolo
      description = rule.value.desc
      cidr_blocks = ["0.0.0.0/0"]
    }
  }
}
```

Con `iterator = rule`, el código dice `rule.value.port` en lugar de `ingress.value.port` — mucho más autoexplicativo. El equipo de seguridad solo modifica la lista de variables para actualizar todas las reglas de red.

---

## 6.17 Resumen: El Poder del Control de Recursos

Los meta-argumentos elevan Terraform de un simple declarador de recursos a una herramienta de **orquestación empresarial**. Dominar `lifecycle` es lo que separa a un administrador junior de un arquitecto de infraestructura senior.

| Principio | Aplicación |
|-----------|------------|
| **Prioriza** | Usa `for_each` sobre `count` siempre que sea posible — identidad por clave = estabilidad en producción |
| **Protege** | Usa `lifecycle` para blindar producción: `prevent_destroy` en BD, `create_before_destroy` para zero-downtime |
| **Automatiza** | Combina `dynamic` con `for_each` y `provider alias` para arquitecturas multi-región escalables |

---

> **[← Volver al índice del Módulo 2](./README.md)**
