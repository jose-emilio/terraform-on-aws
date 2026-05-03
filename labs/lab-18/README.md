# Laboratorio 18 — Seguridad y Control de Tráfico en VPC

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 5 — Networking en AWS con Terraform](../../modulos/modulo-05/README.md)


## Visión general

Implementar un modelo de **seguridad por capas** (Capa 7 y Capa 4) utilizando Security Groups y NACLs, aplicando el patrón de diseño ALB -> EC2 con referencia por Security Group, bloques dinámicos, NACLs defensivas y VPC Flow Logs para diagnóstico.

## Conceptos clave

| Concepto | Descripción |
|---|---|
| **Security Group (SG)** | Firewall stateful a nivel de instancia (Capa 4/7). Evalúa solo reglas de permitir; el tráfico de retorno se permite automáticamente. Se pueden encadenar referenciando el ID de otro SG como origen |
| **`source_security_group_id`** | Permite que un SG acepte tráfico solo desde instancias asociadas a otro SG, sin acoplar CIDRs. Patrón clave para ALB -> EC2 |
| **Bloque `dynamic`** | Meta-argumento de Terraform que genera múltiples bloques anidados (como `ingress`) a partir de una lista o mapa, eliminando repetición |
| **Network ACL (NACL)** | Firewall stateless a nivel de subred (Capa 4). Evalúa reglas de permitir y denegar con prioridad numérica. Requiere reglas explícitas para tráfico de retorno (puertos efímeros) |
| **Puertos efímeros** | Rango 1024-65535 usado por clientes para recibir respuestas. Las NACLs, al ser stateless, necesitan permitir estos puertos explícitamente para que el tráfico de retorno funcione |
| **VPC Flow Logs** | Registro del tráfico IP que entra y sale de las interfaces de red de la VPC. Puede capturar todo, solo ACCEPT, o solo REJECT. Se almacena en CloudWatch Logs o S3 |
| **ALB (Application Load Balancer)** | Balanceador de carga en Capa 7 (HTTP/HTTPS) que distribuye tráfico entre instancias en múltiples AZs |

## Modelo de seguridad por capas

```
Internet
   |
   v
[ NACL subred publica ]  <-- Capa 4: bloquea IPs maliciosas antes de llegar al SG
   |
   v
[ SG del ALB ]            <-- Permite HTTP/HTTPS desde Internet
   |
   v
[ NACL subred privada ]   <-- Capa 4: segunda barrera, permite efimeros
   |
   v
[ SG de las EC2 ]         <-- Solo acepta trafico desde el SG del ALB (source_security_group_id)
   |
   v
[ Aplicacion ]
```

> **Defensa en profundidad:** Las NACLs actúan como primera línea (bloqueo de IPs conocidas, rango de puertos). Los Security Groups actúan como segunda línea (referencia por identidad, no por IP). Ambas capas se complementan.

## Prerrequisitos

- lab02 desplegado: bucket `terraform-state-labs-<ACCOUNT_ID>` con versionado habilitado (usado como backend de tfstate)
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.10 (necesario para `use_lockfile` en el backend S3)

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export BUCKET="terraform-state-labs-${ACCOUNT_ID}"
echo "Bucket: $BUCKET"
```

## Estructura del proyecto

```
lab-18/
├── README.md                    <- Esta guía
├── aws/
│   ├── providers.tf             <- Backend S3 parcial
│   ├── variables.tf             <- Variables: región, CIDR, proyecto, puertos, IP bloqueada
│   ├── main.tf                  <- VPC + ALB + EC2 + SGs + NACLs + Flow Logs
│   ├── outputs.tf               <- IDs, DNS del ALB, SG IDs
│   ├── aws.s3.tfbackend         <- Parámetros del backend (sin bucket)
│   └── scripts/
│       └── app_init.sh          <- user_data de las EC2 (httpd + SSM agent)
└── localstack/
    ├── README.md                <- Guía específica para LocalStack
    ├── providers.tf
    ├── variables.tf
    ├── main.tf                  <- Estructura equivalente (sin tráfico real, sin ALB)
    ├── outputs.tf
    └── localstack.s3.tfbackend  <- Backend completo para LocalStack
