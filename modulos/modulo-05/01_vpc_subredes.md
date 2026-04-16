# Sección 1 — VPC y Subredes

> [← Volver al índice](./README.md) | [Siguiente →](./02_gateways_endpoints.md)

---

## 1.1 La VPC: Tu Datacenter Virtual Privado

Antes de desplegar cualquier recurso en AWS —una instancia EC2, una base de datos RDS, una función Lambda con VPC— necesitas un contenedor de red. Ese contenedor es la **VPC (Virtual Private Cloud)**: una red virtual aislada dentro de la región que tú defines y controlas al 100%.

Piensa en ella como el terreno sobre el que construirás tu ciudad. Sin terreno, no hay edificios. Sin VPC, no hay red.

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr           # Ej: "10.0.0.0/16"
  instance_tenancy     = "default"              # "dedicated" para compliance estricto
  enable_dns_hostnames = true                   # Obligatorio para resolución DNS interna
  enable_dns_support   = true

  tags = {
    Name        = "vpc-produccion"
    Environment = "production"
    ManagedBy   = "terraform"
  }
}
```

Los tres argumentos más críticos:
- `cidr_block`: el espacio de direcciones de toda la VPC. Elige bien: no es fácil cambiar esto después.
- `enable_dns_hostnames`: si está desactivado, los recursos no tienen hostname DNS y herramientas como SSM Agent y CodeDeploy dejan de funcionar.
- `instance_tenancy`: en `"default"` el hardware es compartido (estándar). En `"dedicated"` cada instancia tiene hardware físico exclusivo. Útil para compliance HIPAA/PCI-DSS, pero cuesta entre 2-3x más.

---

## 1.2 Planificación CIDR: El Terreno que No Puedes Recuperar

> "Elige bien tu CIDR al inicio, porque cambiar la VPC después es demoler el edificio y reconstruirlo desde cero."

RFC 1918 define los rangos privados válidos para redes internas. En AWS debes usar uno de estos tres bloques:

| Rango RFC 1918 | Máscara | IPs disponibles | Uso recomendado |
|----------------|---------|-----------------|-----------------|
| `10.0.0.0/8` | `/16` por VPC | 65,534 IPs/VPC | Producción multi-cuenta |
| `172.16.0.0/12` | `/20` por VPC | 4,094 IPs/VPC | Entornos medianos |
| `192.168.0.0/16` | `/24` por VPC | 254 IPs/VPC | Solo dev/lab |

**Reglas de oro para planificar el CIDR:**
1. Reserva bloques contiguos para cada cuenta. Si Networking usa `10.0.0.0/16`, Producción `10.1.0.0/16` y Dev `10.2.0.0/16`, los CIDRs no se solaparán cuando las conectes con VPC Peering o Transit Gateway.
2. Elige `/16` como mínimo para VPCs productivas. Necesitas espacio para subredes, subredes de reserva y crecimiento futuro.
3. Nunca uses `172.17.0.0/16`: es el rango interno de Docker y causará conflictos en entornos de contenedores.

---

## 1.3 Subredes: La Segmentación de tu Red

Si la VPC es el terreno, las subredes son los barrios. Cada subred:
- Vive en **una sola AZ** (Availability Zone)
- Tiene su propio **rango CIDR** (subconjunto del CIDR de la VPC)
- Se clasifica como **pública** o **privada** según su tabla de rutas

La división en niveles es el patrón arquitectónico más importante de toda VPC:

```
Nivel Público    → Subredes con ruta a Internet Gateway (ALB, NAT Gateway, Bastion)
Nivel Privado    → Subredes sin acceso directo desde Internet (EC2, ECS, Lambda)
Nivel Datos      → Subredes solo accesibles desde la capa privada (RDS, ElastiCache)
```

---

## 1.4 La Función `cidrsubnet()`: Matemáticas CIDR Automáticas

Calcular rangos CIDR manualmente es propenso a errores. Terraform ofrece `cidrsubnet()` para dividir un bloque de red en subredes de forma programática:

```hcl
# Sintaxis: cidrsubnet(base_cidr, newbits, netnum)
# newbits: cuántos bits añadir a la máscara
# netnum: índice de la subred (empieza en 0)

