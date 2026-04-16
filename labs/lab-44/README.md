# Laboratorio 44 — Entrega Continua con CodeDeploy

[← Módulo 10 — CI/CD y Automatización con Terraform](../../modulos/modulo-10/README.md)


## Visión general

En este laboratorio separarás la responsabilidad de la infraestructura (Terraform) de la del
software (CodeDeploy). Terraform crea y gestiona todos los recursos AWS necesarios para la
plataforma de despliegue: el ALB con su Target Group, el ASG con 4 instancias Graviton, la
alarma de CloudWatch y la configuración de CodeDeploy. Una vez desplegada la infraestructura,
usarás CodeDeploy para entregar dos versiones de una aplicación web mediante una estrategia
**IN_PLACE rolling**: las instancias se actualizan por lotes manteniendo siempre al menos el
75 % del fleet disponible bajo el ALB.

## Objetivos

- Separar la gestión de infraestructura (Terraform) de la gestión de software (CodeDeploy)
- Configurar un Deployment Group de CodeDeploy IN_PLACE con control de tráfico ALB
- Implementar una política de salud mínima (`FLEET_PERCENT`) para despliegues rolling
- Configurar una CloudWatch Alarm con Metric Math para detectar tasas de error 5xx
- Encadenar la alarma con CodeDeploy para obtener rollback automático basado en métricas reales
- Gestionar el ciclo de vida de los ficheros con hooks de `appspec.yml` (`BeforeInstall`)
- Usar `ignore_changes` en el ASG para coexistir con CodeDeploy

## Requisitos previos

- Laboratorio 02 completado (bucket S3 para el backend de Terraform)
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.5 instalado

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGION="us-east-1"
```

## Arquitectura

```
                    Internet
                        │
                ┌───────▼───────┐
                │      IGW      │
                └───────┬───────┘
                        │
  ┌───── VPC  10.44.0.0/16 ───────────────────────────────┐
  │                                                       │
  │   Subredes públicas  (10.44.0.0/24 · 10.44.1.0/24)    │
  │  ┌─────────────────────────────────────────────────┐  │
  │  │  ┌──────────────────────┐  ┌─────────────────┐  │  │
  │  │  │         ALB          │  │   NAT Gateway   │  │  │
  │  │  │      app-tg (80)     │  │      (EIP)      │  │  │
  │  │  └──────────────────────┘  └─────────────────┘  │  │
  │  └─────────────────────────────────────────────────┘  │
  │               │                       ▲               │
  │           HTTP (80)              salida EC2           │
  │               │                       │               │
  │   Subredes privadas  (10.44.10.0/24 · 10.44.11.0/24)  │
  │  ┌─────────────────────────────────────────────────┐  │
  │  │  ┌─────────────────────────────────────────┐    │  │
  │  │  │   ASG app  (t4g.micro, ARM64)  min=4    │    │  │
  │  │  │   ├── Instancia EC2 (AZ-a)              │    │  │
  │  │  │   ├── Instancia EC2 (AZ-a)              │    │  │
  │  │  │   ├── Instancia EC2 (AZ-b)              │    │  │
  │  │  │   └── Instancia EC2 (AZ-b)              │    │  │
  │  │  │   Apache + agente CodeDeploy            │    │  │
  │  │  └─────────────────────────────────────────┘    │  │
  │  └─────────────────────────────────────────────────┘  │
  └───────────────────────────────────────────────────────┘

  IAM: EC2 Instance Profile
  ├── S3 (leer artefactos)
  ├── SSM (Session Manager, sin SSH)
  └── CloudWatch (métricas)

  CodeDeploy Application
  └── Deployment Group (IN_PLACE)
      ├── WITH_TRAFFIC_CONTROL (ALB)
      ├── MinimumHealthy75Pct  (lotes de 1 instancia)
      ├── auto_rollback: DEPLOYMENT_FAILURE
      │                  DEPLOYMENT_STOP_ON_ALARM
      └── Alarm: 5xx error rate > 1%

  CloudWatch Alarm
  └── Metric Math: IF(requests>0, errors/requests*100, 0)
      evaluation_periods: 2 × 60 s
```

## Conceptos clave

### Separación de responsabilidades: Terraform vs CodeDeploy

| Aspecto | Terraform | CodeDeploy |
|---------|-----------|------------|
| Qué gestiona | Infraestructura (ALB, ASG, SGs, IAM...) | Software (ciclo de vida del despliegue) |
| Cuándo se ejecuta | Al cambiar la infraestructura | En cada nuevo release de la aplicación |
| Fuente de verdad | Código HCL en el repositorio | Artefacto zip en S3 + appspec.yml |
| Rollback | `terraform apply` con versión anterior | Automático por alarma o manual |

### Despliegue IN_PLACE rolling con CodeDeploy y ASG

En un despliegue IN_PLACE, CodeDeploy actualiza las instancias **existentes** del ASG por lotes.
Con `MinimumHealthy75Pct` y 4 instancias, el lote máximo es 1 instancia (25 %), de modo que
siempre quedan 3 instancias activas bajo el ALB:

```
ASG (4 instancias)
  │
  ├── Instancia A  ──► deregistrada del TG → deploy → registrada  (lote 1)
  ├── Instancia B  ──► deregistrada del TG → deploy → registrada  (lote 2)
  ├── Instancia C  ──► deregistrada del TG → deploy → registrada  (lote 3)
  └── Instancia D  ──► deregistrada del TG → deploy → registrada  (lote 4)
