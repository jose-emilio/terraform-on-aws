# Laboratorio 24 — LocalStack: Escalabilidad y Alta Disponibilidad con Zero Downtime

Este documento describe cómo ejecutar el laboratorio 24 contra LocalStack. El código Terraform es el mismo que en `aws/`; solo cambia la configuración del provider.

## Requisitos Previos

- LocalStack en ejecución: `localstack start -d`
- Terraform >= 1.5

---

## 1. Despliegue en LocalStack

### 1.1 Limitaciones conocidas

LocalStack Community simula los servicios de AWS con algunas restricciones relevantes para este laboratorio:

| Servicio | Soporte en Community |
|---|---|
| VPC, subnets, IGW, NAT GW | Completo |
| Security Groups | Completo |
| ALB (`aws_lb`, `aws_lb_listener`) | Parcial — el DNS no resuelve a instancias reales |
| Auto Scaling Group | Parcial — crea el recurso pero no lanza instancias EC2 reales |
| Launch Template | Completo |
| Política Target Tracking | Parcial — se crea el recurso, pero CloudWatch no emite métricas |
| `instance_refresh` | Parcial — se registra la operación, no hay instancias que reemplazar |

El valor del laboratorio con LocalStack radica en verificar que el código Terraform es válido y que los recursos se crean sin errores de API. Para observar el comportamiento real del ALB, ASG e `instance_refresh`, se requiere AWS real o LocalStack Pro.

### 1.2 Inicialización y despliegue

Asegúrate de que LocalStack está en ejecución:

```bash
localstack status
```

Desde el directorio `lab28/localstack/`:

```bash
terraform fmt
terraform init
terraform plan
terraform apply
```

### 1.3 Verificación

Comprueba que los recursos se han creado:

```bash
# VPC y subredes
aws --profile localstack ec2 describe-vpcs \
  --filters "Name=tag:Project,Values=lab28-local" \
  --query 'Vpcs[].{ID:VpcId,CIDR:CidrBlock}' --output table

aws --profile localstack ec2 describe-subnets \
  --filters "Name=tag:Project,Values=lab28-local" \
  --query 'Subnets[].{ID:SubnetId,CIDR:CidrBlock,AZ:AvailabilityZone}' --output table

# ALB
aws --profile localstack elbv2 describe-load-balancers \
  --query 'LoadBalancers[].{Name:LoadBalancerName,DNS:DNSName,State:State.Code}' \
  --output table

# ASG
aws --profile localstack autoscaling describe-auto-scaling-groups \
  --query 'AutoScalingGroups[].{Name:AutoScalingGroupName,Min:MinSize,Max:MaxSize,Desired:DesiredCapacity}' \
  --output table

# Launch Template
aws --profile localstack ec2 describe-launch-templates \
  --query 'LaunchTemplates[].{Name:LaunchTemplateName,Version:LatestVersionNumber}' \
  --output table
```

### 1.4 Demostración del Instance Refresh (LocalStack)

Aunque LocalStack no reemplaza instancias reales, puedes verificar que Terraform genera una nueva versión del Launch Template al cambiar `app_version` y que el ASG registra una operación de refresh:

```bash
# Desde lab28/localstack/
terraform apply -var="app_version=v2"

# Consultar el historial de instance refreshes del ASG
aws --profile localstack autoscaling describe-instance-refreshes \
  --auto-scaling-group-name lab28-local-asg
```

---

## 2. Limpieza

```bash
# Desde lab28/localstack/
terraform destroy
```

---

## 3. Comparativa AWS Real vs LocalStack

| Aspecto | AWS Real | LocalStack |
|---|---|---|
| ALB con DNS funcional | Sí — resuelve a instancias reales | Parcial — DNS simulado |
| Instancias EC2 en ASG | Se lanzan y pasan health checks | No se lanzan instancias reales |
| Instance Refresh visible | Reemplaza instancias gradualmente | Registra la operación sin efecto real |
| Target Tracking (CPU) | CloudWatch escala el ASG | Sin métricas reales — no escala |
| Coste | NAT GW + instancias EC2 + ALB | Sin coste |

---

## 4. Buenas Prácticas

- Usa LocalStack para validar la sintaxis y los tipos de recursos antes de desplegar en AWS real.
- Para probar el comportamiento dinámico (scaling, rolling update), usa AWS real o LocalStack Pro.
- El flag `terraform validate` y `terraform plan` son suficientes para detectar errores de configuración sin necesidad de LocalStack.

---

## 5. Recursos Adicionales

- [LocalStack — ELBv2](https://docs.localstack.cloud/aws/services/elb/)
- [LocalStack — Auto Scaling](https://docs.localstack.cloud/aws/services/autoscaling/)
- [LocalStack Pro — soporte ampliado](https://docs.localstack.cloud/aws/getting-started/)
