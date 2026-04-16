# Terraform on AWS

Material práctico del curso **Terraform on AWS**. Cada laboratorio introduce conceptos progresivos de Infraestructura como Código (IaC) con Terraform, con soporte para despliegue en AWS real y en LocalStack como entorno local de pruebas.

## Requisitos Previos

- Terraform instalado
- AWS CLI configurado con un perfil `default` (AWS real) y un perfil `localstack`
- Docker y LocalStack CLI instalados
- Cuenta de AWS (para los laboratorios con nube real)

> Consulta el [lab01](lab01/README.md) para la guía completa de instalación y configuración del entorno.

## Estructura del Repositorio

```
labs/
├── lab00/  # Entorno de Desarrollo Remoto con VSCode en EC2
├── lab01/  # Primeros Pasos: Terraform, AWS CLI y LocalStack
├── lab02/  # Primer despliegue en AWS: bucket S3 con versionado y cifrado
├── lab03/  # Variables complejas, cidrsubnet() y bloques dynamic
├── lab04/  # for_each, data sources y lifecycle
├── lab05/  # templatefile(), file() y generación de configuraciones
├── lab06/  # Auditoría con data sources y reportes exportables
├── lab07/  # Backend remoto con S3, DynamoDB y state locking
├── lab07b/ # HCP Terraform como Backend Remoto
├── lab08/  # Refactorización declarativa: import, moved y removed
├── lab09/  # Gestión de entornos con workspaces
├── lab10/  # State splitting: capas de infraestructura independientes
├── lab11/  # Gestión de Drift y Disaster Recovery (3-2-1)
├── lab12/  # Gestión de Identidades y Acceso Seguro para EC2
├── lab13/  # Cifrado Transversal con KMS y Jerarquía de Llaves
├── lab14/  # Automatización de Secretos "Zero-Touch"
├── lab15/  # Blindaje del Pipeline DevSecOps
├── lab16/  # Construcción de una Red Multi-AZ Robusta y Dinámica
├── lab17/  # Optimización de Salida a Internet y "NAT Tax"
├── lab18/  # Seguridad y Control de Tráfico en VPC
├── lab19/  # Conectividad Punto a Punto con VPC Peering
├── lab20/  # Hub-and-Spoke con Transit Gateway y RAM
├── lab21/  # Zonas Hospedadas Privadas y Resolución DNS
├── lab22/  # Módulos reutilizables: S3 con estándares corporativos
├── lab23/  # Módulos con validación, precondiciones y postcondiciones
├── lab24/  # Composición de Módulos Públicos con Estándares Corporativos
├── lab25/  # Testing de infraestructura con terraform test
├── lab26/  # Gobernanza, Documentación y Publicación "Lean"
├── lab27/  # Cimientos de EC2: Despliegue Dinámico y Seguro
├── lab28/  # Escalabilidad y Alta Disponibilidad con Zero Downtime
├── lab29/  # Microservicios con ECS Fargate y Malla de Servicios
├── lab30/  # Procesamiento Asíncrono y Resiliencia de Eventos
├── lab31/  # API Serverless: Lambda, API Gateway v2 y Layers
├── lab32/  # FinOps y Rendimiento: Optimización de Cómputo
├── lab33/  # El Data Lake Blindado: S3 con Seguridad y Ciclo de Vida
├── lab34/  # Almacenamiento Híbrido: EBS de Alto Rendimiento y EFS Compartido
├── lab35/  # Base de Datos Relacional Crítica: RDS Multi-AZ y Replicación
├── lab36/  # Arquitectura Moderna NoSQL: DynamoDB con Caché y Eventos
├── lab37/  # Orquestación Imperativa con terraform_data
├── lab38/  # Ingeniería de Datos y Resiliencia con Lifecycle
├── lab39/  # Despliegue Global y Adopción de Infraestructura Existente
├── lab40/  # Refactorización y Optimización de Performance
├── lab41/  # Gobernanza y Control de Versiones en CodeCommit
├── lab42/  # Repositorio Privado de Módulos Terraform con CodeArtifact
├── lab43/  # Canalización CI de IaC con CodeBuild y ECR
├── lab44/  # Entrega Continua con CodeDeploy
├── lab45/  # Pipeline GitOps de Terraform con CodePipeline
├── lab46/  # Observabilidad Proactiva y Dashboards as Code
├── lab47/  # Centralización de Telemetría y Pipeline de Auditoría
├── lab48/  # Fundamentos FinOps: Tags, Budgets y Spot Instances
└── lab49/  # Compliance as Code y Remediación Automática
```