```

Durante el deregister, el ALB drena las conexiones existentes (`deregistration_delay = 10 s`)
antes de dejar de enviar tráfico a la instancia.

### Ciclo de vida de un despliegue IN_PLACE

```
Por cada lote de instancias:

[1] DEREGISTER
    ALB deja de enviar tráfico (draining 10 s)
          │
[2] ApplicationStop
    Para Apache si está en ejecución
          │
[3] BeforeInstall
    Elimina ficheros existentes (/var/www/html/index.html, /health)
          │
[4] Install
    CodeDeploy copia los ficheros del zip a /var/www/html
          │
[5] AfterInstall
    Arranca Apache con la nueva versión
          │
[6] ValidateService
    curl http://localhost/health → debe responder 200
          │
[7] REGISTER
    Instancia vuelve al Target Group del ALB
          │
    Si ValidateService falla o la alarma 5xx se dispara
          └──► ROLLBACK: reinstala la revisión anterior
```

### Hooks del appspec.yml

| Hook | Cuándo se ejecuta | Uso en este lab |
|------|-------------------|-----------------|
| `ApplicationStop` | Antes de instalar | Detiene Apache |
| `BeforeInstall` | Antes de copiar ficheros | Elimina ficheros previos |
| `AfterInstall` | Después de copiar ficheros | Arranca Apache |
| `ValidateService` | Al final del ciclo | Verifica `/health` responde 200 |

> **`BeforeInstall` es necesario** porque el `user_data` crea `index.html` y `health` en el
> primer arranque. Sin este hook, CodeDeploy fallaría con `file already exists at this location`.

El **exit code** del script determina el resultado:
- `exit 0` → hook exitoso, continuar
- `exit != 0` → hook fallido, CodeDeploy marca la instancia como fallida

### Rollback automático por alarma

CodeDeploy monitoriza las alarmas de CloudWatch durante todo el despliegue. Cuando una alarma
pasa a estado `ALARM`:

1. CodeDeploy detiene el despliegue (`DEPLOYMENT_STOP_ON_ALARM`)
2. El rollback reinstala la revisión anterior en las instancias afectadas
3. Si el trigger está configurado (Reto 1), se envían notificaciones vía SNS

La alarma usa **Metric Math** para calcular la tasa de errores 5xx:

```
IF(requests > 0, (errors / requests) * 100, 0)
```

donde `errors` = `HTTPCode_Target_5XX_Count` y `requests` = `RequestCount` del ALB.

### `ignore_changes` para coexistir con CodeDeploy

CodeDeploy puede modificar la `desired_capacity` del ASG durante el despliegue. Sin
`ignore_changes`, `terraform plan` detectaría el cambio como drift:

```hcl
lifecycle {
  ignore_changes = [desired_capacity]
}
```

### IN_PLACE vs Blue/Green vs Canary

| Estrategia | Instancias | Rollback | Tiempo sin servicio | Coste extra |
|-----------|-----------|---------|--------------------| ------------|
| IN_PLACE rolling (este lab) | Existentes, por lotes | Reinstala revisión anterior | No (rolling) | Ninguno |
| Blue/Green | Nuevas (copia del ASG) | Redirige Listener al Blue TG | No | Doble fleet durante ventana |
| Canary (ECS/Lambda) | Nuevas | Redirige tráfico de vuelta | No | Parcial según % canary |

El despliegue IN_PLACE con `FLEET_PERCENT: 75` es la opción más económica: no hay instancias
adicionales en ningún momento y el rollback simplemente reinstala el artefacto anterior en las
instancias afectadas.

## Estructura del proyecto

```
lab44/
├── aws/
│   ├── providers.tf        # Proveedor AWS y backend S3
│   ├── variables.tf        # Variables con validaciones
│   ├── vpc.tf              # VPC, subredes, IGW, NAT Gateway, tablas de rutas
│   ├── main.tf             # Security Groups, ALB, Target Group, S3, Launch Template, ASG
│   ├── deploy.tf           # CloudWatch Alarm, SNS, CodeDeploy App/Config/Deployment Group
│   ├── iam.tf              # Roles para CodeDeploy y las instancias EC2
│   ├── outputs.tf          # Outputs y comandos de despliegue
│   └── aws.s3.tfbackend    # Configuración parcial del backend
└── app/
    ├── v1/                 # Versión 1 (tema azul oscuro)
    │   ├── appspec.yml     # Ciclo de vida del despliegue
    │   ├── index.html      # Página web
    │   ├── health          # Endpoint de health check
    │   └── scripts/
    │       ├── before_install.sh   # Elimina ficheros previos
    │       ├── stop_server.sh      # Para Apache
    │       ├── start_server.sh     # Arranca Apache
    │       └── validate_service.sh # Verifica /health
    └── v2/                 # Versión 2 (tema verde oscuro)
        ├── appspec.yml
        ├── index.html
        ├── health
        └── scripts/
            ├── before_install.sh
            ├── stop_server.sh
            ├── start_server.sh
            └── validate_service.sh
```

---

## Paso 1 — Desplegar la infraestructura con Terraform

### Inicializar y aplicar

Desde el directorio `lab44/aws/`:

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=terraform-state-labs-${ACCOUNT_ID}"

terraform plan
terraform apply
```

Terraform creará:

