# Laboratorio 18 — LocalStack: Seguridad y Control de Trafico en VPC

![Terraform on AWS](../../../images/lab-banner.svg)


Esta guia adapta el lab18 para ejecutarse integramente en LocalStack. Las diferencias principales son que **ELBv2 (ALB) no esta disponible** en LocalStack Community (requiere licencia de pago) y que **no hay trafico de red real**, por lo que no se puede verificar el bloqueo efectivo de la NACL ni consultar Flow Logs con datos reales. El objetivo es validar la estructura de Terraform (Security Groups, NACLs, Flow Logs).

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
cd labs/lab18/localstack

terraform init -backend-config=localstack.s3.tfbackend

terraform apply
```

Revisa los outputs:

```bash
terraform output
# alb_sg_id       = "sg-xxxxxxxxx"
# app_sg_id       = "sg-xxxxxxxxx"
# public_nacl_id  = "acl-xxxxxxxxx"
# flow_log_group  = "/vpc/lab18/flow-logs"
```

## 2. Verificacion

### 2.1 Security Group del ALB (dynamic ingress)

```bash
ALB_SG=$(terraform output -raw alb_sg_id)

awslocal ec2 describe-security-groups \
  --group-ids $ALB_SG \
  --query 'SecurityGroups[].IpPermissions[].{Port: FromPort, CIDR: IpRanges[].CidrIp}' \
  --output json
```

Deberias ver una regla por cada puerto en `var.alb_ingress_ports` (80 y 443 por defecto).

### 2.2 Security Group de las EC2 (referencia por SG)

```bash
APP_SG=$(terraform output -raw app_sg_id)

awslocal ec2 describe-security-groups \
  --group-ids $APP_SG \
  --query 'SecurityGroups[].IpPermissions[].{Port: FromPort, SourceSG: UserIdGroupPairs[].GroupId}' \
  --output json
```

El unico origen permitido debe ser el SG del ALB (no un CIDR).

### 2.3 NACL publica (regla deny)

```bash
awslocal ec2 describe-network-acls \
  --filters Name=tag:Project,Values=lab18 \
  --query 'NetworkAcls[].Entries[?RuleAction==`deny` && !Egress].{RuleNum: RuleNumber, CIDR: CidrBlock, Action: RuleAction}' \
  --output table
```

Deberias ver la regla 50 con `deny` para la IP bloqueada (`203.0.113.0/32`).

### 2.4 VPC Flow Logs

```bash
awslocal logs describe-log-groups \
  --log-group-name-prefix "/vpc/lab18" \
  --query 'logGroups[].{Name: logGroupName, Retention: retentionInDays}' \
  --output table
```

## 3. Limitaciones en LocalStack

| Caracteristica | AWS Real | LocalStack Community |
|---|---|---|
| Security Groups | Filtran trafico real | Emulados, sin filtrado |
| NACLs | Bloquean/permiten trafico real | Emuladas, sin filtrado |
| ALB (ELBv2) | Distribuye trafico HTTP/HTTPS | **No disponible** (requiere licencia) |
| VPC Flow Logs | Capturan trafico REJECT real | Emulados, sin datos de trafico |
| Instancias EC2 | Ejecutan user_data, sirven HTTP | Emuladas, sin proceso real |

Para probar el ALB, el bloqueo efectivo de la NACL y consultar Flow Logs con datos reales, usa la version `aws/`.

## 4. Limpieza

```bash
terraform destroy
```
