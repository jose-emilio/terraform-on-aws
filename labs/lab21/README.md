# Laboratorio 21 — Zonas Hospedadas Privadas y Resolución DNS

[← Módulo 5 — Networking en AWS con Terraform](../../modulos/modulo-05/README.md)


## Visión general

Implementar un sistema de nombres interno (`.internal`) sin necesidad de un dominio comprado en Internet, utilizando una **Zona Hospedada Privada** en Route 53. Verificar que los nombres solo resuelven desde dentro de la VPC.

## Conceptos clave

| Concepto | Descripción |
|---|---|
| **Route 53** | Servicio de DNS gestionado de AWS. Además de dominios públicos, permite crear zonas privadas visibles solo dentro de una o más VPCs |
| **Zona Hospedada Privada (PHZ)** | Zona DNS que solo responde a consultas originadas desde las VPCs asociadas. Ideal para nombres internos como `db.app.internal` o `api.corp` sin registrar un dominio |
| **Registro A** | Registro DNS que mapea un nombre a una dirección IPv4. En Route 53, puede ser un registro A simple (IP fija) o un Alias (apunta a un recurso AWS como un ALB) |
| **Registro Alias** | Extensión de Route 53 que permite apuntar un nombre a un recurso AWS (ALB, CloudFront, S3, etc.) en vez de a una IP. No tiene coste adicional por consultas y resuelve automáticamente la IP del recurso |
| **VPC DNS Resolution** | `enable_dns_support = true` activa el resolutor DNS de AWS en la VPC (servidor `169.254.169.253`). `enable_dns_hostnames = true` asigna nombres DNS públicos a las instancias con IP pública |
| **Split-horizon DNS** | Patrón donde un mismo nombre resuelve a IPs diferentes según desde donde se consulte: IP privada dentro de la VPC, IP pública desde Internet (requiere zona pública adicional) |

## Prerrequisitos

- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.5

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
echo "Bucket: $BUCKET"
```

## Estructura del proyecto

```
lab21/
├── README.md                    <- Esta guía
├── aws/
│   ├── providers.tf             <- Backend S3 parcial
│   ├── variables.tf             <- Variables: región, CIDR, proyecto, dominio interno
│   ├── main.tf                  <- VPC + ALB + EC2 + Route 53 PHZ + registros DNS
│   ├── outputs.tf               <- Zona hospedada, nombres DNS, IPs
│   └── aws.s3.tfbackend         <- Parámetros del backend (sin bucket)
└── localstack/
    ├── README.md                <- Guía específica para LocalStack
    ├── providers.tf
    ├── variables.tf
    ├── main.tf                  <- VPC + Route 53 PHZ (sin ALB en Community)
    ├── outputs.tf
    └── localstack.s3.tfbackend  <- Backend completo para LocalStack
```

## 1. Análisis del código

### 1.1 Arquitectura del laboratorio

```
                    VPC (10.17.0.0/16)
                    ┌─────────────────────────────────────┐
                    │                                     │
                    │   Route 53 Private Hosted Zone      │
                    │   app.internal                      │
                    │   ┌────────────────────────────┐    │
                    │   │ web.app.internal → ALB     │    │
                    │   │ db.app.internal  → 10.17.x │    │
                    │   └────────────────────────────┘    │
                    │                                     │
                    │   ┌──────────┐    ┌──────────┐      │
                    │   │ EC2 web  │    │ EC2 test │      │
                    │   │ (httpd)  │    │ (nslookup│      │
                    │   └────┬─────┘    │  dig)    │      │
                    │        │          └──────────┘      │
                    │        │                            │
                    │   ┌────▼─────┐                      │
                    │   │   ALB    │                      │
                    │   └──────────┘                      │
                    └─────────────────────────────────────┘
