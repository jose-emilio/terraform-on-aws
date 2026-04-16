# Laboratorio 45 — Pipeline GitOps de Terraform con CodePipeline

[← Módulo 10 — CI/CD y Automatización con Terraform](../../modulos/modulo-10/README.md)


## Visión general

En este laboratorio construirás un **pipeline de CI/CD completo** que orquesta el ciclo de vida
de Terraform desde el commit hasta el despliegue. El pipeline tiene cuatro etapas visualizadas
en la consola de CodePipeline: Source (CodeCommit), Build (validación + plan), Approval (manual)
y Deploy (apply + smoke tests).

El concepto central es el **plan inmutable**: `tfplan.bin` se genera **una sola vez** en la
etapa Build y se almacena como artefacto cifrado con KMS en S3. La etapa Deploy recibe
exactamente ese artefacto y ejecuta `terraform apply tfplan.bin` sin re-planificar. Lo que el
aprobador autoriza es exactamente lo que se aplica, sin posibilidad de desviación.

El pipeline también incluye una **Lambda inspectora** que analiza programáticamente el plan
antes de llegar a la aprobación humana: cuenta recursos por tipo de acción y puede bloquear
automáticamente el pipeline si el número de destrucciones supera un umbral configurable.

## Objetivos

- Construir un pipeline CodePipeline de cuatro etapas con artefactos cifrados con KMS
- Configurar acciones paralelas en la etapa Build usando `run_order`
- Implementar el principio del plan inmutable: `tfplan.bin` se genera una vez y se aplica sin re-planificar
- Invocar una función Lambda desde CodePipeline como compuerta programática de seguridad
- Implementar un escáner de seguridad IaC con Checkov usando el patrón Collect-and-Fail
- Configurar una aprobación manual con notificación SNS y enlace al plan descargable
- Escribir smoke tests que verifican el estado real de los recursos mediante la API de AWS

## Requisitos previos

- Laboratorio 02 completado (bucket S3 para el backend de Terraform)
- AWS CLI configurado con credenciales válidas
- Terraform >= 1.9 instalado

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
export REGION="us-east-1"
```

## Arquitectura

```
  ┌─────────────────────────────────────────────────────────────────────────┐
  │  CodeCommit                                                             │
  │  └── rama main  ──►  EventBridge ──► CodePipeline                       │
  └─────────────────────────────────────────────────────────────────────────┘
                                              │
                         ┌────────────────────▼──────────────────────────┐
                         │  Etapa 1: Source                              │
                         │  CodeCommit → source_output (ZIP cifrado KMS) │
                         └────────────────────┬──────────────────────────┘
                                              │
                         ┌────────────────────▼──────────────────────────┐
                         │  Etapa 2: Build                               │
                         │                                               │
                         │  runOrder=1 (paralelas):                      │
                         │  ┌─────────────────┐  ┌────────────────────┐  │
                         │  │ ValidateAndLint │  │   SecurityScan     │  │
                         │  │ fmt + validate  │  │   Checkov + JUnit  │  │
                         │  │ + TFLint        │  │                    │  │
                         │  └─────────────────┘  └────────────────────┘  │
                         │                                               │
                         │  runOrder=2:                                  │
                         │  ┌────────────────────────────────────────┐   │
                         │  │  Plan                                  │   │
                         │  │  tfplan.bin + tfplan.json + tfplan.txt │   │
                         │  └────────────────────────────────────────┘   │
                         │                                               │
                         │  runOrder=3:                                  │
                         │  ┌────────────────────────────────────────┐   │
                         │  │  InspectPlan (Lambda)                  │   │
                         │  │  Cuenta create/update/delete/replace   │   │
                         │  │  Bloquea si destroys > max_threshold   │   │
                         │  └────────────────────────────────────────┘   │
                         └────────────────────┬──────────────────────────┘
                                              │
                         ┌────────────────────▼──────────────────────────┐
                         │  Etapa 3: Approval                            │
                         │  SNS email → aprobador revisa tfplan.txt      │
                         │  Aprueba o rechaza con comentario             │
                         └────────────────────┬──────────────────────────┘
                                              │
                         ┌────────────────────▼──────────────────────────┐
                         │  Etapa 4: Deploy                              │
                         │                                               │
                         │  runOrder=1:                                  │
                         │  ┌─────────────────────────────────────────┐  │
                         │  │  Apply                                  │  │
                         │  │  terraform apply tfplan.bin (inmutable) │  │
                         │  └─────────────────────────────────────────┘  │
                         │                                               │
                         │  runOrder=2:                                  │
                         │  ┌─────────────────────────────────────────┐  │
                         │  │  SmokeTest                              │  │
                         │  │  Verifica S3 + SSM + CloudWatch via API │  │
                         │  └─────────────────────────────────────────┘  │
                         └───────────────────────────────────────────────┘

  Artefactos (cifrados con CMK KMS):
  ├── source_output  → código Terraform del repositorio
  └── plan_output    → tfplan.bin · tfplan.json · tfplan.txt

  IAM (mínimo privilegio):
  ├── pipeline-role        → S3, KMS, CodeCommit, CodeBuild, Lambda, SNS
  ├── codebuild-role       → S3, KMS, CloudWatch Logs, target resources (S3/SSM/CWL)
  ├── lambda-inspector     → S3, KMS, CodePipeline (put_job_result)
  └── events-role          → codepipeline:StartPipelineExecution
```

## Conceptos clave

### El plan inmutable: el contrato entre etapas

El principio fundamental de este laboratorio es que **`tfplan.bin` es un contrato inmutable**
entre la etapa Build y la etapa Deploy:

```
Build                           Deploy
  │                               │
  ├── terraform plan              │
  │   └── tfplan.bin ──────────► Apply
  │       tfplan.json             │   terraform apply tfplan.bin
  │       tfplan.txt              │   (sin re-planificar)
  │                               │
  └── plan_output (ZIP/KMS/S3) ──►│
