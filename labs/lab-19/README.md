# Laboratorio 19 — Conectividad Punto a Punto con VPC Peering

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 5 — Networking en AWS con Terraform](../../modulos/modulo-05/README.md)


## Visión general

Establecer un túnel privado entre dos VPCs independientes para permitir la comunicación bidireccional **sin que el tráfico salga nunca a Internet**. Verificar experimentalmente que el peering **no es transitivo** mediante una tercera VPC.

## Conceptos clave

| Concepto | Descripción |
|---|---|
| **VPC Peering** | Conexión de red privada entre dos VPCs que permite enrutar tráfico entre ellas usando IPs privadas. El tráfico nunca sale a Internet ni pasa por gateways intermedios |
| **Requester / Accepter** | Modelo de solicitud: una VPC solicita el peering (requester) y la otra lo acepta (accepter). Con `auto_accept = true` se acepta automáticamente si ambas VPCs están en la misma cuenta y región |
| **No transitividad** | Propiedad fundamental del peering: si A↔B y B↔C, eso **no** implica A↔C. Cada par de VPCs necesita su propio peering. Esto limita la escalabilidad (N VPCs requieren N×(N-1)/2 peerings) |
| **Rutas bidireccionales** | El peering crea el túnel, pero las VPCs necesitan **rutas explícitas** en sus tablas de rutas para saber que deben enviar el tráfico a través del peering. Sin rutas en ambas direcciones, el tráfico no fluye |
| **CIDR no solapado** | Requisito obligatorio: los rangos CIDR de las VPCs no pueden solaparse. AWS rechaza el peering si detecta solapamiento |
| **Referencia por CIDR en SG** | En peering (a diferencia de Transit Gateway), los Security Groups referencian el CIDR de la otra VPC, no su Security Group ID. La referencia cruzada de SGs solo funciona dentro de la misma VPC o con peerings en la misma región si se habilita explícitamente |

## Cuándo usar Peering vs Transit Gateway

| Aspecto | VPC Peering | Transit Gateway |
|---|---|---|
| Topología | Punto a punto | Hub-and-spoke |
| Transitividad | No | Sí |
| Conexiones para 3 VPCs | 3 peerings | 3 attachments |
| Conexiones para 10 VPCs | 45 peerings | 10 attachments |
| Coste base | $0 | ~$36/mes por attachment |
| Coste por GB | $0.01 (cross-AZ/region) | $0.02 por GB procesado |
| Complejidad de rutas | 2 rutas por peering | Propagación automática |
| Inspección centralizada | No nativo | Sí |

> **Regla práctica:** Usa VPC Peering para 2-3 VPCs con conectividad simple y directa. A partir de 4+ VPCs, o si necesitas transitividad, inspección centralizada o conectividad híbrida, usa Transit Gateway (lab20).

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
lab19/
├── README.md                    <- Esta guía
├── aws/
│   ├── providers.tf             <- Backend S3 parcial
│   ├── variables.tf             <- Variables: region, CIDRs, proyecto
│   ├── main.tf                  <- 3 VPCs + 2 peerings + rutas + instancias de test
│   ├── outputs.tf               <- IDs de VPCs, peerings, IPs de test
│   └── aws.s3.tfbackend         <- Parámetros del backend (sin bucket)
└── localstack/
    ├── README.md                <- Guía específica para LocalStack
    ├── providers.tf
    ├── variables.tf
    ├── main.tf                  <- VPCs y peerings (sin trafico real)
    ├── outputs.tf
    └── localstack.s3.tfbackend  <- Backend completo para LocalStack
```

## 1. Análisis del código

### 1.1 Arquitectura del laboratorio

```
┌──────────────┐         VPC Peering          ┌──────────────┐
│   VPC app    │◄────────────────────────────►│   VPC db     │
│ 10.15.0.0/16 │      (bidireccional)         │ 10.16.0.0/16 │
│              │                              │ SG: 3306     │
└──────┬───────┘                              └──────────────┘
       │
       │  VPC Peering
       │  (bidireccional)
       │
