# Laboratorio 29 — LocalStack: El Data Lake Blindado: S3 con Seguridad y Ciclo de Vida

![Terraform on AWS](../../../images/lab-banner.svg)


Este documento describe cómo ejecutar el laboratorio 29 contra LocalStack. Los recursos S3 (bucket, public access block, versionado, lifecycle configuration) funcionan plenamente en Community. KMS y la condición de VPC endpoint tienen soporte parcial.

## Requisitos Previos

- LocalStack en ejecución: `localstack start -d`
- Terraform >= 1.5

---

## 1. Despliegue en LocalStack

### 1.1 Limitaciones conocidas

| Recurso | Soporte en Community |
|---|---|
| `aws_s3_bucket` | Completo |
| `aws_s3_bucket_public_access_block` | Completo |
| `aws_s3_bucket_versioning` | Completo |
| `aws_s3_bucket_lifecycle_configuration` | Completo |
| `aws_s3_bucket_server_side_encryption_configuration` | Parcial — configuración aceptada; cifrado real no se aplica |
| `aws_kms_key` + `aws_kms_alias` | Parcial — clave creada; SSE-KMS no cifra realmente en Community |
| `aws_vpc` + `aws_route_table` | Completo |
| `aws_vpc_endpoint` (Gateway S3) | Parcial — recurso creado; no enruta tráfico real |
| `aws_s3_bucket_policy` (condición `aws:sourceVpce`) | Parcial — política aceptada; condición no evaluada en Community |
| Módulo `secure-bucket` | Completo — todos los recursos creados sin error |

### 1.2 Inicialización y despliegue

```bash
localstack status

# Desde lab33/localstack/
terraform fmt
terraform init
terraform plan
terraform apply
```

### 1.3 Verificación de S3

```bash
BUCKET=$(terraform output -raw bucket_name)

# Confirma que el bucket existe
awslocal s3api head-bucket --bucket "$BUCKET"

# Verifica el bloqueo de acceso público (los 4 controles en true)
awslocal s3api get-public-access-block --bucket "$BUCKET"

# Verifica el cifrado SSE-KMS
awslocal s3api get-bucket-encryption --bucket "$BUCKET"

# Verifica el versionado
awslocal s3api get-bucket-versioning --bucket "$BUCKET"

# Verifica la lifecycle configuration
awslocal s3api get-bucket-lifecycle-configuration --bucket "$BUCKET"
```

### 1.4 Verificación de versionado

```bash
BUCKET=$(terraform output -raw bucket_name)

# Sube un objeto
echo "version 1" | awslocal s3 cp - s3://"$BUCKET"/test.txt

# Sobreescribe (crea nueva versión)
echo "version 2" | awslocal s3 cp - s3://"$BUCKET"/test.txt

# Lista versiones — deben aparecer 2 versiones de test.txt
awslocal s3api list-object-versions \
  --bucket "$BUCKET" \
  --query 'Versions[*].{Key:Key,VersionId:VersionId,LastModified:LastModified}'
```

### 1.5 Verificación de KMS y VPC Endpoint

```bash
# CMK creada
awslocal kms describe-key \
  --key-id "$(terraform output -raw kms_key_arn)" \
  --query 'KeyMetadata.{KeyId:KeyId,Estado:KeyState,Rotacion:KeyRotationStatus}'

# VPC Endpoint creado
awslocal ec2 describe-vpc-endpoints \
  --vpc-endpoint-ids "$(terraform output -raw vpc_endpoint_id)" \
  --query 'VpcEndpoints[0].{ID:VpcEndpointId,Estado:State,Tipo:VpcEndpointType}'
```

### 1.6 Verificación de la bucket policy

```bash
awslocal s3api get-bucket-policy \
  --bucket "$(terraform output -raw bucket_name)" \
  --query Policy --output text | python3 -m json.tool
```

La política mostrará la condición `aws:sourceVpce`, aunque en LocalStack Community no se evalúa realmente.

---

## 2. Limpieza

```bash
# Vaciar el bucket antes de destruir
awslocal s3 rm s3://"$(terraform output -raw bucket_name)" --recursive

# Destruir la infraestructura
terraform destroy
```

---

## 3. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| Bucket + public access block | Bloqueo real de ACLs y políticas públicas | Configuración aceptada y verificable |
| SSE-KMS + Bucket Key | Cifrado real con CMK; Bucket Key reduce llamadas KMS un 99% | Configuración aceptada; sin cifrado real |
| Versionado | Versiones inmutables; protección real contra ransomware | Versiones creadas correctamente |
| Lifecycle configuration | AWS mueve objetos a Glacier automáticamente a los 90 días | Regla aceptada; sin transición real de storage class |
| VPC Gateway Endpoint | Ruta real inyectada en route table; sin coste de transferencia | Recurso creado; sin enrutamiento real |
| Bucket policy (`aws:sourceVpce`) | Deniega acceso desde fuera del endpoint; probado con `aws s3 cp` desde EC2 | Política aceptada; condición no evaluada |

---

## 4. Recursos Adicionales

- [LocalStack — S3](https://docs.localstack.cloud/aws/services/s3/)
- [LocalStack — KMS](https://docs.localstack.cloud/aws/services/kms/)