- 1 VPC (10.44.0.0/16) con DNS habilitado
- 2 subredes públicas + 2 subredes privadas en AZs con soporte ARM64
- 1 Internet Gateway + 1 NAT Gateway (con IP elástica)
- 2 tablas de rutas (pública → IGW, privada → NAT GW)
- 2 Security Groups (ALB y EC2)
- 1 ALB en subredes públicas + 1 Target Group + 1 Listener
- 1 S3 bucket para artefactos
- 1 Launch Template (ARM64 / Graviton `t4g.micro`) + 1 ASG con 4 instancias en subredes privadas
- 1 CloudWatch Alarm (tasa de errores 5xx)
- 1 SNS Topic + trigger + suscripción de correo (Reto 1)
- 1 CodeDeploy Application + Deployment Config + Deployment Group
- 2 roles IAM (CodeDeploy y EC2)

### Verificar las instancias

Las instancias tardan ~3 minutos en arrancar: primero instalan Apache (que responde `/health`
de inmediato), y después actualizan el sistema e instalan el agente CodeDeploy.

```bash
ALB_DNS=$(terraform output -raw alb_dns_name)

# Verificar health check
curl http://${ALB_DNS}/health
# Esperado: OK

# Estado de las instancias en el Target Group
APP_TG_ARN=$(terraform output -raw app_tg_arn)
aws elbv2 describe-target-health \
  --target-group-arn "${APP_TG_ARN}" \
  --query "TargetHealthDescriptions[*].{id:Target.Id,health:TargetHealth.State}"
```

> Las instancias deben mostrar estado `healthy` antes de continuar. Si aparecen como
> `unhealthy`, verifica que el agente CodeDeploy está instalado con Session Manager.

---

## Paso 2 — Desplegar la versión 1

```bash
BUCKET=$(terraform output -raw artifacts_bucket_name)
APP_NAME=$(terraform output -raw codedeploy_app_name)
DG_NAME=$(terraform output -raw codedeploy_deployment_group_name)

cd ../app/v1
zip -r /tmp/app-v1.zip .
aws s3 cp /tmp/app-v1.zip s3://${BUCKET}/releases/v1.zip

DEPLOY_ID=$(aws deploy create-deployment \
  --application-name "${APP_NAME}" \
  --deployment-group-name "${DG_NAME}" \
  --s3-location bucket=${BUCKET},bundleType=zip,key=releases/v1.zip \
  --description "Despliegue inicial de v1" \
  --query "deploymentId" --output text)

echo "Deployment ID: ${DEPLOY_ID}"
```

### Seguir el progreso

```bash
watch -n 10 "aws deploy get-deployment \
  --deployment-id ${DEPLOY_ID} \
  --query 'deploymentInfo.{status:status,succeeded:deploymentOverview.Succeeded,failed:deploymentOverview.Failed,skipped:deploymentOverview.Skipped}'"
```

En la consola de AWS puedes ver el progreso en **CodeDeploy → Deployments → ${DEPLOY_ID}**.
Observarás cómo CodeDeploy procesa las instancias de una en una, manteniendo las 3 restantes
activas bajo el ALB.

### Verificar la aplicación v1

```bash
ALB_DNS=$(cd ../aws && terraform output -raw alb_dns_name)
curl http://${ALB_DNS}/
# Esperado: página con "v1" y tema azul oscuro
```

---

## Paso 3 — Desplegar la versión 2 (rolling IN_PLACE)

```bash
cd ../v2
zip -r /tmp/app-v2.zip .
aws s3 cp /tmp/app-v2.zip s3://${BUCKET}/releases/v2.zip

DEPLOY_ID=$(aws deploy create-deployment \
  --application-name "${APP_NAME}" \
  --deployment-group-name "${DG_NAME}" \
  --s3-location bucket=${BUCKET},bundleType=zip,key=releases/v2.zip \
  --description "Despliegue rolling IN_PLACE de v2" \
  --query "deploymentId" --output text)

echo "Deployment ID: ${DEPLOY_ID}"
```

### Observar el rolling update

```bash
watch -n 10 "aws deploy get-deployment \
  --deployment-id ${DEPLOY_ID} \
  --query 'deploymentInfo.{status:status,overview:deploymentOverview}'"
```

Mientras el despliegue está en progreso, recarga la URL del ALB varias veces: verás que algunas
respuestas son v1 (instancias aún sin actualizar) y otras v2 (instancias ya actualizadas). Esta
mezcla es característica del rolling update.

---

## Paso 4 — Prueba de rollback automático

Esta prueba demuestra que CodeDeploy revierte el despliegue automáticamente cuando la alarma
de errores 5xx se activa.

### Lanzar un despliegue

```bash
DEPLOY_ID=$(aws deploy create-deployment \
  --application-name "${APP_NAME}" \
  --deployment-group-name "${DG_NAME}" \
  --s3-location bucket=${BUCKET},bundleType=zip,key=releases/v2.zip \
  --description "Despliegue para prueba de rollback" \
  --query "deploymentId" --output text)
```

### Simular la alarma de errores 5xx

Activa la alarma mientras el despliegue está `InProgress`:

```bash
ALARM_NAME=$(cd ../aws && terraform output -raw alarm_name)

aws cloudwatch set-alarm-state \
  --alarm-name "${ALARM_NAME}" \
  --state-value ALARM \
  --state-reason "Simulación de tasa de error 5xx elevada para prueba de rollback"
```

### Observar el rollback

```bash
aws deploy get-deployment \
  --deployment-id "${DEPLOY_ID}" \
  --query "deploymentInfo.{status:status,rollback:rollbackInfo}"
```