La mayoría de laboratorios contienen dos subdirectorios:

- `aws/` — configuración para despliegue en AWS real
- `localstack/` — configuración para despliegue local con LocalStack (cuando los servicios implicados están disponibles en Community)

## Laboratorios

| Lab | Título | Conceptos clave |
|-----|--------|-----------------|
| [lab00](lab00/README.md) | Entorno de Desarrollo Remoto con VSCode en EC2 | EC2 ARM64 (`t4g.large`), Amazon Linux 2023, code-server, plugin HashiCorp Terraform |
| [lab01](lab01/README.md) | Primeros Pasos: Terraform, AWS CLI y LocalStack | Terraform, AWS CLI, LocalStack, VSCode |
| [lab02](lab02/README.md) | Primer despliegue en AWS: bucket S3 con versionado y cifrado | `terraform init/plan/apply/destroy`, providers, outputs, `tfstate` |
| [lab03](lab03/README.md) | Infraestructura Parametrizada | Variables `object`, validaciones, `cidrsubnet()`, bloques `dynamic`, `terraform fmt` |
| [lab04](lab04/README.md) | Identidades y Ciclo de Vida | `for_each`, `each.key/value`, data sources (`aws_ami`, `aws_caller_identity`), `lifecycle` |
| [lab05](lab05/README.md) | Plantillas de Sistema | `templatefile()`, `file()`, directivas `%{if}` y `%{for}`, `merge()`, `local_file` |
| [lab06](lab06/README.md) | Auditoría y Conectividad | Data sources de solo lectura, `aws_vpc/subnets/instances`, `sensitive = true`, reportes exportables |
| [lab07](lab07/README.md) | Backend Remoto Profesional | `backend "s3"`, S3 Versioning, Public Access Block, DynamoDB state locking, `encrypt = true`, migración de estado |
| [lab07b](lab07b/README.md) | HCP Terraform como Backend Remoto | `cloud {}`, HCP Terraform, workspaces CLI-driven, ejecución remota, variables sensibles, historial de runs |
| [lab08](lab08/README.md) | Refactorización Declarativa | `import {}`, `-generate-config-out`, `moved {}`, `removed {}`, adopción de recursos existentes |
| [lab09](lab09/README.md) | Gestión de Entornos con Workspaces | `terraform workspace`, `terraform.workspace`, `lookup()`, `check {}`, `lifecycle { precondition }` |
| [lab10](lab10/README.md) | State Splitting: Capas de Infraestructura | `terraform_remote_state`, state splitting, blast radius, `output` como interfaz entre capas, backends S3 por capa |
| [lab11](lab11/README.md) | Gestión de Drift y Disaster Recovery | Detección de drift, `terraform apply -refresh-only`, reconciliación, restauración de estado desde S3 versioning |
| [lab12](lab12/README.md) | Gestión de Identidades y Acceso Seguro para EC2 | `aws_iam_group`, `aws_iam_user`, `aws_iam_user_group_membership`, `aws_iam_role`, Trust Policy, `aws_iam_instance_profile`, IMDSv2, SSM Session Manager |
| [lab13](lab13/README.md) | Cifrado Transversal con KMS y Jerarquía de Llaves | `aws_kms_key`, `enable_key_rotation`, `aws_kms_alias`, Key Policy segregada, `aws_ebs_volume` cifrado, `aws_s3_bucket_server_side_encryption_configuration`, `bucket_key_enabled`, Bucket Policy SSE forzoso |
| [lab16](lab16/README.md) | Red Multi-AZ Robusta y Dinámica | `for_each`, `cidrsubnet()`, `merge()`, `lifecycle` / `postcondition`, Tags EKS, Multi-AZ |
| [lab17](lab17/README.md) | Optimización de Salida a Internet y "NAT Tax" | Internet Gateway, NAT Gateway, Instancia NAT, `source_dest_check`, VPC Gateway Endpoint, FinOps |
| [lab18](lab18/README.md) | Seguridad y Control de Tráfico en VPC | Security Groups, NACLs, bloques `dynamic`, `source_security_group_id`, VPC Flow Logs, ALB |
| [lab19](lab19/README.md) | Conectividad Punto a Punto con VPC Peering | VPC Peering, rutas bidireccionales, no transitividad, referencia por CIDR en SG, auto_accept |
| [lab20](lab20/README.md) | Hub-and-Spoke con Transit Gateway y RAM | Transit Gateway, TGW Attachments, TGW Route Tables, Hub-and-Spoke, AWS RAM, Appliance Mode |
| [lab21](lab21/README.md) | Zonas Hospedadas Privadas y Resolución DNS | Route 53 PHZ, registro Alias, registro A, resolución interna, split-horizon DNS |
| [lab22](lab22/README.md) | Módulos Reutilizables: S3 Corporativo | Módulos locales, `variable` con validación, `output`, `locals`, `merge()`, convenciones de módulos |
| [lab23](lab23/README.md) | Módulos con Validación y Condiciones | `precondition`, `postcondition`, `check {}`, `variable` validation, error messages, contratos de módulo |
| [lab24](lab24/README.md) | Composición de Módulos Públicos con Estándares Corporativos | Módulo wrapper, Terraform Registry, composición de módulos, `moved {}`, parámetros hardcoded |
| [lab25](lab25/README.md) | Testing de Infraestructura | `terraform test`, `.tftest.hcl`, `run {}`, `mock_provider`, `override_resource`, test unitario vs integración |
| [lab26](lab26/README.md) | Gobernanza, Documentación y Publicación | `terraform-docs`, `pre-commit`, catálogo de ejemplos, versionado semántico, Git tags, `?ref=` |
| [lab27](lab27/README.md) | Cimientos de EC2: Despliegue Dinámico y Seguro | `data "aws_ami"`, IAM Instance Profile, IMDSv2 (`http_tokens`), `templatefile()`, `metadata_options`, SSM |
| [lab28](lab28/README.md) | Escalabilidad y Alta Disponibilidad con Zero Downtime | `aws_launch_template`, ALB, ASG Multi-AZ, Target Tracking, `instance_refresh`, `aws_autoscaling_schedule` |
| [lab29](lab29/README.md) | Microservicios con ECS Fargate y Malla de Servicios | `aws_ecr_repository` IMMUTABLE, `aws_ecr_lifecycle_policy`, `jsonencode()` en task definitions, SSM `SecureString`, Service Connect, Deployment Circuit Breaker |
| [lab30](lab30/README.md) | Procesamiento Asíncrono y Resiliencia de Eventos | `aws_lambda_event_source_mapping`, `batch_size`, `filter_criteria`, `aws_lambda_function_event_invoke_config`, Lambda Destinations, `aws_sqs_queue`, `redrive_policy`, DLQ, `report_batch_item_failures` |
| [lab31](lab31/README.md) | API Serverless: Lambda, API Gateway v2 y Layers | `data "archive_file"`, `source_code_hash`, `aws_lambda_layer_version`, `aws_apigatewayv2_api` HTTP API, `auto_deploy`, `AWS_PROXY`, `payload_format_version`, `aws_lambda_permission` |
| [lab32](lab32/README.md) | FinOps y Rendimiento: Optimización de Cómputo | `aws_ecs_cluster_capacity_providers`, FARGATE_SPOT, `publish = true`, `aws_lambda_alias`, `aws_lambda_provisioned_concurrency_config`, `vpc_config`, `AWSLambdaVPCAccessExecutionRole`, Container Insights, `aws_cloudwatch_metric_alarm`, `aws_sns_topic` |
| [lab33](lab33/README.md) | El Data Lake Blindado: S3 con Seguridad y Ciclo de Vida | `aws_s3_bucket_public_access_block`, SSE-KMS, Bucket Key, `aws_s3_bucket_versioning`, `aws_s3_bucket_lifecycle_configuration`, VPC Gateway Endpoint, `aws:sourceVpce`, módulos locales |
| [lab34](lab34/README.md) | Almacenamiento Híbrido: EBS de Alto Rendimiento y EFS Compartido | `aws_ebs_volume` gp3, `iops`/`throughput`, `aws_dlm_lifecycle_policy`, `aws_efs_file_system` Elastic, `aws_efs_mount_target`, `aws_efs_access_point`, `posix_user`, módulos locales |
| [lab35](lab35/README.md) | Base de Datos Relacional Crítica: RDS Multi-AZ y Replicación | `aws_db_subnet_group`, `aws_db_parameter_group`, `multi_az`, `max_allocated_storage`, `iam_database_authentication_enabled`, `aws_secretsmanager_secret_rotation`, read replica |
| [lab36](lab36/README.md) | Arquitectura Moderna NoSQL: DynamoDB con Caché y Eventos | `aws_dynamodb_table`, `billing_mode = PAY_PER_REQUEST`, `global_secondary_index`, `stream_view_type`, `aws_lambda_event_source_mapping`, `aws_elasticache_replication_group`, `transit_encryption_enabled`, `auth_token`, Cache-Aside, `aws_cloudwatch_metric_alarm` |
| [lab37](lab37/README.md) | Orquestación Imperativa con terraform_data | `terraform_data`, `triggers_replace`, `provisioner "file"`, `provisioner "remote-exec"`, `provisioner "local-exec"`, `on_failure = continue`, bloque `connection`, `aws_key_pair`, `self.triggers_replace` |
| [lab38](lab38/README.md) | Ingeniería de Datos y Resiliencia con Lifecycle | Flatten Pattern, `flatten()`, `merge()`, `optional()`, `try()`, `can()`, `precondition`, `postcondition`, `check {}`, `lifecycle { ignore_changes }`, `default_tags` |
| [lab39](lab39/README.md) | Despliegue Global y Adopción de Infraestructura Existente | Alias de proveedor, despliegue multi-región, `terraform plan -refresh-only`, drift, bloque `import {}`, `-generate-config-out` |
| [lab40](lab40/README.md) | Refactorización y Optimización del Rendimiento | `moved {}`, `count` → `for_each`, extracción a módulos, `plugin_cache_dir`, `-parallelism`, `terraform_remote_state`, state splitting |
| [lab41](lab41/README.md) | Gobernanza y Control de Versiones en CodeCommit | `aws_codecommit_repository`, `aws_codecommit_approval_rule_template`, `aws_codestar_notifications_notification_rule`, IAM Deny explícito, `StringLikeIfExists`, `sts:AssumeRole` pool de aprobadores, EventBridge auditoría, `terraform_data` bootstrap |
| [lab42](lab42/README.md) | Repositorio Privado de Módulos Terraform con CodeArtifact | `aws_codeartifact_domain`, `aws_codeartifact_repository`, `aws_codeartifact_domain_permissions_policy`, `aws_codeartifact_repository_permissions_policy`, CMK con `enable_key_rotation`, `aws:SourceAccount`, Generic Package con namespace, `get-package-version-asset`, separación publisher/consumer, inmutabilidad semántica, VPC endpoint Interface con `aws:SourceVpce` |
| [lab43](lab43/README.md) | Canalización CI de IaC con CodeBuild y ECR | `aws_ecr_repository` IMMUTABLE, `scan_on_push`, `aws_ecr_lifecycle_policy`, `aws_ecr_repository_policy`, `aws_codebuild_project`, `image_pull_credentials_type = "SERVICE_ROLE"`, `buildspec` embebido, patrón Fail Fast, `on-failure: ABORT`, Dockerfile multi-stage, SHA-256 verification, TFLint + tfsec + Checkov, `--exit-code 1` |
| [lab44](lab44/README.md) | Entrega Continua con CodeDeploy | `aws_codedeploy_app`, `aws_codedeploy_deployment_group`, `BLUE_GREEN`, `COPY_AUTO_SCALING_GROUP`, `termination_wait_time_in_minutes`, `auto_rollback_configuration`, `alarm_configuration`, `DEPLOYMENT_STOP_ON_ALARM`, `target_group_pair_info`, `ignore_changes` (Listener + ASG), Metric Math CloudWatch, `appspec.yml`, hooks de ciclo de vida |
| [lab45](lab45/README.md) | Pipeline GitOps de Terraform con CodePipeline | `aws_codepipeline`, `aws_codebuild_project`, `run_order`, artefactos cifrados KMS, plan inmutable, `aws_lambda_function` inspectora, OPA + Rego (`deny contains msg if`), Checkov JUnit reports, `aws_cloudwatch_event_rule`, `input_transformer`, aprobación manual SNS, `PrimarySource`, `CODEBUILD_SRC_DIR_*`, `aws_codecommit_repository` |
| [lab46](lab46/README.md) | Observabilidad Proactiva y Dashboards as Code | `aws_cloudwatch_log_group` con KMS, `aws_cloudwatch_log_metric_filter`, `ANOMALY_DETECTION_BAND`, `aws_cloudwatch_metric_alarm` con `threshold_metric_id`, `aws_cloudwatch_composite_alarm`, `alarm_rule` AND/OR, `aws_cloudwatch_dashboard` con `jsonencode`, CloudWatch Agent, Log Insights, `treat_missing_data`, `default_value`, `AmazonSSMManagedInstanceCore`, `CloudWatchAgentServerPolicy` |
| [lab47](lab47/README.md) | Centralización de Telemetría y Pipeline de Auditoría | VPC Flow Logs REJECT-only, `aws_cloudtrail` multi-región con `enable_log_file_validation`, `aws_kinesis_firehose_delivery_stream` extended_s3 con particionado Hive, `aws_cloudwatch_log_subscription_filter`, `aws_s3_bucket_lifecycle_configuration` → DEEP_ARCHIVE, CMK compartida con confused deputy protection, `bucket_key_enabled`, `error_output_prefix` |
| [lab48](lab48/README.md) | Fundamentos FinOps: Tags, Budgets y Spot Instances | `default_tags` en provider, módulo de naming `{app}-{env}-{component}-{resource}`, `for_each` en módulos, `aws_budgets_budget` FORECASTED + ACTUAL, `aws_sns_topic_policy` con `budgets.amazonaws.com`, `mixed_instances_policy`, `on_demand_base_capacity`, `capacity-optimized`, IMDSv2, ABAC con `aws:ResourceTag`, `aws_ssm_document`, `aws_ssm_association` |
| [lab49](lab49/README.md) | Compliance as Code y Remediación Automática | AWS Config rules, Conformance Packs, `aws_config_config_rule`, `aws_config_remediation_configuration`, SSM Documents, OPA/Rego en pipeline CI/CD, Security Hub, postura de seguridad continua, auto-remediación |

## Flujo de Trabajo General

```bash
# Iniciar LocalStack (si se usa el entorno local)
localstack start -d

# Desde el directorio del laboratorio (aws/ o localstack/)
terraform fmt
terraform init
terraform plan
terraform apply
terraform destroy
```

## Buenas Prácticas Generales

- Añade `terraform.tfstate` y `*.tfstate.backup` al `.gitignore`
- Ejecuta `terraform fmt` antes de cada commit
- Usa `terraform plan` siempre antes de `terraform apply` en entornos reales
- Destruye los recursos de laboratorio al terminar para evitar costos en AWS

## Recursos

- [Documentación de Terraform](https://developer.hashicorp.com/terraform/docs)
- [Terraform AWS Provider](https://registry.terraform.io/providers/hashicorp/aws/latest/docs)
- [Documentación de LocalStack](https://docs.localstack.cloud/)
- [AWS CLI Reference](https://docs.aws.amazon.com/cli/latest/reference/)