```

## 1. Análisis del código

### 1.1 Security Group del ALB — Puerta de entrada controlada

El SG se declara "vacío" (sin reglas inline) y cada regla vive en su propio recurso `aws_vpc_security_group_ingress_rule` / `aws_vpc_security_group_egress_rule` (sucesores oficiales de `aws_security_group_rule` desde el provider AWS 5.x):

```hcl
resource "aws_security_group" "alb" {
  name        = "alb-${var.project_name}"
  description = "Trafico HTTP/HTTPS desde Internet"
  vpc_id      = aws_vpc.main.id
}

# Una regla por cada puerto en var.alb_ingress_ports (80 y 443 por defecto).
resource "aws_vpc_security_group_ingress_rule" "alb_ports" {
  for_each = { for p in var.alb_ingress_ports : tostring(p) => p }

  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = each.value
  to_port           = each.value
  ip_protocol       = "tcp"
  description       = "Puerto ${each.value} desde Internet"
}

resource "aws_vpc_security_group_egress_rule" "alb_all" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
```

El recurso `aws_vpc_security_group_ingress_rule` se crea con `for_each` sobre `var.alb_ingress_ports` (por defecto `[80, 443]`), generando una regla por puerto. Si en el futuro necesitas abrir el 8080, basta con añadir el valor a la lista — sin tocar nada más. Cada regla queda con su propio address en el state (`aws_vpc_security_group_ingress_rule.alb_ports["80"]`, `["443"]`), lo que permite gestionarlas con `lifecycle`, importarlas o destruirlas individualmente.

> **Nota sobre el puerto 443:** el SG y la NACL abren tanto 80 como 443 para reflejar el patrón habitual en producción, pero **el ALB de este laboratorio solo expone un listener HTTP en el puerto 80** (no se configura listener HTTPS porque eso requiere un certificado ACM, fuera del alcance del lab). Una conexión a `https://<alb_dns>` será rechazada por el ALB aunque el tráfico atraviese el SG y la NACL: el handshake TLS falla porque no hay nadie escuchando en 443. Mantenemos la regla 443 abierta como ejemplo de configuración defensiva: cuando añadas el listener HTTPS y el certificado, no tendrás que tocar ni el SG ni la NACL.

**¿Por qué `for_each` sobre la variable y no reglas fijas?**

Con reglas fijas, cada nuevo puerto requiere copiar y pegar un recurso completo. Con `for_each` parametrizado, la lista de puertos es una variable que puede cambiar por entorno (dev podría abrir el 8080 para depuración; producción solo 80 y 443) sin duplicación de código.

**¿Por qué reglas en recursos separados en vez de bloques `ingress`/`egress` inline?**

Cuando las reglas son bloques inline dentro de `aws_security_group`, Terraform las gestiona como parte del propio SG. Eso provoca dos problemas frecuentes:
1. **Drift al editar reglas a mano** (consola, CLI, otra herramienta): el siguiente `apply` revierte todo lo que no esté en el código.
2. **Dependencias circulares** cuando dos SGs se referencian mutuamente — Terraform no puede crear el SG-A porque su regla apunta al SG-B y viceversa. Con reglas separadas, los SGs se crean primero (vacíos) y las reglas después, rompiendo el ciclo.

### 1.2 Security Group de las EC2 — Solo tráfico desde el ALB

```hcl
resource "aws_security_group" "app" {
  name        = "app-${var.project_name}"
  description = "Trafico solo desde el ALB"
  vpc_id      = aws_vpc.main.id
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id   # <-- identidad, no IP
  from_port                    = 80
  to_port                      = 80
  ip_protocol                  = "tcp"
  description                  = "HTTP desde el ALB"
}

resource "aws_vpc_security_group_egress_rule" "app_all" {
  security_group_id = aws_security_group.app.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}
```

Punto clave: la regla de entrada usa `referenced_security_group_id` (identidad del SG del ALB) en lugar de `cidr_ipv4`. Esto significa que **solo las instancias asociadas al SG del ALB** pueden enviar tráfico a las EC2 en el puerto 80. Si alguien intenta acceder directamente a la IP de la EC2, el tráfico se descarta.

**Ventaja sobre CIDR:** Si el ALB cambia de IP (por escalado, reemplazo, etc.), la regla sigue funcionando porque referencia la identidad del SG, no una IP fija.

### 1.3 Network ACL — Bloqueo explícito de IP maliciosa

