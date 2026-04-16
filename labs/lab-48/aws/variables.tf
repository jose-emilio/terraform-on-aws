variable "region" {
  type        = string
  description = "Región de AWS donde se despliega la infraestructura."
  default     = "us-east-1"
}

variable "project" {
  type        = string
  description = "Nombre del proyecto. Etiqueta default_tags y usado en el módulo de naming."
  default     = "lab48"
}

variable "environment" {
  type        = string
  description = "Entorno de despliegue. Etiqueta default_tags y código en el módulo de naming."
  default     = "prd"

  validation {
    condition     = contains(["dev", "stg", "prd"], var.environment)
    error_message = "El entorno debe ser dev, stg o prd."
  }
}

variable "cost_center" {
  type        = string
  description = "Centro de coste de la organización. Etiqueta default_tags para imputación en FinOps."
  default     = "engineering"
}

variable "app_name" {
  type        = string
  description = "Nombre corto de la aplicación. Usado como prefijo en el módulo de naming."
  default     = "myapp"
}

variable "vpc_cidr" {
  type        = string
  description = "Bloque CIDR de la VPC del laboratorio."
  default     = "10.48.0.0/16"

  validation {
    condition     = can(cidrnetmask(var.vpc_cidr))
    error_message = "Debe ser un bloque CIDR válido (ej: 10.48.0.0/16)."
  }
}

variable "budget_limit_amount" {
  type        = string
  description = "Límite mensual en USD para el presupuesto AWS Budgets."
  default     = "20"
}

variable "budget_alert_threshold_pct" {
  type        = number
  description = "Porcentaje del presupuesto (sobre la predicción) que dispara la alerta SNS."
  default     = 85

  validation {
    condition     = var.budget_alert_threshold_pct > 0 && var.budget_alert_threshold_pct <= 200
    error_message = "El umbral debe ser un porcentaje positivo. Puede superar 100 para alertas post-límite."
  }
}

variable "budget_alert_email" {
  type        = string
  description = "Dirección de email a la que se envían las alertas de presupuesto."
  default     = ""
}

variable "asg_min_size" {
  type        = number
  description = "Número mínimo de instancias en el Auto Scaling Group."
  default     = 1
}

variable "asg_max_size" {
  type        = number
  description = "Número máximo de instancias en el Auto Scaling Group."
  default     = 4
}

variable "asg_desired_capacity" {
  type        = number
  description = "Capacidad deseada inicial del Auto Scaling Group."
  default     = 4
}

variable "on_demand_base_capacity" {
  type        = number
  description = "Número fijo de instancias On-Demand que siempre se mantienen (base garantizada)."
  default     = 1
}

variable "on_demand_percentage_above_base" {
  type        = number
  description = "Porcentaje de instancias adicionales (sobre la base) que serán On-Demand. El resto serán Spot."
  default     = 30

  validation {
    condition     = var.on_demand_percentage_above_base >= 0 && var.on_demand_percentage_above_base <= 100
    error_message = "El porcentaje de On-Demand debe estar entre 0 y 100."
  }
}