┌──────▼───────┐
│   VPC C      │ ─ ─ ─ ✗ ─ ─ ─►  VPC db
│ 10.17.0.0/16 │   NO transitivo
└──────────────┘
```

Tres VPCs con dos peerings:
- **app ↔ db**: comunicación directa (ej. aplicación accede a base de datos)
- **app ↔ vpc-c**: comunicación directa
- **vpc-c ↔ db**: **sin peering** — vpc-c no puede alcanzar db a través de app (no transitividad)

### 1.2 VPC Peering — Solicitud y aceptación

```hcl
resource "aws_vpc_peering_connection" "app_to_db" {
  vpc_id        = aws_vpc.app.id       # Requester
  peer_vpc_id   = aws_vpc.db.id        # Accepter
  auto_accept   = true

  tags = merge(local.common_tags, {
    Name = "peering-app-db-${var.project_name}"
  })
}
```

`auto_accept = true` solo funciona si ambas VPCs están en la **misma cuenta y región**. En un escenario multi-cuenta o cross-region, la cuenta/región accepter debe aceptar la solicitud con `aws_vpc_peering_connection_accepter`.

**¿Qué pasa si los CIDRs se solapan?**

AWS rechaza la solicitud de peering con el error `InvalidParameterValue: CIDRs overlap`. Por eso es crítico planificar los rangos CIDR antes de crear las VPCs. En este lab usamos rangos claramente separados:
- app: `10.15.0.0/16`
- db: `10.16.0.0/16`
- vpc-c: `10.17.0.0/16`

### 1.3 Enrutamiento — El paso crítico

```hcl
# app → db: el tráfico hacia 10.16.0.0/16 va por el peering
resource "aws_route" "app_to_db" {
  route_table_id            = aws_route_table.app.id
  destination_cidr_block    = var.db_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_db.id
}

# db → app: ruta de retorno (sin ella, las respuestas se pierden)
resource "aws_route" "db_to_app" {
  route_table_id            = aws_route_table.db.id
  destination_cidr_block    = var.app_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.app_to_db.id
}
```

**Importante:** Las rutas deben apuntar al **CIDR específico** de la VPC peer, no a `0.0.0.0/0`. El peering solo permite tráfico cuyo destino sea el CIDR de la otra VPC — AWS descarta paquetes con destino fuera de ese rango (por ejemplo, tráfico a Internet).

**Error más común con peering:** Crear el peering y olvidar las rutas. El peering aparece como `Active` en la consola, pero el tráfico no fluye porque las VPCs no saben que deben enviar los paquetes por el peering. Cada VPC necesita una ruta explícita hacia el CIDR de la otra VPC usando el ID del peering como target.

**¿Por qué rutas bidireccionales?**

TCP requiere comunicación en ambas direcciones (SYN → SYN-ACK → ACK). Si solo app tiene ruta hacia db, el paquete SYN llega a db, pero el SYN-ACK no puede volver porque db no tiene ruta hacia app. El resultado es un timeout de conexión.

### 1.4 Security Group — Acceso por CIDR

```hcl
resource "aws_security_group" "db" {
  name        = "db-${var.project_name}"
  description = "Permite MySQL desde VPC app"
  vpc_id      = aws_vpc.db.id

  ingress {
    from_port   = 3306
    to_port     = 3306
    protocol    = "tcp"
    cidr_blocks = [var.app_cidr]
    description = "MySQL desde VPC app"
  }
}
```

A diferencia del patrón ALB → EC2 (lab18) donde se referencia el Security Group ID, en peering se usa el **CIDR de la otra VPC** como origen. Esto permite que solo las instancias de vpc-app puedan conectarse al puerto 3306 de las instancias en vpc-db.

### 1.5 No transitividad — Por qué vpc-c no puede hablar con db

```
vpc-c (10.17.0.0/16)
   │
   │  peering con app ✓
   │  ruta: 10.15.0.0/16 → peering-app-c
   │
   ▼
vpc-app (10.15.0.0/16)
   │
   │  peering con db ✓
   │  ruta: 10.16.0.0/16 → peering-app-db
   │
   ▼