```

Si el pipeline re-planificara en Deploy, el estado de la infraestructura podría haber cambiado
entre la aprobación y el apply, resultando en un plan diferente al que se autorizó. Con el plan
inmutable, esto es imposible.

### Acciones paralelas con `run_order`

CodePipeline ejecuta las acciones de una misma etapa según su `run_order`:

| run_order | Acciones | Qué esperan |
|-----------|----------|-------------|
| 1 | ValidateAndLint, SecurityScan | Nada (arrancan juntas) |
| 2 | Plan | Que ambas del runOrder=1 hayan pasado |
| 3 | InspectPlan | Que Plan haya generado el artefacto |

Las acciones con el mismo `run_order` se ejecutan **en paralelo**. Las del siguiente
`run_order` solo arrancan cuando **todas** las anteriores han tenido éxito.

### Lambda como compuerta programática

La acción `Invoke` de CodePipeline llama a la Lambda con un evento JSON que contiene:

```json
{
  "CodePipeline.job": {
    "id": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "data": {
      "artifactCredentials": {
        "accessKeyId": "...",
        "secretAccessKey": "...",
        "sessionToken": "..."
      },
      "inputArtifacts": [
        {
          "name": "plan_output",
          "location": {
            "s3Location": { "bucketName": "...", "objectKey": "..." }
          }
        }
      ]
    }
  }
}
```

La Lambda **debe** llamar a `put_job_success_result` o `put_job_failure_result` antes de que
expire su timeout (60 s). Si no llama a ninguno, CodePipeline esperará hasta que el job expire
y marcará la acción como fallida.

Las `outputVariables` devueltas en el éxito aparecen en la consola de CodePipeline, dando
contexto al aprobador:

```
plan_creates:  2
plan_updates:  1
plan_deletes:  0
plan_replaces: 0
plan_destroys: 0
plan_total:    3
```

### Patrón Collect-and-Fail en SecurityScan

El buildspec ejecuta Checkov en **dos pasadas** para resolver una limitación de la
herramienta: `--output-file-path` hace que Checkov salga con código 0 en algunas
versiones, impidiendo detectar fallos por exit code.

| Pasada | Flags | Propósito |
|--------|-------|-----------|
| 1 | `--output junitxml --output-file-path . --soft-fail` | Escribe `results_junitxml.xml` siempre, sin fallar el build |
| 2 | `--output cli` (sin `--soft-fail`) | Evalúa hallazgos con el exit code correcto; falla el build si los hay |

Así CodeBuild siempre puede subir el informe JUnit a Reports (pasada 1), y el build
falla correctamente si hay hallazgos bloqueantes (pasada 2).

### `-detailed-exitcode` en `terraform plan`

Sin este flag, `terraform plan` siempre sale con código 0 (éxito), incluso cuando hay cambios
pendientes. Con él:

| Código | Significado | Acción en el buildspec |
|--------|-------------|------------------------|
| 0 | Sin cambios | Éxito (el pipeline continúa) |
| 1 | Error en el plan | Fallo real → el buildspec falla |
| 2 | Hay cambios | Éxito esperado → el buildspec continúa |

### `PrimarySource` en acciones con múltiples artefactos

La acción Apply recibe dos artefactos:
- `source_output` → código Terraform (necesario para `terraform init`)
- `plan_output` → contiene `tfplan.bin`

CodeBuild extrae `PrimarySource` en el directorio de trabajo raíz. El artefacto secundario
se extrae en una ruta absoluta que CodeBuild expone en la variable de entorno
`CODEBUILD_SRC_DIR_<nombre>`. Por eso el buildspec referencia el plan como
`${CODEBUILD_SRC_DIR_plan_output}/target/tfplan.bin`.

### Cifrado KMS de artefactos

Todos los artefactos del pipeline (source ZIP, plan ZIP) se cifran con una CMK gestionada.
Cada servicio (CodePipeline, CodeBuild, Lambda) recibe `kms:Decrypt` en su política IAM
para poder leer los artefactos. La política de la clave solo permite acceso a la cuenta raíz;
la autorización granular se delega en IAM.

## Estructura

```
lab45/
├── aws/                         Infraestructura del pipeline
│   ├── providers.tf             Provider AWS + archive, backend S3
│   ├── variables.tf             Variables del módulo
│   ├── main.tf                  KMS, S3 artifacts, CodeCommit, EventBridge, Log Groups
│   ├── codebuild.tf             5 proyectos CodeBuild (validate, security_scan, plan, apply, smoketest)
│   ├── pipeline.tf              SNS, CodePipeline (4 etapas)
│   ├── lambda.tf                Lambda plan inspector + archive_file
│   ├── iam.tf                   4 roles IAM (pipeline, codebuild, lambda, events)
│   ├── outputs.tf               URLs y ARNs de los recursos clave
│   ├── aws.s3.tfbackend         Configuración parcial del backend S3
│   └── lambda/
│       └── plan_inspector.py    Handler Python 3.12 de la Lambda inspectora
└── repo/                        Contenido del repositorio CodeCommit
    ├── .tflint.hcl              Configuración de TFLint (plugin AWS)
    ├── buildspecs/
    │   ├── validate.yml         fmt-check + validate + tflint
    │   ├── security_scan.yml    Checkov con patrón Collect-and-Fail
    │   ├── plan.yml             terraform plan → tfplan.bin/json/txt
    │   ├── apply.yml            terraform apply tfplan.bin (sin re-planificar)
    │   ├── smoketest.yml        Verificación API: S3 + SSM + CloudWatch
    │   └── policy_check.yml     Evaluación de políticas OPA (entregado, ver Reto 3)
    ├── policies/                Políticas Rego para OPA (entregadas, ver Reto 3)
    │   ├── kms.rego             Rotación obligatoria de claves KMS
    │   └── ssm.rego             Parámetros SSM deben ser SecureString
    └── target/                  Recursos que el pipeline despliega
        ├── main.tf              S3 bucket + SSM parameter + CW Log Group
        ├── variables.tf
        └── outputs.tf           bucket_name, ssm_parameter_name, log_group_name
```

## Paso 1 — Desplegar la infraestructura del pipeline

```bash
cd labs/lab45/aws
```

Inicializa y despliega:

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

terraform init \
  -backend-config=aws.s3.tfbackend \
  -backend-config="bucket=terraform-state-labs-${ACCOUNT_ID}"

terraform apply \
  -var="approval_email=tu@email.com"
```

Verifica los outputs:

```bash
terraform output
```

Deberías ver:
- `pipeline_url` — enlace directo a la consola de CodePipeline
- `repository_clone_url_https` — URL para clonar el repositorio
- `artifact_bucket` — bucket donde se almacenan los artefactos y el estado del target
- `approval_topic_arn` — ARN del topic SNS de aprobación
- `plan_inspector_function_name` — nombre de la Lambda inspectora

> **Confirma la suscripción SNS**: busca en tu correo el mensaje de confirmación de
> AWS Notifications y haz clic en "Confirm subscription". Sin este paso, no recibirás
> las notificaciones de aprobación.

> **Ejecución fallida inicial esperada**: en cuanto se crea la canalización, CodePipeline
> la activa automáticamente. Como el repositorio CodeCommit está vacío en este momento,
> la ejecución falla en la etapa Source con el error "No changes". Este es un comportamiento
> normal e inherente a CodePipeline: no es evitable ni configurable. La canalización
> funcionará correctamente en el siguiente paso, cuando subas el código al repositorio.

## Paso 2 — Subir el código al repositorio CodeCommit

Configura las credenciales Git para CodeCommit usando la helper de AWS CLI:

```bash
git config --global credential.helper '!aws codecommit credential-helper $@'
git config --global credential.UseHttpPath true
```

Desde el directorio `labs/lab45/aws/`, obtén la URL y clona el repositorio en `/tmp`:

```bash
REPO_URL=$(terraform output -raw repository_clone_url_https)
REPO_SRC=$(cd .. && pwd)/repo

git clone "$REPO_URL" /tmp/lab45-repo
cd /tmp/lab45-repo
git checkout -b main
```

Copia el contenido de `repo/` al repositorio clonado y haz el primer push:

```bash
cp -r "$REPO_SRC/." /tmp/lab45-repo/

git add .
git commit -m "feat: initial terraform pipeline setup"
git push -u origin main
```

El push dispara EventBridge, que inicia automáticamente el pipeline. Navega a la URL del output
`pipeline_url` para seguir el progreso en tiempo real.

## Paso 3 — Observar la etapa Build

Accede a la consola de CodePipeline y observa la etapa Build:

1. **ValidateAndLint** y **SecurityScan** arrancan en paralelo (runOrder=1)
2. Una vez que ambas pasan, **Plan** arranca (runOrder=2) y genera `tfplan.bin`
3. Tras Plan, **InspectPlan** arranca (runOrder=3) y llama a la Lambda

Puedes seguir los logs de cada acción en tiempo real desde la CLI:

```bash
# runOrder=1 — acciones paralelas
aws logs tail /aws/codebuild/lab45-validate      --follow
aws logs tail /aws/codebuild/lab45-security-scan --follow

# runOrder=2
aws logs tail /aws/codebuild/lab45-plan --follow

# runOrder=3 — Lambda invocada por la acción InspectPlan
aws logs tail /aws/lambda/lab45-plan-inspector --follow
```

Tras completar el **Reto 3**, la acción PolicyCheck se incorpora al stage Build en
`run_order = 3` e InspectPlan se desplaza a `run_order = 4`. Los logs se consultan con:

```bash
# runOrder=3 — PolicyCheck (tras Reto 3)
aws logs tail /aws/codebuild/lab45-policy-check --follow

# runOrder=4 — Lambda InspectPlan (desplazada del runOrder=3 al 4 en Reto 3)
aws logs tail /aws/lambda/lab45-plan-inspector --follow
```

Una vez que SecurityScan termina, CodeBuild publica el informe JUnit de Checkov en
**CodeBuild Reports**. Para consultarlo desde la CLI:

```bash
# Obtener el ARN del último informe del report group
REPORT_ARN=$(aws codebuild list-reports-for-report-group \
  --report-group-arn "arn:aws:codebuild:${REGION}:${ACCOUNT_ID}:report-group/lab45-security-scan-checkov_results" \
  --sort-order DESCENDING \
  --query 'reports[0]' \
  --output text)

# Ver el resumen del informe (total, passed, failed, skipped)
aws codebuild batch-get-reports \
  --report-arns "$REPORT_ARN" \
  --query 'reports[0].{Status:status,Total:testSummary.total,Passed:testSummary.statusCounts.SUCCEEDED,Failed:testSummary.statusCounts.FAILED,Skipped:testSummary.statusCounts.SKIPPED}'

# Ver los checks que han fallado
aws codebuild describe-test-cases \
  --report-arn "$REPORT_ARN" \
  --filter status=FAILED \
  --query 'testCases[].{Check:name,Message:message}'
```

Cuando la acción **Plan** termina, CodePipeline empaqueta `tfplan.bin`, `tfplan.json` y
`tfplan.txt` en un ZIP cifrado con KMS y lo almacena en S3 como artefacto `plan_output`.
Este artefacto es el que la acción **InspectPlan** (Lambda) analiza a continuación y el que
la etapa **Deploy** usará para ejecutar `terraform apply tfplan.bin` sin re-planificar.

Adicionalmente, el buildspec publica `tfplan.txt` en una ruta predecible del mismo bucket
para que el aprobador pueda descargarlo desde el enlace de la notificación SNS:

```bash
BUCKET=$(terraform output -raw artifact_bucket)

# tfplan.txt en formato legible — ruta predecible publicada por el buildspec
aws s3 cp "s3://${BUCKET}/plans/latest/tfplan.txt" /tmp/tfplan.txt && cat /tmp/tfplan.txt
```

Para localizar y descargar el artefacto ZIP completo (`plan_output`) que gestiona CodePipeline:

```bash
BUCKET=$(terraform output -raw artifact_bucket)

# Obtener el ID de la última ejecución del pipeline
EXEC_ID=$(aws codepipeline list-pipeline-executions \
  --pipeline-name "lab45-pipeline" \
  --query 'pipelineExecutionSummaries[0].pipelineExecutionId' \
  --output text)

# Localizar la clave S3 del artefacto plan_output de esa ejecución
# --filter solo acepta pipelineExecutionId; el filtro por stage/action va en --query
ARTIFACT_KEY=$(aws codepipeline list-action-executions \
  --pipeline-name "lab45-pipeline" \
  --filter pipelineExecutionId="$EXEC_ID" \
  --query "actionExecutionDetails[?stageName=='Build' && actionName=='Plan'].output.outputArtifacts[0].s3location.key | [0]" \
  --output text)

# Descargar el ZIP (cifrado con KMS — se descifra automáticamente con las credenciales activas)
aws s3 cp "s3://${BUCKET}/${ARTIFACT_KEY}" /tmp/plan_output.zip

# Extraer y revisar el contenido
unzip -o /tmp/plan_output.zip -d /tmp/plan_output/
cat /tmp/plan_output/target/tfplan.txt
```

Cuando InspectPlan completa con éxito, las `outputVariables` aparecen en la consola de
CodePipeline bajo la acción InspectPlan. Verás algo como:

```
plan_creates:  9
plan_updates:  0
plan_deletes:  0
plan_replaces: 0
plan_destroys: 0
plan_total:    9
```

## Paso 4 — Revisar el plan y aprobar el despliegue

Cuando la etapa Build completa, el pipeline pausa en la etapa **Approval** y envía un correo
a la dirección configurada. El correo incluye un enlace **"Review"** que abre directamente
`tfplan.txt` en la consola de S3: es el plan de Terraform en formato legible, el mismo
que el aprobador debe revisar antes de dar luz verde. Este enlace es la `ExternalEntityLink`
configurada en la acción de aprobación de CodePipeline.

**Antes de aprobar**, descarga y revisa `tfplan.txt` del bucket de artefactos.
Ejecuta desde `labs/lab45/aws/`:

```bash
cd $REPO_SRC/../aws

BUCKET=$(terraform output -raw artifact_bucket)

aws s3 cp "s3://${BUCKET}/plans/latest/tfplan.txt" /tmp/tfplan.txt
cat /tmp/tfplan.txt
```

Una vez revisado el plan, aprueba el despliegue desde la consola de CodePipeline o con la CLI:

```bash
PIPELINE="lab45-pipeline"
TOKEN=$(aws codepipeline get-pipeline-state \
  --name "$PIPELINE" \
  --query 'stageStates[?stageName==`Approval`] | [0].actionStates[0].latestExecution.token' \
  --output text)

aws codepipeline put-approval-result \
  --pipeline-name "$PIPELINE" \
  --stage-name "Approval" \
  --action-name "ManualApproval" \
  --result "summary=Plan revisado y aprobado,status=Approved" \
  --token "$TOKEN"
```

## Paso 5 — Observar la etapa Deploy y los smoke tests

Tras la aprobación, la etapa Deploy ejecuta dos acciones en secuencia:

1. **Apply**: `terraform apply tfplan.bin` con el plan inmutable
2. **SmokeTest**: verifica el estado real de los recursos via API

Para seguir los logs de Apply y SmokeTest en tiempo real desde la consola de CodeBuild,
navega al proyecto `lab45-apply` o `lab45-smoketest` respectivamente.

Desde la CLI, verifica los logs de CloudWatch:

```bash
aws logs tail /aws/codebuild/lab45-apply --follow
aws logs tail /aws/codebuild/lab45-smoketest --follow
```

Los smoke tests verifican:

```
[S3] 1a. El bucket existe                       PASS
[S3] 1b. Versionado habilitado                  PASS
[S3] 1c. Cifrado SSE habilitado                 PASS
[S3] 1d. Acceso público bloqueado               PASS
[SSM] 2a. El parámetro existe                   PASS
[CWL] 3a. El log group existe                   PASS
[CWL] 3b. Periodo de retención correcto         PASS
```

## Verificación final

Comprueba que todos los recursos del target han sido desplegados correctamente:

Ejecuta desde `labs/lab45/aws/`:

```bash
cd $REPO_SRC/../aws

BUCKET=$(terraform output -raw artifact_bucket)

# El estado del target está en el mismo bucket de artefactos
aws s3 ls s3://${BUCKET}/lab45/pipeline/
```

Obtén los nombres reales de los recursos del target desde el estado Terraform:

```bash
cd /tmp/lab45-repo/target
terraform init \
  -backend-config="bucket=${BUCKET}" \
  -backend-config="key=lab45/pipeline/terraform.tfstate" \
  -backend-config="region=${AWS_DEFAULT_REGION:-us-east-1}" \
  -reconfigure

OUTPUTS=$(terraform output -json)
TARGET_BUCKET=$(echo "$OUTPUTS" | python3 -c "import sys,json; print(json.load(sys.stdin)['bucket_name']['value'])")
SSM_PARAM=$(echo "$OUTPUTS"    | python3 -c "import sys,json; print(json.load(sys.stdin)['ssm_parameter_name']['value'])")
LOG_GROUP=$(echo "$OUTPUTS"    | python3 -c "import sys,json; print(json.load(sys.stdin)['log_group_name']['value'])")
cd -
```

