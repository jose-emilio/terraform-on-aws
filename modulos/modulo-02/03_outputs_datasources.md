# Sección 3 — Outputs y Data Sources

> [← Sección anterior](./02_variables.md) | [← Volver al índice](./README.md) | [Siguiente →](./04_expresiones_operadores.md)

---

## 3.1 ¿Qué son los Outputs?

Cuando ejecutas `terraform apply` y la infraestructura se crea correctamente, ¿cómo sabes cuál es la IP del servidor que acaba de crearse? ¿O la URL del balanceador de carga? ¿O el ARN del bucket S3? Sin outputs, tendrías que abrir la consola de AWS y buscarlo manualmente.

Los **outputs** resuelven este problema: exponen información crítica de la infraestructura directamente en la terminal al finalizar el `apply`. Son la "ventana de salida" de tu código.

> *"Los outputs son el puente entre tu infraestructura y las personas que la usan."*

Al igual que una función devuelve un valor al llamador, un output devuelve datos de la infraestructura al operador que ejecutó el despliegue — sin necesidad de buscar en consolas web.

```
Terraform apply completa
        ↓
Outputs:
instancia_ip = "54.23.11.200"
bucket_arn   = "arn:aws:s3:::mi-bucket"
```

---

## 3.2 Declaración de un bloque `output {}`

```hcl
# outputs.tf — convenio: todos los outputs en este archivo

# Exponer la IP pública de la instancia
output "instancia_ip" {
  value       = aws_instance.mi_servidor.public_ip
  description = "IP pública del servidor web"
}

# Exponer el ARN del bucket
output "bucket_arn" {
  value       = aws_s3_bucket.datos.arn
  description = "ARN del bucket de almacenamiento"
}
```

```
# Resultado en terminal tras terraform apply:
Outputs:

instancia_ip = "54.23.11.200"
bucket_arn   = "arn:aws:s3:::mi-bucket-prod"
```

El nombre del output debe ser **único en el módulo** y descriptivo del dato que expone. La referencia sigue el mismo patrón que cualquier atributo de recurso: `tipo_recurso.nombre_local.atributo`.

---

## 3.3 Outputs Sensibles: `sensitive = true`

Sin marcar, contraseñas o claves API aparecen en texto plano en el plan, el apply y los logs de CI/CD — un riesgo de seguridad significativo:

```hcl
# ❌ SIN sensitive — el valor se imprime en claro
output "db_password" {
  value = "MiPassword123!"
}
# Resultado: db_password = "MiPassword123!"  ← expuesto en logs

# ✅ CON sensitive — el valor queda oculto
output "db_password" {
  value     = var.db_password
  sensitive = true
}
# Resultado: db_password = (sensitive value)
```

> **Importante:** `sensitive = true` **solo oculta la visualización en el CLI**. El valor sigue almacenado en el state file. Para proteger el state, usa backends remotos con cifrado (S3 + KMS).

---

## 3.4 Outputs entre Módulos: `module.nombre.output`

Los outputs son la **única forma** de pasar datos de un módulo hijo al módulo padre. Cuando un módulo expone un output, el módulo padre puede acceder a él con la sintaxis `module.<nombre>.<output_name>`:

```hcl
# Módulo "vpc" — expone el ID de la VPC
# modulo-vpc/outputs.tf
output "vpc_id" {
  value = aws_vpc.main.id
}

# Módulo padre — consume el output del módulo vpc
module "ec2" {
  source = "./modulo-ec2"
  vpc_id = module.vpc.vpc_id   # ← sintaxis module.<nombre>.<output>
}
```

Esto crea cadenas de dependencias entre módulos: `vpc → ec2 → alb`. Los IDs fluyen de un módulo a otro formando una arquitectura modular y encapsulada.

> **Regla:** Los módulos **solo exponen lo que declaran explícitamente** en un bloque `output`. Todo lo demás permanece privado dentro del módulo.

---

## 3.5 Data Sources: Leer Infraestructura Existente