Esperado:
```json
{
  "status": "Stopped",
  "rollback": {
    "rollbackDeploymentId": "d-XXXXXXXXX",
    "rollbackMessage": "Deployment d-XXXXXXXXX terminated. Automatic rollback is triggered with a DeploymentId d-XXXXXXXXX."
  }
}
```

### Restablecer la alarma

```bash
aws cloudwatch set-alarm-state \
  --alarm-name "${ALARM_NAME}" \
  --state-value OK \
  --state-reason "Restablecimiento manual post-prueba"
```

---

## Paso 5 — Inspeccionar las instancias con Session Manager

Las instancias no tienen SSH expuesto. Usa AWS Session Manager:

```bash
# Listar instancias del ASG
aws autoscaling describe-auto-scaling-instances \
  --query "AutoScalingInstances[?AutoScalingGroupName=='lab44-app-asg'].{id:InstanceId,state:LifecycleState}"

# Abrir sesión en una instancia
aws ssm start-session --target "<id-de-la-instancia>"
```

### Verificar el agente CodeDeploy

Una vez dentro de la sesión, comprueba que el agente está activo:

```bash
sudo systemctl status codedeploy-agent
```

Salida esperada:
```
● codedeploy-agent.service - AWS CodeDeploy Host Agent
     Loaded: loaded (/usr/lib/systemd/system/codedeploy-agent.service; enabled)
     Active: active (running) since ...
```

### Logs del agente CodeDeploy

El agente registra cada paso del ciclo de vida en:

```
/var/log/aws/codedeploy-agent/codedeploy-agent.log
```

**Seguir el despliegue en tiempo real** (ejecuta esto justo antes de lanzar el `create-deployment`):

```bash
sudo tail -f /var/log/aws/codedeploy-agent/codedeploy-agent.log
```

**Ver los últimos 50 eventos** tras un despliegue:

```bash
sudo tail -50 /var/log/aws/codedeploy-agent/codedeploy-agent.log
```

**Filtrar por un Deployment ID concreto** (por ejemplo `d-ABC1234EF`):

```bash
sudo grep "d-ABC1234EF" /var/log/aws/codedeploy-agent/codedeploy-agent.log
```

**Ver solo los hooks ejecutados y su resultado:**

```bash
sudo grep -E "(Executing|error_code)" /var/log/aws/codedeploy-agent/codedeploy-agent.log | tail -30
```

### Anatomía de un despliegue en los logs

Un despliegue exitoso genera una secuencia de entradas como la siguiente. Cada bloque
corresponde a un evento del ciclo de vida:

```
[Aws::CodeDeploy::Agent] ... Processing DeploymentCommand ... command_name=BlockTraffic
[Aws::CodeDeploy::Agent] ... Executing command ... command_name=BlockTraffic
[Aws::CodeDeploy::Agent] ... Received command ... command_name=ApplicationStop
[Aws::CodeDeploy::Agent] ... Executing lifecycle script: scripts/stop_server.sh
[Aws::CodeDeploy::Agent] ... {"status":"Succeeded","error_code":0,...}
[Aws::CodeDeploy::Agent] ... Received command ... command_name=BeforeInstall
[Aws::CodeDeploy::Agent] ... Executing lifecycle script: scripts/before_install.sh
[Aws::CodeDeploy::Agent] ... {"status":"Succeeded","error_code":0,...}
[Aws::CodeDeploy::Agent] ... Received command ... command_name=Install
[Aws::CodeDeploy::Agent] ... {"status":"Succeeded","error_code":0,...}
[Aws::CodeDeploy::Agent] ... Received command ... command_name=AfterInstall
[Aws::CodeDeploy::Agent] ... Executing lifecycle script: scripts/start_server.sh
[Aws::CodeDeploy::Agent] ... {"status":"Succeeded","error_code":0,...}
[Aws::CodeDeploy::Agent] ... Received command ... command_name=ValidateService
[Aws::CodeDeploy::Agent] ... Executing lifecycle script: scripts/validate_service.sh
[Aws::CodeDeploy::Agent] ... {"status":"Succeeded","error_code":0,...}
[Aws::CodeDeploy::Agent] ... Executing command ... command_name=AllowTraffic
[Aws::CodeDeploy::Agent] ... {"status":"Succeeded","error_code":0,...}
```

### Campos clave en los logs

| Campo | Descripción |
|-------|-------------|
| `command_name` | Evento del ciclo de vida: `BlockTraffic`, `ApplicationStop`, `BeforeInstall`, `Install`, `AfterInstall`, `ValidateService`, `AllowTraffic` |
| `status` | `Succeeded` o `Failed` |
| `error_code` | `0` = éxito; cualquier otro valor indica fallo. El agente reporta este código a CodeDeploy para decidir si continuar o marcar la instancia como fallida |
| `deployment_id` | ID del despliegue en curso (formato `d-XXXXXXXXX`) |
| `lifecycle_event_hook_execution_id` | Identificador único de cada ejecución de hook |

> **`BlockTraffic` y `AllowTraffic`** son eventos especiales gestionados por CodeDeploy
> (no por scripts del `appspec.yml`): desregistran y re-registran la instancia en el Target
> Group del ALB. El estado **Draining** que ves en la consola del ALB ocurre durante
> `BlockTraffic`, cuando el ALB drena las conexiones existentes durante el
> `deregistration_delay` antes de dejar de enviar tráfico.

### Diagnóstico de un fallo

