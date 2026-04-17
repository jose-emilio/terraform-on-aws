# Laboratorio 47 — Centralización de Telemetría y Pipeline de Auditoría

![Terraform on AWS](../../images/lab-banner.svg)


[← Módulo 11 — Observabilidad, Tagging y FinOps](../../modulos/modulo-11/README.md)


## Visión general

En este laboratorio construirás una arquitectura **Hub & Spoke de observabilidad**: múltiples
fuentes de telemetría (tráfico de red, actividad de API) convergen en un punto central de
almacenamiento con un ciclo de vida FinOps que reduce el coste de retención a largo plazo
en un 95%.

La arquitectura tiene cuatro capas:

1. **Captura**: VPC Flow Logs recogen el tráfico de red denegado; CloudTrail recoge cada
   llamada a la API de AWS en todas las regiones.
2. **Centralización**: ambas fuentes envían sus datos a log groups de CloudWatch cifrados
   con KMS, creando un punto único de consulta.
3. **Archivo**: una subscription filter reenvía los Flow Logs en tiempo real a Kinesis
   Firehose, que los entrega comprimidos al bucket S3 de archivo. CloudTrail escribe
   directamente en el mismo bucket.
4. **FinOps**: una política de ciclo de vida mueve automáticamente todos los logs a
   Glacier Deep Archive tras 90 días, aprovechando que los datos de auditoría se
   consultan raramente pero deben conservarse durante años.

## Objetivos

- Habilitar VPC Flow Logs sobre la VPC por defecto, capturando solo el tráfico REJECT
- Entender el formato estándar de los registros de flujo y cómo consultarlos
- Configurar un CloudTrail multi-región con validación de integridad de archivos
- Comprender la diferencia entre eventos de gestión y eventos de datos en CloudTrail
- Desplegar un Kinesis Firehose delivery stream con compresión GZIP y particionado temporal
- Conectar CloudWatch Logs con Firehose mediante una subscription filter
- Aplicar una política de ciclo de vida S3 con transición a Glacier Deep Archive
- Calcular el impacto económico real de la estrategia FinOps de almacenamiento en frío

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
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │  VPC  10.47.0.0/16                                                           │
  │                                                                              │
  │  ┌─────────────────────────┐   ┌─────────────────────────┐                   │
  │  │  Subred pública AZ-a    │   │  Subred pública AZ-b    │                   │
  │  │  10.47.0.0/24           │   │  10.47.1.0/24           │                   │
  │  │                         │   │                         │                   │
  │  │  ┌──────────────────┐   │   │                         │                   │
  │  │  │ EC2 traffic-gen  │   │   │                         │                   │
  │  │  │ t4g.small        │   │   │                         │                   │
  │  │  │ SG: 22 in/all out│   │   │                         │                   │
  │  │  └───────┬──────────┘   │   │                         │                   │
  │  └──────────┼──────────────┘   └─────────────────────────┘                   │
  │             │ ENI primaria                                                   │
  │  ┌──────────▼──────────────┐   ┌─────────────────────────┐                   │
  │  │  Subred privada AZ-a    │   │  Subred privada AZ-b    │                   │
  │  │  10.47.10.0/24          │   │  10.47.11.0/24          │                   │ 
  │  └─────────────────────────┘   └─────────────────────────┘                   │
  │                                                                              │
  └──────────────────────────────┬───────────────────────────────────────────────┘
                                 │ Internet Gateway
                                 ▼
                           Internet (tráfico ALL)

  VPC Flow Log (ENI) ──────────────────────────────────────────────────────────┐
                                                                               │
              ┌────────────────────────────────────────────────────────────────▼─┐
              │  CloudWatch Log Group /lab47/vpc-flow-logs  [KMS · 30d ret.]     │
              │  └── Subscription Filter ─────────────────────────────────────┐  │
              └───────────────────────────────────────────────────────────────┼──┘
                                                                              │
  ┌───────────────────────────────────────────────────────────────────────────▼──┐
  │  Kinesis Firehose  lab47-logs-to-s3                                          │
  │  Buffer: 5 MB / 300 s  ·  Compresión: GZIP  ·  Partición: año/mes/día        │
  └──────────────────────────────────────────────────────────────────────────┬───┘
                                                                             │
  ┌──────────────────────────────────────────────────────────────────────────▼───┐
  │  S3  lab47-archive-<account-id>                [KMS · versioning · ACL off]  │
  │  ├── cloudtrail/AWSLogs/<account-id>/...  ← CloudTrail (JSON.gz)             │
  │  └── firehose/year=/month=/day=/...       ← Kinesis Firehose (GZIP)          │
  │                                                                              │
  │  Lifecycle: Standard ──[90 días]──► Glacier Deep Archive  (~95% ahorro)      │
  └──────────────────────────────────────────────────────────────────────────────┘

  ┌──────────────────────────────────────────────────────────────────────────────┐
  │  AWS CloudTrail  lab47-trail                                                 │
  │  Multi-región  ·  Log file validation  ·  KMS  ·  Global services            │
  │  ├── S3 → cloudtrail/AWSLogs/...              (archivo, ~5 min latencia)     │
  │  └── CloudWatch /lab47/cloudtrail             (tiempo real, Log Insights)    │
  └──────────────────────────────────────────────────────────────────────────────┘
```

## Conceptos clave

### VPC Flow Logs

VPC Flow Logs captura **metadatos** de cada conexión IP que atraviesa una interfaz de red
(ENI) de la VPC. No captura el payload (contenido del paquete), solo la cabecera: quién
habla con quién, en qué puerto, qué protocolo, cuántos bytes y si fue aceptado o rechazado.

El formato estándar de un registro de flujo tiene 15 campos:

```
version account-id interface-id srcaddr dstaddr srcport dstport protocol packets bytes start end action log-status
```

Un ejemplo de registro REJECT (intento de acceso SSH bloqueado):

```
2 123456789012 eni-0abc1234 203.0.113.42 172.31.5.10 49823 22 6 1 40 1716800000 1716800060 REJECT OK
```

Decodificado:
- `203.0.113.42` → IP origen (atacante o escáner)
- `172.31.5.10` → IP destino (instancia EC2 en la VPC)
- `49823` → puerto origen efímero
- `22` → puerto destino (SSH)
- `6` → protocolo TCP (17 = UDP, 1 = ICMP)
- `REJECT` → denegado por Security Group o NACL

**Tipos de tráfico capturables:**
- `REJECT`: solo conexiones denegadas. Útil para detectar escaneos y accesos no autorizados.
- `ACCEPT`: solo conexiones aceptadas. Útil para análisis de tráfico legítimo.
- `ALL`: ambos. Necesario para correlación completa pero genera volumen algo mayor.

Este laboratorio usa `ALL` sobre la ENI de la instancia: captura tanto el tráfico
`ACCEPT` generado por el script de la instancia (peticiones HTTP/HTTPS a internet)
como el tráfico `REJECT` producido por los escáneres de internet que intentan
conectarse a puertos no abiertos. La combinación de ambos permite ejecutar las
consultas de Log Insights incluso antes de que haya actividad externa significativa.

### CloudTrail

AWS CloudTrail es el **registro de auditoría universal** de la cuenta AWS: registra cada
llamada a la API de AWS (consola, CLI, SDK) con el usuario que la hizo, desde qué IP,
cuándo y con qué parámetros de respuesta.

**Tipos de eventos:**

| Tipo | Qué captura | Coste |
|------|-------------|-------|
| Management events | Creación/eliminación de recursos, cambios IAM, login | Gratis (1 trail) |
| Data events | Operaciones sobre objetos S3, invocaciones Lambda | De pago |
| CloudTrail Insights | Detección de actividad anómala de API | De pago |

**Multi-región vs single-región:**

Un trail single-región solo registra eventos de `us-east-1`. Los servicios globales como
IAM, STS, CloudFront y Route53 solo envían eventos a `us-east-1`, pero si el trail no
es multi-región, los eventos de EC2 en `eu-west-1` quedan fuera del registro.
`is_multi_region_trail = true` garantiza cobertura completa con un único trail.

**Validación de integridad de archivos:**

`enable_log_file_validation = true` activa la cadena de custodia criptográfica:

1. CloudTrail genera un archivo JSON de log cada 5 minutos con los eventos del periodo.
2. Cada hora genera un archivo de resumen (`digest`) que contiene:
   - El hash SHA-256 de cada archivo de log del periodo
   - La firma RSA del digest (con clave privada de AWS)
   - La referencia al digest anterior (cadena de hashes)
3. Para validar: `aws cloudtrail validate-logs` descarga el digest, verifica la firma
   con la clave pública de AWS y comprueba que los hashes coinciden.

Si alguien elimina o modifica un archivo de log, la validación detecta la rotura de la
cadena. Esto es fundamental para auditorías de compliance (SOC2, ISO27001, PCI-DSS).

### Kinesis Firehose

Kinesis Firehose es un servicio de **entrega de streaming de datos** completamente
gestionado. No es una cola (no hay consumidores que lean mensajes): es un pipeline
de transformación y entrega que acumula datos en un buffer y los escribe en lotes
al destino final.

**Flujo de datos:**

```
Productor (CloudWatch Logs)
    │  PutRecordBatch()
    ▼