```hcl
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [for k, s in aws_subnet.this : s.id if local.subnets[k].public]

  # Regla 50: Bloquear IP maliciosa (DENY tiene prioridad sobre ALLOW cuando
  # el numero de regla es menor)
  ingress {
    rule_no    = 50
    action     = "deny"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = var.blocked_ip
  }

  # Regla 100: Permitir HTTP
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    from_port  = 80
    to_port    = 80
    cidr_block = "0.0.0.0/0"
  }

  # Regla 110: Permitir HTTPS
  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    from_port  = 443
    to_port    = 443
    cidr_block = "0.0.0.0/0"
  }

  # Regla 120: Puertos efimeros (trafico de retorno)
  ingress {
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    from_port  = 1024
    to_port    = 65535
    cidr_block = "0.0.0.0/0"
  }

  # Regla de salida: las NACLs son stateless, así que el tráfico saliente
  # (incluida la respuesta a las conexiones entrantes permitidas arriba)
  # también necesita una regla allow explícita.
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = "0.0.0.0/0"
  }
}
```

**¿Por qué la regla 50 antes que la 100?**

Las NACLs evalúan reglas en **orden numérico ascendente** y aplican la primera que coincida. La IP maliciosa (`var.blocked_ip`) se bloquea en la regla 50. Aunque la regla 100 permite HTTP desde `0.0.0.0/0`, la IP maliciosa nunca llega a evaluarse contra esa regla porque ya fue denegada.

**¿Por qué puertos efímeros?**

Los Security Groups son **stateful**: si permites tráfico de entrada, el de retorno se permite automáticamente. Las NACLs son **stateless**: cada dirección necesita su propia regla. Sin la regla de puertos efímeros (1024-65535), las respuestas HTTP de las instancias no podrían salir de la subred.

### 1.4 VPC Flow Logs — Solo tráfico REJECT

```hcl
resource "aws_flow_log" "reject" {
  vpc_id               = aws_vpc.main.id
  traffic_type         = "REJECT"
  log_destination_type = "cloud-watch-logs"
  log_destination      = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn         = aws_iam_role.flow_logs.arn
}
```

Capturar solo `REJECT` tiene dos ventajas:
1. **Volumen reducido:** En una VPC activa, el tráfico ACCEPT puede generar GB de logs. REJECT es mucho más reducido y contiene la información de seguridad más valiosa.
2. **Diagnóstico de bloqueos:** Si un servicio no puede conectarse, los logs REJECT muestran exactamente qué regla (SG o NACL) está bloqueando el tráfico.

Los logs se almacenan en un CloudWatch Log Group con retención configurable (por defecto 7 días para el lab).

---

## 2. Despliegue

```bash
cd labs/lab-18/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform apply
```

Terraform creará ~38 recursos: VPC, 4 subredes (2 públicas + 2 privadas), IGW + tabla de rutas pública + asociaciones, EIP + NAT Gateway + tabla de rutas privada + asociaciones, 2 Security Groups (ALB y app) + 5 reglas separadas (2 ingress ALB + 1 egress ALB + 1 ingress app + 1 egress app), 2 NACLs (pública y privada), ALB + Target Group + listener HTTP + 2 attachments, IAM role + policy attachment + instance profile para SSM, 2 instancias EC2, CloudWatch Log Group + IAM role/policy + recurso `aws_flow_log`.

```bash
terraform output
# alb_dns_name     = "lab18-alb-xxxxxxxxx.us-east-1.elb.amazonaws.com"
# alb_sg_id        = "sg-0abc..."
# app_sg_id        = "sg-0def..."
# flow_log_group   = "/vpc/lab18/flow-logs"
```

---

## 3. Verificación final

### 3.1 Verificar el patrón ALB -> EC2 (referencia por SG)

```bash
# Ver el SG de las instancias de aplicacion
APP_SG=$(terraform output -raw app_sg_id)

aws ec2 describe-security-groups \
  --group-ids $APP_SG \
  --query 'SecurityGroups[].IpPermissions[].{Port: FromPort, SourceSG: UserIdGroupPairs[].GroupId}' \
  --output json
```

Deberías ver que el único origen permitido es el SG del ALB (no un CIDR).

### 3.2 Probar el ALB

```bash
ALB_DNS=$(terraform output -raw alb_dns_name)

# Esperar ~2 minutos a que el ALB este activo y los targets sanos
curl -s -o /dev/null -w "%{http_code}" http://$ALB_DNS
# 200
```

### 3.3 Verificar la NACL

```bash
aws ec2 describe-network-acls \
  --filters Name=tag:Project,Values=lab18 \
  --query 'NetworkAcls[].Entries[?RuleAction==`deny`].{RuleNum: RuleNumber, CIDR: CidrBlock, Action: RuleAction}' \
  --output table
```