cidrsubnet("10.0.0.0/16", 8, 0)  # → "10.0.0.0/24"  (256 IPs, primera subred)
cidrsubnet("10.0.0.0/16", 8, 1)  # → "10.0.1.0/24"  (256 IPs, segunda subred)
cidrsubnet("10.0.0.0/16", 8, 10) # → "10.0.10.0/24" (256 IPs, subred 11)
```

Esto permite generar subredes dinámicamente con `for_each`, sin repetir código ni calcular nada a mano.

---

## 1.5 `cidrhost()` y las IPs Reservadas de AWS

AWS reserva automáticamente **las primeras 4 IPs y la última** de cada subred:

| IP | Uso reservado |
|----|---------------|
| `.0` | Dirección de red (no usable) |
| `.1` | Router VPC (Gateway implícito) |
| `.2` | DNS Resolver de Amazon |
| `.3` | Reservada para uso futuro de AWS |
| `.255` | Broadcast (no usable) |

En una subred `/24` de 256 IPs teóricas, **solo 251 están disponibles** para tus recursos.

`cidrhost()` calcula la IP exacta dentro de un rango:

```hcl
cidrhost("10.0.1.0/24", 10)  # → "10.0.1.10" (décima IP de esa subred)
```

---

## 1.6 Arquitectura Multi-AZ con `for_each`

Una arquitectura resiliente despliega recursos en al menos 2 AZs. Con Terraform, lo hacemos de forma dinámica usando `for_each` sobre las AZs disponibles:

```hcl
# Obtener AZs disponibles en la región
data "aws_availability_zones" "available" {
  state = "available"
}

# Crear una subred pública por cada AZ (máx. 3)
resource "aws_subnet" "public" {
  for_each = toset(slice(data.aws_availability_zones.available.names, 0, 3))

  vpc_id                  = aws_vpc.main.id
  availability_zone       = each.key
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, index(data.aws_availability_zones.available.names, each.key))
  map_public_ip_on_launch = true

  tags = merge(var.tags, {
    Name = "public-subnet-${each.key}"
    # Tags requeridos para que EKS descubra las subredes públicas
    "kubernetes.io/role/elb"               = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  })
}
```

`slice()` garantiza que aunque haya 6 AZs disponibles, solo usamos las primeras 3. Esto evita el coste extra de múltiples NAT Gateways sin beneficio real de redundancia.

---

## 1.7 Tags de EKS: Descubrimiento Automático de Subredes

Si planeas usar Amazon EKS en esta VPC, los tags de las subredes son **obligatorios** para que el Cloud Controller Manager de Kubernetes descubra y configure los Load Balancers automáticamente:

| Tag | Valor | Subred | Propósito |
|-----|-------|--------|-----------|
| `kubernetes.io/role/elb` | `1` | Pública | EKS crea ALBs/NLBs externos aquí |
| `kubernetes.io/role/internal-elb` | `1` | Privada | EKS crea LBs internos aquí |
| `kubernetes.io/cluster/<nombre>` | `shared` u `owned` | Ambas | Identifica qué cluster usa la subred |

Sin estos tags, `kubectl apply` de un Service de tipo LoadBalancer fallará silenciosamente.

---

## 1.8 Bloques CIDR Secundarios: Escalar sin Migrar

¿Y si la VPC original se quedó pequeña? No es necesario migrar toda la infraestructura a una nueva VPC. AWS permite añadir **hasta 4 bloques CIDR secundarios**:

```hcl
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"
}

# Bloque adicional: espacio extra sin tocar la VPC original
resource "aws_vpc_ipv4_cidr_block_association" "secondary" {
  vpc_id     = aws_vpc.main.id
  cidr_block = "100.64.0.0/16"   # RFC 6598: espacio de uso compartido, no rutable en Internet

  depends_on = [aws_vpc.main]    # Asegura que la VPC exista antes de asociar
}
```

> Los rangos `100.64.0.0/10` (RFC 6598) son populares para expansiones de VPC porque no solapan con redes corporativas típicas y no son enrutables en Internet.

---

## 1.9 IPv6 Dual-Stack: El Futuro Ya Llegó

AWS asigna automáticamente un bloque `/56` de IPv6 público a tu VPC cuando lo solicitas. Cada subred recibe un `/64`:

```hcl
resource "aws_vpc" "main" {
  cidr_block                       = "10.0.0.0/16"
  assign_generated_ipv6_cidr_block = true   # AWS asigna un /56 de IPv6 automáticamente
}

