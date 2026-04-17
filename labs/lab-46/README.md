# Laboratorio 46 — Observabilidad Proactiva y Dashboards as Code

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 11 — Observabilidad, Tagging y FinOps](../../modulos/modulo-11/README.md)


## Visión general

Construye un sistema de monitoreo completo sobre AWS CloudWatch que no se limita a visualizar
datos, sino que aprende de ellos para reducir la fatiga de alertas. El laboratorio recorre cinco
capas de observabilidad: registro estructurado con cifrado KMS, conversión de texto a métricas,
detección de anomalías con Machine Learning, reducción de ruido con alarmas compuestas y
visualización dinámica como código.

Una instancia EC2 genera logs de aplicación continuamente. El CloudWatch Agent los envía a un
log group cifrado, desde donde un metric filter convierte las líneas `[ERROR]` en una métrica
numérica. Sobre esa métrica y las métricas nativas de EC2 se construyen cuatro alarmas y un
dashboard con cinco widgets, todo definido como código Terraform.

## Objetivos

- Configurar un log group con cifrado KMS y retención limitada
- Enviar logs estructurados desde EC2 mediante el CloudWatch Agent
- Transformar texto de logs en métricas numéricas con un Log Metric Filter
- Implementar Anomaly Detection con Machine Learning para detectar desviaciones de CPU
- Reducir la fatiga de alertas usando una Composite Alarm con lógica `AND`
- Construir un dashboard CloudWatch completo como código con `jsonencode`
- Analizar logs con CloudWatch Log Insights usando el lenguaje nativo de queries

## Requisitos previos

- Laboratorio 02 completado (bucket S3 para el backend de Terraform)
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.9 instalado
- Una dirección de correo válida para recibir las alertas SNS

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGION="us-east-1"
```

## Arquitectura

```
  ┌────────────────────────────────────────────────────────────────────────────┐
  │  EC2 (t3.micro)   /var/log/app.log                                         │
  │  └── log-gen (systemd) ──► CloudWatch Agent                                │
  └────────────────────────────────────────┬───────────────────────────────────┘
                                           │
                    ┌──────────────────────▼──────────────────────────────────┐
                    │  CloudWatch Log Group  /${project}/app                  │
                    │  KMS cifrado · retención 30 días                        │
                    └──────────────────────┬──────────────────────────────────┘
                                           │
                    ┌──────────────────────▼──────────────────────────────────┐
                    │  Log Metric Filter  pattern="ERROR"                     │
                    │  → ${project}/Application :: ErrorCount (Count)         │
                    └─────────────────────────────────────────────────────────┘

  EC2 CPUUtilization (AWS/EC2)
  │
  ├──► Anomaly Detection Alarm ──────────────────────────────────────────────►┐
  │    ANOMALY_DETECTION_BAND(CPU, 2σ) · modelo ML                            │
  │                                                                           │
  ├──► CPU High Alarm ──┐                                                     │
  │    CPU > 80% · 3×5m  ├──► Composite Alarm ──► SNS ──► email               │
  └──► Status Check ────┘    (AND lógico)                                     │
       StatusCheckFailed > 0                                                  │
                                                                              │
  CloudWatch Dashboard  ◄─────────────────────────────────────────────────────┘
  ├── CPU + Anomaly Band (ML)       ├── ErrorCount (log metric)
  ├── Estado de alarmas             ├── Health Check desglosado
  └── IncomingLogEvents (log group)