Firehose buffer (memoria)
    │  Se vacía cuando: tamaño ≥ N MB  OR  tiempo ≥ N segundos
    ▼
Transformación (opcional: Lambda)
    │
    ▼
S3  (objeto GZIP con múltiples registros concatenados)
```

**Parámetros de buffer:**

El buffer es el compromiso entre latencia y eficiencia. Valores extremos:
- Buffer muy pequeño (1 MB / 60 s): muchos objetos S3 pequeños, coste de operaciones PUT alto.
- Buffer grande (128 MB / 900 s): pocos objetos grandes, mayor latencia antes de que los
  datos estén en S3 para consulta. Más riesgo de pérdida en un fallo.

El default de 5 MB / 300 s es adecuado para la mayoría de cargas de trabajo.

**Particionado temporal con expresiones Firehose:**

El prefijo `firehose/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/`
crea una estructura de particiones compatible con Apache Hive, que herramientas como
Amazon Athena y AWS Glue reconocen automáticamente para crear particiones sin escanear
todo el bucket. Una query en Athena con `WHERE year='2026' AND month='04'` solo lee los
datos del mes solicitado.

### CloudWatch Logs Subscription Filter

Una subscription filter conecta un log group de CloudWatch con un destino externo. Cuando
llegan nuevas entradas al log group que coinciden con el patrón de filtro, CloudWatch las
reenvía al destino de forma asíncrona con latencia de segundos.

**Destinos soportados:**
- Kinesis Data Streams (análisis en tiempo real con consumidores)
- Kinesis Firehose (archivo en S3, Redshift, Elasticsearch)
- Lambda (procesamiento serverless por evento)
- OpenSearch Service (búsqueda full-text)

**Cómo funciona el reenvío a Firehose:**

CloudWatch Logs asume el rol IAM especificado en `role_arn` y llama a
`firehose:PutRecordBatch` con los registros que coinciden con el filtro. Los registros
se comprimen (gzip) antes de enviarlos a Firehose, que los acumula en su buffer antes
de escribirlos en S3.

**Límite importante:** cada log group admite como máximo **2 subscription filters**
simultáneos. Si necesitas enviar los mismos logs a múltiples destinos, debes usar
Kinesis Data Streams como intermediario (fanout pattern).

### Ciclo de vida S3 y FinOps

AWS S3 ofrece varios tiers de almacenamiento con diferente coste y tiempo de acceso:

| Tier | Coste/GB/mes | Acceso | Duración mínima cobrada |
|------|-------------|--------|------------------------|
| Standard | ~$0.023 | Inmediato | Sin mínimo |
| Intelligent-Tiering | ~$0.023 + $0.0025 (monitoreo) | Inmediato | 30 días |
| Standard-IA | ~$0.0125 | Inmediato | 30 días |
| Glacier Instant Retrieval | ~$0.004 | Milisegundos | 90 días |
| Glacier Flexible Retrieval | ~$0.0036 | 1-12 horas | 90 días |
| **Glacier Deep Archive** | **~$0.00099** | **12-48 horas** | **180 días** |

**¿Por qué Glacier Deep Archive para logs de auditoría?**

Los logs de red y auditoría tienen un patrón de acceso bimodal:
- **Primeros 30 días**: acceso frecuente (análisis de incidentes, debugging, dashboards)
- **Después**: acceso casi nulo, pero retención obligatoria por compliance (1-7 años)

Para la segunda fase, Glacier Deep Archive es ideal:
- **Ahorro**: $0.023 → $0.00099 = **95.7% menos** de coste de almacenamiento
- **Contrapartida**: recuperación en 12-48 horas (aceptable para auditorías)
- **Consideración**: duración mínima cobrada de 180 días (si mueves a GDA a los 90 días,
  pagas por 180 días de GDA aunque luego lo elimines a los 91 días)

Para 1 TB de logs de auditoría retenidos 2 años:
- Solo S3 Standard: 1000 GB × $0.023 × 24 meses = **$552**
- 3 meses Standard + 21 meses GDA: (3 × $23) + (21 × $0.99) = $69 + $20.79 = **$89.79**
- Ahorro total: **~$462 por TB** (83% menos en el escenario completo)

## Estructura

```
lab47/
└── aws/                          Infraestructura del laboratorio
    ├── providers.tf              Provider AWS ~6.0, backend S3
    ├── variables.tf              Variables: región, proyecto, VPC CIDR, instancia, retención, Firehose
    ├── main.tf                   KMS, S3 archive, lifecycle FinOps
    ├── network.tf                VPC, IGW, subredes públicas/privadas en 2 AZs, route tables
    ├── ec2.tf                    AMI, Security Group, IAM role SSM, instancia generadora de tráfico
    ├── templates/
    │   └── user_data.sh.tpl      Script de generación de tráfico (instalado en la instancia)
    ├── flow_logs.tf              VPC Flow Log (ENI) → CloudWatch Log Group
    ├── cloudtrail.tf             CloudTrail multi-región → S3 + CloudWatch
    ├── firehose.tf               Kinesis Firehose + Subscription Filter
    ├── outputs.tf                IDs de VPC/subredes/instancia/ENI, ARNs y prefijos S3
    └── aws.s3.tfbackend          Configuración parcial del backend S3
```

## Paso 1 — Desplegar la infraestructura

```bash
cd labs/lab47/aws

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=terraform-state-labs-${ACCOUNT_ID}" \
  -backend-config="region=${REGION}"

terraform plan
terraform apply
```

El apply crea aproximadamente 35 recursos en este orden:
1. KMS key y alias
2. VPC, Internet Gateway, subredes públicas y privadas, route tables
3. S3 bucket + versioning + SSE + public access block + lifecycle
4. Log groups de CloudWatch (flow logs, cloudtrail, firehose)
5. IAM roles y políticas (flow logs, cloudtrail, firehose, cw→firehose, instancia EC2)
6. Security Group de la instancia
7. Instancia EC2 con el script generador de tráfico
8. Bucket policy de CloudTrail
9. VPC Flow Log (sobre la ENI de la instancia)
10. CloudTrail
11. Kinesis Firehose delivery stream
12. Subscription filter

> **Tiempos de espera tras el apply:**
> - **5-10 min** — primeros registros de Flow Logs en CloudWatch
> - **5-15 min** — primeros eventos de CloudTrail en CloudWatch Logs
> - **5-15 min** — primera entrega de Firehose a S3 (si hay tráfico suficiente)
> - **~1 hora** — primer archivo de resumen (digest) de CloudTrail para `validate-logs`

Guarda los outputs para los pasos siguientes:

```bash
BUCKET=$(terraform output -raw archive_bucket_name)
FLOW_LOG_GROUP=$(terraform output -raw flow_logs_log_group)
CLOUDTRAIL_LOG_GROUP=$(terraform output -raw cloudtrail_log_group)
TRAIL_NAME=$(terraform output -raw cloudtrail_name)
FIREHOSE_NAME=$(terraform output -raw firehose_name)
INSTANCE_ID=$(terraform output -raw traffic_gen_instance_id)
ENI_ID=$(terraform output -raw traffic_gen_eni_id)
PUBLIC_IP=$(terraform output -raw traffic_gen_public_ip)
```

---

## Paso 2 — Verificar VPC Flow Logs

### Confirmar que el flow log está activo

```bash
aws ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=${ENI_ID}" \
  --query 'FlowLogs[].{ID:FlowLogId,Estado:FlowLogStatus,TipoTrafico:TrafficType,Destino:LogDestination}' \
  --output table
```

Salida esperada:

```
---------------------------------------------------------------------------------------
|                                  DescribeFlowLogs                                   |
+-------------+-----------------------------------------------------------------------+
|  Destino    |  arn:aws:logs:us-east-1:<account-id>:log-group:/lab47/vpc-flow-logs   |
|  Estado     |  ACTIVE                                                               |
|  ID         |  fl-0xxxxxxxxxxxx                                                     |
|  TipoTrafico|  ALL                                                                  |
+-------------+-----------------------------------------------------------------------+
```

El estado debe ser `ACTIVE`. Si aparece `FAILED`, revisa el rol IAM y los permisos
del log group.

### Verificar que la instancia está corriendo

```bash
aws ec2 describe-instances \
  --instance-ids "$INSTANCE_ID" \
  --query 'Reservations[0].Instances[0].{Estado:State.Name,IP:PublicIpAddress,ENI:NetworkInterfaces[0].NetworkInterfaceId}' \
  --output table