Hasta ahora hemos visto cómo crear infraestructura con `resource`. Pero ¿qué pasa cuando necesitas conectar tu nueva infraestructura con recursos que ya existen y están fuera del control de Terraform? Por ejemplo, una VPC corporativa gestionada por el equipo de red, o un rol IAM gestionado por el equipo de seguridad.

Los **data sources** permiten **consultar información** de recursos existentes sin gestionarlos. Si los outputs son la salida de datos, los data sources son la entrada.

| Característica | Descripción |
|---------------|-------------|
| **Solo lectura** | Terraform consulta pero **nunca modifica** un data source |
| **Consulta en tiempo real** | Pregunta a la API del proveedor y recupera atributos actuales |
| **Casos de uso** | VPC ya existente, AMI de otra cuenta, rol IAM del equipo de seguridad... |

```
Sintaxis:  data "<tipo>" "<nombre>" { filtros }
Referencia: data.<tipo>.<nombre>.<atributo>
```

---

## 3.6 `resource {}` vs `data {}` — La Diferencia Clave

La distinción es fundamental y evita errores conceptuales graves:

```hcl
# resource {} → CREA infraestructura nueva
resource "aws_vpc" "mi_vpc" {
  cidr_block = "10.0.0.0/16"
}
# Tiene ciclo de vida completo: plan, apply, destroy
# Terraform lo gestiona y lo incluye en el state

# data {} → LEE infraestructura existente
data "aws_vpc" "vpc_existente" {
  default = true   # Busca la VPC por defecto de la cuenta
}
# Solo lectura — no tiene estado propio
# Terraform no puede destruirla ni modificarla
```

> **Regla de oro:** Si ya existe y no quieres que Terraform lo gestione → usa `data`. Si lo creas con Terraform → usa `resource`.

---

## 3.7 Data Source: `aws_ami` (El Más Importante)

El data source más utilizado en el día a día. Los IDs de AMI cambian con cada región y con cada nueva versión del sistema operativo. Hardcodear `"ami-0abcd1234"` en el código es una **bomba de tiempo**: ese ID solo es válido en una región concreta y se vuelve obsoleto cuando Canonical publica una nueva versión de Ubuntu.

```hcl
# Buscar siempre la última versión de Ubuntu 22.04 LTS
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"]   # Cuenta oficial de Canonical (Ubuntu)

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-*"]
  }
}

# Uso: la instancia siempre usa la AMI más reciente de Canonical
resource "aws_instance" "web" {
  ami           = data.aws_ami.ubuntu.id
  instance_type = "t3.micro"
}
```

> **Nota de seguridad:** Siempre verifica el `owner` del AMI. `099720109477` es la cuenta oficial de Canonical para Ubuntu. Usar un AMI de un owner desconocido puede significar que estás lanzando máquinas con código malicioso.

---

## 3.8 Data Source: `aws_vpc` y `aws_subnets`

Para conectar con la red corporativa existente sin necesidad de conocer sus IDs internos de antemano:

```hcl
# Buscar la VPC de producción por su tag
data "aws_vpc" "corp" {
  filter {
    name   = "tag:Env"
    values = ["production"]
  }
}

# Obtener todas las subredes públicas de esa VPC
data "aws_subnets" "publicas" {
  filter {
    name   = "tag:Tier"
    values = ["Public"]
  }
}

# Uso: desplegar en las subredes correctas sin IDs estáticos
resource "aws_instance" "app" {
  subnet_id = data.aws_subnets.publicas.ids[0]
}
```

Este patrón permite que el código sea **independiente de los IDs específicos de la infraestructura** — funciona en cualquier cuenta AWS que tenga los tags correctos.

---

## 3.9 Data Source: `aws_caller_identity`

Devuelve información sobre la cuenta AWS activa: Account ID, ARN del caller y User ID. Esencial para construir ARNs dinámicos y políticas de seguridad portables entre cuentas:

```hcl
# No necesita argumentos de filtrado
data "aws_caller_identity" "current" {}

# ARN dinámico sin hardcodear el Account ID
resource "aws_s3_bucket_policy" "main" {
  policy = jsonencode({
    Statement = [{
      Principal = {
        AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
      }
    }]
  })
}
```

| Atributo | Descripción |
|----------|-------------|
| `.account_id` | ID numérico de la cuenta AWS (12 dígitos) |
| `.arn` | ARN del usuario o rol que ejecuta Terraform |
| `.user_id` | Identificador único del principal activo |

---

## 3.10 Data Source: `aws_availability_zones`

Lista dinámicamente las Availability Zones disponibles en la región activa. Permite crear subredes en AZs reales sin hardcodear `"us-east-1a"`, `"us-east-1b"`... — haciendo el código independiente de la región:

```hcl
# Obtener todas las AZs disponibles en la región activa
data "aws_availability_zones" "azs" {
  state = "available"
}

# Crear una subred por AZ automáticamente
resource "aws_subnet" "main" {
  count             = length(data.aws_availability_zones.azs.names)
  vpc_id            = aws_vpc.main.id
  availability_zone = data.aws_availability_zones.azs.names[count.index]
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index)
}
```

El atributo `.names` devuelve una lista de strings con los nombres de todas las AZs disponibles. Este código funciona igual en `us-east-1` (6 AZs) que en `eu-west-1` (3 AZs) sin cambiar una línea.

---

## 3.11 Otros Data Sources Frecuentes

```hcl
# Reutilizar un Security Group existente
data "aws_security_group" "app_sg" {
  filter {
    name   = "group-name"
    values = ["app-sg-prod"]
  }
}
# Uso: vpc_security_group_ids = [data.aws_security_group.app_sg.id]

# Recuperar un rol IAM gestionado por el equipo de seguridad
data "aws_iam_role" "lambda_exec" {
  name = "lambda-execution-role"
}
# Uso: role = data.aws_iam_role.lambda_exec.arn

# Localizar una tabla de rutas por tag
data "aws_route_table" "main" {
  filter {
    name   = "tag:Name"
    values = ["main-rt"]
  }
}
# Uso: route_table_id = data.aws_route_table.main.id
```

El patrón es siempre el mismo: **data source → descubrir recurso existente → referenciar su ID en un recurso nuevo** = infraestructura dinámica sin IDs hardcodeados.

---

## 3.12 Filtrado Avanzado y Dependencias

### Filtros en data sources

Los filtros usan los **nombres de atributos de la API de AWS** (no los nombres del recurso Terraform). Consulta la documentación del provider para conocer los filtros disponibles de cada data source.

### Dependencias implícitas

Terraform siempre lee los data sources **antes** de intentar crear los recursos que dependen de ellos. Esta dependencia es automática al referenciar el data source — no necesitas `depends_on`.

> **Consejo de seguridad:** Si un data source no encuentra resultados que coincidan con los filtros, Terraform fallará durante el `plan`, actuando como una **validación de seguridad** antes de aplicar cambios. Esto es una feature, no un bug: es mejor descubrir que la VPC de producción no existe antes de intentar crear subredes en ella.

---

## 3.13 Resumen: El Ciclo de Información

Con variables, outputs y data sources, tenemos control total sobre el flujo de datos en nuestra infraestructura:

```
Data Sources          Variables            Outputs
Traen datos de fuera  Parametrizan         Devuelven resultados
data "aws_vpc" {}  →  var.entorno      →   output "ip" {}

        ↓                  ↓                    ↓
  Infraestructura   Infraestructura      Usuario/operador
  existente         configurable         recibe los datos
```

Sustituye IDs, IPs y ARNs hardcodeados por data sources dinámicos y variables parametrizadas. Tu código será más robusto, portable y reutilizable entre entornos y cuentas.

---

> **Siguiente:** [Sección 4 — Expresiones y Operadores →](./04_expresiones_operadores.md)