Si un hook falla, el log mostrará `"status":"Failed"` y `"error_code"` distinto de `0`. Para
ver el output exacto del script fallido:

```bash
# Los logs detallados de cada ejecución de hook se guardan aquí:
sudo ls /opt/codedeploy-agent/deployment-root/
# Estructura: <deployment-id>/<deployment-group-id>/logs/scripts.log

# Ejemplo:
sudo find /opt/codedeploy-agent/deployment-root/ -name "scripts.log" | \
  xargs sudo tail -30
```

El fichero `scripts.log` captura el stdout y stderr del script, lo que permite ver exactamente
qué línea falló y por qué.

---

## Verificación final

Ejecuta desde el directorio `lab44/aws/`:

```bash
# ── 1. Outputs de Terraform ──────────────────────────────────────────────────
terraform output

# ── 2. ALB responde ──────────────────────────────────────────────────────────
curl http://$(terraform output -raw alb_dns_name)/health
# Esperado: OK

# ── 3. Instancias en estado healthy en el Target Group ───────────────────────
aws elbv2 describe-target-health \
  --target-group-arn "$(terraform output -raw app_tg_arn)" \
  --query "TargetHealthDescriptions[*].{id:Target.Id,estado:TargetHealth.State}"
# Esperado: las 4 instancias en estado "healthy"

# ── 4. Configuración del Deployment Group ────────────────────────────────────
aws deploy get-deployment-group \
  --application-name "$(terraform output -raw codedeploy_app_name)" \
  --deployment-group-name "$(terraform output -raw codedeploy_deployment_group_name)" \
  --query "deploymentGroupInfo.{tipo:deploymentStyle.deploymentType,config:deploymentConfigName}"
# Esperado:
# {
#   "tipo": "IN_PLACE",
#   "config": "lab44-MinimumHealthy75Pct"
# }

# ── 5. Alarma en estado OK ───────────────────────────────────────────────────
aws cloudwatch describe-alarms \
  --alarm-names "$(terraform output -raw alarm_name)" \
  --query "MetricAlarms[0].{nombre:AlarmName,estado:StateValue}"
# Esperado: "estado": "OK" (o "INSUFFICIENT_DATA" si aún no hay tráfico)
```

---

## Retos

### Reto 1 — Notificaciones de despliegue por correo electrónico

La infraestructura base no incluye ningún sistema de notificaciones: no hay SNS Topic, el
Deployment Group no tiene trigger y nadie recibe avisos cuando un despliegue empieza, falla
o hace rollback. Tu tarea es implementar el sistema de notificaciones completo desde cero.

1. En `aws/variables.tf`: añade una variable `alert_email` de tipo `string` con una validación
   que rechace valores que no tengan el formato de una dirección de correo electrónico
   (`can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))`).
2. En `aws/deploy.tf`: añade un recurso `aws_sns_topic` llamado `${var.project}-deployments`.
3. En `aws/deploy.tf`: añade un bloque `trigger_configuration` dentro del recurso
   `aws_codedeploy_deployment_group.inplace` con `trigger_name = "notify-deployments"`,
   `trigger_target_arn = aws_sns_topic.deployments.arn` y los eventos
   `DeploymentStart`, `DeploymentSuccess`, `DeploymentFailure`, `DeploymentRollback`,
   `DeploymentStop`.
4. En `aws/deploy.tf`: añade un recurso `aws_sns_topic_subscription` con
   `protocol = "email"`, `topic_arn = aws_sns_topic.deployments.arn` y
   `endpoint = var.alert_email`.
5. En `aws/outputs.tf`: añade un output `deployments_topic_arn` con el ARN del topic.
6. Ejecuta `terraform apply`, confirma la suscripción en el correo que recibirás de AWS
   (asunto *AWS Notification - Subscription Confirmation*), lanza un despliegue de v1 o v2
   y verifica que recibes los eventos `DeploymentStart` y `DeploymentSuccess`. Después simula
   un rollback con el comando `set-alarm-state` del README y verifica que llega el evento
   `DeploymentStop` con el motivo del rollback.

---

### Reto 2 — Grupo de despliegue de desarrollo con estrategia all-at-once

El Deployment Group de producción actualiza una instancia por lote para
mantener el 75 % del fleet disponible durante el despliegue. En un entorno de
desarrollo la disponibilidad es secundaria y el objetivo es reducir el tiempo
total del despliegue al mínimo. Tu tarea es crear un segundo Deployment Group
que actualice todas las instancias simultáneamente, usando la misma aplicación
CodeDeploy pero una configuración de despliegue distinta, y comparar el tiempo
de ejecución frente al grupo de producción.

1. En `aws/deploy.tf`: crea un nuevo `aws_codedeploy_deployment_config` llamado
   `${var.project}-AllAtOnce` con `compute_platform = "Server"` y
   `minimum_healthy_hosts { type = "HOST_COUNT", value = 0 }`. El valor `0`
   indica que CodeDeploy puede poner todas las instancias fuera de servicio a la
   vez; es el equivalente al preset `CodeDeployDefault.AllAtOnce`.
2. En `aws/deploy.tf`: crea un segundo `aws_codedeploy_deployment_group` llamado
   `${var.project}-dev-dg` que use el nuevo config, el mismo ASG
   (`aws_autoscaling_group.app.name`) y el mismo Target Group
   (`aws_lb_target_group.app.name`). Configura `auto_rollback_configuration`
   solo para `DEPLOYMENT_FAILURE` (sin alarma de métricas: en dev se acepta
   tráfico degradado puntualmente).