```

La instancia necesita unos minutos para arrancar y que el script de `user_data`
empiece a generar tráfico. Puedes conectarte a ella con SSM para verificar:

```bash
aws ssm start-session --target "$INSTANCE_ID"
# Dentro de la instancia:
tail -f /var/log/traffic-gen.log
```

Salida esperada (similar):

```
2026-04-14T04:45:04Z [SLEEP] 43s hasta el siguiente ciclo
2026-04-14T04:45:47Z [OK] HTTP checkip.amazonaws.com
2026-04-14T04:45:47Z [OK] HTTPS aws.amazon.com
2026-04-14T04:45:47Z [SLEEP] 31s hasta el siguiente ciclo
2026-04-14T04:46:18Z [OK] HTTP checkip.amazonaws.com
2026-04-14T04:46:18Z [OK] HTTPS aws.amazon.com
2026-04-14T04:46:18Z [SLEEP] 29s hasta el siguiente ciclo
2026-04-14T04:46:47Z [OK] HTTP checkip.amazonaws.com
2026-04-14T04:46:47Z [OK] HTTPS aws.amazon.com
2026-04-14T04:46:47Z [SLEEP] 38s hasta el siguiente ciclo
```

### Esperar y ver los primeros registros

> **Latencia esperada**: los Flow Logs tardan **5-10 minutos** en aparecer en
> CloudWatch Logs desde el momento en que se genera el tráfico. Si el log group
> aparece vacío, espera y vuelve a comprobarlo.

Comprueba si hay log streams en el log group:

```bash
aws logs describe-log-streams \
  --log-group-name "$FLOW_LOG_GROUP" \
  --order-by LastEventTime \
  --descending \
  --max-items 5 \
  --query 'logStreams[].{Stream:logStreamName,UltimoEvento:lastEventTimestamp}' \
  --output table
```

Salida esperada:

```
------------------------------------------------
|              DescribeLogStreams              |
+----------------------------+-----------------+
|           Stream           |  UltimoEvento   |
+----------------------------+-----------------+
|  eni-0xxxxxxxxxxxx-reject  |  1776084346000  |
+----------------------------+-----------------+
```

Cada stream corresponde a una ENI. El sufijo `-reject` indica que el flow log captura
únicamente tráfico denegado. `UltimoEvento` es un timestamp Unix en milisegundos.

### Leer los registros de flujo

```bash
# Lee los registros del stream que corresponde a la ENI monitorizada
STREAM=$(aws logs describe-log-streams \
  --log-group-name "$FLOW_LOG_GROUP" \
  --log-stream-name-prefix "$ENI_ID" \
  --query 'logStreams[0].logStreamName' \
  --output text)

aws logs get-log-events \
  --log-group-name "$FLOW_LOG_GROUP" \
  --log-stream-name "$STREAM" \
  --limit 10 \
  --query 'events[].message' \
  --output text
```

### Analizar con Log Insights

**Primera consulta — resumen de tráfico por acción** (siempre devuelve resultados
en cuanto hay datos en el log group):

```bash
QUERY_ID=$(aws logs start-query \
  --log-group-name "$FLOW_LOG_GROUP" \
  --start-time $(($(date +%s) - 3600)) \
  --end-time $(date +%s) \
  --query-string '
    parse @message "* * * * * * * * * * * * * *" as version, account, eni, src, dst, srcport, dstport, protocol, packets, bytes, start, end, action, status
    | filter eni = "'$ENI_ID'"
    | stats count(*) as total by action
    | sort total desc
  ' \
  --query 'queryId' --output text)

sleep 10
aws logs get-query-results --query-id "$QUERY_ID" \
  --query 'results[*][*].[field,value]' \
  --output text
```

Salida esperada (similar):

```
action  REJECT
total   131
```

Esta consulta muestra el total de conexiones denegadas registradas por el flow log
de la ENI monitorizada.

**Segunda consulta — puertos destino más atacados** (puede tardar en tener datos
si los escáneres aún no han encontrado la instancia):

```bash
QUERY_ID=$(aws logs start-query \
  --log-group-name "$FLOW_LOG_GROUP" \
  --start-time $(($(date +%s) - 3600)) \
  --end-time $(date +%s) \
  --query-string '
    parse @message "* * * * * * * * * * * * * *" as version, account, eni, src, dst, srcport, dstport, protocol, packets, bytes, start, end, action, status
    | filter eni = "'$ENI_ID'"
    | stats count(*) as intentos by dstport
    | sort intentos desc
    | limit 10
  ' \
  --query 'queryId' --output text)

sleep 10
aws logs get-query-results --query-id "$QUERY_ID" \
  --query 'results[*][*].[field,value]' \
  --output text
```

Salida esperada (similar):

```
dstport 0
intentos        4
dstport 80
intentos        3
dstport 8728
intentos        2
dstport 8080
intentos        2
dstport 5985
intentos        2
dstport 8200
intentos        2
dstport 23
intentos        2
dstport 65003
intentos        2
dstport 90
intentos        2
dstport 48808
intentos        1
```

**Tercera consulta — IPs origen con más intentos rechazados:**

```bash
QUERY_ID=$(aws logs start-query \
  --log-group-name "$FLOW_LOG_GROUP" \
  --start-time $(($(date +%s) - 3600)) \
  --end-time $(date +%s) \
  --query-string '
    parse @message "* * * * * * * * * * * * * *" as version, account, eni, src, dst, srcport, dstport, protocol, packets, bytes, start, end, action, status
    | filter eni = "'$ENI_ID'"
    | stats count(*) as intentos by src
    | sort intentos desc
    | limit 10
  ' \
  --query 'queryId' --output text)

sleep 10
aws logs get-query-results --query-id "$QUERY_ID" \
  --query 'results[*][*].[field,value]' \
  --output text
```

Salida esperada (similar):

```
src     35.203.211.49
intentos        2
src     193.32.162.28
intentos        2
src     172.237.150.22
intentos        2
src     162.216.150.199
intentos        2
src     205.210.31.180
intentos        2
src     45.205.1.26
intentos        1
src     45.142.154.87
intentos        1
src     147.185.133.247
intentos        1
src     35.203.210.128
intentos        1
src     173.230.150.73
intentos        1
```

---

## Paso 3 — Explorar CloudTrail

### Verificar el trail

```bash
aws cloudtrail describe-trails \
  --trail-name-list "$TRAIL_NAME" \
  --query 'trailList[0].{
    Nombre:Name,
    MultiRegion:IsMultiRegionTrail,
    GlobalServices:IncludeGlobalServiceEvents,
    ValidacionIntegridad:LogFileValidationEnabled,
    KMS:KmsKeyId,
    BucketS3:S3BucketName,
    LogGroupCW:CloudWatchLogsLogGroupArn
  }' \
  --output table
```

Salida esperada:

```
---------------------------------------------------------------------------------------------------------
|                                            DescribeTrails                                             |
+----------------------+--------------------------------------------------------------------------------+
|  BucketS3            |  lab47-archive-<account-id>                                                    |
|  GlobalServices      |  True                                                                          |
|  KMS                 |  arn:aws:kms:us-east-1:<account-id>:key/<key-id>                               |
|  LogGroupCW          |  arn:aws:logs:us-east-1:<account-id>:log-group:/lab47/cloudtrail:*             |
|  MultiRegion         |  True                                                                          |
|  Nombre              |  lab47-trail                                                                   |
|  ValidacionIntegridad|  True                                                                          |
+----------------------+--------------------------------------------------------------------------------+
```


Comprueba el estado (activo o no):

```bash
aws cloudtrail get-trail-status --name "$TRAIL_NAME" \
  --query '{
    Activo:IsLogging,
    UltimaEntregaS3:LatestDeliveryTime,
    UltimoError:LatestDeliveryError
  }' \
  --output table
```

Salida esperada:

```
---------------------------------------------------------------
|                       GetTrailStatus                        |
+--------+------------------------------------+---------------+
| Activo |          UltimaEntregaS3           |  UltimoError  |
+--------+------------------------------------+---------------+
|  True  |  2026-04-13T15:17:42.516000+02:00  |  None         |
+--------+------------------------------------+---------------+
```

`UltimoError` debe ser `None`. Si muestra un error de `S3`, revisa la bucket policy.

### Consultar eventos recientes

Los eventos de gestión (management events) se registran inmediatamente. Busca los
últimos eventos de la cuenta:

```bash
aws cloudtrail lookup-events \
  --max-results 10 \
  --query 'Events[].{
    Hora:EventTime,
    Evento:EventName,
    Usuario:Username,
    Recurso:Resources[0].ResourceName
  }' \
  --output table
```

Salida esperada (ejemplo):

```
----------------------------------------------------------------------------------------------
|                                        LookupEvents                                        |
+---------------------------+-----------------------------+----------+-----------------------+
|          Evento           |            Hora             | Recurso  |        Usuario        |
+---------------------------+-----------------------------+----------+-----------------------+
|  Decrypt                  |  2026-04-13T15:19:19+02:00  |  None    |  None                 |
|  RegisterContainerInstance|  2026-04-13T15:19:10+02:00  |  None    |  i-xxxxxxxxxxxx       |
|  ...                      |  ...                        |  ...     |  ...                  |
+---------------------------+-----------------------------+----------+-----------------------+
```

Los eventos `Decrypt` o `GenerateDataKey` corresponden a llamadas KMS generadas internamente por los servicios
del laboratorio (CloudTrail, Firehose, CloudWatch Logs) al cifrar o descifrar datos con la
CMK. `Usuario: None` es normal en estos casos porque el principal es un servicio AWS, no
un usuario IAM. `RegisterContainerInstance` indica actividad de ECS en la cuenta.

Filtra solo los eventos de IAM (cambios de permisos, creación de usuarios):

```bash
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventSource,AttributeValue=iam.amazonaws.com \
  --max-results 10 \
  --query 'Events[].{Hora:EventTime,Evento:EventName,Usuario:Username}' \
  --output table
