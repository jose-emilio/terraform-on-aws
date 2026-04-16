# Laboratorio 28: Escalabilidad y Alta Disponibilidad con Zero Downtime

[← Módulo 7 — Cómputo en AWS con Terraform](../../modulos/modulo-07/README.md)


## Visión general

En este laboratorio desplegarás una arquitectura web tolerante a fallos de zona de disponibilidad que se actualiza sin interrupciones de servicio. Combinarás un Launch Template versionado, un Application Load Balancer, un Auto Scaling Group Multi-AZ, una política de Target Tracking y un mecanismo de rolling update mediante `instance_refresh`.

## Objetivos de Aprendizaje

Al finalizar este laboratorio serás capaz de:

- Crear un `aws_launch_template` versionado que encapsule la configuración de red, seguridad y `user_data` de la flota
- Desplegar un ALB con un `aws_lb_listener` que redirija el tráfico HTTP (puerto 80) al puerto de aplicación 8080 de las instancias
- Configurar un ASG que distribuya instancias en todas las subredes privadas disponibles mediante `vpc_zone_identifier`
- Aplicar una política de Target Tracking basada en CPU media al 50% para escalar automáticamente
- Implementar un bloque `instance_refresh` con `min_healthy_percentage = 90` para actualizar la flota sin caída de servicio

## Requisitos Previos

- Terraform >= 1.5 instalado
- Laboratorio 2 completado — el bucket `terraform-state-labs-<ACCOUNT_ID>` debe existir
- Perfil AWS con permisos sobre EC2, VPC, ELB, Auto Scaling e IAM
- LocalStack en ejecución (para la sección de LocalStack)

---

## Conceptos Clave

### Launch Template versionado

`aws_launch_template` es la forma moderna de definir la configuración de las instancias de un ASG. Sustituye a los `aws_launch_configuration` (deprecados). Cada vez que Terraform detecta un cambio en el recurso, genera una nueva versión numerada automáticamente.

```hcl
resource "aws_launch_template" "web" {
  name_prefix   = "lab28-web-"
  image_id      = data.aws_ami.al2023.id
  instance_type = var.instance_type

  lifecycle {
    create_before_destroy = true
  }
}
```

La política `create_before_destroy = true` garantiza que la nueva versión del template existe antes de que el ASG empiece a sustituir instancias.

### Application Load Balancer (ALB)

El ALB opera en capa 7 (HTTP/HTTPS) e inspecciona el contenido de las peticiones para enrutarlas. Sus componentes principales son:

| Componente | Recurso Terraform | Función |
|---|---|---|
| Load Balancer | `aws_lb` | Punto de entrada público; vive en subredes públicas |
| Target Group | `aws_lb_target_group` | Agrupa instancias y ejecuta health checks al puerto 8080 |
| Listener | `aws_lb_listener` | Escucha en el puerto 80 y reenvía al target group |

El ASG se registra en el target group mediante `target_group_arns`. Cuando el ASG añade o elimina instancias, el ALB las incorpora o retira del balanceo automáticamente.

### Auto Scaling Group Multi-AZ

El parámetro `vpc_zone_identifier` recibe una lista de subnets. El ASG distribuye instancias entre ellas de forma equilibrada. Si una AZ cae, el ASG lanza nuevas instancias en las AZs disponibles para mantener la capacidad deseada.

```hcl
resource "aws_autoscaling_group" "web" {
  vpc_zone_identifier = aws_subnet.private[*].id
  # ...
}
```

Usando `health_check_type = "ELB"`, el ASG delega la comprobación de salud al ALB: una instancia solo se considera sana si supera los health checks del target group.

### Target Tracking Scaling

La política de Target Tracking es la forma más simple de escalar automáticamente. El ASG añade o elimina instancias para mantener una métrica en torno a un valor objetivo, sin necesidad de definir alarmas de CloudWatch manualmente.

```hcl
resource "aws_autoscaling_policy" "cpu" {
  policy_type = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }
    target_value = 50.0
  }
}
```

El ASG escala hacia arriba cuando la CPU media supera el 50% y escala hacia abajo cuando cae por debajo, respetando los tiempos de estabilización para evitar oscilaciones.

### Instance Refresh (Rolling Update)

`instance_refresh` permite reemplazar las instancias de un ASG de forma gradual cuando cambia el Launch Template. Con `min_healthy_percentage = 90`, el ASG garantiza que al menos el 90% de la capacidad deseada está sana en todo momento durante la sustitución.