```

Una VPC con:
- Una **Zona Hospedada Privada** `app.internal` asociada a la VPC
- Un registro **Alias** `web.app.internal` que apunta al ALB
- Un registro **A** `db.app.internal` que apunta a la IP privada de una instancia (simulando una DB)
- Una instancia de test para verificar la resolucion DNS con `nslookup` y `dig`

### 1.2 Zona Hospedada Privada — DNS solo interno

```hcl
resource "aws_route53_zone" "internal" {
  name = var.internal_domain

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = merge(local.common_tags, {
    Name = "phz-${var.internal_domain}-${var.project_name}"
  })
}
```

Puntos clave:
- El bloque `vpc {}` convierte la zona en **privada**. Sin él, sería una zona pública accesible desde Internet
- Solo las instancias dentro de las VPCs asociadas pueden resolver los nombres de esta zona
- No se necesita comprar ni registrar el dominio `.internal` — es un nombre arbitrario que solo existe dentro de la VPC
- Se puede asociar la misma zona a múltiples VPCs (incluso en otras cuentas)

**¿Por qué `.internal` y no `.local`?**

`.local` está reservado para mDNS (Multicast DNS) y puede causar conflictos. AWS recomienda usar TLDs como `.internal`, `.corp`, `.private` o dominios propios con un subdominio dedicado (ej: `internal.miempresa.com`).

### 1.3 Registro Alias — Apuntar al ALB

```hcl
resource "aws_route53_record" "web" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "web.${var.internal_domain}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}
```

Un registro Alias es diferente de un CNAME:

| Aspecto | CNAME | Alias |
|---|---|---|
| Destino | Cualquier nombre DNS | Solo recursos AWS (ALB, CloudFront, S3...) |
| Apex domain | No permitido (`app.internal` no puede ser CNAME) | Sí permitido |
| Coste por consulta | $0.40/millón | $0 (gratuito) |
| Resolución | Dos consultas DNS (CNAME → IP) | Una consulta (resuelve directo a IP) |

`evaluate_target_health = true` hace que Route 53 deje de responder con este registro si el ALB no tiene targets sanos, evitando enviar tráfico a un servicio caído.

### 1.4 Registro A — IP fija para la "base de datos"

```hcl
resource "aws_route53_record" "db" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "db.${var.internal_domain}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.db.private_ip]
}
```

Un registro A simple que mapea `db.app.internal` a la IP privada de la instancia. El TTL de 300 segundos (5 minutos) indica cuánto tiempo los clientes DNS deben cachear la respuesta.

> **Nota:** En producción, para una base de datos RDS se usaría un registro Alias apuntando al endpoint de RDS en vez de una IP fija. Las IPs de las instancias EC2 cambian si se detienen y reinician.

### 1.5 VPC DNS — Requisitos

```hcl
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true    # Activa el resolutor DNS de AWS
  enable_dns_hostnames = true    # Asigna nombres DNS a instancias
}
```

Ambas opciones deben estar habilitadas para que Route 53 Private Hosted Zones funcione:

- **`enable_dns_support`**: Sin esto, las instancias no pueden resolver ningún nombre DNS (ni público ni privado)
- **`enable_dns_hostnames`**: Sin esto, las instancias no reciben un nombre DNS automático (como `ip-10-17-10-10.ec2.internal`)

---

## 2. Despliegue

```bash
cd labs/lab21/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform apply
```

Terraform creará ~25 recursos: VPC, subredes, IGW, NAT Gateway, ALB, instancias EC2, Route 53 PHZ, registros DNS, IAM role SSM.

```bash
terraform output
# zone_id                = "Z0123456789ABCDEF"
# internal_domain        = "app.internal"
# web_fqdn               = "web.app.internal"
# db_fqdn                = "db.app.internal"
# db_private_ip          = "10.17.10.10"
# alb_dns_name           = "lab21-alb-xxxxxxxxx.us-east-1.elb.amazonaws.com"
# test_instance_id       = "i-0abc..."
```

---

## Verificación final

### 3.1 Zona Hospedada Privada

Verificar que la zona existe y está asociada a la VPC:

```bash
ZONE_ID=$(terraform output -raw zone_id)

aws route53 get-hosted-zone \
  --id $ZONE_ID \
  --query '{Name: HostedZone.Name, Private: HostedZone.Config.PrivateZone, VPCs: VPCs[].VPCId}' \
  --output json
