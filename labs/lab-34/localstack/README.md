# Laboratorio 30 — LocalStack: Almacenamiento Híbrido: EBS de Alto Rendimiento y EFS Compartido

Este documento describe cómo ejecutar el laboratorio 30 contra LocalStack. Los recursos EFS (file system, mount targets, access points) y EC2/EBS funcionan en Community con las limitaciones indicadas. DLM no está disponible en Community.

## Requisitos Previos

- LocalStack en ejecución: `localstack start -d`
- Terraform >= 1.5

---

## 1. Despliegue en LocalStack

### 1.1 Limitaciones conocidas

| Recurso | Soporte en Community |
|---|---|
| `aws_vpc` + `aws_subnet` | Completo |
| `aws_security_group` | Completo |
| `aws_instance` | Parcial — instancia creada; estado simulado |
| `aws_ebs_volume` (gp3, iops, throughput) | Parcial — volumen creado; iops/throughput aceptados sin efecto real |
| `aws_volume_attachment` | Parcial — adjunto aceptado; sin bloque de dispositivo real |
| `aws_dlm_lifecycle_policy` | **No disponible** — omitido en esta versión |
| `aws_efs_file_system` | **No disponible** — requiere licencia de pago; módulo `efs-share` omitido |
| `aws_efs_mount_target` | **No disponible** — depende de EFS |
| `aws_efs_access_point` | **No disponible** — depende de EFS |
| Módulo `efs-share` | **Omitido** — EFS no incluido en LocalStack Community |

### 1.2 Inicialización y despliegue

```bash
localstack status

# Desde lab34/localstack/
terraform fmt
terraform init
terraform plan
terraform apply
```

### 1.3 Verificación de EBS

```bash
EBS_ID=$(terraform output -raw ebs_volume_id)

# Confirma el volumen y sus parámetros gp3
awslocal ec2 describe-volumes \
  --volume-ids "$EBS_ID" \
  --query 'Volumes[0].{Tipo:VolumeType,Tamanyo:Size,IOPS:Iops,Throughput:Throughput,Cifrado:Encrypted}'
```

### 1.4 Verificación de EFS

EFS no está disponible en LocalStack Community. Consulta la sección de [AWS real](#25-montaje-del-efs-desde-la-instancia-ssm) del README principal para las verificaciones de EFS.

---

## 2. Limpieza

```bash
terraform destroy
```

---

## 3. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| EBS gp3 iops/throughput | Rendimiento real desacoplado del tamaño | Parámetros aceptados; sin efecto real |
| DLM snapshots automáticos | Snapshots reales creados y rotados | No disponible en Community |
| EFS (file system, mount targets, access points) | Recursos reales con cifrado y POSIX enforcement | **No disponible** en Community — módulo omitido |

---

## 4. Recursos Adicionales

- [LocalStack — EFS](https://docs.localstack.cloud/aws/services/efs/)
- [LocalStack — EC2](https://docs.localstack.cloud/aws/services/ec2/)