```hcl
instance_refresh {
  strategy = "Rolling"
  preferences {
    min_healthy_percentage = 90
    instance_warmup        = 60
  }
  triggers = ["launch_template"]
}
```

El campo `triggers = ["launch_template"]` le indica a Terraform que debe iniciar un refresh cuando cambie el bloque `launch_template` del ASG. Usando `version = aws_launch_template.web.latest_version` (en lugar de `"$Latest"`), cualquier cambio en el Launch Template provoca un cambio en ese campo y activa el mecanismo.

---

## Estructura del proyecto

```
lab28/
├── aws/
│   ├── aws.s3.tfbackend  # Parámetros del backend S3 (sin bucket)
│   ├── providers.tf      # Backend S3, Terraform >= 1.5, provider AWS
│   ├── variables.tf      # region, project, vpc_cidr, instance_type, sizes, app_version
│   ├── main.tf           # VPC, ALB, Launch Template, ASG, scaling policy
│   ├── outputs.tf        # URL del ALB, nombre del ASG, versión del Launch Template
│   └── user_data.sh      # Script de arranque; templatefile() inyecta app_version
└── localstack/
    ├── providers.tf      # Endpoints apuntando a LocalStack
    ├── variables.tf      # Mismas variables, valores por defecto para entorno local
    ├── main.tf           # Idéntico a aws/main.tf
    ├── outputs.tf
    └── user_data.sh      # Versión simplificada del script (sin IMDSv2)
```

---

## 1. Despliegue en AWS Real

### 1.1 Arquitectura

```
Internet
    │ (puerto 80)
    ▼
┌──────────────────────────────────────────────────────┐
│  ALB  (subredes públicas, AZ-a y AZ-b)               │
└───────────────┬──────────────────────────────────────┘
                │ (puerto 8080, health check /)
    ┌───────────┴────────────┐
    ▼                        ▼
┌─────────────────┐    ┌─────────────────┐
│  subred pub AZ-a│    │  subred pub AZ-b│
│  NAT Gateway-a  │    │  NAT Gateway-b  │
└────────┬────────┘    └────────┬────────┘
         │ (salida)             │ (salida)
┌────────┴────────┐    ┌────────┴────────┐
│ subred priv AZ-a│    │ subred priv AZ-b│
│    EC2 AZ-a     │    │    EC2 AZ-b     │  ← ASG
└─────────────────┘    └─────────────────┘
```

Cada AZ tiene su propio NAT Gateway: si una zona cae, las instancias de las otras AZs conservan conectividad de salida. Las instancias del ASG nunca reciben tráfico directo de Internet; todo el tráfico entrante pasa por el ALB.

### 1.2 Código Terraform

**`aws/main.tf`** — Fragmentos clave:

El Launch Template usa `latest_version` para que cada cambio de configuración genere una nueva versión y active el instance_refresh:

```hcl
launch_template {
  id      = aws_launch_template.web.id
  version = aws_launch_template.web.latest_version
}
```

El script de arranque vive en `user_data.sh` y se carga con `templatefile()`, que inyecta `app_version` antes de enviarlo a la instancia. Las variables bash (`$TOKEN`, `$AZ`, `$ID`) no usan llaves y no son afectadas por la interpolación de Terraform:

```hcl
user_data = base64encode(templatefile("${path.module}/user_data.sh", {
  app_version = var.app_version
}))
```

El script `aws/user_data.sh` instala Apache (`httpd`), lo configura para escuchar en el puerto 8080 y añade la cabecera `Connection: close` para que el navegador cierre la conexión TCP tras cada respuesta — lo que obliga al ALB a balancear en la siguiente recarga. `templatefile()` inyecta `${app_version}` antes de enviar el script; el resto de variables (`$AZ`, `$ID`, `$TYPE`) las resuelve bash en tiempo de ejecución consultando el servicio de metadatos IMDSv2:

```bash
#!/bin/bash
dnf install -y httpd
sed -i 's/^Listen 80$/Listen 8080/' /etc/httpd/conf/httpd.conf

# Connection: close → el navegador abre una conexión nueva en cada recarga
echo 'Header always set Connection "close"' > /etc/httpd/conf.d/lab28.conf

# Genera /var/www/html/index.html con versión, AZ, ID, tipo y timestamp
# ... (templatefile inyecta ${app_version}; bash resuelve $AZ, $ID, $TYPE)

systemctl enable --now httpd
```

### 1.3 Inicialización y despliegue