Deberías ver la regla 50 con `deny` para la IP bloqueada.

### 3.4 Consultar VPC Flow Logs (tráfico REJECT)

```bash
LOG_GROUP=$(terraform output -raw flow_log_group)

# Esperar 5-10 minutos para que los primeros logs aparezcan
aws logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --filter-pattern "REJECT" \
  --max-items 10 \
  --query 'events[].message' \
  --output text
```

Cada línea muestra: interfaz, IP origen, IP destino, puerto origen, puerto destino, protocolo, paquetes, bytes, acción (REJECT).

---

## 4. Reto: WAF básico con NACL dinámica

**Situación**: El equipo de seguridad te proporciona una lista de IPs maliciosas que cambia semanalmente. Necesitas una NACL que bloquee todas esas IPs de forma mantenible, sin copiar y pegar reglas.

**Tu objetivo**:

1. Cambiar la variable `blocked_ip` por una variable `blocked_ips` de tipo `list(string)` con al menos 3 IPs de ejemplo (usa rangos de documentación RFC 5737: `192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`)
2. Usar un bloque `dynamic "ingress"` en la NACL para generar una regla `deny` por cada IP de la lista, asignando números de regla consecutivos (50, 51, 52...)
3. Las reglas de `allow` (HTTP, HTTPS, efímeros) deben mantener números de regla superiores (100+) para que los `deny` siempre tengan prioridad
4. Verificar con `terraform plan` que se generan exactamente N reglas de deny (una por IP bloqueada)
5. Añadir o quitar una IP de la lista y verificar que `terraform plan` solo muestra los cambios incrementales

**Pistas**:
- `dynamic "ingress"` puede iterar sobre una lista con índice: `for_each = var.blocked_ips`
- Usa `50 + index(var.blocked_ips, ingress.value)` para generar números de regla consecutivos
- La NACL completa se define en un solo recurso `aws_network_acl` con múltiples bloques `ingress`