3. En `aws/outputs.tf`: añade un output `codedeploy_dev_deployment_group_name`
   con el nombre del nuevo grupo.
4. Ejecuta `terraform apply` y lanza el mismo artefacto sobre los dos grupos
   en paralelo con dos llamadas `aws deploy create-deployment`. Mide el tiempo
   de cada uno con `time` o comparando los timestamps en la consola de
   CodeDeploy. Con 4 instancias y `start_server.sh` consultando el IMDS, la
   diferencia debería ser de 3× a 4×.

---

## Soluciones

<details>
<summary>Reto 1 — Notificaciones de despliegue por correo electrónico</summary>

### Por qué no llegan notificaciones por defecto

Son tres piezas que deben encajar: el SNS Topic (el bus), el `trigger_configuration` en el
Deployment Group (el emisor) y la `aws_sns_topic_subscription` (el receptor). Si falta
cualquiera de las tres, el sistema es mudo:

- **Sin SNS Topic**: no hay bus. El trigger no tiene dónde publicar.
- **Sin trigger en el Deployment Group**: CodeDeploy emite eventos internamente pero no los
  envía a ningún sitio externo. El topic existe pero nunca recibe mensajes.
- **Sin suscripción**: SNS recibe los mensajes pero los descarta silenciosamente. No hay
  reintentos ni almacenamiento — el mensaje desaparece.

### Pieza 1 — Variable de entrada

La dirección de correo se parametriza para que el mismo código funcione en cualquier entorno
sin tocar el fichero `.tf`. La validación rechaza valores que no tengan el formato
`algo@dominio.tld` antes de que Terraform llegue a llamar a AWS, lo que evita crear una
suscripción con un endpoint inválido que nunca recibirá la confirmación.

```hcl
# variables.tf
variable "alert_email" {
  type        = string
  description = "Dirección de correo para recibir notificaciones de despliegue."

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))
    error_message = "El valor debe ser una dirección de correo electrónico válida."
  }
}
```

### Pieza 2 — SNS Topic

El topic es el bus central. CodeDeploy publica en él a través del trigger; cualquier número
de suscriptores (correo, Lambda, SQS, HTTP...) pueden escucharlo de forma independiente sin
que el emisor necesite saber quién está al otro lado.

```hcl
# deploy.tf
resource "aws_sns_topic" "deployments" {
  name = "${var.project}-deployments"

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}
```

### Pieza 3 — Trigger en el Deployment Group

El bloque `trigger_configuration` le dice a CodeDeploy: "cuando ocurra cualquiera de estos
eventos, publica un mensaje en este ARN de SNS". Se añade **dentro** del recurso
`aws_codedeploy_deployment_group.inplace` existente:

```hcl
# deploy.tf — dentro de aws_codedeploy_deployment_group.inplace
  trigger_configuration {
    trigger_name       = "notify-deployments"
    trigger_target_arn = aws_sns_topic.deployments.arn
    trigger_events = [
      "DeploymentStart",
      "DeploymentSuccess",
      "DeploymentFailure",
      "DeploymentRollback",
      "DeploymentStop",
    ]
  }
```

Los cinco eventos cubren todo el ciclo de vida: inicio, éxito, fallo técnico, rollback
automático y parada manual. `DeploymentRollback` se dispara cuando CodeDeploy instala la
revisión anterior; es distinto de `DeploymentStop`, que se dispara cuando el despliegue se
detiene (por alarma o manualmente) antes de completarse.

### Pieza 4 — Suscripción de correo

La suscripción conecta el topic con el endpoint de correo. A diferencia de protocolos como
SQS o Lambda, el protocolo `email` requiere confirmación manual: AWS envía un correo al
endpoint con un enlace que el destinatario debe pulsar antes de que SNS empiece a entregarle
mensajes.

```hcl
# deploy.tf
resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.deployments.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
```

> Terraform crea la suscripción y la deja en estado `PendingConfirmation`. El recurso no
> espera a que el usuario confirme — `terraform apply` termina inmediatamente. Si lanzas un
> despliegue antes de confirmar, los mensajes se pierden.

### Pieza 5 — Output

El ARN del topic se exporta para poder inspeccionarlo desde la CLI sin entrar a la consola:

```hcl
# outputs.tf
output "deployments_topic_arn" {
  description = "ARN del SNS Topic de notificaciones de despliegue."
  value       = aws_sns_topic.deployments.arn
}
```

### Flujo de confirmación y verificación

1. Tras `terraform apply`, AWS envía un correo con asunto
   *AWS Notification - Subscription Confirmation*. Pulsa el enlace *Confirm subscription*.

2. Comprueba que la suscripción está activa:

   ```bash
   TOPIC_ARN=$(terraform output -raw deployments_topic_arn)
   aws sns list-subscriptions-by-topic --topic-arn "${TOPIC_ARN}" \
     --query "Subscriptions[0].{protocolo:Protocol,endpoint:Endpoint,estado:SubscriptionArn}"
   ```

   Mientras no se confirme, `SubscriptionArn` vale `PendingConfirmation`.
   Tras confirmar, mostrará el ARN real de la suscripción.

3. Lanza un despliegue y verifica que llegan los eventos `DeploymentStart` y
   `DeploymentSuccess` al correo.

4. Simula el rollback con `set-alarm-state` y verifica que llega `DeploymentStop`
   con el motivo en el cuerpo del mensaje.

</details>