```

Salida esperada:

```
-------------------------------------------------------------------------
|                             LookupEvents                              |
+---------------------------+-----------------------------+-------------+
|          Evento           |            Hora             |   Usuario   |
+---------------------------+-----------------------------+-------------+
|  GetRolePolicy            |  2026-04-14T07:18:49+02:00  |  <usuario>  |
|  GetRolePolicy            |  2026-04-14T07:18:48+02:00  |  <usuario>  |
|  GetRolePolicy            |  2026-04-14T07:18:47+02:00  |  <usuario>  |
|  ListAttachedRolePolicies |  2026-04-14T07:18:47+02:00  |  <usuario>  |
|  GetInstanceProfile       |  2026-04-14T07:18:47+02:00  |  <usuario>  |
|  ListAttachedRolePolicies |  2026-04-14T07:18:47+02:00  |  <usuario>  |
|  GetRole                  |  2026-04-14T07:18:47+02:00  |  <usuario>  |
|  GetRolePolicy            |  2026-04-14T07:18:47+02:00  |  <usuario>  |
|  GetRolePolicy            |  2026-04-14T07:18:47+02:00  |  <usuario>  |
|  ListAttachedRolePolicies |  2026-04-14T07:18:47+02:00  |  <usuario>  |
+---------------------------+-----------------------------+-------------+
```

Los eventos corresponden a las llamadas IAM realizadas durante el propio `terraform apply`:
`GetRolePolicy`, `ListAttachedRolePolicies`, `GetRole` e `GetInstanceProfile` son las
lecturas que Terraform ejecuta para reconciliar el estado de los recursos IAM del laboratorio.
En una cuenta de producción verías aquí los cambios realizados por ingenieros o pipelines de CI/CD.

### Verificar la entrega a CloudWatch Logs

Antes de consultar Log Insights, confirma que CloudTrail está entregando eventos
al log group:

```bash
aws cloudtrail get-trail-status --name "$TRAIL_NAME" \
  --query '{CWLogsEntrega:LatestCloudWatchLogsDeliveryTime, CWLogsError:LatestCloudWatchLogsDeliveryError}' \
  --output table
```

Salida esperada:

```
-----------------------------------------------------
|                  GetTrailStatus                   |
+-----------------------------------+---------------+
|           CWLogsEntrega           |  CWLogsError  |
+-----------------------------------+---------------+
|  2026-04-13T15:36:09.116000+02:00 |  None         |
+-----------------------------------+---------------+
```

`CWLogsError: None` confirma que el rol IAM se asume correctamente. Si aparece
`CannotAssumeRole`, ejecuta `terraform apply` para propagar la condición
`aws:SourceArn` del trust policy del rol.

### Consultar en Log Insights (tiempo real)

> **Latencia esperada**: CloudTrail tarda **5-15 minutos** en entregar los primeros
> eventos al log group de CloudWatch. Si las consultas devuelven vacío, espera unos
> minutos y vuelve a ejecutarlas.

Los eventos aparecen en CloudWatch Logs con latencia de segundos a minutos:

Eventos recientes de la cuenta (últimas 3 horas):

```bash
QUERY_ID=$(aws logs start-query \
  --log-group-name "$CLOUDTRAIL_LOG_GROUP" \
  --start-time $(($(date +%s) - 10800)) \
  --end-time $(date +%s) \
  --query-string '
    fields @timestamp, eventName, eventSource, userIdentity.type, sourceIPAddress
    | sort @timestamp desc
    | limit 20
  ' \
  --query 'queryId' --output text)

sleep 10
aws logs get-query-results --query-id "$QUERY_ID" \
  --query 'results[*][*].[field,value]' \
  --output text
```

Salida esperada (similar):

```
@timestamp      2026-04-14 05:25:03.477
eventName       DescribeVerifiedAccessEndpoints
eventSource     ec2.amazonaws.com
userIdentity.type       AssumedRole
sourceIPAddress resource-explorer-2.amazonaws.com
@timestamp      2026-04-14 05:25:03.476
eventName       AssumeRole
eventSource     sts.amazonaws.com
userIdentity.type       AWSService
sourceIPAddress resource-explorer-2.amazonaws.com
@timestamp      2026-04-14 05:23:55.720
eventName       GenerateDataKey
eventSource     kms.amazonaws.com
userIdentity.type       AWSService
sourceIPAddress fas.s3.amazonaws.com
@timestamp      2026-04-14 05:23:55.720
eventName       GenerateDataKey
eventSource     kms.amazonaws.com
userIdentity.type       AWSService
sourceIPAddress fas.s3.amazonaws.com
```

Llamadas KMS generadas por los servicios del laboratorio:

```bash
QUERY_ID=$(aws logs start-query \
  --log-group-name "$CLOUDTRAIL_LOG_GROUP" \
  --start-time $(($(date +%s) - 10800)) \
  --end-time $(date +%s) \
  --query-string '
    fields @timestamp, eventName, userIdentity.invokedBy, requestParameters.keyId
    | filter eventSource = "kms.amazonaws.com"
    | stats count(*) as total by eventName
    | sort total desc
  ' \
  --query 'queryId' --output text)

sleep 10
aws logs get-query-results --query-id "$QUERY_ID" \
  --query 'results[*][*].[field,value]' \
  --output text
```

Salida esperada (similar):

```
eventName       GenerateDataKey
total   6195
eventName       Decrypt
total   430
eventName       GetKeyPolicy
total   68
eventName       DescribeKey
total   68
eventName       ListResourceTags
total   39
eventName       GetKeyRotationStatus
total   39
eventName       ListRetirableGrants
total   21
eventName       ListAliases
total   16
eventName       Encrypt
total   6
eventName       ListKeys
total   3
```

### Validar la integridad de los logs

> **Requiere al menos 1 hora de actividad.** CloudTrail genera el primer archivo
> de resumen (digest) aproximadamente 1 hora después de que el trail empieza a
> escribir logs. Ejecuta este comando tras esperar ese tiempo.

Limita el rango de tiempo a la última hora para ver solo los logs del despliegue
actual:

```bash
aws cloudtrail validate-logs \
  --trail-arn "arn:aws:cloudtrail:${REGION}:${ACCOUNT_ID}:trail/${TRAIL_NAME}" \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)"
```

Salida esperada tras al menos 1 hora de actividad correcta:

```
Results requested for 2026-04-13T14:37:33Z to 2026-04-13T15:37:33Z
Results found for 2026-04-13T14:37:33Z to 2026-04-13T15:37:33Z:

N/N digest files valid
N/N log files valid
```

> **`INVALID: not found` en archivos de la primera hora** — Si el rango incluye
> el periodo inicial del despliegue, es posible ver archivos `not found`. Esto ocurre
> cuando CloudTrail no pudo escribir los archivos en S3 (por ejemplo, por un permiso
> KMS incompleto), pero sí generó el digest que los referencia. El digest detecta
> correctamente la ausencia: es la herramienta funcionando como se espera, no un fallo
> de la validación en sí. Ajusta `--start-time` a un momento posterior a que
> `CWLogsError` pasara a `None`.

---

## Paso 4 — Verificar la tubería Firehose → S3

### Estado del delivery stream

```bash
aws firehose describe-delivery-stream \
  --delivery-stream-name "$FIREHOSE_NAME" \
  --query 'DeliveryStreamDescription.{
    Estado:DeliveryStreamStatus,
    Tipo:DeliveryStreamType,
    Destino:Destinations[0].ExtendedS3DestinationDescription.BucketARN,
    Buffer_MB:Destinations[0].ExtendedS3DestinationDescription.BufferingHints.SizeInMBs,
    Buffer_s:Destinations[0].ExtendedS3DestinationDescription.BufferingHints.IntervalInSeconds,
    Compresion:Destinations[0].ExtendedS3DestinationDescription.CompressionFormat
  }' \
  --output table
```

Salida esperada:

```
-----------------------------------------------------------------------------------------------------------
|                                         DescribeDeliveryStream                                          |
+-----------+-----------+-------------+-------------------------------------------+---------+-------------+
| Buffer_MB | Buffer_s  | Compresion  |                  Destino                  | Estado  |    Tipo     |
+-----------+-----------+-------------+-------------------------------------------+---------+-------------+
|  5        |  300      |  GZIP       |  arn:aws:s3:::lab47-archive-<account-id>  |  ACTIVE |  DirectPut  |
+-----------+-----------+-------------+-------------------------------------------+---------+-------------+
```

El estado debe ser `ACTIVE`. `Tipo: DirectPut` indica que CloudWatch Logs envía los
registros directamente a Firehose (sin pasar por Kinesis Data Streams). Un estado
`CREATING` indica que el stream aún se está inicializando (puede tardar hasta 30 segundos).

### Comprobar la subscription filter

```bash
aws logs describe-subscription-filters \
  --log-group-name "$FLOW_LOG_GROUP" \
  --query 'subscriptionFilters[].{
    Nombre:filterName,
    Patron:filterPattern,
    Destino:destinationArn
  }' \
  --output table