Verifica el bucket target:

```bash
aws s3api get-bucket-versioning --bucket "$TARGET_BUCKET"
# Esperado: {"Status": "Enabled"}

aws s3api get-bucket-encryption --bucket "$TARGET_BUCKET" \
  --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault'
# Esperado: {"SSEAlgorithm": "aws:kms", ...}
```

Verifica el parámetro SSM:

```bash
aws ssm get-parameter --name "$SSM_PARAM" --with-decryption \
  --query 'Parameter.Value' --output text
# Esperado: dev
```

Verifica el log group:

```bash
aws logs describe-log-groups --log-group-name-prefix "$LOG_GROUP" \
  --query "logGroups[?logGroupName=='${LOG_GROUP}'].{name:logGroupName,retention:retentionInDays}"
# Esperado: [{"name": "/lab45/<sufijo>/app", "retention": 365}]
```

## Retos

### Reto 1 — Activar la compuerta de destrucciones

Actualmente `max_destroys_threshold = -1` (la Lambda solo inspecciona y reporta, nunca bloquea).

Modifica el pipeline para que bloquee automáticamente si el plan incluye **cualquier destrucción**:

1. Actualiza la variable en `terraform.tfvars` o pásala en la CLI
2. Aplica el cambio en la infraestructura del pipeline
3. Introduce un cambio en el target que fuerce la destrucción de un recurso (por ejemplo,
   cambia el nombre del bucket S3)
4. Haz push del cambio al repositorio y observa cómo InspectPlan bloquea el pipeline
5. Verifica en CloudWatch Logs el mensaje de la Lambda explicando el bloqueo
6. ¿Qué mensaje aparece en la consola de CodePipeline? ¿Cómo recuperas el pipeline?

### Reto 2 — Notificaciones de estado del pipeline con EventBridge

El pipeline actualmente envía una notificación manual de aprobación via SNS.
Configura notificaciones automáticas para los siguientes eventos:

1. Crea un topic SNS adicional `lab45-pipeline-alerts`
2. Crea una regla EventBridge que capture el inicio y la finalización exitosa de la
   **ejecución completa del pipeline** (eventos a nivel de pipeline, no de etapa)
3. Crea una segunda regla EventBridge que capture los fallos de cualquier **etapa**
   del pipeline
4. Ambas reglas deben enviar al mismo topic SNS con mensajes legibles que incluyan
   el nombre del pipeline, el estado y el ID de ejecución
5. Prueba provocando un fallo (introduce un error de sintaxis en el código Terraform del repo)
6. Verifica que recibes el correo de alerta poco después de que la etapa falle

**Pistas:**
- CodePipeline emite dos tipos de eventos distintos:
  - `CodePipeline Pipeline Execution State Change` — cambios de estado de la ejecución
    completa (STARTED, SUCCEEDED, FAILED, CANCELED, SUPERSEDED)
  - `CodePipeline Stage Execution State Change` — cambios de estado por etapa
- El campo `detail.state` contiene el estado en ambos tipos de evento
- Necesitarás dos reglas EventBridge separadas porque los filtros de estado son distintos
  en cada una

### Reto 3 — Validación de políticas organizativas con OPA

Actualmente el pipeline detecta problemas de seguridad con Checkov, pero Checkov evalúa
reglas genéricas de la comunidad. Las organizaciones tienen políticas propias que Checkov
no puede expresar: regiones permitidas, rotación de claves obligatoria, tipos de instancia
prohibidos, convenciones de nombrado, etc.

El repositorio ya incluye el directorio `repo/policies/` con las políticas Rego necesarias.
Añade una acción **PolicyCheck** con OPA que evalúe el plan de Terraform antes del despliegue.
La etapa Build debe quedar así:

```
  Etapa 2: Build

  runOrder=1 (paralelas):
  ┌─────────────────┐  ┌────────────────────┐
  │ ValidateAndLint │  │   SecurityScan     │
  │ fmt + validate  │  │   Checkov + JUnit  │
  │ + TFLint        │  │                    │
  └─────────────────┘  └────────────────────┘

  runOrder=2:
  ┌────────────────────────────────────────┐
  │  Plan                                  │
  │  tfplan.bin + tfplan.json + tfplan.txt │
  └────────────────────────────────────────┘

  runOrder=3:                               ← NUEVO
  ┌────────────────────────────────────────┐
  │  PolicyCheck                           │
  │  OPA evalúa tfplan.json                │
  │  Bloquea si viola políticas Rego       │
  └────────────────────────────────────────┘

  runOrder=4:                               ← desplazado
  ┌────────────────────────────────────────┐
  │  InspectPlan (Lambda)                  │
  │  Cuenta create/update/delete/replace   │
  │  Bloquea si destroys > max_threshold   │
  └────────────────────────────────────────┘
```

1. Crea el proyecto CodeBuild `lab45-policy-check` con el buildspec `buildspecs/policy_check.yml`
2. Añade la acción PolicyCheck al stage Build con `run_order = 3` (después de Plan, para tener
   acceso al artefacto `plan_output` con el `tfplan.json`). Desplaza InspectPlan de
   `run_order = 3` a `run_order = 4` para evitar conflictos
3. Verifica que PolicyCheck evalúa el plan y bloquea el pipeline si hay violaciones
4. Introduce una violación deliberada (`enable_key_rotation = false` en `target/main.tf`) y
   observa cómo PolicyCheck bloquea el pipeline sin llegar al Apply

**Pistas:**
- OPA evalúa políticas Rego con: `opa eval --data policies/ --input tfplan.json 'data.terraform.deny'`
- El input de las políticas es `tfplan.json`, generado por el buildspec `plan.yml` y publicado
  en el artefacto `plan_output`
- La acción PolicyCheck necesita `plan_output` como artefacto de entrada y `source_output`
  como `PrimarySource` (para que CodeBuild encuentre el buildspec y el directorio `policies/`)
- Las políticas deben evaluar atributos explícitos del plan (`enable_key_rotation`, `region`…),
  no etiquetas inyectadas por `default_tags`, que Terraform no siempre incluye en `change.after`

## Soluciones

<details>
<summary><strong>Solución al Reto 1 — Activar la Compuerta de destrucciones</strong></summary>

### Solución al Reto 1 — Activar la Compuerta de destrucciones

**Cómo funciona el mecanismo de bloqueo:**

La Lambda inspectora recibe `tfplan.json` como artefacto de entrada, lo parsea y cuenta
cuántos recursos tienen la acción `delete` o `replace` (un replace equivale a destruir el
recurso antiguo y crear uno nuevo, por lo que también cuenta como destrucción). El resultado
se compara con la variable de entorno `MAX_DESTROYS`, que se inyecta en la Lambda desde la
variable Terraform `max_destroys_threshold`:

| Valor | Comportamiento |
|-------|----------------|
| `-1` | Solo inspecciona y publica `outputVariables`. Nunca bloquea. Útil para observar sin riesgo. |
| `0` | Bloquea si hay **cualquier** destrucción (delete o replace). Máxima protección. |
| `N > 0` | Permite hasta N destrucciones. Útil cuando hay refactorizaciones planificadas. |

La Lambda no falla el build directamente: llama a `codepipeline:PutJobFailureResult` para
marcar la acción de CodePipeline como fallida con un mensaje de error descriptivo. Esto
detiene el pipeline antes de que llegue a la aprobación manual, evitando que el aprobador
autorice cambios sin ser consciente del alcance destructivo.

**Pieza 1 — Activar el umbral:**

El valor por defecto es `-1` (solo informa, nunca bloquea). Para activar la protección,
aplica la infraestructura del pipeline con `max_destroys_threshold=0`. Terraform actualizará
la variable de entorno `MAX_DESTROYS` de la Lambda sin necesidad de redeployarla:

```bash
cd $REPO_SRC$/../aws

terraform apply \
  -var="approval_email=tu@email.com" \
  -var="max_destroys_threshold=0"
```

**Pieza 2 — Forzar una destrucción en el target:**

La forma más directa es comentar uno de los recursos en [repo/target/main.tf](repo/target/main.tf).
Terraform interpretará su ausencia como una instrucción de destruirlo. El log group de
CloudWatch es el candidato ideal: no tiene dependencias con otros recursos del módulo,
por lo que comentarlo produce exactamente una destrucción limpia.

Comenta el recurso en [repo/target/main.tf](repo/target/main.tf) y los dos outputs que
lo referencian en [repo/target/outputs.tf](repo/target/outputs.tf) (si no, `terraform plan`
fallaría con un error de referencia antes de llegar a la Lambda):

```hcl
# target/main.tf
# resource "aws_cloudwatch_log_group" "app" {
#   name              = "/${var.project}/${random_pet.suffix.id}/app"
#   retention_in_days = var.log_retention_days
#   kms_key_id        = aws_kms_key.target.arn
# }
```

```hcl
# target/outputs.tf
# output "log_group_name" {
#   description = "Nombre del grupo de logs de CloudWatch."
#   value       = aws_cloudwatch_log_group.app.name
# }
#
# output "log_retention_days" {
#   description = "Periodo de retencion configurado en el log group."
#   value       = aws_cloudwatch_log_group.app.retention_in_days
# }
```

Y la variable que solo usa ese recurso en [repo/target/variables.tf](repo/target/variables.tf)
(TFLint falla el build si detecta variables declaradas pero no referenciadas):

```hcl
# target/variables.tf
# variable "log_retention_days" {
#   type        = number
#   description = "Dias de retencion del grupo de logs de CloudWatch."
#   default     = 365
#
#   validation {
#     condition     = contains([1, 3, 5, 7, 14, 30, 60, 90, 120, 150, 180, 365], var.log_retention_days)
#     error_message = "El valor debe ser uno de los periodos validos de CloudWatch Logs."
#   }
# }
```

Haz commit y push al repositorio CodeCommit. El plan generará:

```
-  aws_cloudwatch_log_group.app (destroy)
```

Esto genera `plan_destroys = 1`, que supera `max_destroys_threshold = 0`, y la Lambda
bloqueará el pipeline.

Para recuperar el estado después de observar el bloqueo, descomenta el recurso y haz push.

**Pieza 3 — Observar el bloqueo:**

Sigue los logs de la Lambda en tiempo real para ver el razonamiento del bloqueo:

```bash
aws logs tail /aws/lambda/lab45-plan-inspector --follow
```

Verás un mensaje similar a:

```
Plan bloqueado: El plan destruye 1 recurso(s), pero el umbral máximo es 0.
Revisa el plan y apruébalo manualmente si es intencionado.
```

En la consola de CodePipeline, la acción InspectPlan aparecerá como **Failed**. El mensaje
de error es visible directamente en la consola sin necesidad de entrar en los logs, lo que
facilita la revisión por parte del equipo.

**Pieza 4 — Recuperar el pipeline:**

Tienes dos opciones según si la destrucción era intencionada o no:

a) Si fue un error, revierte el cambio en el repo y haz push. El pipeline arrancará de nuevo
sin destrucciones y la Lambda lo dejará pasar:

```bash
git revert HEAD
git push origin main
```

b) Si la destrucción es intencionada (por ejemplo, un renombrado planificado), sube el umbral
temporalmente para permitirla, aplica la infraestructura del pipeline y vuelve a disparar la
ejecución manualmente:

```bash
cd $REPO_SRC/../aws

terraform apply \
  -var="approval_email=tu@email.com" \
  -var="max_destroys_threshold=1"

aws codepipeline start-pipeline-execution --name lab45-pipeline
```

Recuerda volver a bajar el umbral a `0` una vez que el cambio haya sido desplegado, para
restaurar la protección.

</details>

---

<details>
<summary><strong>Solución al Reto 2 — Notificaciones de estado del pipeline con EventBridge</strong></summary>

### Solución al Reto 2 — Notificaciones de estado del pipeline con EventBridge

**Por qué EventBridge y no CloudWatch Alarms:**

CodePipeline publica eventos de cambio de estado en EventBridge de forma nativa: cada vez
que una ejecución o una etapa cambia de estado (STARTED, SUCCEEDED, FAILED, CANCELED),
EventBridge recibe un evento con todos los detalles. Esto es más preciso y menos costoso
que sondear la API o configurar alarmas de CloudWatch, y permite filtrar por pipeline
concreto, por etapa y por estado con un patrón JSON declarativo.

La arquitectura de la solución es:
```
CodePipeline → EventBridge (regla con filtro) → SNS topic → email
```

El `input_transformer` permite reescribir el payload del evento antes de enviarlo al
topic SNS, extrayendo solo los campos relevantes y dando formato al mensaje que se
recibirá por correo.

Las piezas 1–4 van en un nuevo fichero [aws/eventbridge.tf](aws/eventbridge.tf) dentro de
la infraestructura del pipeline.

**Pieza 1 — Topic SNS de alertas** → [aws/eventbridge.tf](aws/eventbridge.tf):

Crea un topic SNS independiente del topic de aprobaciones ya existente. Reutilizar el topic
de aprobaciones mezclaría dos tipos de notificaciones con semánticas distintas: una requiere
acción humana, la otra es solo informativa.

```hcl
resource "aws_sns_topic" "pipeline_alerts" {
  name = "${var.project}-pipeline-alerts"

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_sns_topic_subscription" "pipeline_alerts_email" {
  topic_arn = aws_sns_topic.pipeline_alerts.arn
  protocol  = "email"
  endpoint  = var.approval_email
}
```

**Pieza 2 — Regla EventBridge para inicio y finalización exitosa** → [aws/eventbridge.tf](aws/eventbridge.tf):

Esta regla opera a nivel de **ejecución completa del pipeline** (`Pipeline Execution State
Change`), no a nivel de etapa. Filtra únicamente los estados `STARTED` y `SUCCEEDED` para
notificar cuándo arranca una ejecución y cuándo termina con éxito:

```hcl
resource "aws_cloudwatch_event_rule" "pipeline_execution_notify" {
  name        = "${var.project}-execution-notify"
  description = "Notifica el inicio y la finalización exitosa del pipeline."

  event_pattern = jsonencode({
    source      = ["aws.codepipeline"]
    detail-type = ["CodePipeline Pipeline Execution State Change"]
    resources   = [aws_codepipeline.main.arn]
    detail = {
      state = ["STARTED", "SUCCEEDED"]
    }
  })
}
```

**Pieza 3 — Regla EventBridge para fallos de etapa** → [aws/eventbridge.tf](aws/eventbridge.tf):

Esta segunda regla opera a nivel de **etapa** (`Stage Execution State Change`). El filtro
`resources = [arn]` limita la regla a este pipeline concreto, evitando falsos positivos si
hay otros pipelines en la cuenta:

```hcl
resource "aws_cloudwatch_event_rule" "pipeline_stage_failed" {
  name        = "${var.project}-stage-failed"
  description = "Notifica cuando una etapa del pipeline falla."

  event_pattern = jsonencode({
    source      = ["aws.codepipeline"]
    detail-type = ["CodePipeline Stage Execution State Change"]
    resources   = [aws_codepipeline.main.arn]
    detail = {
      state = ["FAILED"]
    }
  })
}
```

**Pieza 4 — Targets EventBridge → SNS** → [aws/eventbridge.tf](aws/eventbridge.tf):

