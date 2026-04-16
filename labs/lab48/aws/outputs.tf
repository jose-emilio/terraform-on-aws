output "vpc_id" {
  description = "ID de la VPC del laboratorio."
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "IDs de las subredes públicas (una por AZ)."
  value       = aws_subnet.public[*].id
}

output "asg_name" {
  description = "Nombre del Auto Scaling Group."
  value       = aws_autoscaling_group.main.name
}

output "launch_template_id" {
  description = "ID del Launch Template del ASG."
  value       = aws_launch_template.asg.id
}

output "launch_template_version" {
  description = "Última versión del Launch Template."
  value       = aws_launch_template.asg.latest_version
}

output "security_group_id" {
  description = "ID del Security Group de las instancias del ASG."
  value       = aws_security_group.asg.id
}

output "sns_topic_arn" {
  description = "ARN del topic SNS de alertas de presupuesto."
  value       = aws_sns_topic.budget_alerts.arn
}

output "budget_name" {
  description = "Nombre del presupuesto de AWS Budgets."
  value       = aws_budgets_budget.monthly.name
}

output "ami_id" {
  description = "ID de la AMI de Amazon Linux 2023 usada en el Launch Template."
  value       = data.aws_ami.al2023.id
}

output "ami_name" {
  description = "Nombre de la AMI de Amazon Linux 2023 usada."
  value       = data.aws_ami.al2023.name
}

output "naming_examples" {
  description = "Ejemplos de nombres generados por el módulo de naming para los recursos del laboratorio."
  value = {
    vpc        = module.naming["vpc"].name
    subnet_a   = module.naming["sn_pub_a"].name
    subnet_b   = module.naming["sn_pub_b"].name
    sg_asg     = module.naming["sg_asg"].name
    asg        = module.naming["asg"].name
    lt         = module.naming["lt"].name
    budget     = module.naming["budget"].name
    sns_budget = module.naming["sns_budget"].name
  }
}
