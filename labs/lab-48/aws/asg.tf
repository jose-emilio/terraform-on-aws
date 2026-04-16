# ═══════════════════════════════════════════════════════════════════════════════
# IAM — Rol para las instancias EC2 del ASG
# ═══════════════════════════════════════════════════════════════════════════════
#
# El rol permite conectarse a las instancias via AWS Systems Manager Session Manager
# sin necesidad de abrir el puerto 22 ni gestionar claves SSH. SSM es el método
# recomendado de acceso en instancias sin IP pública y en entornos corporativos.

data "aws_iam_policy_document" "ec2_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "asg_instance" {
  name               = module.naming["iam_role"].name
  assume_role_policy = data.aws_iam_policy_document.ec2_assume_role.json

  tags = {
    Name = module.naming["iam_role"].name
  }
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.asg_instance.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "asg_instance" {
  name = module.naming["iam_role"].name
  role = aws_iam_role.asg_instance.name
}

# ═══════════════════════════════════════════════════════════════════════════════
# Security Group — Firewall de las instancias del ASG
# ═══════════════════════════════════════════════════════════════════════════════
#
# Las instancias solo necesitan tráfico de salida para:
#   - Comunicarse con el endpoint de SSM (HTTPS 443)
#   - Descargar actualizaciones del sistema
# No se abre ningún puerto de entrada porque el acceso es solo via SSM.

resource "aws_security_group" "asg" {
  name        = module.naming["sg_asg"].name
  description = "SG de instancias del ASG ${module.naming["asg"].name}. Solo trafico de salida."
  vpc_id      = aws_vpc.main.id

  egress {
    description = "Trafico de salida irrestricto (SSM, yum, actualizaciones)."
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = module.naming["sg_asg"].name
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Launch Template — Plantilla de configuración de instancias EC2
# ═══════════════════════════════════════════════════════════════════════════════
#
# El Launch Template define la configuración base que heredan TODAS las instancias
# del ASG, independientemente de si son On-Demand o Spot. La Mixed Instances Policy
# puede sobreescribir únicamente el tipo de instancia; el resto (AMI, red, IAM, SG)
# es común.
#
# Versiones: el Launch Template tiene versionado. El ASG puede referenciar:
#   $Latest   → siempre usa la versión más reciente (actualización automática)
#   $Default  → usa la versión marcada como default (cambio controlado)
#   "3"       → versión fija (pinning para máxima estabilidad)
#
# En el laboratorio usamos $Latest para simplificar. En producción es preferible
# $Default para poder probar cambios en una versión nueva antes de promoverla.

resource "aws_launch_template" "asg" {
  name        = module.naming["lt"].name
  description = "Launch Template para el ASG con Mixed Instances Policy del Lab48."

  # AMI dinámica: siempre la última Amazon Linux 2023 x86_64
  # instance_type se omite intencionadamente: este Launch Template solo se usa
  # dentro de la mixed_instances_policy, donde los bloques override dictan los
  # tipos de instancia reales. Definirlo aquí sesgaría la selección de AWS hacia
  # ese tipo aunque la estrategia capacity-optimized prefiriera otro del pool.
  image_id = data.aws_ami.al2023.id

  # IMDSv2 (Instance Metadata Service v2) es obligatorio en instancias modernas.
  # Requiere token para acceder a los metadatos, previniendo ataques SSRF donde
  # una petición desde la instancia roba las credenciales del rol IAM.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  iam_instance_profile {
    name = aws_iam_instance_profile.asg_instance.name
  }

  network_interfaces {
    associate_public_ip_address = true
    security_groups             = [aws_security_group.asg.id]
    delete_on_termination       = true
  }

  # EBS optimizado y volumen root con gp3 (mejor rendimiento/precio que gp2)
  ebs_optimized = true

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Tag propagation: las tags del ASG se propagarán a las instancias.
  # Combinado con default_tags del provider, cada instancia tendrá:
  # Environment, Project, ManagedBy, CostCenter (default_tags) +
  # Name (definida en el ASG) + las tags de propagación del ASG.
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${module.naming["asg"].prefix}-instance"
    }
  }

  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${module.naming["asg"].prefix}-vol"
    }
  }

  tags = {
    Name = module.naming["lt"].name
  }
}