Cada regla necesita su propio target. El `input_transformer` extrae campos del evento con
`input_paths` (sintaxis JMESPath) y los interpola en `input_template`. Sin él, el mensaje
recibido sería el JSON completo del evento, difícil de leer en un correo. Los eventos de
ejecución de pipeline no tienen `stage`, por eso el mensaje de la primera regla omite ese
campo:

```hcl
resource "aws_cloudwatch_event_target" "pipeline_execution_notify_sns" {
  rule = aws_cloudwatch_event_rule.pipeline_execution_notify.name
  arn  = aws_sns_topic.pipeline_alerts.arn

  input_transformer {
    input_paths = {
      pipeline  = "$.detail.pipeline"
      state     = "$.detail.state"
      execution = "$.detail.execution-id"
    }
    input_template = "\"INFO: El pipeline <pipeline> ha cambiado de estado a <state>. Ejecucion: <execution>\""
  }
}

resource "aws_cloudwatch_event_target" "pipeline_stage_failed_sns" {
  rule = aws_cloudwatch_event_rule.pipeline_stage_failed.name
  arn  = aws_sns_topic.pipeline_alerts.arn

  input_transformer {
    input_paths = {
      pipeline  = "$.detail.pipeline"
      stage     = "$.detail.stage"
      state     = "$.detail.state"
      execution = "$.detail.execution-id"
    }
    input_template = "\"ALERTA: La etapa <stage> del pipeline <pipeline> ha fallado. Estado: <state>. Ejecucion: <execution>\""
  }
}
```

**Pieza 5 — Política del topic SNS** → [aws/eventbridge.tf](aws/eventbridge.tf):

Por defecto, un topic SNS solo acepta publicaciones del propietario de la cuenta. EventBridge
es un servicio AWS diferente y necesita permiso explícito para publicar en el topic. Sin esta
política, EventBridge intentará publicar el evento y recibirá un error de autorización, por
lo que el correo nunca llegaría aunque la regla dispare correctamente:

```hcl
resource "aws_sns_topic_policy" "pipeline_alerts" {
  arn = aws_sns_topic.pipeline_alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "AllowEventBridge"
      Effect    = "Allow"
      Principal = { Service = "events.amazonaws.com" }
      Action    = "sns:Publish"
      Resource  = aws_sns_topic.pipeline_alerts.arn
    }]
  })
}
```

**Aplicar la infraestructura:**

Una vez creadas las piezas 1–5 en [aws/eventbridge.tf](aws/eventbridge.tf), aplica los cambios:

```bash
cd labs/lab45/aws
terraform apply -var="approval_email=tu@email.com"
```

Confirma la suscripción al nuevo topic `lab45-pipeline-alerts` desde el correo que recibirás
de AWS (asunto "AWS Notification - Subscription Confirmation"). Sin confirmar, SNS descartará
los mensajes silenciosamente.

**Pieza 6 — Probar el fallo:**

La forma más rápida de provocar un fallo en la etapa Build es introducir un error de sintaxis
en el código Terraform del target. El buildspec de `validate.yml` ejecuta `terraform validate`
y fallará inmediatamente. Edita `target/main.tf`, elimina un `}` de cierre y haz push:

```bash
git add target/main.tf
git commit -m "test: error de sintaxis para probar notificaciones"
git push origin main
```

La etapa Build fallará en la acción ValidateAndLint. EventBridge detectará el cambio de
estado a `FAILED` y enviará el correo de alerta en cuestión de segundos. Recuerda revertir
el cambio una vez verificado:

```bash
git revert HEAD --no-edit
git push origin main
```

</details>

---

<details>
<summary><strong>Solución al Reto 3 — Validación de políticas organizativas con OPA</strong></summary>

### Solución al Reto 3 — Validación de políticas organizativas con OPA

**Por qué OPA sobre `tfplan.json` y no sobre el código fuente:**

Checkov analiza el código HCL estático: evalúa lo que está escrito, no lo que Terraform
calculará realmente al aplicar. OPA evaluando `tfplan.json` opera sobre el plan ya
calculado: conoce los valores concretos que tendrán los atributos tras el apply, incluyendo
los que provienen de data sources, variables interpoladas y referencias a otros recursos.
Esto permite políticas más precisas; por ejemplo, verificar que el valor efectivo de una
etiqueta no es una cadena vacía, o que la región de despliegue real está en la lista de
regiones permitidas por la organización.

La acción PolicyCheck se coloca en `run_order = 3` para que reciba `plan_output` (el
artefacto que contiene `tfplan.json` generado en `run_order = 2`). InspectPlan se desplaza
a `run_order = 4` para mantener el orden lógico: primero validación de políticas y luego
inspección de destrucciones.

**Pieza 1a — Rol IAM para el proyecto** → [aws/iam.tf](aws/iam.tf):

Cada proyecto CodeBuild tiene su propio rol con el mínimo de permisos necesarios. PolicyCheck
solo necesita leer el artefacto `plan_output` del bucket y escribir logs: no requiere acceso
al estado de Terraform ni permisos de infraestructura porque OPA trabaja únicamente sobre
el fichero `tfplan.json` que CodePipeline ya extrae en el workspace:

```hcl
resource "aws_iam_role" "codebuild_policy_check" {
  name        = "${var.project}-codebuild-policy-check"
  description = "Rol para el proyecto PolicyCheck (OPA)."

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "codebuild.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })

  tags = { Project = var.project, ManagedBy = "terraform" }
}

resource "aws_iam_role_policy" "codebuild_policy_check" {
  name = "${var.project}-codebuild-policy-check-policy"
  role = aws_iam_role.codebuild_policy_check.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(local.codebuild_pipeline_statements, [
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:${data.aws_caller_identity.current.account_id}:log-group:/aws/codebuild/${var.project}-policy-check*"
      }
    ])
  })
}
```

Además, añade el nuevo rol a los statements `CodeBuildActions` e `IamPassRole` de la política
del pipeline en [aws/iam.tf](aws/iam.tf), para que CodePipeline pueda arrancar el proyecto
y pasarle el rol:

```hcl
# En el Sid "CodeBuildActions", añade:
aws_codebuild_project.policy_check.arn,

# En el Sid "IamPassRole", añade:
aws_iam_role.codebuild_policy_check.arn,
```

**Pieza 1b — Proyecto CodeBuild y log group** → [aws/codebuild.tf](aws/codebuild.tf) y [aws/main.tf](aws/main.tf):

Añade el log group en [aws/main.tf](aws/main.tf) junto al resto de log groups de CodeBuild,
referenciando `var.log_retention_days` para mantener la consistencia con los demás proyectos:

```hcl
resource "aws_cloudwatch_log_group" "policy_check" {
  name              = "/aws/codebuild/${var.project}-policy-check"
  retention_in_days = var.log_retention_days

  tags = { Project = var.project, ManagedBy = "terraform" }
}
```

Añade el proyecto CodeBuild en [aws/codebuild.tf](aws/codebuild.tf) referenciando el log group
por nombre de recurso en lugar de una cadena literal, de la misma forma que el resto de proyectos:

```hcl
resource "aws_codebuild_project" "policy_check" {
  name          = "${var.project}-policy-check"
  description   = "Validacion de politicas organizativas con OPA sobre tfplan.json."
  service_role  = aws_iam_role.codebuild_policy_check.arn
  build_timeout = 10

  # type = "CODEPIPELINE" indica a CodeBuild que busque el buildspec en el artefacto
  # que CodePipeline designe como PrimarySource para esta acción. La ruta es relativa
  # a la raíz de ese artefacto. El PrimarySource se configura en la acción del pipeline
  # (Pieza 2), no aquí.
  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspecs/policy_check.yml"
  }

  artifacts { type = "CODEPIPELINE" }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    dynamic "environment_variable" {
      for_each = local.common_env
      content {
        name  = environment_variable.value.name
        value = environment_variable.value.value
        type  = environment_variable.value.type
      }
    }
  }

  logs_config {
    cloudwatch_logs {
      group_name = aws_cloudwatch_log_group.policy_check.name
    }
  }

  tags = { Project = var.project, ManagedBy = "terraform" }
}
```