```

## Conceptos clave

### Log Metric Filter: de texto a telemetría

CloudWatch Logs no es solo un almacén de texto: puede transformar patrones de texto en métricas
numéricas que alimentan alarmas y dashboards. Un `aws_cloudwatch_log_metric_filter` define:

| Campo | Función |
|-------|---------|
| `pattern` | Expresión de filtrado (`"ERROR"`, `{ $.level = "ERROR" }`, etc.) |
| `metric_transformation.value` | Valor a emitir cuando el patrón coincide (normalmente `"1"`) |
| `metric_transformation.default_value` | Valor a emitir cuando NO coincide (normalmente `"0"`) |
| `metric_transformation.namespace` | Namespace personalizado donde se publica la métrica |

El `default_value = "0"` es crítico: sin él, los periodos sin errores no publican ningún
datapoint y las alarmas con `treat_missing_data = "notBreaching"` no evalúan correctamente.

### Anomaly Detection: ML en lugar de umbrales fijos

Las alarmas tradicionales usan un umbral fijo: "alerta si CPU > 80%". El problema es que
ese umbral tiene que ser correcto para todos los momentos del día, todos los días de la semana.
Un batch nocturno legítimo que sube la CPU al 85% generaría falsa alarma cada noche.

`ANOMALY_DETECTION_BAND(metric, N)` entrena un modelo ML sobre el historial de la métrica
y genera una banda dinámica de valores "normales":

```
Banda = Media_histórica ± N × Desviación_típica_histórica
```

- **N=2** cubre aproximadamente el 95% de los valores históricos normales
- **N=3** cubre el 99.7% (menos sensible, menos falsos positivos)
- El modelo aprende patrones diarios y semanales automáticamente
- Necesita ~15 minutos de datos para funcionar y ~24 horas para calibrarse completamente

La alarma solo salta cuando la métrica **supera el límite superior** de la banda
(`comparison_operator = "GreaterThanUpperThreshold"`), indicando un comportamiento
genuinamente inusual respecto al patrón histórico.

### Composite Alarm: reducción de ruido

Una `aws_cloudwatch_composite_alarm` combina varias alarmas con lógica booleana
(`AND`, `OR`, `NOT`) y solo notifica cuando la condición compuesta se cumple:

```
Composite = ALARM("status-check") AND ALARM("cpu-high")
```

Esto elimina dos clases de falsos positivos comunes:
- **CPU alta aislada**: un batch, una compilación o un reíndice legítimo sube la CPU
  sin que haya nada roto. Sin la composición, cada ejecución de batch enviaría un email.
- **Health check transitorio**: AWS puede reiniciar automáticamente el hipervisor en
  mantenimientos programados, causando un status check failure de segundos que se
  recupera solo. Sin la composición, cada mantenimiento enviaría una alerta.

Solo cuando **ambas condiciones coinciden** la situación es un incidente real que
merece notificación: la instancia está bajo presión extrema Y degradada simultáneamente.

### Dashboard as Code con jsonencode

`aws_cloudwatch_dashboard` recibe el JSON del dashboard en `dashboard_body`. En lugar de
escribir JSON a mano (frágil, sin validación de tipos), se usa `jsonencode()`:

```hcl
dashboard_body = jsonencode({
  widgets = [
    {
      type   = "metric"
      x      = 0
      y      = 0
      width  = 12
      height = 6
      properties = {
        metrics = [
          ["AWS/EC2", "CPUUtilization", "InstanceId", aws_instance.app.id, { ... }]
        ]
      }
    }
  ]
})
```

Las referencias a recursos Terraform (`aws_instance.app.id`, ARNs, nombres) se resuelven en
tiempo de `apply`. El dashboard siempre apunta a los recursos reales aunque se recreen y
cambien de ID, sin necesidad de actualizar el JSON manualmente.

### Cifrado de logs con KMS

Un log group con `kms_key_id` cifra cada evento antes de escribirlo en disco. La CMK requiere
un statement específico en su política que otorgue permisos al servicio
`logs.<region>.amazonaws.com`:

```hcl
{
  Sid    = "AllowCloudWatchLogs"
  Effect = "Allow"
  Principal = { Service = "logs.us-east-1.amazonaws.com" }
  Action = ["kms:Encrypt*", "kms:Decrypt*", "kms:GenerateDataKey*", ...]
  Condition = {
    ArnLike = {
      "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:us-east-1:<account>:*"
    }
  }
}
```

Sin este statement, Terraform crea el log group pero las escrituras fallan con
`AccessDeniedException: User is not authorized to perform kms:GenerateDataKey`.
La condición `ArnLike` restringe el acceso a los log groups de esta cuenta
específica, evitando que otras cuentas usen la misma CMK.

## Estructura

```
lab46/
└── aws/                          Infraestructura del laboratorio
    ├── providers.tf              Provider AWS ~6.0, backend S3
    ├── variables.tf              Variables: región, proyecto, email, umbrales
    ├── main.tf                   KMS, IAM, Security Group, EC2
    ├── monitoring.tf             SNS, Log Group, Metric Filter, Alarmas, Dashboard
    ├── outputs.tf                URLs y ARNs de los recursos clave
    ├── aws.s3.tfbackend          Configuración parcial del backend S3
    └── templates/
        └── user_data.sh.tpl      Instalación CloudWatch Agent + servicio log-gen
```

## Paso 1 — Desplegar la infraestructura

Inicializa el backend y despliega todos los recursos:

```bash
cd labs/lab46/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=terraform-state-labs-$(aws sts get-caller-identity --query Account --output text)"

terraform plan -var="alert_email=tu@email.com"
terraform apply -var="alert_email=tu@email.com"
```

Revisa los outputs:

```bash
terraform output
```

Deberías ver:
- `dashboard_url` — enlace directo al dashboard en la consola de CloudWatch
- `instance_id` — ID de la instancia EC2
- `log_group_name` — nombre del log group (`/lab46/app`)
- `ssm_session_command` — comando para conectarte sin SSH

> **Confirma la suscripción SNS**: busca en tu correo el mensaje de AWS Notifications
> con asunto "AWS Notification - Subscription Confirmation" y haz clic en
> "Confirm subscription". Sin este paso, la Composite Alarm no enviará emails.

## Paso 2 — Verificar el flujo de logs

La instancia EC2 tarda 2-3 minutos en arrancar y que el generador de logs comience a
escribir entradas. Verifica que los logs llegan a CloudWatch:

```bash
LOG_GROUP=$(terraform output -raw log_group_name)