resource "aws_subnet" "public_ipv6" {
  vpc_id          = aws_vpc.main.id
  cidr_block      = cidrsubnet(aws_vpc.main.cidr_block, 8, 0)
  ipv6_cidr_block = cidrsubnet(aws_vpc.main.ipv6_cidr_block, 8, 0)  # /64 de IPv6

  assign_ipv6_address_on_creation = true   # Recursos en esta subred obtienen IPv6

  tags = { Name = "public-dualstack" }
}
```

En IPv6, cada recurso tiene una IP globalmente enrutable — no hay NAT. Para controlar el tráfico saliente sin permitir conexiones entrantes, se usa el **Egress-Only Internet Gateway** (ver sección 2).

---

## 1.10 La VPC por Defecto: `aws_default_vpc`

AWS crea automáticamente una VPC por defecto en cada región con CIDR `172.31.0.0/16`. No deberías usarla en producción, pero si alguien ha creado recursos ahí, no puedes borrarla con Terraform directamente.

`aws_default_vpc` **importa y gestiona** la VPC por defecto sin crear una nueva:

```hcl
resource "aws_default_vpc" "default" {
  # Gestiona sin crear. Permite añadir tags y gestionar como código.
  tags = {
    Name = "default-vpc-no-usar"
  }
}
```

> La VPC por defecto tiene subredes públicas por defecto — todo recurso obtiene IP pública. Para entornos empresariales, la práctica recomendada es dejarla vacía o eliminarla manualmente y gestionar solo VPCs custom.

---

## 1.11 Postconditions: Validación de Red como Código

Con Terraform 1.2+ puedes añadir validaciones automáticas a tus recursos usando bloques `postcondition`. Esto garantiza que el CIDR de la VPC sea siempre un rango RFC 1918 válido:

```hcl
resource "aws_vpc" "main" {
  cidr_block = var.vpc_cidr

  lifecycle {
    postcondition {
      # Falla el plan si el CIDR no es RFC 1918
      condition = anytrue([
        startswith(self.cidr_block, "10."),
        startswith(self.cidr_block, "172.16."),
        startswith(self.cidr_block, "192.168.")
      ])
      error_message = "El CIDR de la VPC debe ser un rango RFC 1918 privado."
    }
  }
}
```

Si alguien intenta desplegar una VPC con un CIDR público por error, el plan fallará con un mensaje claro antes de que se cree cualquier recurso.

---

## 1.12 Resumen: Los Cimientos de tu Red en AWS

```
VPC (Contenedor)
 ├── CIDR: 10.0.0.0/16  (RFC 1918, planificado, no cambiable fácilmente)
 ├── DNS: enable_dns_hostnames = true  (obligatorio para la mayoría de servicios)
 │
 ├── Subredes Públicas (por AZ)
 │    ├── 10.0.0.0/24  (AZ-a)
 │    ├── 10.0.1.0/24  (AZ-b)
 │    └── 10.0.2.0/24  (AZ-c)
 │
 ├── Subredes Privadas (por AZ)
 │    ├── 10.0.10.0/24 (AZ-a)
 │    ├── 10.0.11.0/24 (AZ-b)
 │    └── 10.0.12.0/24 (AZ-c)
 │
 └── Subredes de Datos (por AZ)
      ├── 10.0.20.0/24 (AZ-a)
      └── 10.0.21.0/24 (AZ-b)
```

| Recurso | Función |
|---------|---------|
| `aws_vpc` | Contenedor de red con CIDR, DNS y tenancy |
| `aws_subnet` | Segmento en una AZ con su propio CIDR |
| `cidrsubnet()` | Calcula subredes automáticamente |
| `aws_vpc_ipv4_cidr_block_association` | Añade espacio de IPs sin migrar |
| `aws_default_vpc` | Gestiona la VPC por defecto sin recrearla |

> **Principio:** Un CIDR bien planificado al inicio evita migraciones dolorosas al crecer. Trata el diseño de red como una decisión arquitectónica de primera clase — es el único componente de AWS que realmente no puedes modificar en caliente.

---

> **Siguiente:** [Sección 2 — Internet Gateway, NAT y VPC Endpoints →](./02_gateways_endpoints.md)
