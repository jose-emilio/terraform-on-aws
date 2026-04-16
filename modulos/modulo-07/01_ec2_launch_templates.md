# Sección 1 — Instancias EC2 y Launch Templates

> [← Volver al índice](./README.md) | [Siguiente →](./02_asg_load_balancers.md)

---

## 1.1 Cómputo en AWS: El Recurso `aws_instance`

Cuando hablamos de cómputo en AWS con Terraform, el punto de partida es siempre `aws_instance`. Es el bloque fundamental: define una máquina virtual (instancia EC2) en AWS. Sin embargo, una instancia no es un bloque aislado — necesita tres ingredientes mínimos para existir: una imagen base (AMI), un tipo de instancia que determina CPU y RAM, y una subred que define en qué red y zona de disponibilidad vive.

> *"Una instancia EC2 sin los tres pilares — AMI, tipo y subred — es como un coche sin motor, sin carrocería y sin ruedas. Terraform lo rechazará antes siquiera de planificar."*

Los tres pilares:

| Componente | Qué define | Ejemplos |
|------------|-----------|---------|
| **AMI** | Imagen base del SO | Amazon Linux 2023, Ubuntu 22.04 |
| **Instance Type** | CPU + RAM del servidor | `t3.micro`, `m5.large`, `c7g.xlarge` |
| **Subnet ID** | Red, AZ y VPC donde se despliega | Pública o privada |

Además de los tres mínimos, una instancia de producción siempre lleva: Security Groups, un IAM Instance Profile y configuración de metadatos (IMDSv2).

---

## 1.2 Código: `aws_instance` Básico

```hcl
resource "aws_instance" "web" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "t3.micro"
  subnet_id     = aws_subnet.public[0].id

  # Seguridad
  vpc_security_group_ids = [
    aws_security_group.web.id
  ]
  iam_instance_profile = aws_iam_instance_profile.ec2.name

  # Metadatos — siempre IMDSv2
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"   # IMDSv2
    http_put_response_hop_limit = 1
  }

  tags = {
    Name = "${var.project}-web"
  }
}
```

---

## 1.3 Búsqueda Dinámica: El Data Source `aws_ami`

Hay un anti-patrón que todo el mundo comete al principio: hardcodear un AMI ID en el código.

```hcl
# ❌ NUNCA hacer esto
ami = "ami-0abcdef1234567890"   # Solo válido en us-east-1, caducará pronto
```

Los AMI IDs son únicos por región y se deprecan cuando Amazon publica versiones más nuevas. Si hardcodeas un AMI, tu código deja de ser portable y eventualmente romperá en producción cuando la imagen caduque.

La solución correcta es un data source `aws_ami` que busca dinámicamente la imagen más reciente según filtros:

```hcl
data "aws_ami" "amazon_linux" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-*-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "state"
    values = ["available"]
  }
}

# Uso: data.aws_ami.amazon_linux.id
# Retorna la AMI más reciente que coincida
```

Con este data source, tu código funciona en cualquier región y siempre usa la imagen más actualizada con los últimos parches de seguridad.

---

## 1.4 Identidad Segura: IAM Instance Profile

> *"¿Por qué tu servidor tiene una contraseña permanente en el código si AWS puede darle un carnet de identidad temporal que se renueva solo? El Instance Profile es ese carnet."*

El IAM Instance Profile es el mecanismo que permite que una instancia EC2 asuma permisos AWS sin usar Access Keys estáticas. La cadena es: IAM Role → Instance Profile → EC2.

| | Instance Profile | Access Keys en EC2 |
|--|-----------------|-------------------|
| Tipo de credencial | Temporales (STS) | Permanentes |
| Rotación | Automática | Manual |
| Riesgo de filtración | Muy bajo | Alto (pueden estar en código) |
| Auditoría | CloudTrail completo | Difícil de rastrear |

```hcl
# 1. Crear el IAM Role con AssumeRole para EC2
resource "aws_iam_role" "ec2_role" {
  name               = "mi-ec2-role"
  assume_role_policy = data.aws_iam_policy_document.ec2.json
}

# 2. Crear el Instance Profile (puente Role → EC2)
resource "aws_iam_instance_profile" "ec2" {
  role = aws_iam_role.ec2_role.name
}

# 3. Asociar a la instancia EC2
resource "aws_instance" "app" {
  iam_instance_profile = aws_iam_instance_profile.ec2.name
  # ... resto de configuración
}
```

---

## 1.5 Blindaje: IMDSv2 y `metadata_options`

El endpoint de metadatos de instancia (IMDS — `169.254.169.254`) expone información crítica: las credenciales temporales del Instance Profile, la región, el ID de instancia y más. IMDSv1 permite acceder a todo esto con un simple GET sin autenticación, lo que lo hace vulnerable a ataques SSRF (Server-Side Request Forgery).