# Seguir los logs en tiempo real
aws logs tail "$LOG_GROUP" --follow

# Buscar solo errores en los últimos 15 minutos
aws logs filter-log-events \
  --log-group-name "$LOG_GROUP" \
  --filter-pattern "ERROR" \
  --start-time $(($(date +%s) - 900))000 \
  --query 'events[].message' \
  --output text
```


Si los logs no aparecen tras 5 minutos, verifica el estado del CloudWatch Agent via SSM:

```bash
INSTANCE_ID=$(terraform output -raw instance_id)

aws ssm start-session --target "$INSTANCE_ID"

# Dentro de la sesión SSM:
sudo systemctl status log-gen
sudo systemctl status amazon-cloudwatch-agent
sudo /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl -a status
```

## Paso 3 — Explorar el dashboard

Abre el dashboard en el navegador:

```bash
terraform output dashboard_url
```

O desde la CLI, consulta el estado actual de todas las alarmas:

```bash
PROJECT="lab46"

aws cloudwatch describe-alarms \
  --alarm-name-prefix "$PROJECT" \
  --query 'MetricAlarms[].{Nombre:AlarmName,Estado:StateValue,Razon:StateReason}' \
  --output table

aws cloudwatch describe-alarms \
  --alarm-name-prefix "$PROJECT" \
  --alarm-types CompositeAlarm \
  --query 'CompositeAlarms[].{Nombre:AlarmName,Estado:StateValue,Regla:AlarmRule}' \
  --output table
```

El dashboard muestra cinco widgets:
1. **CPU + Anomaly Band**: la línea azul es la CPU real; la banda gris es el rango
   "normal" calculado por ML. Al principio la banda es ancha (pocos datos históricos)
   y se estrecha a medida que el modelo aprende el patrón de la instancia.
2. **ErrorCount**: suma de errores por minuto procedentes del log metric filter.
3. **Estado de alarmas**: semáforo visual con el estado actual de las cuatro alarmas.
4. **Health Check**: `StatusCheckFailed` desglosado en instancia y sistema.
5. **IncomingLogEvents**: volumen de entradas que llegan al log group por minuto.

> **Nota sobre Anomaly Detection**: el modelo necesita al menos 15 minutos de datos
> para generar la primera banda y ~24 horas para calibrarse completamente. Durante las
> primeras horas verás la banda "INSUFFICIENT_DATA" o muy ancha.

## Paso 4 — Probar las alarmas

### Provocar un pico de CPU (Anomaly Detection)

Conéctate a la instancia via SSM y ejecuta `stress-ng` para generar carga:

```bash
INSTANCE_ID=$(terraform output -raw instance_id)
aws ssm start-session --target "$INSTANCE_ID"

# Dentro de la sesión SSM — estresar 2 core durante 5 minutos:
sudo dnf install -y stress-ng
sudo stress-ng --cpu 2 --timeout 300s
```

Tras 5-10 minutos, la alarma `lab46-cpu-anomaly` debería pasar a ALARM si la CPU
supera la banda histórica. Observa cómo la banda ML se mantiene baja (el modelo
aprendió que la CPU normal es baja) mientras la métrica real la supera.

### Simular la Composite Alarm

La Composite Alarm requiere que **ambas** condiciones estén en ALARM simultáneamente.
Para probarla puedes forzar manualmente el estado de las alarmas componentes:

```bash
PROJECT="lab46"

# Forzar ambas alarmas a ALARM (solo para test, no afecta la métrica real)
aws cloudwatch set-alarm-state \
  --alarm-name "${PROJECT}-status-check" \
  --state-value ALARM \
  --state-reason "Test manual de Composite Alarm"

aws cloudwatch set-alarm-state \
  --alarm-name "${PROJECT}-cpu-high" \
  --state-value ALARM \
  --state-reason "Test manual de Composite Alarm"
```

La Composite Alarm debería pasar a ALARM en segundos y enviar el email de alerta.
Restáurala a OK cuando termines. Al hacerlo recibirás una segunda notificación informando
del cambio de estado de ALARM a OK, ya que la Composite Alarm tiene configurado `ok_actions`
apuntando al mismo topic SNS:

```bash
aws cloudwatch set-alarm-state \
  --alarm-name "${PROJECT}-status-check" \
  --state-value OK \
  --state-reason "Restauracion manual post-test"