```

Salida esperada:

```
----------------------------------------------------------------------------------------------------------------------
|                                             DescribeSubscriptionFilters                                            |
+--------------------------------------------------------------------------+-------------------------------+---------+
|                                  Destino                                 |            Nombre             | Patron  |
+--------------------------------------------------------------------------+-------------------------------+---------+
|  arn:aws:firehose:us-east-1:<account-id>:deliverystream/lab47-logs-to-s3 |  lab47-flow-logs-to-firehose  |         |
+--------------------------------------------------------------------------+-------------------------------+---------+
```

`Patron` vacío significa `filter_pattern = ""` — captura todos los registros del log
group sin filtrar. El destino es el ARN del delivery stream de Firehose.

### Esperar la primera entrega a S3

Firehose espera a que se cumpla el umbral de buffer (5 MB o 300 segundos). Con poco
tráfico de red, puede tardar hasta 5 minutos en crear el primer objeto en S3.

```bash
# Espera y luego lista los objetos bajo el prefijo de Firehose
aws s3 ls "s3://${BUCKET}/firehose/" --recursive --human-readable
```

Salida esperada (similar):

```
2026-04-14 06:20:20    6.1 KiB firehose/year=2026/month=04/day=14/lab47-logs-to-s3-1-2026-04-14-04-15-19-883ab1ba-337b-450b-9ffb-8f52c2115075.gz
2026-04-14 06:25:50    5.5 KiB firehose/year=2026/month=04/day=14/lab47-logs-to-s3-1-2026-04-14-04-20-45-74255b46-dce4-450d-afae-f46443c9db92.gz
2026-04-14 06:30:51    4.5 KiB firehose/year=2026/month=04/day=14/lab47-logs-to-s3-1-2026-04-14-04-25-45-e37c7771-1cac-4a25-878e-6f52fc711b1e.gz
2026-04-14 06:36:22    2.8 KiB firehose/year=2026/month=04/day=14/lab47-logs-to-s3-1-2026-04-14-04-31-16-aa2bfa5e-1179-467e-8e83-01ee1c190143.gz
2026-04-14 06:41:43    3.0 KiB firehose/year=2026/month=04/day=14/lab47-logs-to-s3-1-2026-04-14-04-36-38-884b6054-a59a-4964-a6e9-529998428dd0.gz
...
```

Cada objeto se entrega aproximadamente cada 5 minutos (buffer de 300 s) con tamaños
de 3-6 KiB comprimidos. Si no hay objetos aún, espera un poco más. Los Flow Logs
necesitan tráfico REJECT real para generar registros que fluyan a Firehose.

### Verificar el contenido de un objeto GZIP

```bash
# Obtiene la clave del objeto más reciente entregado por Firehose
FIREHOSE_KEY=$(aws s3api list-objects-v2 \
  --bucket "$BUCKET" \
  --prefix "firehose/" \
  --query 'sort_by(Contents, &LastModified)[-1].Key' \
  --output text)

aws s3 cp "s3://${BUCKET}/${FIREHOSE_KEY}" /tmp/firehose-sample.gz

# Decodifica el contenido con doble descompresión y parseo de JSON concatenados
python3 << 'EOF'
import gzip, json

with open('/tmp/firehose-sample.gz', 'rb') as f:
    data = f.read()

# Capa 1: GZIP aplicado por Firehose al escribir en S3
inner = gzip.decompress(data)

# Capa 2: múltiples streams GZIP de CloudWatch Logs concatenados en binario.
# gzip.decompress() en Python 3.2+ descomprime todos los miembros GZIP
# concatenados y devuelve sus contenidos JSON uno tras otro.
all_json = gzip.decompress(inner).decode('utf-8')

decoder = json.JSONDecoder()
pos, count = 0, 0
while pos < len(all_json) and count < 5:
    try:
        obj, end = decoder.raw_decode(all_json, pos)
        for event in obj.get('logEvents', []):
            print(event['message'])
            count += 1
        pos = end
    except json.JSONDecodeError:
        pos += 1
EOF
```

Salida esperada (similar):

```
2 <account-id> eni-0xxxxxxxxxxxx 147.185.132.224 10.47.0.200 51126 47528 6 1 44 1776144126 1776144154 REJECT OK
2 <account-id> eni-0xxxxxxxxxxxx 162.216.150.192 10.47.0.200 54662 27087 6 1 44 1776144126 1776144154 REJECT OK
2 <account-id> eni-0xxxxxxxxxxxx 162.216.150.240 10.47.0.200 57039 9222  6 1 44 1776144126 1776144154 REJECT OK
2 <account-id> eni-0xxxxxxxxxxxx 147.185.133.73  10.47.0.200 55059 32508 6 1 44 1776144155 1776144181 REJECT OK
2 <account-id> eni-0xxxxxxxxxxxx 165.154.41.182  10.47.0.200 38878 8183  6 1 40 1776144155 1776144181 REJECT OK
2 <account-id> eni-0xxxxxxxxxxxx 192.155.81.124  10.47.0.200 52591 8091  6 1 44 1776144155 1776144181 REJECT OK
```

Cada línea es un registro de flujo en [formato estándar de VPC Flow Logs v2](https://docs.aws.amazon.com/vpc/latest/userguide/flow-log-records.html):
`version account-id interface-id srcaddr dstaddr srcport dstport protocol packets bytes start end action log-status`.
Todas las entradas muestran `REJECT OK`, confirmando que el pipeline captura exclusivamente
el tráfico denegado por el Security Group y lo archiva correctamente en S3.

**Por qué la doble capa:** CloudWatch Logs subscription filter envía cada lote de
registros a Firehose como un stream gzip-comprimido binario, con metadatos JSON
(`logGroup`, `logStream`, `logEvents`). Firehose almacena esos blobs binarios en el
buffer y, al vaciar a S3, aplica su propio GZIP sobre el conjunto concatenado.
El resultado es `GZIP_Firehose(gzip_CW_1 + gzip_CW_2 + ...)`.

En producción se añade una función Lambda como transformación en el delivery stream
para decodificar este formato y escribir registros planos directamente consultables
por Athena sin transformación adicional.

### Métricas de Firehose en CloudWatch

```bash
# Registros entregados a S3 en la última hora
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Firehose" \
  --metric-name "DeliveryToS3.Records" \
  --dimensions Name=DeliveryStreamName,Value="$FIREHOSE_NAME" \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 \
  --statistics Sum \
  --query 'sort_by(Datapoints,&Timestamp)[].{Hora:Timestamp,Registros:Sum}' \
  --output table

# Tasa de éxito de entrega (debe ser 1.0 = 100%)
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Firehose" \
  --metric-name "DeliveryToS3.Success" \
  --dimensions Name=DeliveryStreamName,Value="$FIREHOSE_NAME" \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 \
  --statistics Average \
  --query 'sort_by(Datapoints,&Timestamp)[].{Hora:Timestamp,Exito:Average}' \
  --output table
```

Salida esperada (similar):

```
--------------------------------------------
|            GetMetricStatistics           |
+----------------------------+-------------+
|            Hora            |  Registros  |
+----------------------------+-------------+
|  2026-04-14T06:48:00+02:00 |  10.0       |
+----------------------------+-------------+
----------------------------------------
|          GetMetricStatistics         |
+-------+------------------------------+
| Exito |            Hora              |
+-------+------------------------------+
|  1.0  |  2026-04-14T06:48:00+02:00   |
+-------+------------------------------+
```

`Exito: 1.0` confirma una tasa de entrega del 100%. `Registros` muestra el número de
registros de flow log entregados a S3 en ese periodo de 5 minutos.

---

## Paso 5 — Ciclo de vida S3 y análisis FinOps

### Verificar la política de ciclo de vida

```bash
aws s3api get-bucket-lifecycle-configuration \
  --bucket "$BUCKET" \
  --query 'Rules[].{
    ID:ID,
    Estado:Status,
    TransicionDias:Transitions[0].Days,
    ClaseDestino:Transitions[0].StorageClass,
    LimpiezaMultipart:AbortIncompleteMultipartUpload.DaysAfterInitiation,
    ExpiracionVersiones:NoncurrentVersionExpiration.NoncurrentDays
  }' \
  --output table
```

Salida esperada:

```
---------------------------------------------------------------
|               GetBucketLifecycleConfiguration               |
+----------------------+--------------------------------------+
|  ClaseDestino        |  DEEP_ARCHIVE                        |
|  Estado              |  Enabled                             |
|  ExpiracionVersiones |  180                                 |
|  ID                  |  transition-to-glacier-deep-archive  |
|  LimpiezaMultipart   |  7                                   |
|  TransicionDias      |  90                                  |
+----------------------+--------------------------------------+
```

Confirma que los tres componentes de la política están activos:
- `TransicionDias: 90` → los objetos pasan a Glacier Deep Archive a los 90 días
- `LimpiezaMultipart: 7` → las cargas multiparte incompletas se eliminan a los 7 días
- `ExpiracionVersiones: 180` → las versiones no actuales expiran a los 180 días

### Calcular el volumen de logs acumulado

```bash
# Tamaño total del bucket por prefijo
echo "=== Volumen CloudTrail ==="
aws s3 ls "s3://${BUCKET}/cloudtrail/" --recursive --human-readable \
  | tail -1