```bash
export BUCKET="terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"

# Desde lab28/aws/
terraform fmt
terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=$BUCKET"

terraform plan
terraform apply
```

El despliegue completo tarda entre 3 y 5 minutos. El NAT Gateway es el recurso más lento en aprovisionarse.

Al finalizar, los outputs mostrarán:

```
alb_url                        = "http://lab28-alb-123456789.us-east-1.elb.amazonaws.com"
asg_name                       = "lab28-asg"
launch_template_id             = "lt-0a1b2c3d4e5f"
launch_template_latest_version = 1
private_subnet_ids             = ["subnet-aaa", "subnet-bbb"]
```

### 1.4 Verificar la distribución Multi-AZ y el ALB

Espera ~2 minutos a que las instancias superen los health checks del target group.

**Paso 1** — Obtén la URL del ALB:

```bash
terraform output alb_url
```

**Paso 2** — Abre la URL en Firefox o Chrome para comprobar que la página carga correctamente con la información de la instancia.

> Si el navegador devuelve "Esta página no está disponible", las instancias aún están arrancando o pasando los health checks. Espera 30 segundos y recarga.

**Paso 3** — Recarga la página con `F5` (o `Cmd+R`). El servidor incluye la cabecera `Connection: close` en cada respuesta, lo que indica al navegador que cierre la conexión TCP tras recibirla. En la siguiente recarga el navegador abre una conexión nueva y el ALB la dirige a una instancia diferente. Observa cómo cambian la **Availability Zone** y el **Instance ID** entre recargas.

**Paso 4** — Confirma el estado de salud de las instancias:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names "$(terraform output -raw asg_name)" \
  --query 'AutoScalingGroups[0].Instances[].{ID:InstanceId,AZ:AvailabilityZone,Health:HealthStatus}' \
  --output table
```

### 1.5 Demostrar el Rolling Update (Instance Refresh)

Cambia la versión de la aplicación para generar una nueva versión del Launch Template. El ASG detectará el cambio y reemplazará las instancias gradualmente manteniendo el servicio activo.

**Paso 1** — Inicia el rolling update cambiando `app_version`:

```bash
terraform apply -var="app_version=v2"
```

Terraform generará un plan con dos cambios:
1. El Launch Template recibe una nueva versión (`v2` embebida en `user_data`)
2. El ASG detecta el cambio en `version` y activa un `instance_refresh`

**Paso 2** — Mientras Terraform aplica, monitoriza el progreso del refresh en otra terminal:

```bash
watch -n 5 "aws autoscaling describe-instance-refreshes \
  --auto-scaling-group-name lab28-asg \
  --query 'InstanceRefreshes[0].{Status:Status,Percentage:PercentageComplete,Remaining:InstancesToUpdate}' \
  --output table"
```

**Paso 3** — Envía peticiones continuas al ALB para observar la transición sin interrupciones:

```bash
while true; do
  curl -s "$ALB_URL"
  echo ""
  sleep 2
done
```

Durante el proceso verás respuestas mezcladas (`v1` y `v2`) hasta que todas las instancias se hayan reemplazado. En ningún momento el servicio devuelve un error.

**Paso 4** — Cuando el refresh complete, todas las respuestas serán `v2`:

```
v2 | AZ: us-east-1a | ID: i-0xyz789
v2 | AZ: us-east-1b | ID: i-0uvw012
```

### 1.6 Demostrar el Target Tracking Scaling

Genera carga artificial en una instancia para observar cómo el ASG añade capacidad automáticamente.

**Paso 1** — Identifica el ID de una instancia del ASG:

```bash
aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names lab28-asg \
  --query 'AutoScalingGroups[0].Instances[0].InstanceId' \
  --output text
```

**Paso 2** — Conéctate a la instancia vía SSM Session Manager (no requiere SSH ni bastión):

```bash
aws ssm start-session --target <INSTANCE_ID>
```

> Si el perfil IAM de la instancia no tiene permisos de SSM, usa `aws ec2-instance-connect send-ssh-public-key` o lanza una instancia bastion temporal.

**Paso 3** — Desde dentro de la instancia, instala `stress` y genera carga de CPU:

```bash
sudo dnf install -y stress