```

Debe mostrar `PrivateZone: true` y el ID de la VPC.

### 3.2 Registros DNS

Listar los registros de la zona:

```bash
aws route53 list-resource-record-sets \
  --hosted-zone-id $ZONE_ID \
  --query 'ResourceRecordSets[].{Name: Name, Type: Type, AliasTarget: AliasTarget.DNSName, Records: ResourceRecords[].Value}' \
  --output table
```

Deberías ver:
- `web.app.internal.` tipo A (Alias → ALB)
- `db.app.internal.` tipo A (IP privada)
- `app.internal.` tipo NS y SOA (creados automáticamente)

### 3.3 Verificar resolucion DNS desde dentro de la VPC

Conectarse a la instancia de test via SSM:

```bash
INSTANCE_TEST=$(terraform output -raw test_instance_id)

aws ssm start-session --target $INSTANCE_TEST
```

Una vez dentro de la sesión:

```bash
# Test 1: Resolver web.app.internal (debe devolver IPs del ALB)
nslookup web.app.internal
# Server:    10.17.0.2 (resolutor DNS de la VPC)
# Address:   10.17.0.2#53
# Name:      web.app.internal
# Address:   10.17.x.x (IPs privadas del ALB)

# Test 2: Resolver db.app.internal (debe devolver la IP fija de la instancia)
nslookup db.app.internal
# Address:   10.17.10.10

# Test 3: Usar dig para ver más detalles (TTL, tipo de registro)
dig web.app.internal
dig db.app.internal +short

# Test 4: Verificar que la aplicación responde via el nombre DNS
curl -s http://web.app.internal
# Debe mostrar la página de la instancia web

# Test 5: Verificar que el nombre NO resuelve desde Internet
# (esto no se puede probar desde dentro de la VPC, pero se puede
#  intentar resolver un nombre de la zona pública para comparar)

exit
```

### 3.4 Verificar que el nombre no resuelve desde fuera

Desde tu máquina local (fuera de la VPC):

```bash
nslookup web.app.internal
# ** server can't find web.app.internal: NXDOMAIN

dig web.app.internal
# status: NXDOMAIN (el nombre no existe fuera de la VPC)
```

Esto confirma que la zona es **estrictamente privada** — los nombres solo existen dentro de las VPCs asociadas.

---

## 4. Reto: Ampliar la zona con nuevos registros y comparar tipos

**Situación**: El equipo de desarrollo necesita registros DNS internos adicionales para sus microservicios. Quieren entender las diferencias prácticas entre registros A, CNAME y Alias dentro de la zona privada.

**Tu objetivo**:

1. Crear un registro A `api.app.internal` que apunte directamente a la IP privada de la instancia web (acceso directo sin ALB)
2. Crear un registro CNAME `api-lb.app.internal` que apunte al DNS interno del ALB (`aws_lb.main.dns_name`)
3. Desde la instancia de test, comparar con `dig` el comportamiento de los tres registros:
   - `web.app.internal` (Alias → ALB): resuelve directo a IP en una consulta
   - `api.app.internal` (A → IP fija): resuelve directo a IP en una consulta
   - `api-lb.app.internal` (CNAME → ALB DNS): resuelve en dos pasos (CNAME + resolucion del target)
**Pistas**:
- No puedes tener un CNAME y un A para el mismo nombre — usa nombres diferentes (`api` vs `api-lb`)
- `dig +short` muestra solo la respuesta, `dig` completo muestra la sección ANSWER con el tipo de registro
- Un CNAME en el apex del dominio (`app.internal`) no está permitido — solo se puede en subdominios

La solución está en la [sección 5](#5-solucion-del-reto).

---

## 5. Solución del Reto

### Paso 1: Registro A directo

```hcl
resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "api.${var.internal_domain}"
  type    = "A"
  ttl     = 60
  records = [aws_instance.web.private_ip]
}
```

### Paso 2: Registro CNAME hacia el ALB

```hcl
resource "aws_route53_record" "api_lb" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "api-lb.${var.internal_domain}"
  type    = "CNAME"
  ttl     = 300
  records = [aws_lb.main.dns_name]
}
```

### Paso 3: Comparar los tres tipos desde la instancia de test

```bash
aws ssm start-session --target $(terraform output -raw test_instance_id)
```

```bash
# Alias (web) → resuelve directo a IP, sin paso intermedio
dig web.app.internal +short
# 10.17.x.x