vpc-db (10.16.0.0/16)
```

Aunque vpc-c tiene peering con app, y app tiene peering con db, vpc-c **no puede** enviar tráfico a db a través de app. ¿Por qué?

1. vpc-c envía un paquete a `10.16.0.0/16` (db)
2. La tabla de rutas de vpc-c **no tiene** ruta hacia `10.16.0.0/16` → el paquete se descarta
3. Incluso si añadiéramos una ruta `10.16.0.0/16 → peering-app-c`, el paquete llegaría a app pero app **no reenvía** tráfico entre peerings — AWS lo descarta explícitamente

Esta es una restricción a nivel de la plataforma AWS, no de configuración. El peering es **estrictamente punto a punto**. Para conectividad transitiva, se necesita Transit Gateway (lab20).

### 1.6 Acceso SSM sin salida a Internet — AMI con SSM + VPC Endpoints

vpc-db y vpc-c no tienen IGW ni NAT Gateway, y **el peering no permite reenviar tráfico a Internet** — solo permite tráfico cuyo destino sea el CIDR de la VPC peer. Para poder conectarse a las instancias via SSM Session Manager se combinan dos estrategias:

1. **AMI con SSM Agent preinstalado:** Se usa Amazon Linux 2023 estándar (no `minimal`) que incluye el SSM Agent de fábrica. Así no se necesita descargar nada en el arranque.
2. **VPC Interface Endpoints (PrivateLink):** El agente SSM necesita conectarse a los servicios `ssm`, `ssmmessages` y `ec2messages` de AWS para registrarse. Sin Internet, se crean 3 endpoints por VPC que resuelven estos servicios a IPs privadas dentro de la VPC.

```hcl
resource "aws_vpc_endpoint" "db_ssm" {
  for_each = toset(["ssm", "ssmmessages", "ec2messages"])

  vpc_id              = aws_vpc.db.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = [for k, s in aws_subnet.db : s.id]
  security_group_ids  = [aws_security_group.ssm_endpoints_db.id]
  private_dns_enabled = true
}
```

> **Nota:** vpc-app tiene IGW + NAT Gateway, por lo que su SSM Agent sale directamente por Internet sin necesidad de endpoints.

---

## 2. Despliegue

```bash
cd labs/lab19/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform apply
```

Terraform creará ~35 recursos: 3 VPCs, subredes, IGW, NAT Gateway, 2 peerings, rutas bidireccionales, Security Groups, IAM role SSM e instancias de test.

```bash
terraform output
# peering_app_db_id            = "pcx-0abc..."
# peering_app_c_id             = "pcx-0def..."
# app_vpc_id                   = "vpc-0aaa..."
# db_vpc_id                    = "vpc-0bbb..."
# c_vpc_id                     = "vpc-0ccc..."
# test_instance_app_id         = "i-0aaa..."
# test_instance_db_id          = "i-0bbb..."
# test_instance_c_id           = "i-0ccc..."
# test_instance_app_private_ip = "10.15.10.10"
# test_instance_db_private_ip  = "10.16.10.10"
# test_instance_c_private_ip   = "10.17.10.10"
```

---

## Verificación final

### 3.1 Estado de los peerings

Verificar que ambos peerings están en estado `active`:

```bash
aws ec2 describe-vpc-peering-connections \
  --filters Name=tag:Project,Values=lab19 \
  --query 'VpcPeeringConnections[].{Name: Tags[?Key==`Name`].Value|[0], ID: VpcPeeringConnectionId, Status: Status.Code}' \
  --output table
```

Deberías ver 2 peerings en estado `active`.

### 3.2 Tablas de rutas

Verificar que las rutas bidireccionales estan configuradas:

```bash
aws ec2 describe-route-tables \
  --filters Name=tag:Project,Values=lab19 \
  --query 'RouteTables[].{Name: Tags[?Key==`Name`].Value|[0], PeeringRoutes: Routes[?VpcPeeringConnectionId!=null].{Dest: DestinationCidrBlock, Peering: VpcPeeringConnectionId}}' \
  --output json
```

Cada tabla de rutas debe tener rutas hacia los CIDRs de las VPCs con las que tiene peering.

### 3.3 Security Group de db

Verificar que el SG de db permite MySQL (3306) desde el CIDR de app:

```bash
DB_SG=$(terraform output -raw db_sg_id)

aws ec2 describe-security-groups \
  --group-ids $DB_SG \
  --query 'SecurityGroups[].IpPermissions[].{Port: FromPort, CIDR: IpRanges[].CidrIp}' \
  --output json
```

### 3.4 Conectividad app ↔ db (debe funcionar)

```bash
INSTANCE_APP=$(terraform output -raw test_instance_app_id)

aws ssm start-session --target $INSTANCE_APP
```

Una vez dentro de la sesión:

```bash
# Ping a db (debe funcionar — hay peering + rutas + SG)
ping -c 3 10.16.10.10

# Verificar salida a Internet
curl -s --max-time 5 https://checkip.amazonaws.com