echo "=== Volumen Firehose ==="
aws s3 ls "s3://${BUCKET}/firehose/" --recursive --human-readable \
  | tail -1

echo "=== Tamaño total del bucket ==="
aws s3 ls "s3://${BUCKET}/" --recursive --human-readable \
  | tail -1
```

### Análisis FinOps: proyección de costes

El coste real de S3 no es solo el almacenamiento. Para logs de auditoría hay que
considerar también:

| Concepto | Standard | Glacier Deep Archive |
|----------|----------|----------------------|
| Almacenamiento | $0.023/GB/mes | $0.00099/GB/mes |
| PUT / COPY / POST (por 1.000 ops) | $0.005 | $0.05 |
| GET / SELECT (por 1.000 ops) | $0.0004 | $0.0004 + $0.0025 restauración |
| Duración mínima cobrada | Sin mínimo | 180 días |
| Recuperación | Inmediata | 12-48 horas ($0.02/GB bulk) |

Para los logs de este laboratorio (escritura frecuente, lectura casi nula), el
coste dominante es el almacenamiento. Pero si los logs se consultan con frecuencia
en los primeros meses, las operaciones GET y los costes de restauración de Glacier
pueden superar el ahorro en almacenamiento. Evalúa el patrón de acceso real antes
de elegir el tier de transición.

Con el volumen conocido puedes proyectar el coste de almacenamiento mensual:

```bash
# Ejemplo con 10 GB de logs por mes
VOLUME_GB=10

echo "Proyección de coste de almacenamiento para ${VOLUME_GB} GB de logs:"
echo ""
echo "S3 Standard:            $(echo "scale=2; $VOLUME_GB * 0.023" | bc) USD/mes"
echo "S3 Standard-IA:         $(echo "scale=2; $VOLUME_GB * 0.0125" | bc) USD/mes"
echo "Glacier Instant:        $(echo "scale=4; $VOLUME_GB * 0.004" | bc) USD/mes"
echo "Glacier Deep Archive:   $(echo "scale=4; $VOLUME_GB * 0.00099" | bc) USD/mes"
echo ""
echo "Ahorro Standard → GDA:  $(echo "scale=1; (1 - 0.00099/0.023) * 100" | bc)%"
echo ""
echo "Nota: no incluye costes de operaciones PUT/GET ni restauración de Glacier."
```

### Ver cuándo se producirá la primera transición

La política de ciclo de vida de S3 evalúa los objetos una vez al día (típicamente
a medianoche UTC). Si el bucket tiene objetos creados hoy, pasarán a Glacier Deep
Archive el día `creación + glacier_transition_days`. Puedes ver la fecha de creación
de los objetos más antiguos:

```bash
aws s3api list-objects-v2 \
  --bucket "$BUCKET" \
  --query 'sort_by(Contents, &LastModified)[0:3].{Key:Key,Creado:LastModified,Clase:StorageClass}' \
  --output table
```

Salida esperada:

```
------------------------------------------------------------------------------------------------------------------------------
|                                                       ListObjectsV2                                                        |
+----------+----------------------------+------------------------------------------------------------------------------------+
|   Clase  |          Creado            |                                       Key                                          |
+----------+----------------------------+------------------------------------------------------------------------------------+
|  STANDARD|  2026-04-13T12:44:20+00:00 |  cloudtrail/AWSLogs/<account-id>/CloudTrail-Digest/                                |
|  STANDARD|  2026-04-13T12:44:20+00:00 |  cloudtrail/AWSLogs/<account-id>/CloudTrail/                                       |
|  STANDARD|  2026-04-13T12:45:00+00:00 |  cloudtrail/AWSLogs/<account-id>/CloudTrail/ca-central-1/2026/04/13/...json.gz     |
+----------+----------------------------+------------------------------------------------------------------------------------+
```

Todos los objetos están en `STANDARD`. La columna `Creado` marca el punto de partida
del contador de 90 días. El primer prefijo `CloudTrail-Digest/` corresponde a los
archivos de resumen para `validate-logs`; `CloudTrail/` contiene los archivos de
eventos. Fíjate en que el trail multi-región escribe en subdirectorios por región
(`ca-central-1`, `us-east-1`, etc.).

---

## Verificación final

```bash
echo "=== VPC Flow Log ==="
aws ec2 describe-flow-logs \
  --filter "Name=resource-id,Values=${ENI_ID}" \
  --query 'FlowLogs[].{ID:FlowLogId,Estado:FlowLogStatus,TipoTrafico:TrafficType}' \
  --output table

echo "=== CloudTrail activo ==="
aws cloudtrail get-trail-status --name "$TRAIL_NAME" \
  --query '{Activo:IsLogging,UltimaEntrega:LatestDeliveryTime}' \
  --output table

echo "=== Log groups con datos ==="
for LG in "$FLOW_LOG_GROUP" "$CLOUDTRAIL_LOG_GROUP"; do
  COUNT=$(aws logs describe-log-streams \
    --log-group-name "$LG" \
    --query 'length(logStreams)' \
    --output text 2>/dev/null || echo 0)
  echo "  $LG: $COUNT streams"
done

echo "=== Firehose activo ==="
aws firehose describe-delivery-stream \
  --delivery-stream-name "$FIREHOSE_NAME" \
  --query 'DeliveryStreamDescription.DeliveryStreamStatus' \
  --output text

echo "=== Objetos en S3 ==="
aws s3 ls "s3://${BUCKET}/" --recursive --human-readable | wc -l
echo "objetos en el bucket de archivo"
```

---

## Retos

### Reto 1 — Alarma de seguridad sobre intentos de acceso SSH/RDP

Los VPC Flow Logs REJECT ya fluyen a CloudWatch. El siguiente paso natural es
convertir los rechazos en puertos críticos en una alerta automatizada.

**Objetivo**: crear una métrica y una alarma que notifique cuando se detecten más de
20 intentos de acceso a SSH (puerto 22) o RDP (puerto 3389) en 5 minutos, lo que
podría indicar un escáner de puertos o un ataque de fuerza bruta.

1. Crea dos `aws_cloudwatch_log_metric_filter` sobre el log group de flow logs:
   - Uno con patrón `dstport=22, action=REJECT` que publique la métrica `SshRejects`
   - Otro con patrón `dstport=3389, action=REJECT` que publique la métrica `RdpRejects`
   - Ambos en el namespace `${var.project}/Security` con `value = "1"` y `unit = "Count"`
2. Crea un `aws_sns_topic` y una suscripción de email para recibir la alerta
3. Crea un `aws_cloudwatch_metric_alarm` que:
   - Use `metric_query` con metric math para sumar `SshRejects + RdpRejects`
   - Evalúe la suma (`Sum`) en periodos de 300 segundos
   - Dispare si supera 20 intentos en 1 periodo consecutivo
   - Envíe la notificación al topic SNS

**Pistas:**
- El patrón de VPC Flow Logs usa campos posicionales separados por espacios
- El operador `||` en los patrones de CloudWatch Logs no existe para campos posicionales: necesitas dos filtros separados, uno por puerto
- `evaluation_periods = 1` es apropiado para amenazas de seguridad (respuesta rápida)
- `unit = "Count"` es el tipo de dato de la métrica; `stat = "Sum"` es cómo se agrega en la alarma — son cosas distintas

---

### Reto 2 — Reenviar CloudTrail a Firehose (fanout de logs)

Actualmente solo los VPC Flow Logs van a Firehose. Para un archivo centralizado
completo, los eventos de CloudTrail también deberían estar en S3 con el mismo
formato y ciclo de vida.

**Objetivo**: añadir una segunda subscription filter que reenvíe los eventos de
CloudTrail desde su log group de CloudWatch al mismo delivery stream de Firehose.

1. Añade un `aws_cloudwatch_log_subscription_filter` sobre `aws_cloudwatch_log_group.cloudtrail`
2. Usa el mismo `destination_arn` del delivery stream existente
3. Usa el mismo rol IAM `aws_iam_role.cw_to_firehose` (ya tiene los permisos)
4. Usa `filter_pattern = ""` para capturar todos los eventos de CloudTrail

> **Nota**: con este cambio, tanto los Flow Logs como los eventos de CloudTrail
> llegarán al mismo prefijo `firehose/` en S3. En producción, usarías prefijos
> distintos por fuente, o un delivery stream separado para cada una.

**Verificación:**

```bash
# Debe haber 2 subscription filters sobre el log group de CloudTrail
aws logs describe-subscription-filters \
  --log-group-name "$CLOUDTRAIL_LOG_GROUP"