# A (api) → resuelve directo a IP fija
dig api.app.internal +short
# 10.17.10.x

# CNAME (api-lb) → primero muestra el CNAME, luego resuelve la IP del target
dig api-lb.app.internal
# ANSWER SECTION:
# api-lb.app.internal. 300 IN CNAME internal-lab21-alb-xxxx.us-east-1.elb.amazonaws.com.
# internal-lab21-alb-xxxx... 60 IN A 10.17.x.x

exit
```

La diferencia clave: el CNAME genera una consulta adicional (resolución del target), mientras que Alias y A resuelven en un solo paso. Además, el CNAME expone el nombre DNS del ALB al cliente, mientras que el Alias lo oculta.

---

## 6. Reto 2: Delegación de subdominio a otra zona privada

**Situación**: El equipo de base de datos quiere gestionar sus propios registros DNS bajo `db.app.internal` de forma independiente, sin depender del equipo de plataforma que administra la zona `app.internal`. Necesitan una zona privada delegada donde puedan crear registros como `primary.db.app.internal` y `replica.db.app.internal` autónomamente.

**Tu objetivo**:

1. Crear una segunda Zona Hospedada Privada para el subdominio `db.app.internal`, asociada a la misma VPC
2. Eliminar el registro A `db.app.internal` de la zona padre (no puede coexistir un A y un NS para el mismo nombre)
3. En la zona padre (`app.internal`), crear un registro NS que delegue `db.app.internal` a los nameservers de la zona hija
4. Crear registros A en la zona hija: `primary.db.app.internal` → IP privada de la instancia db, y `replica.db.app.internal` → otra IP (puede ser ficticia como `10.17.10.20`)
5. Verificar desde la instancia de test que `primary.db.app.internal` y `replica.db.app.internal` resuelven correctamente con `dig`, y que `db.app.internal` ya no resuelve (el registro A fue eliminado y la delegacion NS solo aplica a subdominios)

**Pistas**:
- La zona hija tiene sus propios nameservers (atributo `name_servers` del recurso `aws_route53_zone`)
- El registro NS en la zona padre debe apuntar a esos nameservers exactos
- Ambas zonas deben estar asociadas a la misma VPC
- La delegación permite que cada equipo gestione su subdominio con permisos IAM independientes

La solución está en la [sección 7](#7-solucion-del-reto-2).

---

## 7. Solución del Reto 2

### Paso 1: Zona hija para db.app.internal

```hcl
resource "aws_route53_zone" "db" {
  name = "db.${var.internal_domain}"

  vpc {
    vpc_id = aws_vpc.main.id
  }

  tags = merge(local.common_tags, {
    Name = "phz-db-${var.internal_domain}-${var.project_name}"
  })
}
```

### Paso 2: Eliminar el registro A de db.app.internal en la zona padre

El registro A `db.app.internal` creado en el laboratorio base entra en conflicto con la delegacion — no puede existir un registro A y un NS para el mismo nombre. Eliminar o comentar el recurso `aws_route53_record.db` de `main.tf`:

```hcl
# ELIMINAR:
# resource "aws_route53_record" "db" {
#   zone_id = aws_route53_zone.internal.zone_id
#   name    = "db.${var.internal_domain}"
#   type    = "A"
#   ttl     = 300
#   records = [aws_instance.db.private_ip]
# }
```

### Paso 3: Registro NS en la zona padre (delegación)

```hcl
resource "aws_route53_record" "db_delegation" {
  zone_id = aws_route53_zone.internal.zone_id
  name    = "db.${var.internal_domain}"
  type    = "NS"
  ttl     = 300
  records = aws_route53_zone.db.name_servers
}
```

Este registro le dice al resolutor DNS de la VPC: "para cualquier consulta bajo `db.app.internal`, pregunta a los nameservers de la zona hija".

### Paso 4: Registros en la zona hija

```hcl
resource "aws_route53_record" "db_primary" {
  zone_id = aws_route53_zone.db.zone_id
  name    = "primary.db.${var.internal_domain}"
  type    = "A"
  ttl     = 300
  records = [aws_instance.db.private_ip]
}