# 2 workers de CPU durante 5 minutos (uno por vCPU en t4g.micro)
stress --cpu 2 --timeout 300
```

> **Nota:** El Target Tracking calcula la CPU **media de todas las instancias del ASG**. Si el ASG tiene dos instancias y solo estreses una, la media puede quedarse en torno al 50% — justo en el umbral — y el escalado no llegará a activarse. Para garantizar el experimento, repite el mismo comando en la segunda instancia (obtenla con el mismo comando del Paso 1 cambiando `Instances[0]` por `Instances[1]`).

**Paso 4** — Monitoriza el escalado desde tu terminal local:

```bash
watch -n 30 "aws autoscaling describe-auto-scaling-groups \
  --auto-scaling-group-names lab28-asg \
  --query 'AutoScalingGroups[0].{Min:MinSize,Desired:DesiredCapacity,Max:MaxSize,Instances:length(Instances)}' \
  --output table"
```

El ASG aumentará `DesiredCapacity` para mantener la CPU media en torno al 50%. Cuando `stress` finalice tras los 300 segundos, el ASG reducirá la capacidad gradualmente respetando el periodo de enfriamiento.

---

> **Antes de comenzar los retos**, asegúrate de que todos los cambios de `main.tf` están aplicados (`terraform apply`). Si hay modificaciones pendientes en el ASG, se aplicarán junto con el reto y el criterio *"sin cambios en recursos existentes"* no se cumplirá.

## 2. Reto 1: Escalado Programado

La política de Target Tracking reacciona a la carga en tiempo real, pero hay patrones de uso predecibles — por ejemplo, un pico de tráfico siempre entre las 08:00 y las 20:00 UTC de lunes a viernes. El escalado programado (`aws_autoscaling_schedule`) ajusta la capacidad del ASG en horarios fijos, complementando al Target Tracking.

### Requisitos

1. Crea un archivo `schedules.tf` en `aws/` con dos recursos `aws_autoscaling_schedule`.
2. El primero, `scale_up`, debe ejecutarse de lunes a viernes a las **08:00 UTC** y escalar el ASG a `min_size = 4`, `desired_capacity = 4`.
3. El segundo, `scale_down`, debe ejecutarse de lunes a viernes a las **20:00 UTC** y devolver el ASG a `min_size = var.min_size`, `desired_capacity = var.desired_capacity`.
4. Ambas acciones deben expresarse en formato cron y referenciar el ASG ya existente sin modificarlo.

### Criterios de éxito

- `terraform plan` no muestra cambios en los recursos existentes — solo añade los dos schedules.
- `aws autoscaling describe-scheduled-actions --auto-scaling-group-name lab28-asg` lista las dos acciones con los horarios correctos.
- Puedes explicar por qué `max_size` no se modifica en `scale_up` aunque la capacidad deseada aumente.

[Ver solución →](#4-solución-de-los-retos)

---

## 3. Reto 2: Alarma CloudWatch y Notificacion SNS

El Target Tracking gestiona el escalado, pero no avisa al equipo cuando la carga es anormalmente alta. Un umbral de CPU del 80% sostenido durante 2 minutos podría indicar un problema en la aplicación (bucle infinito, fuga de memoria) más que una demanda legítima.

### Requisitos

1. Crea un archivo `alerts.tf` en `aws/` con los siguientes recursos:
   - `aws_sns_topic` con nombre `"${var.project}-alerts"`.
   - `aws_sns_topic_subscription` de tipo `email` a tu dirección de correo.
   - `aws_cloudwatch_metric_alarm` que se active cuando la **CPU media del ASG supere el 80%** durante **2 periodos consecutivos de 60 segundos** y envíe la notificación al topic SNS.
2. La alarma debe también enviar una notificación de recuperación (`ok_actions`) cuando la CPU baje del umbral.
3. Añade a `outputs.tf` la ARN del SNS topic y el nombre de la alarma.

### Criterios de éxito

- `terraform apply` completa sin errores.
- Recibes un correo de confirmación de suscripción SNS de AWS; debes aceptarlo para activar las notificaciones.
- `aws cloudwatch describe-alarms --alarm-names "lab28-cpu-high"` muestra el estado `OK`.
- Al generar carga de CPU superior al 80% durante 2 minutos (usando `yes > /dev/null &`), recibes un correo de alerta.

[Ver solución →](#4-solución-de-los-retos)

---

## 4. Solución de los Retos

> Intenta resolver los retos antes de leer esta sección.

### Solución Reto 1 — Escalado Programado

Crea el archivo `aws/schedules.tf`:

```hcl
resource "aws_autoscaling_schedule" "scale_up" {
  scheduled_action_name  = "${var.project}-scale-up"
  autoscaling_group_name = aws_autoscaling_group.web.name
  recurrence             = "0 8 * * 1-5"   # Lunes–viernes, 08:00 UTC
  time_zone              = "UTC"

  min_size         = 4
  max_size         = -1   # -1 significa "no cambiar el valor actual"
  desired_capacity = 4
}