**Pieza 2 — Acción en el pipeline:**

Añade la acción en [pipeline.tf](aws/pipeline.tf) dentro del stage Build con `run_order = 3`.

La acción necesita dos artefactos de entrada porque cada uno aporta algo distinto:
- `source_output` — snapshot del repositorio CodeCommit. Contiene `buildspecs/policy_check.yml`
  (que CodeBuild necesita para saber qué ejecutar) y el directorio `policies/` (con las reglas Rego).
- `plan_output` — artefacto generado por la acción Plan. Contiene `target/tfplan.json`.

Con `PrimarySource = "source_output"`, CodeBuild extrae el repositorio en la raíz del
workspace (haciendo accesibles `buildspecs/` y `policies/` con rutas relativas), mientras
que `plan_output` se extrae en el subdirectorio `plan_output/`. Sin `source_output` como
artefacto de entrada, CodeBuild intentaría leer el buildspec desde `plan_output`, que solo
contiene ficheros del plan y no tiene `buildspecs/policy_check.yml`.

Desplaza también InspectPlan de `run_order = 3` a `run_order = 4`:

```hcl
action {
  name             = "PolicyCheck"
  category         = "Build"
  owner            = "AWS"
  provider         = "CodeBuild"
  version          = "1"
  input_artifacts  = ["source_output", "plan_output"]
  run_order        = 3

  configuration = {
    ProjectName = aws_codebuild_project.policy_check.name

    # PrimarySource indica a CodeBuild en qué artefacto buscar el buildspec
    # (buildspecs/policy_check.yml) y qué extractar en la raíz del workspace.
    # Sin esta línea, CodeBuild usaría plan_output como fuente y no encontraría
    # el buildspec ni el directorio policies/.
    PrimarySource = "source_output"
  }
}
```

**Aplicar la infraestructura:**

Con las piezas 1a, 1b y 2 en su lugar, aplica los cambios para crear el proyecto CodeBuild
y actualizar la definición del pipeline:

```bash
cd $REPO_SRC/../aws
terraform apply -var="approval_email=tu@email.com"
```

**Pieza 3 — Disparar el pipeline:**

`buildspecs/policy_check.yml` y el directorio `policies/` con `kms.rego` y `ssm.rego` ya
están en CodeCommit: se subieron en el push inicial del Paso 2 junto con el resto del
repositorio. No es necesario crearlos ni volver a subirlos.

Para disparar el pipeline con la nueva acción PolicyCheck activa, basta con hacer cualquier
push a la rama `main`. Por ejemplo, un commit vacío:

```bash
cd /tmp/lab45-repo
git commit --allow-empty -m "ci: activar accion PolicyCheck"
git push origin main
```

CodePipeline detectará el push y arrancará el pipeline ya actualizado. `source_output`
capturará el snapshot del repositorio en ese momento, que ya contiene `buildspecs/` y
`policies/`. Como `source_output` es el `PrimarySource`, CodeBuild extrae el repositorio
en la raíz del workspace (haciendo accesibles `buildspecs/` y `policies/` con rutas
relativas), mientras que `plan_output` se expone en la ruta absoluta
`$CODEBUILD_SRC_DIR_plan_output`.

**Pieza 3a — `repo/buildspecs/policy_check.yml`:**

OPA evalúa la expresión `data.terraform.deny` sobre el fichero `tfplan.json`. El resultado
es el conjunto de mensajes de violación generados por todas las reglas Rego del directorio
`policies/`. La primera invocación muestra el detalle de las violaciones en los logs; la
segunda cuenta cuántas hay para decidir si fallar el build. Se hacen dos invocaciones porque
`--format raw` con `count()` devuelve solo el número sin los mensajes descriptivos:

```yaml
version: 0.2

phases:
  install:
    commands:
      - |
        curl -fsSLo /usr/local/bin/opa \
          "https://openpolicyagent.org/downloads/v${OPA_VERSION}/opa_linux_amd64_static"
        chmod +x /usr/local/bin/opa
        opa version

  build:
    commands:
      - echo "=== OPA policy evaluation ==="
      - |
        set -e
        # Con PrimarySource=source_output, CodeBuild extrae source_output en la raiz
        # del workspace (policies/ accesible con ruta relativa) y plan_output en la
        # ruta absoluta expuesta en CODEBUILD_SRC_DIR_plan_output.
        TFPLAN_JSON="${CODEBUILD_SRC_DIR_plan_output}/target/tfplan.json"

        if [ ! -f "$TFPLAN_JSON" ]; then
          echo "ERROR: tfplan.json no encontrado en $TFPLAN_JSON"
          exit 1
        fi

        # Primera pasada: muestra el detalle de todas las violaciones en los logs
        opa eval \
          --data policies/ \
          --input "${TFPLAN_JSON}" \
          --format pretty \
          'data.terraform.deny'

        # Segunda pasada: cuenta violaciones para decidir si fallar el build
        VIOLATIONS=$(opa eval \
          --data policies/ \
          --input "${TFPLAN_JSON}" \
          --format raw \
          'count(data.terraform.deny)')

        echo "Violaciones encontradas: $VIOLATIONS"

        if [ "$VIOLATIONS" -gt 0 ]; then
          echo "ERROR: el plan viola $VIOLATIONS politica(s) organizativa(s)."
          exit 1
        fi

  post_build:
    commands:
      - echo "Todas las politicas OPA pasaron correctamente."
```

**Pieza 3b — `repo/policies/kms.rego` y `repo/policies/ssm.rego`:**

Rego es el lenguaje declarativo de OPA. Cada regla `deny contains msg if { ... }` aporta
mensajes al conjunto de violaciones: si el cuerpo de la regla se evalúa a verdadero para
alguna combinación de variables, el mensaje `msg` se añade al conjunto. Si el conjunto
`deny` está vacío al finalizar la evaluación, no hay violaciones y el build pasa.

La política de KMS verifica que ninguna clave acabe en un estado sin rotación automática,
tanto en creaciones como en actualizaciones. El filtro `change.after != null` cubre las
acciones `create`, `update` y `replace`, excluyendo únicamente los `delete` (donde
`change.after` es `null`). Filtrar solo por `"create"` no detectaría cambios sobre
recursos ya existentes:

```rego
# policies/kms.rego
package terraform

deny contains msg if {
  some r in input.resource_changes
  r.type == "aws_kms_key"
  r.change.after != null
  not r.change.after.enable_key_rotation
  msg := sprintf("KMS: '%v' no tiene rotacion de clave habilitada", [r.address])
}
```

La política de SSM verifica que todos los parámetros creados o actualizados sean de tipo
`SecureString`. Es un control fiable porque `type` es un atributo explícito que Terraform
siempre incluye en `change.after`:

```rego
# policies/ssm.rego
package terraform

deny contains msg if {
  some r in input.resource_changes
  r.type == "aws_ssm_parameter"
  r.change.after != null
  r.change.after.type != "SecureString"
  msg := sprintf("SSM: '%v' debe ser de tipo SecureString", [r.address])
}
```

**Pieza 4 — Probar las violaciones:**

**Violación 1 — Rotación de clave KMS:**

Edita `aws_kms_key.target` en [repo/target/main.tf](repo/target/main.tf), cambia
`enable_key_rotation` a `false` y añade el skip de Checkov `CKV_AWS_7` para que la acción SecurityScan
no bloquee el pipeline antes de que llegue al PolicyCheck:

```hcl
resource "aws_kms_key" "target" {
  # checkov:skip=CKV_AWS_7: Lab - probando violacion de politica OPA
  ...
  enable_key_rotation     = false   # ← violación deliberada
}
```

Haz commit y push. La acción PolicyCheck fallará con:

```
KMS: 'aws_kms_key.target' no tiene rotacion de clave habilitada
Violaciones encontradas: 1
ERROR: el plan viola 1 politica(s) organizativa(s).
```

Para resolverla elimina el skip y restaura el valor original:

```hcl
resource "aws_kms_key" "target" {
  ...
  enable_key_rotation     = true
}
```

**Violación 2 — Parámetro SSM sin cifrar:**

Edita `aws_ssm_parameter.environment` en [repo/target/main.tf](repo/target/main.tf) y
cambia el tipo a `String`. El skip `CKV2_AWS_34` es necesario porque SecurityScan
(`run_order=1`) se ejecuta antes que PolicyCheck (`run_order=3`): sin él, SecurityScan
fallaría primero y el pipeline nunca llegaría a evaluar las políticas OPA:

```hcl
resource "aws_ssm_parameter" "environment" {
  # checkov:skip=CKV2_AWS_34: Lab - probando violacion de politica OPA
  ...
  type   = "String"   # ← violación deliberada
  key_id = null       # SecureString requiere key_id; String no lo admite
}
```

Haz commit y push. La acción PolicyCheck fallará con:

```
SSM: 'aws_ssm_parameter.environment' debe ser de tipo SecureString
Violaciones encontradas: 1
ERROR: el plan viola 1 politica(s) organizativa(s).
```

Para resolverla restaura los valores originales:

```hcl
resource "aws_ssm_parameter" "environment" {
  ...
  type   = "SecureString"
  key_id = aws_kms_key.target.arn
}
```

> **Nota sobre el formato:** al editar `main.tf` ejecuta `terraform fmt` antes del push.
> La acción Validate falla con `exit status 3` si el fichero no está correctamente
> formateado según el estilo canónico de Terraform.

</details>

## Limpieza

```bash
# 1. Destruir la infraestructura desplegada por el pipeline (target)
#    El estado del target está en el bucket de artefactos del pipeline,
#    no en el bucket general de estado del laboratorio.
cd $REPO_SRC/../aws
ARTIFACT_BUCKET=$(terraform output -raw artifact_bucket)

cd /tmp/lab45-repo/target

terraform init \
  -backend-config="bucket=${ARTIFACT_BUCKET}" \
  -backend-config="key=lab45/pipeline/terraform.tfstate" \
  -backend-config="region=${AWS_DEFAULT_REGION:-us-east-1}"

terraform destroy \
  -var="project=lab45" \
  -var="region=${AWS_DEFAULT_REGION:-us-east-1}"

# 2. Destruir la infraestructura del pipeline
cd $REPO_SRC/../aws
terraform destroy -var="approval_email=tu@email.com"

# Nota: si el bucket de artefactos tiene objetos, force_destroy = true
# garantiza que Terraform puede eliminarlo sin errores.
```

> Destruye siempre el target **antes** que el pipeline: el bucket de artefactos
> contiene el estado remoto del target, y si se elimina primero el pipeline
> Terraform pierde la referencia al estado.
>
> Si has completado los Retos, asegúrate de destruir también los recursos adicionales
> (topics SNS, reglas EventBridge) que hayas creado.

## Solución de problemas

### La Lambda InspectPlan falla con "artifact not found"

El ZIP del artefacto `plan_output` no contiene `tfplan.json`. Verifica que el buildspec
`plan.yml` genera correctamente el fichero:

```bash
aws logs tail /aws/codebuild/lab45-plan --follow
```

Busca el paso `terraform show -json`. Si falla, el artefacto ZIP se crea sin el fichero JSON.

### El pipeline no arranca tras el push

Verifica que la regla EventBridge está correctamente configurada:

```bash
aws events list-rules --name-prefix "lab45-on-push"
aws events list-targets-by-rule --rule "lab45-on-push-main"
```

También puedes comprobar si EventBridge está recibiendo el evento:

```bash
# Busca en CloudTrail el evento de CodeCommit
aws cloudtrail lookup-events \
  --lookup-attributes AttributeKey=EventName,AttributeValue=UpdateReference \
  --max-results 5
```

Si la regla existe y tiene el target correcto, pero el pipeline no arranca, verifica que
el rol de EventBridge (`lab45-events`) tiene el permiso `codepipeline:StartPipelineExecution`.

### Los smoke tests fallan en el paso de retención de logs

El log group del target usa `retention_in_days = var.log_retention_days`. Si el valor
de la variable no coincide con el que devuelve `terraform output log_retention_days`,
el test fallará. Verifica que el apply completó sin errores antes de investigar.

### La aprobación manual expira antes de revisar el plan

CodePipeline mantiene la aprobación pendiente durante **7 días** por defecto. Pasado ese
tiempo, la acción expira y el pipeline falla. Para reiniciar el pipeline desde la etapa
de aprobación no es posible: debes reiniciar la ejecución completa desde Source.

### `terraform apply` falla con "plan file was created by a different Terraform version"

El `tfplan.bin` se generó con la versión de Terraform definida en `TF_VERSION`. Si cambias
la versión entre el Plan y el Apply (modificando la variable y aplicando la infraestructura),
los binarios de los dos proyectos CodeBuild tendrán versiones distintas. Asegúrate de que
`TF_VERSION` no cambia entre ejecuciones del pipeline.

## Buenas prácticas

- **Nunca re-planifiques en Deploy**: el plan inmutable es la garantía de que lo aprobado
  es lo aplicado. Romperla invalida el propósito de la aprobación manual.

- **Usa `-detailed-exitcode` siempre**: sin él, `terraform plan` no distingue entre
  "sin cambios" y "hay cambios", devolviendo siempre 0. El buildspec trataría un plan
  vacío como éxito, aplicando nada en Deploy.

- **Almacena `tfplan.txt` para auditoría**: el fichero de texto del plan es legible por
  humanos y debe estar disponible para el aprobador. Considera subirlo a S3 con una
  política de retención larga (90+ días) para auditoría.

- **Establece umbrales conservadores en producción**: `max_destroys_threshold = 0` en
  producción obliga a revisar y aumentar el umbral explícitamente para cualquier cambio
  destructivo, actuando como una segunda capa de seguridad.

- **Versiona los buildspecs en el repositorio**: al tener los buildspecs en el mismo repo
  que el código Terraform, cada commit contiene tanto el código como el pipeline que lo
  procesa. Esto garantiza coherencia entre versiones.

- **Usa `PollForSourceChanges = false`**: delegar el trigger en EventBridge en lugar de
  que CodePipeline haga polling reduce la latencia de inicio y elimina el coste de las
  comprobaciones periódicas.

## Recursos

- [CodePipeline — Acciones de tipo Invoke Lambda](https://docs.aws.amazon.com/codepipeline/latest/userguide/actions-invoke-lambda-function.html)
- [CodePipeline — Artefactos de entrada y salida](https://docs.aws.amazon.com/codepipeline/latest/userguide/welcome-introducing-artifacts.html)
- [CodeBuild — PrimarySource en acciones con múltiples artefactos](https://docs.aws.amazon.com/codepipeline/latest/userguide/action-reference-CodeBuild.html)
- [Checkov — Documentación oficial](https://www.checkov.io/1.Welcome/Quick%20Start.html)
- [TFLint — Plugin AWS](https://github.com/terraform-linters/tflint-ruleset-aws)
- [terraform plan -detailed-exitcode](https://developer.hashicorp.com/terraform/cli/commands/plan#detailed-exitcode)
