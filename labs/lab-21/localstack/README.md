# Laboratorio 21 — LocalStack: Zonas Hospedadas Privadas y Resolución DNS

![Terraform on AWS](../../../images/lab-banner.svg)


Esta guía adapta el lab21 para ejecutarse íntegramente en LocalStack. LocalStack emula Route 53 a nivel de API pero **no ejecuta resolución DNS real** desde las instancias EC2 emuladas. Además, **ELBv2 (ALB / NLB) sigue siendo una funcionalidad de pago** en LocalStack — está incluida en los planes Base y Ultimate, pero no en Community Edition ni en el nuevo plan gratuito Hobby (vigente desde marzo 2026). Por eso este lab sustituye el registro Alias del ALB por un registro A con la IP privada de la instancia web. El objetivo es validar la estructura de Terraform; para verificar la resolución DNS real con `nslookup` / `dig` usa la versión `aws/`.

## Prerrequisitos

- LocalStack corriendo: `localstack start -d`
- lab02/localstack desplegado (crea el bucket `terraform-state-labs` usado como backend de tfstate)
- AWS CLI configurado para LocalStack:

```bash
export AWS_ACCESS_KEY_ID=test
export AWS_SECRET_ACCESS_KEY=test
export AWS_DEFAULT_REGION=us-east-1
alias awslocal='aws --endpoint-url=http://localhost.localstack.cloud:4566'
```

## Despliegue

```bash
cd labs/lab-21/localstack

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

## Verificacion

### Zona Hospedada Privada

```bash
ZONE_ID=$(terraform output -raw zone_id)

awslocal route53 get-hosted-zone \
  --id $ZONE_ID \
  --query '{Name: HostedZone.Name, Private: HostedZone.Config.PrivateZone}' \
  --output json
```

### Registros DNS

```bash
awslocal route53 list-resource-record-sets \
  --hosted-zone-id $ZONE_ID \
  --query 'ResourceRecordSets[].{Name: Name, Type: Type, Records: ResourceRecords[].Value}' \
  --output table
```

## Limitaciones en LocalStack

| Caracteristica | AWS Real | LocalStack Community |
|---|---|---|
| Route 53 PHZ | Resolución DNS real dentro de la VPC | Emulada, sin resolución |
| Registro Alias | Apunta a ALB/CloudFront | **No disponible** (sin ELBv2) |
| Registro A | Resuelve a IP | Emulado |
| nslookup/dig | Funciona dentro de la VPC | No verificable sin DNS real |

Para verificar la resolución DNS real con `nslookup`/`dig`, usa la versión `aws/`.

## Limpieza

```bash
terraform destroy
```