<details>
<summary>Reto 2 — Grupo de despliegue de desarrollo con estrategia all-at-once</summary>

### La mecánica de `minimum_healthy_hosts`

`minimum_healthy_hosts` es el parámetro que controla el tamaño de cada lote. CodeDeploy
calcula el lote máximo como el complemento: las instancias que puede actualizar a la vez son
las que superen ese mínimo.

Con `FLEET_PERCENT: 75` y 4 instancias:
- Mínimo sano = 75 % de 4 = 3 instancias
- Lote máximo = 4 − 3 = **1 instancia por ronda → 4 rondas en total**

Con `HOST_COUNT: 0`:
- Mínimo sano = 0 instancias
- Lote máximo = 4 − 0 = **4 instancias por ronda → 1 sola ronda**

El valor `HOST_COUNT: 0` es lo que AWS llama internamente `CodeDeployDefault.AllAtOnce`.
No significa que las instancias se actualicen simultáneamente dentro de la ronda — el agente
CodeDeploy en cada instancia trabaja en paralelo de forma independiente —, sino que CodeDeploy
no espera a que una instancia termine antes de enviar el comando a la siguiente. El efecto
práctico es que todas las instancias ejecutan los hooks al mismo tiempo.

### Por qué dev no necesita alarma de métricas

El grupo de producción tiene `DEPLOYMENT_STOP_ON_ALARM` encadenado con la alarma 5xx: si la
tasa de error sube durante el despliegue, CodeDeploy para y revierte. En desarrollo esto es
contraproducente: el entorno ya no sirve tráfico real y el ruido de la alarma interrumpiría
despliegues de prueba. Por eso el grupo dev solo tiene `DEPLOYMENT_FAILURE`, que revierte
únicamente si un hook falla con exit code distinto de 0 — un fallo técnico real, no una
métrica de negocio.

### Pieza 1 — Deployment Config personalizado

La configuración de despliegue es un recurso independiente que se puede reutilizar en
varios Deployment Groups. Definir uno propio en lugar de usar el preset
`CodeDeployDefault.AllAtOnce` permite documentarlo como código y darle un nombre
significativo dentro del proyecto:

```hcl
# deploy.tf
resource "aws_codedeploy_deployment_config" "all_at_once" {
  deployment_config_name = "${var.project}-AllAtOnce"
  compute_platform       = "Server"

  minimum_healthy_hosts {
    type  = "HOST_COUNT"
    value = 0
  }
}
```

> `compute_platform = "Server"` es obligatorio para grupos EC2/ASG. Los valores `ECS` y
> `Lambda` tienen sus propios modelos de despliegue y no admiten `minimum_healthy_hosts`.

### Pieza 2 — Deployment Group de desarrollo

El grupo dev comparte la misma aplicación CodeDeploy (`aws_codedeploy_app.app`) y el mismo
ASG que el grupo de producción, pero usa el config `AllAtOnce` y omite la alarma:

```hcl
# deploy.tf
resource "aws_codedeploy_deployment_group" "dev" {
  app_name               = aws_codedeploy_app.app.name
  deployment_group_name  = "${var.project}-dev-dg"
  service_role_arn       = aws_iam_role.codedeploy.arn
  deployment_config_name = aws_codedeploy_deployment_config.all_at_once.id

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "IN_PLACE"
  }

  autoscaling_groups = [aws_autoscaling_group.app.name]

  load_balancer_info {
    target_group_info {
      name = aws_lb_target_group.app.name
    }
  }

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Env       = "dev"
  }
}
```

Mantener `WITH_TRAFFIC_CONTROL` también en dev es importante aunque actualice todas las
instancias a la vez: el ALB desregistra las 4 instancias antes de desplegar y las vuelve a
registrar después. Sin esto, el ALB enviaría tráfico a instancias en medio de la instalación.

### Pieza 3 — Output

```hcl
# outputs.tf
output "codedeploy_dev_deployment_group_name" {
  description = "Nombre del grupo de despliegue de desarrollo (all-at-once)."
  value       = aws_codedeploy_deployment_group.dev.deployment_group_name
}
```

### Comparación de tiempos en paralelo

Lanza los dos despliegues simultáneamente desde dos terminales:

```bash
# Terminal 1 — grupo de producción (rolling, 4 rondas)
time aws deploy create-deployment \
  --application-name "${APP_NAME}" \
  --deployment-group-name "${DG_NAME}" \
  --s3-location bucket=${BUCKET},bundleType=zip,key=releases/v2.zip \
  --query "deploymentId" --output text

# Terminal 2 — grupo de desarrollo (all-at-once, 1 ronda)
DEV_DG=$(terraform output -raw codedeploy_dev_deployment_group_name)

time aws deploy create-deployment \
  --application-name "${APP_NAME}" \
  --deployment-group-name "${DEV_DG}" \
  --s3-location bucket=${BUCKET},bundleType=zip,key=releases/v2.zip \
  --query "deploymentId" --output text
```

Con 4 instancias, `deregistration_delay = 10 s` y `start_server.sh` consultando el IMDS
(~2 s por instancia), los tiempos aproximados son:

| Grupo | Config | Lotes | Draining | Tiempo aprox. |
|-------|--------|-------|----------|---------------|
| `inplace-dg` | `MinimumHealthy75Pct` | 4 × 1 instancia | 4 × 10 s | ~120 s |
| `dev-dg` | `AllAtOnce` | 1 × 4 instancias | 1 × 10 s | ~40 s |