La solución está en la [sección 5](#5-solución-del-reto).

---

## 5. Solución del Reto

### Paso 1: Cambiar la variable

En `variables.tf`, reemplaza `blocked_ip` por `blocked_ips`:

```hcl
variable "blocked_ips" {
  type        = list(string)
  description = "Lista de CIDRs maliciosos a bloquear en la NACL"
  default     = [
    "192.0.2.0/24",     # RFC 5737 - TEST-NET-1
    "198.51.100.0/24",  # RFC 5737 - TEST-NET-2
    "203.0.113.0/24",   # RFC 5737 - TEST-NET-3
  ]
}
```

### Paso 2: Usar `dynamic "ingress"` en la NACL pública

Reemplaza la regla 50 estática por un bloque dinámico que genera una regla `deny` por cada IP de la lista:

```hcl
resource "aws_network_acl" "public" {
  vpc_id     = aws_vpc.main.id
  subnet_ids = [for k, s in aws_subnet.this : s.id if local.subnets[k].public]

  # --- Reglas DENY dinamicas (una por IP bloqueada) ---
  # Los numeros de regla empiezan en 50 y son consecutivos (50, 51, 52...)
  # para que siempre tengan prioridad sobre las reglas ALLOW (100+).
  dynamic "ingress" {
    for_each = var.blocked_ips
    content {
      rule_no    = 50 + index(var.blocked_ips, ingress.value)
      action     = "deny"
      protocol   = "-1"
      from_port  = 0
      to_port    = 0
      cidr_block = ingress.value
    }
  }

  # Regla 100: Permitir HTTP
  ingress {
    rule_no    = 100
    action     = "allow"
    protocol   = "tcp"
    from_port  = 80
    to_port    = 80
    cidr_block = "0.0.0.0/0"
  }

  # Regla 110: Permitir HTTPS
  ingress {
    rule_no    = 110
    action     = "allow"
    protocol   = "tcp"
    from_port  = 443
    to_port    = 443
    cidr_block = "0.0.0.0/0"
  }

  # Regla 120: Puertos efimeros
  ingress {
    rule_no    = 120
    action     = "allow"
    protocol   = "tcp"
    from_port  = 1024
    to_port    = 65535
    cidr_block = "0.0.0.0/0"
  }

  # Salida: Permitir todo
  egress {
    rule_no    = 100
    action     = "allow"
    protocol   = "-1"
    from_port  = 0
    to_port    = 0
    cidr_block = "0.0.0.0/0"
  }

  tags = merge(local.common_tags, {
    Name = "nacl-public-${var.project_name}"
  })
}
```

### Paso 3: Aplicar y verificar

```bash
terraform plan
# Plan: 1 to change (la NACL se actualiza con las 3 reglas deny)

terraform apply
```

Verifica que se generaron exactamente 3 reglas `deny`:

```bash
aws ec2 describe-network-acls \
  --filters Name=tag:Project,Values=lab18 \
  --query 'NetworkAcls[].Entries[?RuleAction==`deny` && !Egress].{RuleNum: RuleNumber, CIDR: CidrBlock}' \
  --output table
```

### Paso 4: Probar cambios incrementales

Añade una IP a la lista y verifica que solo cambia lo necesario:

```bash
terraform plan -var='blocked_ips=["192.0.2.0/24","198.51.100.0/24","203.0.113.0/24","100.64.0.0/10"]'
# ~ update in place: 1 regla deny añadida (regla 53)
```

---

## 6. Limpieza

Cuando hayas terminado el laboratorio (incluido el Reto si lo has completado), destruye toda la infraestructura para evitar costes:

```bash
terraform destroy
```

> **Nota:** El laboratorio no crea ningún bucket S3 propio. No destruyas el bucket de tfstate del lab-02 (`terraform-state-labs-<ACCOUNT_ID>`), ya que es un recurso compartido entre laboratorios.

---

## 7. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta el directorio `localstack/`.

LocalStack emula Security Groups, NACLs y VPC Flow Logs a nivel de API, pero no ejecuta tráfico real. El objetivo es validar la estructura de Terraform y el plan de despliegue.

---

## Buenas prácticas aplicadas

- **Referencia entre Security Groups en lugar de CIDR**: la regla `source_security_group_id` del SG de EC2 que solo permite tráfico del SG del ALB es más segura y mantenible que abrir un rango CIDR amplio, ya que escala automáticamente con las IPs del ALB.
- **NACLs como defensa en profundidad**: los Security Groups son stateful (las respuestas se permiten automáticamente), las NACLs son stateless. Usar ambas capas proporciona una segunda línea de defensa ante configuraciones incorrectas de Security Groups.
- **Bloques `dynamic` para reglas de NACL**: las NACLs requieren números de regla y muchas entradas repetitivas. El bloque `dynamic` genera las reglas desde una lista de objetos, reduciendo la duplicación y facilitando el mantenimiento.
- **VPC Flow Logs para diagnóstico**: habilitar Flow Logs permite diagnosticar tráfico denegado sin necesitar acceso a las instancias. El patrón `REJECT` en los logs indica un bloqueo de SG o NACL.
- **Rango de puertos efímeros en NACLs de salida**: las NACLs deben permitir el rango de puertos efímeros (1024-65535) en las reglas de salida de las subnets que reciben conexiones TCP entrantes, o el handshake de tres vías falla.
- **Reglas de Security Group como recursos independientes (`aws_vpc_security_group_ingress_rule` / `aws_vpc_security_group_egress_rule`)**: el lab declara los SGs vacíos y gestiona cada regla en su propio recurso (sucesores oficiales del antiguo `aws_security_group_rule`, soft-deprecated desde el provider AWS 5.x). Ventajas: (1) cada regla tiene su propio address en el state y se puede importar / destruir / aplicar `lifecycle` por separado; (2) evita el drift cuando alguien añade reglas fuera de Terraform, ya que el SG en sí no las controla; (3) rompe dependencias circulares cuando dos SGs se referencian entre sí — los SGs se crean primero (vacíos) y las reglas después.

---

## Recursos

- [AWS: Security Groups](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-security-groups.html)
- [AWS: Network ACLs](https://docs.aws.amazon.com/vpc/latest/userguide/vpc-network-acls.html)
- [AWS: VPC Flow Logs](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html)
- [AWS: Security Group Referencing](https://docs.aws.amazon.com/vpc/latest/userguide/security-group-rules.html)
- [Terraform: `dynamic` blocks](https://developer.hashicorp.com/terraform/language/expressions/dynamic-blocks)
- [Terraform: `aws_security_group`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/security_group)
- [Terraform: `aws_network_acl`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/network_acl)
- [Terraform: `aws_flow_log`](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/flow_log)
