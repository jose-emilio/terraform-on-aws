# Laboratorio 17 — LocalStack: Zonas Hospedadas Privadas y Resolucion DNS

Esta guia adapta el lab21 para ejecutarse integramente en LocalStack. LocalStack emula Route 53 a nivel de API pero **no ejecuta resolucion DNS real**. El ALB no esta disponible en Community, por lo que se usa un registro A con IP fija en lugar de Alias. El objetivo es validar la estructura de Terraform.

## Prerrequisitos

- LocalStack corriendo: `localstack start -d`
- lab07/localstack desplegado (crea bucket `terraform-state-labs`)
- AWS CLI configurado para LocalStack:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
alias awslocal='aws --endpoint-url=http://localhost.localstack.cloud:4566'
```

## 1. Despliegue

```bash
cd labs/lab21/localstack

terraform init -backend-config=localstack.s3.tfbackend

terraform apply
```

Revisa los outputs:

```bash
terraform output
# zone_id         = "Z0123456789ABCDEF"
# internal_domain = "app.internal"
# web_fqdn        = "web.app.internal"
# db_fqdn         = "db.app.internal"
```

## 2. Verificacion

### 2.1 Zona Hospedada Privada

```bash
ZONE_ID=$(terraform output -raw zone_id)

awslocal route53 get-hosted-zone \
  --id $ZONE_ID \
  --query '{Name: HostedZone.Name, Private: HostedZone.Config.PrivateZone}' \
  --output json
```

### 2.2 Registros DNS

```bash
awslocal route53 list-resource-record-sets \
  --hosted-zone-id $ZONE_ID \
  --query 'ResourceRecordSets[].{Name: Name, Type: Type, Records: ResourceRecords[].Value}' \
  --output table
```

## 3. Limitaciones en LocalStack

| Caracteristica | AWS Real | LocalStack Community |
|---|---|---|
| Route 53 PHZ | Resolucion DNS real dentro de la VPC | Emulada, sin resolucion |
| Registro Alias | Apunta a ALB/CloudFront | **No disponible** (sin ELBv2) |
| Registro A | Resuelve a IP | Emulado |
| nslookup/dig | Funciona dentro de la VPC | No verificable sin DNS real |

Para verificar la resolucion DNS real con `nslookup`/`dig`, usa la version `aws/`.

## 4. Limpieza

```bash
terraform destroy
```