# ═══════════════════════════════════════════════════════════════════════════════
# Auto Scaling Group — Mixed Instances Policy (On-Demand + Spot)
# ═══════════════════════════════════════════════════════════════════════════════
#
# La Mixed Instances Policy combina dos tipos de capacidad:
#
#   1. On-Demand (garantizada): instancias que AWS NO puede interrumpir.
#      Precio estándar. Apropiada para la carga base mínima que debe estar
#      siempre disponible.
#
#   2. Spot (interrumpible): instancias de capacidad sobrante de AWS, con
#      descuentos de hasta 90% sobre el precio On-Demand. AWS puede
#      interrumpirlas con 2 minutos de aviso cuando necesita recuperar
#      la capacidad.
#
# Parámetros clave de la Mixed Instances Policy:
#
#   on_demand_base_capacity (var.on_demand_base_capacity = 1):
#     Las primeras N instancias son SIEMPRE On-Demand. Esto garantiza que
#     la aplicación tenga al menos 1 instancia no interrumpible.
#
#   on_demand_percentage_above_base_capacity (var.on_demand_percentage_above_base = 30):
#     De las instancias adicionales a la base, el 30% serán On-Demand y el
#     70% serán Spot. Con desired=2: 1 base On-Demand + 1 adicional donde
#     el 30% es On-Demand → 0.3 instancias On-Demand = redondeado a 0 = Spot.
#     Efectivamente: 1 On-Demand + 1 Spot.
#
#   spot_allocation_strategy = "capacity-optimized":
#     AWS elige la combinación de tipos de instancia con MAYOR disponibilidad
#     de capacidad Spot en ese momento. Reduce la tasa de interrupción porque
#     asigna instancias a los pools con más capacidad sobrante.
#     Alternativa: "lowest-price" prioriza el coste más bajo, pero tiene
#     mayor tasa de interrupción porque los pools baratos suelen estar más llenos.
#
#   Pool de tipos de instancia (instances_distribution override):
#     Definir múltiples tipos (t3.small, t3a.small, t3.medium, t3a.medium)
#     es fundamental para Spot. Si un pool se agota, el ASG usa otro tipo.
#     Con un solo tipo de instancia, una interrupción masiva podría dejar
#     el ASG sin capacidad Spot disponible.

resource "aws_autoscaling_group" "main" {
  name = module.naming["asg"].name

  min_size         = var.asg_min_size
  max_size         = var.asg_max_size
  desired_capacity = var.asg_desired_capacity

  # Distribución en todas las subredes públicas (multi-AZ).
  # El ASG intentará mantener la distribución equilibrada entre AZs.
  vpc_zone_identifier = aws_subnet.public[*].id

  # health_check_type = "EC2": el ASG considera una instancia sana si el
  # estado EC2 es "running". Con "ELB" esperaría que el Load Balancer
  # confirme la salud (más estricto, pero requiere un ALB adjunto).
  health_check_type         = "EC2"
  health_check_grace_period = 300

  # Permite actualizar las instancias cuando cambia el Launch Template
  # sin necesidad de destruir y recrear el ASG.
  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
  }

  # ── Mixed Instances Policy ──────────────────────────────────────────────────
  mixed_instances_policy {
    instances_distribution {
      on_demand_base_capacity                  = var.on_demand_base_capacity
      on_demand_percentage_above_base_capacity = var.on_demand_percentage_above_base
      spot_allocation_strategy                 = "capacity-optimized"
    }

    launch_template {
      launch_template_specification {
        launch_template_id = aws_launch_template.asg.id
        version            = "$Latest"
      }

      # Pool de instancias para Spot: cuatro tipos similares en recursos
      # (1-2 vCPU, 2 GB RAM) pero de distintas familias para maximizar la
      # disponibilidad de capacidad Spot. AWS elige de este pool según
      # la estrategia capacity-optimized.
      override {
        instance_type = "t3.small"
      }
      override {
        instance_type = "t3a.small"
      }
      override {
        instance_type = "t3.medium"
      }
      override {
        instance_type = "t3a.medium"
      }
    }
  }

  # Propaga las tags del ASG a las instancias que lance.
  # Las tags de la instancia quedan como: default_tags + estas tags propagadas.
  tag {
    key                 = "Name"
    value               = "${module.naming["asg"].prefix}-instance"
    propagate_at_launch = true
  }

  tag {
    key                 = "Component"
    value               = "compute"
    propagate_at_launch = true
  }
}