Con IMDSv1, un atacante que consiga que tu servidor haga una petición HTTP arbitraria puede obtener las credenciales AWS de tu instancia en milisegundos.

IMDSv2 requiere primero obtener un token de sesión mediante un PUT con un header especial, lo que bloquea completamente los ataques SSRF.

```hcl
# ── IMDSv2 en aws_instance ──
resource "aws_instance" "secure" {
  # ... otros argumentos ...
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"  # Fuerza IMDSv2
    http_put_response_hop_limit = 1           # Bloquea desde containers
    instance_metadata_tags      = "enabled"   # Tags en metadata
  }
}

# ── IMDSv2 en Launch Template ──
resource "aws_launch_template" "secure" {
  # ... otros argumentos ...
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
}
```

El `http_put_response_hop_limit = 1` es especialmente importante cuando hay contenedores en la instancia: impide que procesos dentro de un contenedor accedan al IMDS de la instancia host.

---

## 1.6 Acceso: `aws_key_pair` y Gestión de SSH

El recurso `aws_key_pair` registra una llave pública SSH existente en AWS. La regla de oro es **nunca generar el par de claves dentro de Terraform** — si Terraform guarda la clave privada en el state, ese state se convierte en un objetivo de seguridad.

La mejor práctica moderna es reemplazar el acceso SSH por AWS SSM Session Manager, que no requiere puertos SSH abiertos ni llaves en ningún sitio.

```hcl
# ── Opción aceptable: importar llave pública externa ──
resource "aws_key_pair" "ssh" {
  key_name   = "mi-key"
  public_key = file("~/.ssh/id_rsa.pub")   # Llave pública del operador
}

# ── Si necesitas generar en TF (acepta el riesgo) ──
resource "tls_private_key" "ssh" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

resource "aws_key_pair" "deployer" {
  key_name   = "${var.project}-key"
  public_key = tls_private_key.ssh.public_key_openssh
}

# ── Guardar clave privada localmente ──
resource "local_file" "ssh_key" {
  content         = tls_private_key.ssh.private_key_pem
  filename        = "${path.module}/key.pem"
  file_permission = "0400"
}

# Uso en aws_instance:
#   key_name = aws_key_pair.deployer.key_name
```

---

## 1.7 User Data: Scripts de Bootstrap

El atributo `user_data` ejecuta un script una sola vez durante el primer arranque de la instancia. Es el mecanismo de bootstrapping: instalar paquetes, configurar servicios, montar volúmenes.

Tres características importantes a recordar:

- **Solo al primer boot**: si necesitas re-ejecutarlo, debes recrear la instancia
- **Ejecuta como root**: sin restricciones, con toda la potencia y el riesgo que eso implica
- **Límite de 16 KB**: si tu script es más grande, usa S3 como almacén y descarga desde `user_data`

### La función `templatefile()`

La manera profesional de gestionar `user_data` es desacoplar el script del código HCL con `templatefile()`. Esta función lee un archivo externo y reemplaza las variables `${var}` con valores de Terraform:

```hcl
# scripts/init.sh.tpl
#!/bin/bash
set -euo pipefail

# Instalar dependencias
yum update -y
yum install -y docker

# Variable inyectada por Terraform
export DB_HOST="${db_host}"

# Iniciar app
systemctl start docker
docker run -e DB=$DB_HOST app
```

```hcl
# main.tf
resource "aws_instance" "app" {
  ami           = data.aws_ami.al2.id
  instance_type = "t3.micro"

  user_data = templatefile(
    "scripts/init.sh.tpl",
    {
      db_host = aws_db_instance.main.endpoint
    }
  )
}
```

`templatefile()` separa la lógica del script de la infraestructura — puedes testear el script de forma independiente y el código HCL queda limpio.

---

## 1.8 Almacenamiento (I): Root Block Device

El `root_block_device` configura el volumen EBS raíz de la instancia — el disco donde vive el sistema operativo. Los parámetros más importantes:

```hcl
resource "aws_instance" "db" {
  ami           = data.aws_ami.amazon_linux.id
  instance_type = "m5.large"

  root_block_device {
    volume_type           = "gp3"     # IOPS gratuitos base: 3000
    volume_size           = 50        # GiB
    iops                  = 3000      # Hasta 16000
    throughput            = 125       # MiB/s (máx 1000)
    encrypted             = true
    kms_key_id            = aws_kms_key.ebs.arn
    delete_on_termination = true

    tags = {
      Name = "${var.project}-root"
    }
  }
}
```

**gp3 vs gp2**: usa siempre `gp3`. Es un 20% más barato, ofrece 3000 IOPS base gratuitas independientemente del tamaño, y permite ajustar IOPS y throughput de forma independiente al tamaño del disco.