aws cloudwatch set-alarm-state \
  --alarm-name "${PROJECT}-cpu-high" \
  --state-value OK \
  --state-reason "Restauracion manual post-test"
```

### Verificar la métrica de errores

Consulta los datapoints de `ErrorCount` de los últimos 30 minutos:

```bash
PROJECT="lab46"

aws cloudwatch get-metric-statistics \
  --namespace "${PROJECT}/Application" \
  --metric-name ErrorCount \
  --start-time "$(date -u -d '30 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-30M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Sum \
  --query 'sort_by(Datapoints, &Timestamp)[].{Timestamp:Timestamp,Errores:Sum}' \
  --output table
```

La salida esperada es una tabla con un datapoint por minuto. La columna `Errores` muestra
cuántas líneas `[ERROR]` detectó el metric filter en ese periodo. Los minutos sin errores
aparecen con `0.0` gracias al `default_value = "0"` configurado en el filter:

```
----------------------------------------------------------------------------------
|                           GetMetricStatistics                                  |
+----------------------------------+---------------------------------------------+
|           Errores                |               Timestamp                     |
+----------------------------------+---------------------------------------------+
|  0.0                             |  2024-01-15T10:01:00+00:00                  |
|  2.0                             |  2024-01-15T10:02:00+00:00                  |
|  0.0                             |  2024-01-15T10:03:00+00:00                  |
|  1.0                             |  2024-01-15T10:04:00+00:00                  |
|  3.0                             |  2024-01-15T10:05:00+00:00                  |
+----------------------------------+---------------------------------------------+
```

> Si la tabla aparece vacía (`[]`), el metric filter aún no ha procesado datos. Espera
> 2-3 minutos tras el arranque de la instancia y vuelve a ejecutar el comando. Los
> datapoints solo se generan cuando llegan entradas al log group.

---

## Paso 5 — Analizar logs con Log Insights

CloudWatch Log Insights permite ejecutar queries analíticas directamente sobre los logs
almacenados en el log group, sin necesidad de exportarlos ni de herramientas externas.
Usa un pipeline de comandos (`parse`, `filter`, `stats`, `sort`, `limit`) que se encadenan con `|`.

```bash
LOG_GROUP=$(terraform output -raw log_group_name)
```

### Lenguaje nativo de Log Insights

Usa un pipeline de comandos separados por `|`. Cada comando transforma el resultado
del anterior:

| Comando | Función |
|---------|---------|
| `parse` | Extrae campos de texto no estructurado con glob o regex |
| `filter` | Filtra filas por condición (equivale a `WHERE`) |
| `stats` | Agrega con `count()`, `avg()`, `sum()`, `min()`, `max()` |
| `sort` | Ordena el resultado por un campo o alias |
| `limit` | Limita el número de filas devueltas |

**Top 5 errores más frecuentes de la última hora:**

`parse` extrae los tres campos del formato `TIMESTAMP [LEVEL] mensaje`. Al agrupar
por `msg` (sin timestamp), entradas idénticas se suman correctamente.

```bash
QUERY_ID=$(aws logs start-query \
  --log-group-name "$LOG_GROUP" \
  --start-time $(($(date +%s) - 3600)) \
  --end-time $(date +%s) \
  --query-string '
    parse @message "* [*] *" as ts, level, msg
    | filter level = "ERROR"
    | stats count(*) as total by msg
    | sort total desc
    | limit 5
  ' \
  --query 'queryId' --output text)

sleep 8
aws logs get-query-results --query-id "$QUERY_ID" \
  --query 'results[*][*].[field,value]' \
  --output text
```

**Errores por ventana de 5 minutos en la última hora:**

`bin(5m)` agrupa los eventos en cubos de 5 minutos. El campo de ordenación es
`@timestamp`, no `bin(5m)` (que solo es válido dentro de `stats`).

```bash
QUERY_ID=$(aws logs start-query \
  --log-group-name "$LOG_GROUP" \
  --start-time $(($(date +%s) - 3600)) \
  --end-time $(date +%s) \
  --query-string '
    parse @message "* [*] *" as ts, level, msg
    | filter level = "ERROR"
    | stats count(*) as errores by bin(5m)
    | sort @timestamp asc
  ' \
  --query 'queryId' --output text)

sleep 8
aws logs get-query-results --query-id "$QUERY_ID" \
  --query 'results[*][*].[field,value]' \
  --output text
```

**Distribución de niveles de log en las últimas 3 horas:**

```bash
QUERY_ID=$(aws logs start-query \
  --log-group-name "$LOG_GROUP" \
  --start-time $(($(date +%s) - 10800)) \
  --end-time $(date +%s) \
  --query-string '
    parse @message "* [*] *" as ts, level, msg
    | stats count(*) as total by level
    | sort total desc
  ' \
  --query 'queryId' --output text)

sleep 8
aws logs get-query-results --query-id "$QUERY_ID" \
  --query 'results[*][*].[field,value]' \
  --output text
```

---

## Verificación final

Comprueba que todos los recursos están operativos antes de pasar a los retos:

```bash
cd labs/lab46/aws

PROJECT=$(terraform output -raw log_group_name | cut -d/ -f2)
LOG_GROUP=$(terraform output -raw log_group_name)
INSTANCE_ID=$(terraform output -raw instance_id)
```

**EC2 — el servicio log-gen está activo:**

```bash
aws ssm start-session --target "$INSTANCE_ID"
# Dentro de la sesión:
sudo systemctl status log-gen
sudo tail -f /var/log/app.log
```

**CloudWatch Agent — logs llegando al log group:**

```bash
aws logs describe-log-streams \
  --log-group-name "$LOG_GROUP" \
  --order-by LastEventTime \
  --descending \
  --query 'logStreams[0].{stream:logStreamName,lastEvent:lastEventTime}' \
  --output table
```

**Metric Filter — datapoints de ErrorCount generados:**

```bash
aws cloudwatch get-metric-statistics \
  --namespace "${PROJECT}/Application" \
  --metric-name ErrorCount \
  --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-5M +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 60 \
  --statistics Sum \
  --query 'Datapoints[].Sum' \
  --output text
```

**Alarmas — todas en estado OK o INSUFFICIENT_DATA (no ALARM):**

```bash
aws cloudwatch describe-alarms \
  --alarm-name-prefix "$PROJECT" \
  --query 'MetricAlarms[].{Alarma:AlarmName,Estado:StateValue}' \
  --output table

aws cloudwatch describe-alarms \
  --alarm-types CompositeAlarm \
  --query 'CompositeAlarms[].{Alarma:AlarmName,Estado:StateValue}' \
  --output table
```

**Dashboard — accesible en la consola:**

```bash
terraform output dashboard_url
```

---

## Retos

### Reto 1 — Alarma de umbral fijo para la métrica de errores

La métrica `ErrorCount` del log metric filter solo tiene visualización en el dashboard.
Añade una alarma de umbral fijo que notifique por SNS cuando el número de errores
por minuto supere un umbral configurable.

**Objetivo**: entender la diferencia entre anomaly detection (ML dinámico) y threshold
alarm (umbral estático), y cuándo es apropiado usar cada uno.

1. Define un `aws_cloudwatch_metric_alarm` sobre la métrica `ErrorCount` del namespace
   `${var.project}/Application` con un umbral de `var.error_threshold` errores por periodo
2. Conecta la alarma al topic SNS `aws_sns_topic.alerts` como `alarm_actions`
3. Usa `treat_missing_data = "notBreaching"` para evitar alarmas espurias en el arranque
4. Añade el ARN de la nueva alarma al widget de estado del dashboard

**Pistas:**
- La métrica `ErrorCount` tiene `unit = "Count"` y `period = 60` en el metric filter
- `statistic = "Sum"` es más apropiado que `Average` para métricas de conteo
- `evaluation_periods = 2` evita que un minuto aislado con muchos errores dispare la alarma

---

### Reto 2 — Widget de Log Insights en el dashboard

CloudWatch Log Insights permite incrustar queries directamente en el dashboard como
widgets de tipo `log`. Añade un widget que muestre los mensajes de error más frecuentes
de la última hora.

**Objetivo**: integrar Log Insights en el dashboard as code y aprender la sintaxis de
queries de Log Insights.

1. Añade un nuevo widget de tipo `"log"` al array `widgets` del dashboard
2. La query debe agrupar los errores por mensaje y mostrar los 5 más frecuentes:
   ```
   parse @message "* [*] *" as ts, level, msg
   | filter level = "ERROR"
   | stats count(*) as total by msg
   | sort total desc
   | limit 5
   ```
3. Colócalo en la fila 3 del dashboard (`y = 15`, `width = 24`, `height = 6`)

**Pistas:**
- Los widgets de tipo `log` usan `"type": "log"` y en `properties` van `query`,
  `logGroupNames` (array) y `view = "table"`
- El campo `period` no se usa en widgets de Log Insights; se usa `start` y `end`
  en formato relativo como `"-PT1H"` (última hora)

---

### Reto 3 — Filtro de métrica para WARN y comparativa en el dashboard

Actualmente solo se monitoriza el nivel ERROR. Añade un segundo log metric filter
para el nivel WARN y crea un widget de comparativa en el dashboard que muestre
ambas métricas en la misma gráfica.

**Objetivo**: entender cómo múltiples filtros sobre el mismo log group generan
métricas independientes, y cómo representar varias métricas en un mismo widget.

1. Define un `aws_cloudwatch_log_metric_filter` para el patrón `"WARN"` publicando
   la métrica `WarnCount` en el mismo namespace `${var.project}/Application`
2. Añade un widget de comparativa al dashboard con ambas métricas en la misma
   gráfica (mismo `metrics` array, distintas entradas)
3. Usa colores diferenciados: `#FF9800` (naranja) para WARN y `#F44336` (rojo) para ERROR

**Pistas:**
- Los dos metric filters pueden coexistir sobre el mismo log group sin interferirse
- En un widget de tipo `metric`, incluir dos entradas en el array `metrics` las muestra
  en la misma gráfica con ejes compartidos
- Si el patrón `"WARN"` captura también líneas con `"WARNING"`, usa `"[WARN]"` para
  hacer el match exacto del texto entre corchetes

---

## Soluciones

<details>
<summary><strong>Solución al Reto 1 — Alarma de umbral fijo para ErrorCount</strong></summary>

### Solución al Reto 1 — Alarma de umbral fijo para ErrorCount

**Umbral fijo vs Anomaly Detection:**

El umbral fijo es apropiado para la métrica `ErrorCount` porque su valor "normal"
es predecible. El generador de logs produce ~12 errores/minuto en condiciones normales
(25% de ~48 eventos/min con intervalo de 0.5-2 s). Un umbral de 25 deja margen sobre
la línea base sin ignorar picos reales. Un modelo ML de anomaly detection aprendería
que "12 errores/min son normales" y no alertaría ante incrementos moderados.

Anomaly Detection es mejor para métricas con patrones complejos (CPU con batches
nocturnos, tráfico web con picos de negocio). El umbral fijo es mejor para métricas
de "error rate" donde cualquier error significativo es anómalo.

**Nueva variable** → [aws/variables.tf](aws/variables.tf):

```hcl
variable "error_threshold" {
  type        = number
  description = "Numero de errores por minuto que activa la alarma de errores de aplicacion."
  default     = 25

  validation {
    condition     = var.error_threshold > 0
    error_message = "El umbral de errores debe ser un numero positivo."
  }
}
```

**Alarma** → [aws/monitoring.tf](aws/monitoring.tf):

```hcl
resource "aws_cloudwatch_metric_alarm" "error_count" {
  alarm_name          = "${var.project}-error-count"
  alarm_description   = "Mas de ${var.error_threshold} errores por minuto en la aplicacion."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ErrorCount"
  namespace           = "${var.project}/Application"
  period              = 60
  statistic           = "Sum"
  threshold           = var.error_threshold
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = { Project = var.project, ManagedBy = "terraform" }
}
```

**Actualizar el widget de estado** → añade el ARN al array `alarms` del widget tipo `"alarm"`:

```hcl
alarms = [
  aws_cloudwatch_metric_alarm.cpu_anomaly.arn,
  aws_cloudwatch_metric_alarm.status_check.arn,
  aws_cloudwatch_metric_alarm.cpu_high.arn,
  aws_cloudwatch_composite_alarm.app_critical.arn,
  aws_cloudwatch_metric_alarm.error_count.arn,  # ← nueva
]
```

Aplica los cambios:

```bash
terraform apply -var="alert_email=tu@email.com"
```

Para probar la alarma, aumenta temporalmente el ratio de errores del generador de logs
desde una sesión SSM:

```bash
# Inyectar ~1 error/s durante 2 minutos para superar el umbral en 2 periodos consecutivos.
# El generador normal produce ~12 errores/min; sumando esta inyección se superan los 25/min.
# sudo tee -a es necesario porque >> necesita permisos de root sobre /var/log/app.log.
end=$(($(date +%s) + 120))
i=1
while [ "$(date +%s)" -lt "$end" ]; do
  echo "$(date '+%Y-%m-%d %H:%M:%S') [ERROR] Test alarm trigger $i" | sudo tee -a /var/log/app.log > /dev/null
  i=$((i + 1))
  sleep 1
done
```

</details>

---

<details>
<summary><strong>Solución al Reto 2 — Widget de Log Insights en el dashboard</strong></summary>

### Solución al Reto 2 — Widget de Log Insights en el dashboard

**Por qué Log Insights en el dashboard:**

Los widgets de tipo `metric` muestran series temporales agregadas (cuántos errores por
minuto). Log Insights añade la dimensión del **contenido**: qué mensajes de error son más
frecuentes. Es la diferencia entre saber que hay 50 errores/min y saber que 40 de ellos
son "Database connection timeout" (problema de base de datos) y 10 son "Auth failed"
(problema de autenticación). Esa distinción guía el diagnóstico directamente.

**Añadir el widget al dashboard** → [aws/monitoring.tf](aws/monitoring.tf):

En el array `widgets` del recurso `aws_cloudwatch_dashboard.main`, añade al final:

```hcl
# ── Widget 6: Top errores con Log Insights ───────────────────────────────────
{
  type   = "log"
  x      = 0
  y      = 15
  width  = 24
  height = 6
  properties = {
    title   = "Top 5 mensajes de ERROR (ultima hora)"
    region  = var.region
    view    = "table"
    query   = join("\n", [
      "SOURCE '${aws_cloudwatch_log_group.app.name}'",
      "| parse @message '* [*] *' as ts, level, msg",
      "| filter level = 'ERROR'",
      "| stats count(*) as total by msg",
      "| sort total desc",
      "| limit 5"
    ])
  }
}
```

> **Nota**: la sintaxis `SOURCE 'log-group-name'` dentro del campo `query` del widget
> es la forma de especificar el log group en el JSON del dashboard. Es diferente a cómo
> se especifica cuando se ejecuta una query desde la consola de Log Insights o desde la CLI.

Aplica los cambios:

```bash
terraform apply -var="alert_email=tu@email.com"
```

Puedes también ejecutar la misma query desde la CLI para verificar el resultado:

```bash
LOG_GROUP=$(terraform output -raw log_group_name)

QUERY_ID=$(aws logs start-query \
  --log-group-name "$LOG_GROUP" \
  --start-time $(($(date +%s) - 3600)) \
  --end-time $(date +%s) \
  --query-string 'parse @message "* [*] *" as ts, level, msg | filter level = "ERROR" | stats count(*) as total by msg | sort total desc | limit 5' \
  --query 'queryId' \
  --output text)

# Espera 5-10 segundos y obtén los resultados
sleep 8
aws logs get-query-results --query-id "$QUERY_ID" \
  --query 'results[*][*].[field,value]' \
  --output text
```

</details>

---

<details>
<summary><strong>Solución al Reto 3 — Filtro WARN y widget comparativo</strong></summary>

### Solución al Reto 3 — Filtro WARN y widget comparativo

**Por qué monitorizar WARN además de ERROR:**

Los warnings son señales tempranas de degradación: alta presión de memoria, queries lentas
o conexiones de pool al límite suelen aparecer como WARN antes de convertirse en ERROR.
Monitorizar la relación entre ambos niveles permite detectar degradación gradual: si la
tasa de WARN sube progresivamente durante horas sin convertirse aún en ERROR, algo está
deteriorándose y puede prevenirse antes de que falle.

**Segundo Log Metric Filter** → [aws/monitoring.tf](aws/monitoring.tf):

```hcl
resource "aws_cloudwatch_log_metric_filter" "warnings" {
  name           = "${var.project}-warn-count"
  pattern        = "[WARN]"
  log_group_name = aws_cloudwatch_log_group.app.name

  metric_transformation {
    name          = "WarnCount"
    namespace     = "${var.project}/Application"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}
```

> **Nota sobre el pattern**: `"[WARN]"` usa los corchetes para hacer match exacto del
> texto `[WARN]` tal como aparece en los logs (`2024-01-01 10:00:00 [WARN] ...`).
> El pattern `"WARN"` también capturaría líneas como "WARNING" o "FORWARDING".

**Widget comparativo** → añade al array `widgets`:

```hcl
# ── Widget 7: Comparativa ERROR vs WARN ──────────────────────────────────────
{
  type   = "metric"
  x      = 0
  y      = 21
  width  = 24
  height = 6
  properties = {
    title   = "Comparativa ERROR vs WARN (log metrics)"
    view    = "timeSeries"
    stacked = false
    region  = var.region
    period  = 60
    metrics = [
      ["${var.project}/Application", "ErrorCount",
        { stat = "Sum", label = "Errores/min", color = "#F44336" }],
      ["${var.project}/Application", "WarnCount",
        { stat = "Sum", label = "Warnings/min", color = "#FF9800" }]
    ]
  }
}
```

Aplica los cambios:

```bash
terraform apply -var="alert_email=tu@email.com"
```

> **Nota:** la métrica `WarnCount` puede tardar 2-3 minutos en aparecer en el dashboard
> tras el primer `apply`. CloudWatch Log Insights solo publica datapoints cuando el metric
> filter detecta eventos que coinciden con el patrón; hasta que llegan las primeras líneas
> `[WARN]` al log group y se procesan, la serie temporal aparece vacía o sin datos.

Para verificar que ambas métricas tienen datos:

```bash
PROJECT="lab46"

for METRIC in ErrorCount WarnCount; do
  echo "=== $METRIC (últimos 10 min) ==="
  aws cloudwatch get-metric-statistics \
    --namespace "${PROJECT}/Application" \
    --metric-name "$METRIC" \
    --start-time "$(date -u -d '10 minutes ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-10M +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --period 60 \
    --statistics Sum \
    --query 'sort_by(Datapoints,&Timestamp)[].Sum' \
    --output text
done
```

</details>

---

## Limpieza

```bash
cd labs/lab46/aws

terraform destroy -var="alert_email=tu@email.com"
```

> `terraform destroy` elimina todos los recursos: instancia EC2, log group (incluidos
> los logs almacenados), alarmas, dashboard, topic SNS y CMK KMS. La CMK tiene un
> periodo de eliminación de 7 días configurado en `deletion_window_in_days`: durante
> ese periodo aparece en estado "Pending deletion" pero no genera costes adicionales.

---

## Solución de problemas

### El CloudWatch Agent no envía logs

Comprueba el estado del agente y sus logs internos desde una sesión SSM:

```bash
sudo systemctl status amazon-cloudwatch-agent
sudo cat /opt/aws/amazon-cloudwatch-agent/logs/amazon-cloudwatch-agent.log
```

Si aparece un error de permisos KMS, verifica que el statement `AllowCloudWatchLogs`
de la CMK incluye el servicio `logs.<region>.amazonaws.com` con la condición
`kms:EncryptionContext:aws:logs:arn`.

### La métrica ErrorCount no genera datapoints

El metric filter solo publica un datapoint cuando detecta al menos una coincidencia
en el periodo. Espera 2-3 minutos tras el arranque de la instancia y comprueba que
el servicio `log-gen` está activo:

```bash
aws ssm start-session --target "$INSTANCE_ID"
sudo systemctl status log-gen
sudo tail /var/log/app.log
```

### La Composite Alarm no pasa a ALARM

La Composite Alarm requiere que **ambas** alarmas componentes estén en ALARM
simultáneamente. Comprueba el estado individual de `cpu-high` y `status-check`.
Para probar sin esperar a condiciones reales usa `set-alarm-state` (ver Paso 4).

### El modelo de Anomaly Detection no dispara

El modelo ML necesita al menos 15 minutos de datos históricos para generar una banda.
Durante ese periodo la alarma permanece en `INSUFFICIENT_DATA`. Tras las primeras horas,
el modelo aprende el patrón de CPU y la banda se ajusta al comportamiento real.

### `terraform destroy` falla al eliminar el log group

Si el log group tiene retención activa y hay streams recientes, el destroy puede fallar
si la CMK ya ha sido marcada para eliminación antes de que CloudWatch termine de procesar
los últimos eventos cifrados. Ejecuta `terraform destroy` de nuevo o elimina el log group
manualmente desde la consola antes de volver a intentarlo.

---

## Buenas prácticas

- **Cifra los logs en reposo**: el log group usa una CMK con rotación automática anual.
  Sin cifrado KMS, cualquier usuario con permisos de CloudWatch Logs puede leer los logs.

- **Limita la retención**: sin `retention_in_days`, los logs se acumulan indefinidamente.
  Define siempre una retención acorde al valor de los datos y a los requisitos de auditoría.

- **Usa `default_value = "0"` en metric filters**: garantiza que los periodos sin errores
  publican un datapoint con valor 0. Sin él, CloudWatch trata la ausencia de datos como
  `INSUFFICIENT_DATA` y las alarmas no evalúan correctamente en periodos tranquilos.

- **Prefiere Anomaly Detection para métricas con patrones**: CPU, latencia y tráfico
  tienen patrones diarios y semanales. Un umbral fijo del 70% de CPU dispararía cada
  mañana si hay un batch. La banda ML aprende ese patrón y no genera falsos positivos.

- **Usa Composite Alarms para reducir ruido**: una alarma individual de CPU alta o de
  health check puede ser transitoria. La combinación `AND` garantiza que solo se notifica
  cuando ambas condiciones coinciden, señalando un incidente real.

- **Define dashboards como código**: `jsonencode` en Terraform garantiza que el dashboard
  siempre apunta a los recursos reales (IDs, ARNs, nombres) aunque se recreen tras
  un `destroy`. Un dashboard creado manualmente quedaría huérfano.

---

## Recursos

- [CloudWatch Log Metric Filters — Sintaxis de patrones](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/FilterAndPatternSyntax.html)
- [CloudWatch Anomaly Detection — Cómo funciona el modelo ML](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Anomaly_Detection.html)
- [CloudWatch Composite Alarms — alarm_rule sintaxis](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/Create_Composite_Alarm.html)
- [CloudWatch Dashboards — Referencia de widgets](https://docs.aws.amazon.com/AmazonCloudWatch/latest/APIReference/CloudWatch-Dashboard-Body-Structure.html)
- [CloudWatch Log Insights — Sintaxis de queries](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/CWL_QuerySyntax.html)
- [CloudWatch Agent — Configuración para EC2](https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/install-CloudWatch-Agent-on-EC2-Instance.html)
- [KMS — Cifrado de CloudWatch Logs](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/encrypt-log-data-kms.html)