```

---

### Reto 3 — CloudTrail Insights para detección de anomalías de API

CloudTrail Insights analiza estadísticamente el volumen de llamadas a la API y
genera eventos cuando detecta desviaciones significativas respecto al comportamiento
habitual. Es el equivalente al Anomaly Detection de CloudWatch, pero para auditoría
de API.

**Objetivo**: habilitar CloudTrail Insights en el trail existente para detectar
tanto anomalías en la tasa de llamadas (`ApiCallRateInsight`) como en la tasa de
errores de API (`ApiErrorRateInsight`).

1. Añade el bloque `insight_selector` al recurso `aws_cloudtrail.main`:
   ```hcl
   insight_selector {
     insight_type = "ApiCallRateInsight"
   }

   insight_selector {
     insight_type = "ApiErrorRateInsight"
   }
   ```
2. Aplica los cambios con `terraform apply`
3. Verifica que Insights está habilitado:
   ```bash
   aws cloudtrail get-insight-selectors --trail-name "$TRAIL_NAME"
   ```

> **Nota**: CloudTrail Insights tiene un coste adicional por evento de Insights
> generado y requiere al menos 7 días de datos para establecer la línea base.
> En este laboratorio no verás eventos de Insights inmediatamente, pero el
> trail quedará listo para detectar anomalías en producción.

**Pistas:**
- `insight_selector` admite múltiples bloques, uno por tipo
- Los eventos de Insights se almacenan en S3 bajo el prefijo `CloudTrail-Insight/`
- También se pueden enviar a CloudWatch Logs si el trail tiene integración CW habilitada

---

## Soluciones

<details>
<summary><strong>Solución al Reto 1 — Alarma sobre intentos SSH/RDP</strong></summary>

### Solución al Reto 1 — Alarma sobre intentos SSH/RDP

**Por qué un umbral de 20 intentos en 5 minutos:**

Un escáner de puertos típico (nmap, masscan) envía decenas de paquetes por segundo.
20 rechazos en 5 minutos (~0.07 por segundo) es un umbral muy conservador: filtra
el ruido de fondo de internet (bots, crawlers ocasionales) pero captura patrones
activos de escaneo. En producción ajustarías este valor según el baseline observado.

**SNS Topic y suscripción** → [aws/monitoring.tf](aws/monitoring.tf):

```hcl
resource "aws_sns_topic" "security_alerts" {
  name = "${var.project}-security-alerts"
  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_sns_topic_subscription" "security_email" {
  topic_arn = aws_sns_topic.security_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}