---

## 1.9 Almacenamiento (II): Volúmenes EBS Adicionales

A diferencia del `root_block_device` que es parte de la instancia, los volúmenes EBS adicionales tienen un ciclo de vida independiente. Se crean como recursos separados y se adjuntan como discos adicionales:

```hcl
# Volumen de datos independiente
resource "aws_ebs_volume" "data" {
  availability_zone = "us-east-1a"   # Debe coincidir con la instancia
  size              = 100             # GiB
  type              = "gp3"
  encrypted         = true
}

# Adjuntar a la instancia
resource "aws_volume_attachment" "data_att" {
  device_name = "/dev/xvdf"
  volume_id   = aws_ebs_volume.data.id
  instance_id = aws_instance.app.id
}
```

Al separar el volumen de datos de la instancia, puedes: terminar la instancia y preservar los datos, adjuntar el volumen a una nueva instancia, o tomar snapshots independientemente.

---

## 1.10 FinOps: Control con `delete_on_termination`

> *"Los volúmenes huérfanos son el coste invisible de AWS. Terminas una instancia un viernes y el lunes descubres que pagaste 72 horas de disco que nadie usa."*

Cuando terminas una instancia, el comportamiento de los volúmenes EBS depende de `delete_on_termination`:

| | `= true` (Efímero) | `= false` (Persistente) |
|--|-------------------|------------------------|
| Al terminar EC2 | El disco se borra | El disco queda huérfano |
| Coste residual | Ninguno | Continúa facturando |
| Ideal para | Dev/Test, stateless | Producción, bases de datos |
| Riesgo | Pérdida de datos | Facturas fantasma |

**Regla**: en desarrollo usa `= true`. En producción, si el volumen tiene datos importantes, usa `= false` **junto con** `lifecycle { prevent_destroy = true }` para que Terraform no borre el recurso por accidente.

---

## 1.11 Launch Template: Plantilla Reutilizable de EC2

Un Launch Template (`aws_launch_template`) es una **plantilla versionada** que define todos los parámetros de configuración de EC2: AMI, tipo de instancia, networking, seguridad, user data. No crea ninguna instancia por sí solo — es la receta que usan los Auto Scaling Groups para lanzar instancias.

> *"Si `aws_instance` es cocinar un plato concreto, el Launch Template es escribir la receta en una tarjeta. El ASG usará esa tarjeta cada vez que necesite preparar un plato nuevo."*

```hcl
resource "aws_launch_template" "app" {
  name_prefix            = "app-"
  image_id               = data.aws_ami.al2.id
  instance_type          = "t3.micro"
  update_default_version = true   # Nueva versión = versión activa

  network_interfaces {
    security_groups = [aws_security_group.app.id]
  }

  metadata_options {
    http_tokens = "required"   # IMDSv2 siempre
  }

  user_data = base64encode(templatefile("${path.module}/scripts/init.sh.tpl", {
    db_host = var.db_host
  }))

  tags = { Name = "app-lt" }
}
```

Diferencia clave con `aws_instance`: el user_data en un Launch Template **debe ir en base64** (`base64encode()`), mientras que en `aws_instance` Terraform lo codifica automáticamente.

---

## 1.12 Placement Groups: Ubicación Física de Instancias

Los Placement Groups controlan dónde AWS coloca físicamente las instancias en su hardware. Tres estrategias para tres casos de uso distintos:

| Estrategia | Hardware | Latencia | HA | Ideal para |
|-----------|---------|---------|----|----|
| **Cluster** | Mismo rack | Mínima (<1ms) | Baja | HPC, ML distribuido |
| **Spread** | Hardware distinto c/u | Media | Máxima | Servicios críticos (máx 7/AZ) |
| **Partition** | Grupos en racks separados | Media | Alta | Kafka, Hadoop, Cassandra |

```hcl
# ── Cluster: baja latencia para HPC ──
resource "aws_placement_group" "hpc" {
  name     = "${var.project}-hpc"
  strategy = "cluster"   # Mismo rack, máximo rendimiento
}

# ── Spread: máxima disponibilidad ──
resource "aws_placement_group" "ha" {
  name         = "${var.project}-ha"
  strategy     = "spread"   # Hardware separado por instancia
  spread_level = "rack"     # rack | host
}

# ── Partition: grandes clusters distribuidos ──
resource "aws_placement_group" "kafka" {
  name            = "${var.project}-kafka"
  strategy        = "partition"
  partition_count = 3   # 3 particiones independientes
}

# Uso en aws_instance o launch_template:
#   placement_group = aws_placement_group.hpc.id
```

---

## 1.13 Tenancy: Aislamiento de Hardware