exit
```

### 3.5 Conectividad vpc-c → db (debe fallar — no transitivo)

Conectarse a la instancia en vpc-c via SSM (funciona gracias a los VPC Endpoints):

```bash
INSTANCE_C=$(terraform output -raw test_instance_c_id)

aws ssm start-session --target $INSTANCE_C
```

Una vez dentro de la sesión:

```bash
# Ping a app (debe funcionar — hay peering directo)
ping -c 3 10.15.10.10

# Ping a db (debe FALLAR — no hay peering vpc-c ↔ db)
ping -c 3 -W 2 10.16.10.10
# 100% packet loss

exit
```

Este es el momento clave del laboratorio: vpc-c puede hablar con app (peering directo), pero **no puede** hablar con db a través de app. El peering no es transitivo.

También se puede verificar desde vpc-db:

```bash
INSTANCE_DB=$(terraform output -raw test_instance_db_id)

aws ssm start-session --target $INSTANCE_DB
```

```bash
# Ping a app (debe funcionar — hay peering directo)
ping -c 3 10.15.10.10

# Ping a vpc-c (debe FALLAR — no hay peering db ↔ vpc-c)
ping -c 3 -W 2 10.17.10.10
# 100% packet loss

exit
```

### 3.6 Si SSM no conecta

Si `start-session` se queda colgado, esperar 2-3 minutos para que el SSM Agent se registre:

```bash
aws ssm describe-instance-information \
  --filters Key=InstanceIds,Values=$(terraform output -raw test_instance_app_id) \
  --query 'InstanceInformationList[].{ID: InstanceId, Ping: PingStatus}' \
  --output table
```

---

## 4. Reto: Resolver la no transitividad con un peering directo

**Situación**: El equipo necesita que vpc-c acceda a la base de datos en vpc-db. Actualmente no puede porque el peering no es transitivo.

**Tu objetivo**:

1. Crear un tercer peering entre vpc-c y vpc-db (`aws_vpc_peering_connection`)
2. Añadir las rutas bidireccionales en las tablas de rutas de vpc-c y vpc-db
3. Actualizar el Security Group de db para permitir tráfico desde el CIDR de vpc-c en el puerto 3306
4. Verificar que vpc-c puede hacer ping a db
5. Reflexionar: ahora tienes 3 peerings para 3 VPCs. ¿Cuántos peerings necesitarías para 10 VPCs? (Respuesta: 45). ¿Y para 20? (190). Este es el problema que resuelve Transit Gateway.

**Pistas**:
- El tercer peering sigue el mismo patron que los dos existentes
- Necesitas 2 rutas nuevas (vpc-c → db y db → vpc-c) y 1 regla de SG
- La formula para peerings en una malla completa es N×(N-1)/2

La solución está en la [sección 5](#5-solucion-del-reto).

---

## 5. Solución del Reto

### Paso 1: Crear el tercer peering

```hcl
resource "aws_vpc_peering_connection" "c_to_db" {
  vpc_id      = aws_vpc.c.id
  peer_vpc_id = aws_vpc.db.id
  auto_accept = true

  tags = merge(local.common_tags, {
    Name = "peering-c-db-${var.project_name}"
  })
}
```

### Paso 2: Rutas bidireccionales

```hcl
resource "aws_route" "c_to_db" {
  route_table_id            = aws_route_table.c.id
  destination_cidr_block    = var.db_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.c_to_db.id
}

resource "aws_route" "db_to_c" {
  route_table_id            = aws_route_table.db.id
  destination_cidr_block    = var.c_cidr
  vpc_peering_connection_id = aws_vpc_peering_connection.c_to_db.id
}
```

### Paso 3: Actualizar el Security Group de db

El peering y las rutas permiten que los paquetes lleguen a vpc-db, pero el Security Group es la última barrera. Actualmente, el SG de db solo permite ICMP y MySQL desde `var.app_cidr`. El tráfico desde vpc-c (`10.17.0.0/16`) será descartado por el SG aunque tenga peering y rutas.

Hay que añadir reglas ingress para el CIDR de vpc-c. En el recurso `aws_security_group.db` de `main.tf`, añadir estos dos bloques `ingress` junto a los existentes:

```hcl
ingress {
  from_port   = 3306
  to_port     = 3306
  protocol    = "tcp"
  cidr_blocks = [var.c_cidr]
  description = "MySQL desde VPC C"
}