El `deregistration_delay` explica la mayor parte de la diferencia: con la configuración
rolling se paga ese tiempo de drenado **por cada lote** (4 veces). Con all-at-once se paga
una sola vez. La diferencia se amplía linealmente al aumentar el número de instancias o el
valor del `deregistration_delay`.

> Durante el despliegue all-at-once el ALB no tiene instancias `healthy` en el Target Group:
> todas están en `Draining` o instalando la nueva versión. Cualquier petición entrante
> recibirá un 503. Es el precio aceptable en desarrollo; en producción el rolling garantiza
> que siempre hay instancias disponibles.

</details>

---

## Limpieza

> Los recursos de este laboratorio tienen coste si se dejan activos: el NAT Gateway
> (~$1/día), el ALB y las 4 instancias EC2 `t4g.micro`.

```bash
cd labs/lab44/aws
terraform destroy
```

`force_destroy = true` en el bucket S3 garantiza que Terraform puede eliminarlo aunque
contenga objetos.

---

## Solución de problemas

**Las instancias aparecen como `unhealthy` en el Target Group**

El agente CodeDeploy tarda ~3 minutos en instalarse porque `user_data` ejecuta `dnf update`
antes de instalar el agente. Apache se instala primero para que `/health` responda desde el
arranque. Si las instancias siguen en `unhealthy` tras 5 minutos, conéctate con Session
Manager y verifica:

```bash
sudo systemctl status httpd codedeploy-agent
sudo tail -20 /var/log/aws/codedeploy-agent/codedeploy-agent.log
```

**Error `file already exists at this location` en el primer despliegue**

El `user_data` crea `index.html` y `health` al arrancar la instancia. El hook `BeforeInstall`
los elimina antes de que CodeDeploy copie los ficheros del artefacto. Si el error persiste,
verifica que `before_install.sh` tiene permisos de ejecución (`mode: "0755"` en la sección
`permissions` del `appspec.yml`).

**El despliegue falla en `BlockTraffic` con instancias en estado `Draining`**

Esto es comportamiento normal: `BlockTraffic` desregistra la instancia del ALB y el ALB
drena las conexiones existentes durante `deregistration_delay`. Una vez drenadas, el ciclo
continúa con `ApplicationStop`. No es un error.

**Error en el rol de CodeDeploy: `not authorized to perform: autoscaling:...`**

El rol `AWSCodeDeployRole` no incluye permisos para Launch Templates. Añade la política
inline `codedeploy-launch-template-support` con `ec2:RunInstances`, `ec2:CreateTags` y
`iam:PassRole` (ver `iam.tf`).

**`terraform plan` detecta drift en `desired_capacity` del ASG**

CodeDeploy modifica `desired_capacity` durante los despliegues. El bloque
`lifecycle { ignore_changes = [desired_capacity] }` en el recurso `aws_autoscaling_group`
evita que Terraform revierta este valor en el siguiente `apply`.

---

## Buenas prácticas aplicadas

- **Separación de responsabilidades**: Terraform gestiona infraestructura, CodeDeploy gestiona software.
- **Apache arranca antes que `dnf update`**: el `user_data` instala y arranca Apache en los primeros segundos para que el health check del ALB pase desde el arranque, sin esperar a que `dnf update` termine.
- **`BeforeInstall` limpia ficheros previos**: evita el error `file already exists` en primer despliegue y en despliegues sucesivos.
- **`ignore_changes` selectivo**: solo en `desired_capacity`, no en todo el ASG.
- **Rollback por alarma**: basado en métricas reales del ALB, no en heurísticas manuales.
- **`deregistration_delay = 10 s`**: valor reducido para laboratorio; en producción se ajusta al tiempo de respuesta máximo de la aplicación.
- **`health_check_grace_period = 300 s`**: evita que el ASG termine instancias mientras el agente CodeDeploy se instala.
- **VPC dedicada**: instancias en subredes privadas sin IP pública; solo el ALB y el NAT Gateway en subredes públicas.
- **ARM64 / Graviton**: `t4g.micro` ofrece mejor precio/rendimiento. Las subredes se crean solo en AZs que soportan el tipo de instancia configurado.
- **NAT Gateway único (laboratorio)**: un único NAT Gateway reduce costes. En producción se recomienda uno por AZ.
- **IMDSv2 obligatorio**: `http_tokens = "required"` en el Launch Template previene SSRF.
- **Session Manager**: acceso a las instancias sin SSH expuesto ni claves PEM.
- **Política de bucket**: fuerza HTTPS para todas las operaciones sobre el bucket de artefactos.

## Recursos

- [Documentación de AWS CodeDeploy](https://docs.aws.amazon.com/codedeploy/latest/userguide/welcome.html)
- [Despliegues IN_PLACE con CodeDeploy y ASG](https://docs.aws.amazon.com/codedeploy/latest/userguide/deployment-groups-create-in-place.html)
- [Referencia del appspec.yml para EC2](https://docs.aws.amazon.com/codedeploy/latest/userguide/reference-appspec-file-structure-hooks.html)
- [Rollback automático en CodeDeploy](https://docs.aws.amazon.com/codedeploy/latest/userguide/deployments-rollback-and-redeploy.html)
- [Metric Math en CloudWatch](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/using-metric-math.html)
- [Recurso aws_codedeploy_deployment_group](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/codedeploy_deployment_group)
- [Rol de servicio de CodeDeploy](https://docs.aws.amazon.com/codedeploy/latest/userguide/getting-started-create-service-role.html)