```hcl
# Default: hardware compartido (99% de los casos)
resource "aws_instance" "shared" {
  ami           = data.aws_ami.al.id
  instance_type = "t3.micro"
  tenancy       = "default"
}

# Dedicated Instance: hardware exclusivo por instancia
resource "aws_instance" "ded" {
  ami           = data.aws_ami.al.id
  instance_type = "m5.xlarge"
  tenancy       = "dedicated"   # ~2x precio On-Demand
}

# Dedicated Host: servidor físico completo (BYOL)
resource "aws_ec2_host" "lic" {
  instance_type     = "m5.xlarge"
  availability_zone = "us-east-1a"
  auto_placement    = "on"
}

resource "aws_instance" "byol" {
  ami           = data.aws_ami.al.id
  instance_type = "m5.xlarge"
  host_id       = aws_ec2_host.lic.id
  tenancy       = "host"
}
```

El **Dedicated Host** es el nivel más costoso pero es necesario para licencias de software BYOL (Bring Your Own License) como Windows Server o SQL Server, donde la licencia está vinculada a un socket de CPU físico.

---

## 1.14 Spot Instances: Ahorro Agresivo de Costes

Las Spot Instances usan capacidad sobrante de AWS a precios reducidos — hasta un 90% de descuento respecto a On-Demand. La contrapartida: AWS puede reclamarlas con solo 2 minutos de aviso cuando necesita esa capacidad.

```hcl
resource "aws_launch_template" "spot" {
  name_prefix   = "spot-worker-"
  image_id      = data.aws_ami.al2.id
  instance_type = "m5.large"

  instance_market_options {
    market_type = "spot"
    spot_options {
      max_price                      = "0.05"       # Precio máximo a pagar
      spot_instance_type             = "one-time"
      instance_interruption_behavior = "terminate"  # Al recibir aviso: terminar
    }
  }
}
```

**Casos de uso ideales**: CI/CD runners, procesamiento batch, entrenamiento ML, dev/test. **Nunca para**: APIs síncronas críticas, bases de datos con estado, servicios que no toleran interrupciones.

---

## 1.15 Monitorización: CloudWatch y EC2

```hcl
# ── Habilitar monitoring detallado (1 min) ──
resource "aws_instance" "monitored" {
  ami           = data.aws_ami.al.id
  instance_type = "t3.micro"
  monitoring    = true   # Detailed monitoring (tiene coste adicional)
}

# ── CloudWatch Alarm: CPU alta ──
resource "aws_cloudwatch_metric_alarm" "cpu" {
  alarm_name          = "${var.project}-high-cpu"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300   # 5 minutos
  statistic           = "Average"
  threshold           = 80
  alarm_actions       = [aws_sns_topic.alerts.arn]

  dimensions = {
    InstanceId = aws_instance.monitored.id
  }
}
```

Por defecto, CloudWatch recoge métricas EC2 cada **5 minutos** (basic monitoring, gratuito). Con `monitoring = true` se activa **detailed monitoring** a 1 minuto, necesario para auto-scaling reactivo. Nota: la memoria RAM **no es una métrica nativa de EC2** — para monitorizar memoria necesitas instalar el CloudWatch Agent.

---

## 1.16 Troubleshooting: Errores Comunes con EC2

| Error | Causa probable | Solución |
|-------|---------------|---------|
| **AMI Not Found** | AMI deprecada o creada en otra región | Usar `data.aws_ami` dinámico |
| **Insufficient Capacity** | La AZ no tiene el tipo de instancia disponible | Diversificar AZs y tipos |
| **InvalidKeyPair** | Key pair registrado en otra región | Usar `aws_key_pair` en la región correcta |
| **Timeout en provisioners** | SG bloquea SSH o instancia sin IP pública | Preferir `user_data` sobre provisioners |

---

## 1.17 Resumen: EC2 y Launch Templates

| Componente | Función | Buena práctica |
|-----------|---------|---------------|
| `aws_instance` | Instancia EC2 individual | `data.aws_ami` dinámico, nunca hardcodear AMI |
| `aws_iam_instance_profile` | Identidad de la instancia | Credenciales temporales, nunca Access Keys |
| `metadata_options` | IMDSv2 | `http_tokens = "required"` siempre |
| `user_data + templatefile()` | Bootstrap al primer arranque | Scripts externos, no inline |
| `root_block_device` | Disco del SO | `gp3`, `encrypted = true` |
| `aws_ebs_volume` | Discos adicionales | Ciclo de vida separado de la instancia |
| `aws_launch_template` | Plantilla versionada para ASG | `update_default_version = true` |
| Placement Groups | Control físico de ubicación | Cluster/Spread/Partition según caso |
| Spot Instances | Ahorro hasta 90% | Solo cargas tolerantes a interrupciones |

---

> **Siguiente:** [Sección 2 — Auto Scaling Groups y Load Balancers →](./02_asg_load_balancers.md)
