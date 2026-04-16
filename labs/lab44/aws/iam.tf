# ═══════════════════════════════════════════════════════════════════════════════
# IAM — Roles para CodeDeploy y las instancias EC2
# ═══════════════════════════════════════════════════════════════════════════════
#
# Estructura de permisos:
#
#   Rol:  lab44-codedeploy-role
#   └── AWSCodeDeployRole (politica gestionada AWS)
#       Permite a CodeDeploy: describir y modificar ASGs, registrar/deregistrar
#       instancias en Target Groups y acceder al bucket de artefactos.
#   └── Politica inline: codedeploy-launch-template-support
#       Permisos adicionales para Launch Templates (ec2:RunInstances, ec2:CreateTags,
#       iam:PassRole).
#
#   Rol:  lab44-ec2-role
#   ├── Politica inline: ec2-s3-artifacts
#   │   ├── s3:GetObject, s3:GetObjectVersion  (descargar el zip del despliegue)
#   │   └── s3:ListBucket                      (listar revisiones disponibles)
#   ├── AmazonSSMManagedInstanceCore           (acceso via Session Manager sin SSH)
#   └── CloudWatchAgentServerPolicy            (enviar metricas y logs del agente)

# ── Rol de servicio para CodeDeploy ──────────────────────────────────────────
#
# CodeDeploy necesita este rol para orquestar el despliegue IN_PLACE: gestionar
# el ASG, desregistrar y volver a registrar instancias en el Target Group del ALB.

data "aws_iam_policy_document" "codedeploy_trust" {
  statement {
    sid    = "AllowCodeDeployAssumeRole"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "codedeploy" {
  name               = "${var.project}-codedeploy-role"
  path               = "/codedeploy/"
  description        = "Rol de servicio para CodeDeploy IN_PLACE con ASG. Lab44."
  assume_role_policy = data.aws_iam_policy_document.codedeploy_trust.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "codedeploy-service-role"
  }
}

# AWSCodeDeployRole concede a CodeDeploy los permisos necesarios para gestionar
# instancias EC2, ASGs, ELBs y notificaciones SNS durante los despliegues.
resource "aws_iam_role_policy_attachment" "codedeploy" {
  role       = aws_iam_role.codedeploy.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSCodeDeployRole"
}

# Permisos adicionales requeridos cuando el ASG usa Launch Template.
# Segun la doc oficial de CodeDeploy, AWSCodeDeployRole cubre los permisos base
# pero cuando el grupo de autoescalado referencia un Launch Template hay que
# anadir explicitamente estas tres acciones:
#   ec2:RunInstances — necesario para que el ASG lance instancias desde la plantilla
#   ec2:CreateTags   — etiquetar los recursos creados durante el despliegue
#   iam:PassRole     — pasar el instance profile de EC2 a las nuevas instancias
# Ref: https://docs.aws.amazon.com/codedeploy/latest/userguide/getting-started-create-service-role.html
data "aws_iam_policy_document" "codedeploy_launch_template" {
  statement {
    sid    = "LaunchTemplateSupport"
    effect = "Allow"

    actions = [
      "ec2:RunInstances",
      "ec2:CreateTags",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "PassRoleToEC2"
    effect = "Allow"

    actions   = ["iam:PassRole"]
    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com", "autoscaling.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "codedeploy_launch_template" {
  name   = "codedeploy-launch-template-support"
  role   = aws_iam_role.codedeploy.id
  policy = data.aws_iam_policy_document.codedeploy_launch_template.json
}

# ── Rol de instancia EC2 ───────────────────────────────────────────────────────
#
# Cada instancia EC2 del ASG usa este rol para:
#   - Descargar el paquete de despliegue desde S3
#   - Conectarse via Session Manager (sin necesidad de SSH ni clave PEM)
#   - Enviar metricas y logs al agente de CloudWatch

data "aws_iam_policy_document" "ec2_trust" {
  statement {
    sid    = "AllowEC2AssumeRole"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${var.project}-ec2-role"
  path               = "/codedeploy/"
  description        = "Rol de instancia EC2 para el despliegue con CodeDeploy. Lab44."
  assume_role_policy = data.aws_iam_policy_document.ec2_trust.json

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
    Purpose   = "ec2-instance-role"
  }
}

# Permisos minimos sobre el bucket de artefactos:
#   GetObject / GetObjectVersion — descargar el zip de la revision
#   ListBucket — CodeDeploy necesita listar el bucket para verificar que el
#                objeto existe antes de descargarlo
data "aws_iam_policy_document" "ec2_s3" {
  statement {
    sid    = "AllowReadArtifacts"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]

    resources = ["${aws_s3_bucket.artifacts.arn}/*"]
  }

  statement {
    sid    = "AllowListBucket"
    effect = "Allow"

    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.artifacts.arn]
  }
}

resource "aws_iam_role_policy" "ec2_s3" {
  name   = "ec2-s3-artifacts"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2_s3.json
}

# Session Manager: permite abrir una sesion interactiva en la instancia desde
# la consola de AWS o la AWS CLI sin exponer puertos SSH ni gestionar claves PEM.
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# CloudWatch Agent: permite enviar metricas del sistema (CPU, memoria, disco) y
# logs de Apache e httpd al servicio CloudWatch desde la instancia.
resource "aws_iam_role_policy_attachment" "ec2_cloudwatch" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${var.project}-ec2-profile"
  role = aws_iam_role.ec2.name

  tags = {
    Project   = var.project
    ManagedBy = "terraform"
  }
}