resource "aws_route53_record" "db_replica" {
  zone_id = aws_route53_zone.db.zone_id
  name    = "replica.db.${var.internal_domain}"
  type    = "A"
  ttl     = 300
  records = ["10.17.10.20"]
}
```

### Paso 5: Verificar

```bash
terraform apply

aws ssm start-session --target $(terraform output -raw test_instance_id)
```

```bash
# Registros de la zona hija (delegada)
dig primary.db.app.internal +short
# 10.17.10.10

dig replica.db.app.internal +short
# 10.17.10.20

# db.app.internal ya no resuelve (se eliminó el registro A de la zona padre
# y la delegación NS solo aplica a subdominios como primary.db.app.internal)
dig db.app.internal +short
# (sin respuesta)

exit
```

### Reflexión: ¿cuándo delegar?

| Escenario | Zona única | Delegación |
|---|---|---|
| Equipo pequeño, pocos registros | Sí | Innecesario |
| Múltiples equipos, autonomía | Complejo (permisos compartidos) | Sí (permisos IAM por zona) |
| Entornos separados (dev/prod) | Riesgo de errores cruzados | Sí (una zona por entorno) |
| Microservicios con nombres propios | Zona grande, difícil de gestionar | Sí (un subdominio por servicio) |

La delegación permite que cada equipo gestione su subdominio con políticas IAM independientes, reduciendo el riesgo de que un equipo modifique registros de otro.

---

## 8. Limpieza

```bash
terraform destroy \
  -var="region=us-east-1"
```

> **Nota:** No destruyas el bucket S3 (lab02).

---

## 9. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

LocalStack emula Route 53 a nivel de API. El ALB no está disponible en Community, por lo que la versión localstack usa registros A con IPs fijas.

---

## Buenas practicas aplicadas

- **Zona hospedada privada sin dominio público**: crear una PHZ con sufijo `.internal` o `.corp` permite tener un sistema DNS interno completamente controlado sin comprar un dominio en Internet ni exponer nombres internos.
- **Registros Alias para endpoints AWS**: usar registros Alias en lugar de CNAME para ALBs y otros recursos AWS evita el costo adicional de resoluciones DNS y garantiza actualizaciones automáticas si la IP del endpoint cambia.
- **Habilitar `enable_dns_support` y `enable_dns_hostnames` en la VPC**: sin estos dos atributos activos, Route 53 no puede resolver los nombres de la PHZ desde la VPC.
- **`private_zone = true` en data sources de Route 53**: filtrar explícitamente por zonas privadas evita confusiones con zonas públicas del mismo nombre si ambas existen.
- **TTL bajo durante el desarrollo**: durante el laboratorio, un TTL de 60 segundos permite iterar rápidamente en los registros. En producción, aumentarlo reduce la carga en los resolvers DNS.
- **Asociar la PHZ a múltiples VPCs**: las zonas privadas se pueden asociar a varias VPCs de la misma o diferente cuenta, lo que facilita la resolución de nombres en arquitecturas multi-VPC.

---

## Recursos

- [AWS: Route 53 Private Hosted Zones](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zones-private.html)
- [AWS: Choosing Between Alias and Non-Alias Records](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/resource-record-sets-choosing-alias-non-alias.html)
- [AWS: Associating a PHZ with a VPC](https://docs.aws.amazon.com/Route53/latest/DeveloperGuide/hosted-zone-private-associate-vpcs.html)
- [AWS: DNS Resolution in VPCs](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-dns.html)
- [Terraform: `aws_route53_zone`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_zone)
- [Terraform: `aws_route53_record`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_record)