resource "aws_autoscaling_schedule" "scale_down" {
  scheduled_action_name  = "${var.project}-scale-down"
  autoscaling_group_name = aws_autoscaling_group.web.name
  recurrence             = "0 20 * * 1-5"  # Lunes–viernes, 20:00 UTC
  time_zone              = "UTC"

  min_size         = var.min_size
  max_size         = -1
  desired_capacity = var.desired_capacity
}
```

El valor `-1` en `max_size` le indica al ASG que no modifique el máximo vigente en ese momento. Si se pusiera el valor explícito de `var.max_size`, funcionaría igual, pero `-1` es más robusto: si alguien cambia manualmente el máximo fuera de ciclo, la acción programada no lo sobreescribirá.

Verificación:

```bash
terraform apply

aws autoscaling describe-scheduled-actions \
  --auto-scaling-group-name lab28-asg \
  --query 'ScheduledUpdateGroupActions[].{Nombre:ScheduledActionName,Cron:Recurrence,Min:MinSize,Desired:DesiredCapacity}' \
  --output table
```

### Solución Reto 2 — Alarma CloudWatch y Notificación SNS

Crea el archivo `aws/alerts.tf`:

```hcl
resource "aws_sns_topic" "alerts" {
  name = "${var.project}-alerts"
  tags = local.tags
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = "tu-correo@ejemplo.com"   # Sustituye por tu dirección real
}

resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "${var.project}-cpu-high"
  alarm_description   = "CPU media del ASG por encima del 80% durante 2 minutos"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Average"
  threshold           = 80

  dimensions = {
    AutoScalingGroupName = aws_autoscaling_group.web.name
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = local.tags
}
```

Añade a `outputs.tf`:

```hcl
output "sns_topic_arn" {
  description = "ARN del topic SNS de alertas"
  value       = aws_sns_topic.alerts.arn
}

output "cloudwatch_alarm_name" {
  description = "Nombre de la alarma de CPU alta"
  value       = aws_cloudwatch_metric_alarm.cpu_high.alarm_name
}
```

> **Importante:** tras el `terraform apply`, AWS envía un correo a la dirección configurada con un enlace de confirmación. La suscripción queda en estado `PendingConfirmation` hasta que se acepte; sin confirmar, no se reciben notificaciones.

Verificación:

```bash
terraform apply

# Confirmar que la alarma existe y está en estado OK
aws cloudwatch describe-alarms \
  --alarm-names "lab28-cpu-high" \
  --query 'MetricAlarms[0].{Nombre:AlarmName,Estado:StateValue,Umbral:Threshold}' \
  --output table

# Generar carga para activar la alarma
stress --cpu 2 --timeout 300 &

# Monitorizar el estado de la alarma
watch -n 15 "aws cloudwatch describe-alarms \
  --alarm-names lab28-cpu-high \
  --query 'MetricAlarms[0].StateValue' --output text"
```

---

## Verificación final

```bash
# Obtener la URL del ALB
ALB_URL=$(terraform output -raw alb_url)

# Probar la aplicacion
curl -s "http://${ALB_URL}" | head -5

# Verificar que el ASG tiene instancias en servicio
aws autoscaling describe-auto-scaling-groups \
  --query 'AutoScalingGroups[?contains(AutoScalingGroupName,`lab28`)].{Name:AutoScalingGroupName,Min:MinSize,Max:MaxSize,Desired:DesiredCapacity}' \
  --output table

# Ver el estado del target group
TG_ARN=$(terraform output -raw target_group_arn 2>/dev/null || \
  aws elbv2 describe-target-groups \
    --query 'TargetGroups[?contains(TargetGroupName,`lab28`)].TargetGroupArn' \
    --output text)
aws elbv2 describe-target-health \
  --target-group-arn "$TG_ARN" \
  --query 'TargetHealthDescriptions[*].{ID:Target.Id,State:TargetHealth.State}' \
  --output table
