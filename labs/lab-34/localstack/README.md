# Laboratorio 34 — LocalStack: Almacenamiento Híbrido: EBS de Alto Rendimiento y EFS Compartido

![Terraform on AWS](../../../images/lab-banner.svg)


Este documento describe cómo ejecutar el laboratorio 34 contra LocalStack. Los recursos EFS (file system, mount targets, access points) y EC2/EBS funcionan en Community con las limitaciones indicadas. DLM no está disponible en Community.

## Requisitos Previos

- LocalStack en ejecución: `localstack start -d`
- Terraform >= 1.10

---

## Despliegue en LocalStack

### Limitaciones conocidas

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

### Inicialización y despliegue

```bash
localstack status

# Desde lab34/localstack/
terraform fmt
terraform init
terraform plan
terraform apply
```

### Verificación de EBS

```bash
EBS_ID=$(terraform output -raw ebs_volume_id)

# Confirma el volumen y sus parámetros gp3
awslocal ec2 describe-volumes \
  --volume-ids "$EBS_ID" \
  --query 'Volumes[0].{Tipo:VolumeType,Tamanyo:Size,IOPS:Iops,Throughput:Throughput,Cifrado:Encrypted}'
```

### Verificación de EFS

EFS no está disponible en LocalStack Community. Consulta la sección [Montaje del EFS desde la instancia (SSM)](../README.md#montaje-del-efs-desde-la-instancia-ssm) del README principal para las verificaciones de EFS.

---

## Limpieza

```bash
terraform destroy
```

---

## Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| EBS gp3 iops/throughput | Rendimiento real desacoplado del tamaño | Parámetros aceptados; sin efecto real |
| DLM snapshots automáticos | Snapshots reales creados y rotados | No disponible en Community |
| EFS (file system, mount targets, access points) | Recursos reales con cifrado y POSIX enforcement | **No disponible** en Community — módulo omitido |

---

## Recursos Adicionales

- [LocalStack — EFS](https://docs.localstack.cloud/aws/services/efs/)
- [LocalStack — EC2](https://docs.localstack.cloud/aws/services/ec2/)