```

**Variable de email** → [aws/variables.tf](aws/variables.tf):

```hcl
variable "alert_email" {
  type        = string
  description = "Email para recibir alertas de seguridad."

  validation {
    condition     = can(regex("^[^@]+@[^@]+\\.[^@]+$", var.alert_email))
    error_message = "Debe ser una dirección de email válida."
  }
}
```

**Metric Filters** → [aws/flow_logs.tf](aws/flow_logs.tf):

```hcl
resource "aws_cloudwatch_log_metric_filter" "ssh_rejects" {
  name           = "${var.project}-ssh-rejects"
  log_group_name = aws_cloudwatch_log_group.flow_logs.name

  pattern = "[v, account, eni, src, dst, srcport, dstport=22, protocol, packets, bytes, start, end, action=REJECT, status]"

  metric_transformation {
    name          = "SshRejects"
    namespace     = "${var.project}/Security"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}

resource "aws_cloudwatch_log_metric_filter" "rdp_rejects" {
  name           = "${var.project}-rdp-rejects"
  log_group_name = aws_cloudwatch_log_group.flow_logs.name

  pattern = "[v, account, eni, src, dst, srcport, dstport=3389, protocol, packets, bytes, start, end, action=REJECT, status]"

  metric_transformation {
    name          = "RdpRejects"
    namespace     = "${var.project}/Security"
    value         = "1"
    default_value = "0"
    unit          = "Count"
  }
}
```

**Alarma con metric math** → [aws/flow_logs.tf](aws/flow_logs.tf):

```hcl
resource "aws_cloudwatch_metric_alarm" "admin_port_brute_force" {
  alarm_name          = "${var.project}-admin-port-brute-force"
  alarm_description   = "Mas de 20 intentos de acceso a SSH o RDP en 5 minutos — posible escaneo o fuerza bruta."
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 20
  treat_missing_data  = "notBreaching"

  metric_query {
    id = "ssh"
    metric {
      metric_name = "SshRejects"
      namespace   = "${var.project}/Security"
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id = "rdp"
    metric {
      metric_name = "RdpRejects"
      namespace   = "${var.project}/Security"
      period      = 300
      stat        = "Sum"
    }
  }

  metric_query {
    id          = "total"
    expression  = "ssh + rdp"
    label       = "Intentos SSH + RDP"
    return_data = true
  }

  alarm_actions = [aws_sns_topic.security_alerts.arn]
  ok_actions    = [aws_sns_topic.security_alerts.arn]

  tags = { Project = var.project, ManagedBy = "terraform" }
}
```

Aplica los cambios y confirma la suscripción SNS por email:

```bash
terraform apply -var="alert_email=tu@email.com"
```

#### Verificar en la consola de AWS

**1. Metric Filters** — navega a los filtros creados:

> CloudWatch → Log groups → `/lab47/vpc-flow-logs` → pestaña **Metric filters**

Verás dos filtros:
- `lab47-ssh-rejects` — patrón `dstport=22, action=REJECT`. Cada vez que el log group recibe un registro de flujo rechazado hacia el puerto 22, este filtro incrementa la métrica `SshRejects` en 1 dentro del namespace `lab47/Security`.
- `lab47-rdp-rejects` — igual pero para `dstport=3389`, incrementa `RdpRejects`.

Los metric filters son la capa de traducción entre texto de log y dato numérico de CloudWatch Metrics. Sin ellos, CloudWatch no puede agregar ni alarmar sobre el contenido de los logs.

**2. Alarma** — navega a la alarma creada:

> CloudWatch → Alarms → All alarms → `lab47-admin-port-brute-force`

La alarma evalúa una **metric math expression** que suma las dos métricas:

```
total = SshRejects + RdpRejects
```

Se dispara (`ALARM`) cuando `total > 20` en un periodo de 5 minutos. Cuando está en verde (`OK`) significa que el volumen combinado de intentos SSH+RDP está por debajo del umbral. `treat_missing_data = notBreaching` evita falsas alarmas en periodos sin tráfico: la ausencia de datos no se interpreta como un problema.

En la pestaña **History** puedes ver cada transición de estado. En **Actions** aparece el SNS topic configurado, que enviará un email a la dirección indicada tanto al dispararse la alarma como al recuperarse.

</details>

---

<details>
<summary><strong>Solución al Reto 2 — Reenvío de CloudTrail a Firehose</strong></summary>

### Solución al Reto 2 — Reenvío de CloudTrail a Firehose

**Por qué usar el mismo rol IAM:**

El rol `cw_to_firehose` ya tiene permiso para llamar a `firehose:PutRecordBatch` sobre
el delivery stream. La política de confianza del rol admite `logs.amazonaws.com` como
principal, que es el servicio que asume el rol tanto para los flow logs como para los
eventos de CloudTrail. No es necesario crear un segundo rol.

**Nueva subscription filter** → [aws/firehose.tf](aws/firehose.tf):

```hcl
resource "aws_cloudwatch_log_subscription_filter" "cloudtrail_to_firehose" {
  name            = "${var.project}-cloudtrail-to-firehose"
  log_group_name  = aws_cloudwatch_log_group.cloudtrail.name
  filter_pattern  = ""
  destination_arn = aws_kinesis_firehose_delivery_stream.logs.arn
  role_arn        = aws_iam_role.cw_to_firehose.arn
  distribution    = "Random"
}
```

Aplica:

```bash
terraform apply
```

Verifica que ambas subscription filters están activas:

```bash
for LG in "$FLOW_LOG_GROUP" "$CLOUDTRAIL_LOG_GROUP"; do
  echo "=== Log group: $LG ==="
  aws logs describe-subscription-filters \
    --log-group-name "$LG" \
    --query 'subscriptionFilters[].{Nombre:filterName,Destino:destinationArn}' \
    --output table
done
```

Salida esperada:

```
=== Log group: /lab47/vpc-flow-logs ===
------------------------------------------------------------------------------------------------------------
|                                        DescribeSubscriptionFilters                                       |
+--------------------------------------------------------------------------+-------------------------------+
|                                  Destino                                 |            Nombre             |
+--------------------------------------------------------------------------+-------------------------------+
|  arn:aws:firehose:us-east-1:<account-id>:deliverystream/lab47-logs-to-s3|  lab47-flow-logs-to-firehose  |
+--------------------------------------------------------------------------+-------------------------------+
=== Log group: /lab47/cloudtrail ===
-------------------------------------------------------------------------------------------------------------
|                                        DescribeSubscriptionFilters                                        |
+--------------------------------------------------------------------------+--------------------------------+
|                                  Destino                                 |            Nombre              |
+--------------------------------------------------------------------------+--------------------------------+
|  arn:aws:firehose:us-east-1:<account-id>:deliverystream/lab47-logs-to-s3 |  lab47-cloudtrail-to-firehose  |
+--------------------------------------------------------------------------+--------------------------------+
```

Ambos log groups apuntan al mismo delivery stream. A partir de este momento, los
objetos que Firehose entregue en `s3://<bucket>/firehose/` contendrán una mezcla de
registros de flow log y eventos de CloudTrail concatenados en el mismo GZIP.

</details>

---

<details>
<summary><strong>Solución al Reto 3 — CloudTrail Insights</strong></summary>

### Solución al Reto 3 — CloudTrail Insights

**Cómo funciona Insights:**

CloudTrail Insights monitoriza continuamente el volumen de escrituras de API y de
errores de API. Durante las primeras horas, establece una línea base del comportamiento
normal. Cuando detecta una desviación estadísticamente significativa (un pico de
llamadas a `RunInstances`, un aumento súbito de errores `AccessDenied`, etc.),
genera un evento de Insights que se publica en S3 y opcionalmente en CloudWatch Logs.

Casos de uso reales:
- Campaña de cryptojacking: pico anormal de `RunInstances` en muchas regiones
- Credenciales comprometidas: cientos de `GetObject` en S3 desde una IP desconocida
- Misconfiguration en masa: acceso denegado masivo por una política IAM errónea

**Modificación del trail** → [aws/cloudtrail.tf](aws/cloudtrail.tf):

```hcl
resource "aws_cloudtrail" "main" {
  name                          = "${var.project}-trail"
  s3_bucket_name                = aws_s3_bucket.archive.id
  s3_key_prefix                 = "cloudtrail"
  include_global_service_events = true
  is_multi_region_trail         = true
  enable_log_file_validation    = true
  kms_key_id                    = aws_kms_key.main.arn

  cloud_watch_logs_group_arn = "${aws_cloudwatch_log_group.cloudtrail.arn}:*"
  cloud_watch_logs_role_arn  = aws_iam_role.cloudtrail_cw.arn

  event_selector {
    read_write_type           = "All"
    include_management_events = true
  }

  insight_selector {
    insight_type = "ApiCallRateInsight"
  }

  insight_selector {
    insight_type = "ApiErrorRateInsight"
  }

  depends_on = [aws_s3_bucket_policy.archive]

  tags = { Project = var.project, ManagedBy = "terraform" }
}
```

Aplica y verifica:

```bash
terraform apply

aws cloudtrail get-insight-selectors --trail-name "$TRAIL_NAME" \
  --query 'InsightSelectors[].InsightType' \
  --output table
```

Salida esperada:

```
-------------------------
|  GetInsightSelectors  |
+-----------------------+
|  ApiCallRateInsight   |
|  ApiErrorRateInsight  |
+-----------------------+
```

Los eventos de Insights se guardan en S3 bajo:
```
s3://<bucket>/cloudtrail/AWSLogs/<account-id>/CloudTrail-Insight/<region>/
```

</details>

---

## Limpieza

```bash
cd labs/lab47/aws

terraform destroy
```

> `terraform destroy` elimina todos los recursos. El bucket S3 tiene `force_destroy = true`
> por lo que se eliminará aunque contenga objetos. La CMK entra en estado "Pending deletion"
> durante 7 días antes de ser eliminada definitivamente (`deletion_window_in_days = 7`).
> Durante ese periodo no puede usarse pero no genera costes adicionales.

---

## Solución de problemas

### VPC Flow Log en estado FAILED

El flow log pasa a FAILED si el rol IAM no puede escribir en el log group. Comprueba:

```bash
# Verifica que el rol existe y tiene la política correcta
aws iam get-role-policy \
  --role-name "lab47-flow-logs-role" \
  --policy-name "lab47-flow-logs-policy"

# Verifica el estado del flow log
aws ec2 describe-flow-logs \
  --query 'FlowLogs[].{ID:FlowLogId,Estado:FlowLogStatus,Error:DeliverLogsErrorMessage}'
```

El error más común es `FLOW_LOGS_ACCESS_DENIED`, que indica que el rol no tiene
permisos de escritura en el log group o que la condición ArnLike de la política de
confianza no coincide con el ARN del flow log.

### CloudTrail no escribe en S3

Si `LatestDeliveryError` en `get-trail-status` muestra errores, comprueba la bucket
policy. Los tres fallos más comunes:

1. La política de bucket no existe (el `depends_on` no se respetó): destruye y re-aplica
2. El prefijo del `aws:SourceArn` no coincide con el nombre real del trail
3. El bucket tiene `block_public_policy = true` y hay algún error en la política: revisa
   con `aws s3api get-bucket-policy --bucket <bucket>`

### Firehose no entrega datos a S3

```bash
# Revisa las métricas de error de Firehose
aws cloudwatch get-metric-statistics \
  --namespace "AWS/Firehose" \
  --metric-name "DeliveryToS3.DataFreshness" \
  --dimensions Name=DeliveryStreamName,Value="$FIREHOSE_NAME" \
  --start-time "$(date -u -d '1 hour ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -v-1H +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 300 \
  --statistics Maximum

# Comprueba el log group de errores de Firehose
aws logs tail "/lab47/firehose" --follow
```

`DataFreshness` alto (> 600 s) indica que los datos llevan más de 10 minutos en el
buffer sin entregarse. Suele ser un error de permisos S3 o KMS en el rol de Firehose.

### La subscription filter no aparece activa

```bash
aws logs describe-subscription-filters \
  --log-group-name "$FLOW_LOG_GROUP"
```

Si la lista está vacía, la subscription filter no se creó. Verifica que el delivery
stream de Firehose estaba en estado `ACTIVE` antes de crear el filtro (Terraform
gestiona esto automáticamente con la dependencia implícita del ARN, pero un estado
`CREATING` prolongado puede generar un error de apply).

---

## Buenas prácticas

- **Una CMK por servicio en producción**: este laboratorio usa una CMK compartida para
  simplificar. En producción, cada servicio (CloudWatch, CloudTrail, Firehose, S3) debe
  tener su propia CMK para que una clave comprometida no exponga todos los datos.

- **Activa Flow Logs en TODAS las VPCs**: este laboratorio monitoriza la ENI de una
  instancia concreta, pero en producción deberías habilitar flow logs a nivel de VPC
  completa (incluidas las VPCs de servicios gestionados como EKS). Sin ellos, un
  movimiento lateral dentro de la VPC es invisible.

- **CloudTrail organizacional para multi-cuenta**: si la empresa usa AWS Organizations,
  un trail organizacional (`is_organization_trail = true`) desde la cuenta de gestión
  captura los eventos de TODAS las cuentas miembro en un único bucket centralizado.
  No es posible desactivarlo desde las cuentas miembro.

- **No almacenes los digest de CloudTrail en el mismo bucket que los logs**: si un
  atacante con acceso al bucket elimina tanto el log como su digest, la validación
  no puede detectarlo (no hay referencia externa). Separa los digest en un bucket
  diferente con una política más restrictiva.

- **Prefijos Hive en Firehose para compatibilidad con Athena**: el particionado
  `year=.../month=.../day=...` permite a Athena descubrir particiones automáticamente
  con `MSCK REPAIR TABLE`. Sin este formato, cada consulta escanea todo el bucket.

- **`bucket_key_enabled = true` es gratuito y reduce costes KMS**: sin bucket key,
  cada `PutObject` genera una llamada a KMS (`GenerateDataKey`). Con Firehose entregando
  cientos de objetos por hora, esto se convierte en miles de llamadas KMS diarias
  ($0.03 por 10.000 llamadas). El bucket key elimina el 99% de esas llamadas.

- **Evalúa Intelligent-Tiering antes de Glacier**: si los logs se consultan ocasionalmente
  en los primeros 6 meses (análisis de incidentes, auditorías trimestrales), Glacier Deep
  Archive con 12-48 horas de recuperación puede ser demasiado lento. S3 Intelligent-Tiering
  mueve automáticamente los objetos entre tiers según el acceso real.

---

## Recursos

- [VPC Flow Logs — Formato de registros](https://docs.aws.amazon.com/vpc/latest/userguide/flow-logs.html#flow-logs-fields)
- [CloudTrail — Eventos de gestión y datos](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/logging-management-events-with-cloudtrail.html)
- [CloudTrail — Validación de integridad de archivos](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/cloudtrail-log-file-validation-intro.html)
- [CloudTrail Insights — Detección de anomalías](https://docs.aws.amazon.com/awscloudtrail/latest/userguide/logging-insights-events-with-cloudtrail.html)
- [Kinesis Firehose — Expresiones de prefijo dinámico](https://docs.aws.amazon.com/firehose/latest/dev/s3-prefixes.html)
- [CloudWatch Logs — Subscription Filters](https://docs.aws.amazon.com/AmazonCloudWatch/latest/logs/SubscriptionFilters.html)
- [S3 Lifecycle — Clases de almacenamiento](https://docs.aws.amazon.com/AmazonS3/latest/userguide/storage-class-intro.html)
- [S3 — Precios de almacenamiento](https://aws.amazon.com/s3/pricing/)