```

---

## 5. Limpieza

```bash
# Desde lab28/aws/
terraform destroy
```

El destroy elimina recursos en orden inverso. El NAT Gateway, el ALB y las instancias del ASG tardan varios minutos en destruirse completamente.

> El bucket S3 de estado (`terraform-state-labs-<ACCOUNT_ID>`) no se destruye: se reutiliza en otros laboratorios.

---

## 6. LocalStack

Para ejecutar este laboratorio sin cuenta de AWS, consulta [localstack/README.md](localstack/README.md).

LocalStack Community soporta VPC, subnets y Launch Templates completamente. El ALB y el ASG tienen soporte parcial: los recursos se crean pero las instancias no se lanzan realmente y el DNS del ALB no resuelve a backends funcionales. Para observar el comportamiento dinámico del rolling update y el escalado, se requiere AWS real o LocalStack Pro.

---

## 7. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| VPC, subnets, route tables | Infraestructura real | Soportado |
| NAT Gateway | Activo, con coste por hora y datos | Simulado sin coste |
| ALB con DNS funcional | Resuelve a instancias reales | DNS simulado, sin backends reales |
| Instancias EC2 en ASG | Se lanzan, ejecutan `user_data` y pasan health checks | No se lanzan instancias reales |
| Instance Refresh visible | Reemplaza instancias gradualmente | Registra la operación sin efecto real |
| Target Tracking Scaling | CloudWatch emite métricas y el ASG escala | Sin métricas reales — no escala |
| Coste aproximado del lab | ~$0.10–0.20/hora (NAT GW + ALB + EC2) | Sin coste |

---

## Buenas prácticas aplicadas

- **Un NAT Gateway por AZ.** Este laboratorio crea un NAT Gateway por AZ (`count = length(local.azs)`). Si una zona cae, las instancias de las AZs restantes conservan su conectividad de salida. Usar un único NAT Gateway abarataría el laboratorio, pero convertiría ese recurso en un SPOF de la conectividad de salida.
- **Usa `version = aws_launch_template.web.latest_version` en lugar de `"$Latest"`.** El puntero `$Latest` no cambia en el estado de Terraform, por lo que no activa el `instance_refresh` al actualizar el template. Referenciar `latest_version` directamente garantiza que Terraform detecta el cambio.
- **Ajusta `min_healthy_percentage` según tu SLA.** Al 90% con 10 instancias, el ASG puede reemplazar como máximo 1 instancia a la vez. Al 50% puede reemplazar 5 simultáneamente (más rápido, pero con mayor riesgo).
- **Combina `instance_warmup` con el tiempo real de arranque de tu aplicación.** Si `user_data` tarda 90 segundos en levantar el servicio, configura `instance_warmup = 120` para que el ASG no evalúe la salud antes de que la instancia esté lista.
- **Habilita `enabled_metrics` en el ASG.** Sin este bloque, CloudWatch solo recibe métricas de instancia individuales con granularidad de 5 minutos. Con `metrics_granularity = "1Minute"` y `enabled_metrics`, el ASG publica métricas propias (instancias en servicio, pendientes, terminando…) cada minuto, lo que acelera la respuesta del Target Tracking y permite monitorizar el escalado en tiempo real desde la consola de CloudWatch.
- **Usa `health_check_type = "ELB"` siempre que tengas un ALB.** El health check de tipo EC2 solo comprueba que la instancia está encendida; el de tipo ELB comprueba que la aplicación responde correctamente al health check del target group.
- **Protege las subredes privadas.** Los Security Groups de las instancias solo deben aceptar tráfico del Security Group del ALB, nunca de `0.0.0.0/0`. Así, ningún atacante puede llegar directamente a las instancias aunque conozca su IP.

---

## Recursos

- [aws_launch_template — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/launch_template)
- [aws_autoscaling_group — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_group)
- [aws_autoscaling_schedule — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/autoscaling_schedule)
- [aws_cloudwatch_metric_alarm — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/cloudwatch_metric_alarm)
- [aws_sns_topic — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/sns_topic)
- [aws_lb / aws_lb_listener — Terraform Registry](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/lb)
- [Instance Refresh — AWS Docs](https://docs.aws.amazon.com/autoscaling/ec2/userguide/asg-instance-refresh.html)
- [Target Tracking Scaling — AWS Docs](https://docs.aws.amazon.com/autoscaling/ec2/userguide/as-scaling-target-tracking.html)
- [Scheduled Scaling — AWS Docs](https://docs.aws.amazon.com/autoscaling/ec2/userguide/ec2-auto-scaling-scheduled-scaling.html)
- [Multi-AZ ASG — AWS Docs](https://docs.aws.amazon.com/autoscaling/ec2/userguide/auto-scaling-benefits.html)