ingress {
  from_port   = -1
  to_port     = -1
  protocol    = "icmp"
  cidr_blocks = [var.c_cidr]
  description = "ICMP desde VPC C"
}
```

Sin la regla ICMP, el ping de verificación fallaría aunque el peering y las rutas estén correctos — un error fácil de confundir con un problema de red cuando en realidad es el Security Group.

También hay que actualizar el SG de vpc-c para permitir tráfico desde db. Actualmente solo acepta ICMP desde `var.app_cidr`. Si db necesita iniciar conexiones hacia vpc-c, el SG lo bloquearía. En el recurso `aws_security_group.c`, añadir:

```hcl
ingress {
  from_port   = -1
  to_port     = -1
  protocol    = "icmp"
  cidr_blocks = [var.db_cidr]
  description = "ICMP desde VPC db"
}
```

> **Recordatorio:** Los Security Groups son **stateful** — si vpc-c inicia un ping hacia db y el SG de db lo permite, la respuesta vuelve automáticamente sin necesidad de regla en el SG de vpc-c. Pero si db necesita **iniciar** tráfico hacia vpc-c, sí se necesita la regla explícita.

### Paso 4: Verificar

```bash
terraform apply

INSTANCE_C=$(terraform output -raw test_instance_c_id)
aws ssm start-session --target $INSTANCE_C
```

```bash
# Ahora sí funciona — peering directo vpc-c ↔ db
ping -c 3 10.16.10.10

exit
```

### Reflexión: escalabilidad del peering

| VPCs | Peerings necesarios (malla completa) |
|------|--------------------------------------|
| 3 | 3 |
| 5 | 10 |
| 10 | 45 |
| 20 | 190 |
| 50 | 1.225 |

Cada peering requiere 2 rutas + reglas de SG. Con 20 VPCs serían 190 peerings, 380 rutas y cientos de reglas de SG. Transit Gateway (lab20) resuelve esto con N attachments y propagación automática de rutas.

---

## 6. Limpieza

```bash
terraform destroy \
  -var="region=us-east-1"
```

> **Nota:** No destruyas el bucket S3 (lab02).

---

## 7. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

LocalStack emula VPC Peering a nivel de API pero no ejecuta tráfico real. El objetivo es validar la estructura de Terraform.

---

## Buenas prácticas aplicadas

- **CIDR no solapantes entre VPCs**: el VPC Peering no funciona si los bloques CIDR de las VPCs se solapan. Planificar el espacio de direccionamiento desde el principio evita tener que redesplegar toda la infraestructura de red.
- **Rutas explícitas en ambas tablas de rutas**: el peering es bidireccional pero las rutas no se crean automáticamente. Deben declararse en la tabla de rutas de cada VPC para que el tráfico pueda fluir en ambas direcciones.
- **Aceptación automática con `auto_accept = true`**: solo funciona cuando ambas VPCs pertenecen a la misma cuenta. Para peerings cross-account, el proceso de aceptación debe ser manual o gestionado por un módulo dedicado.
- **`enable_dns_resolution = true` en el peering**: necesario si quieres resolver nombres DNS de recursos en la VPC remota (por ejemplo, endpoints de RDS). Sin esta opción, solo funciona la conectividad por IP.
- **Seguridad via Security Groups**: aunque el peering establece conectividad, el acceso real entre instancias lo controlan los Security Groups. Referenciar el Security Group de la VPC remota en las reglas de ingress es más seguro que abrir rangos CIDR amplios.
- **Documentar la no transitividad**: en arquitecturas con tres o más VPCs, el equipo debe saber que VPC-A puede hablar con VPC-B y VPC-C pero que VPC-B no puede hablar con VPC-C a través de VPC-A. Para transitividad, usar Transit Gateway.

---

## Recursos

- [AWS: VPC Peering](https://docs.aws.amazon.com/vpc/latest/peering/what-is-vpc-peering.html)
- [AWS: VPC Peering Limitations](https://docs.aws.amazon.com/vpc/latest/peering/vpc-peering-basics.html#vpc-peering-limitations)
- [AWS: Invalid VPC Peering Configurations](https://docs.aws.amazon.com/vpc/latest/peering/vpc-peering-basics.html)
- [AWS: Updating Route Tables for Peering](https://docs.aws.amazon.com/vpc/latest/peering/vpc-peering-routing.html)
- [Terraform: `aws_vpc_peering_connection`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_peering_connection)
- [Terraform: `aws_route`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route)
