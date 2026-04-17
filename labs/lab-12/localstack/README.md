# Laboratorio 12 — LocalStack: Gestión de Identidades y Acceso Seguro para EC2

![Terraform on AWS](../../../images/lab-banner.svg)


Entorno local con LocalStack para practicar los recursos IAM del laboratorio
sin necesidad de una cuenta de AWS.

> Para la guía completa (conceptos, arquitectura, retos y buenas prácticas)
> consulta el [README principal](../README.md).

## Limitaciones respecto a AWS real

| Aspecto | LocalStack Community |
|---------|---------------------|
| Recursos IAM (grupo, usuario, rol, profile) | Soportados |
| Instancia EC2 | **Omitida** — LocalStack Community no propaga el Instance Profile antes de `RunInstances` (error 404) |
| Ejecución de `user_data.sh` | **No soportada** |
| IMDSv2 y credenciales temporales en IMDS | **No disponible** |
| SSM Session Manager | **No disponible** |

La verificación de credenciales temporales requiere AWS real.
Este entorno cubre únicamente la creación y validación de los recursos IAM.

## Prerrequisitos

- LocalStack CLI instalado y Docker en ejecución.
- Terraform ≥ 1.5.

## Despliegue

```bash
# Arrancar LocalStack
localstack start -d

cd labs/lab12/localstack
terraform init
terraform plan
terraform apply
```

## Verificación en LocalStack

### Confirmar recursos IAM creados

```bash
# Usar el endpoint local de LocalStack
export AWS_ENDPOINT_URL=http://localhost.localstack.cloud:4566

aws iam get-group --group-name lab12-developers
aws iam get-user --user-name lab12-dev-01
aws iam get-role --role-name lab12-ec2-role
aws iam get-instance-profile --instance-profile-name lab12-ec2-profile
```

### Verificar la Trust Policy del rol

```bash
aws iam get-role --role-name lab12-ec2-role \
  --query 'Role.AssumeRolePolicyDocument' --output json
```

### Verificar membresía del grupo

```bash
aws iam list-groups-for-user --user-name lab12-dev-01 \
  --query 'Groups[].GroupName'
```

### Ver outputs de Terraform

```bash
terraform output
```

## Limpieza

```bash
terraform destroy
localstack stop   # opcional
```
