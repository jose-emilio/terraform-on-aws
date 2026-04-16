# ══════════════════════════════════════════════════════════════════════════════
# FLATTEN PATTERN
# ══════════════════════════════════════════════════════════════════════════════
#
# Problema: var.vpc_config es un mapa anidado (VPC → subredes). for_each
# solo acepta mapas planos o sets. No se puede escribir:
#
#   for_each = var.vpc_config   ← itera sobre VPCs, no sobre subredes
#
# Solucion — Flatten Pattern en tres pasos:
#
#   1. for externo: itera sobre cada VPC del mapa
#   2. for interno: itera sobre cada subred de esa VPC
#   3. flatten(): convierte la lista de listas en una lista plana
#
# El resultado es una lista de objetos, uno por subred, con todos los datos
# necesarios para crear el recurso (vpc_key, subnet_key, cidr, az, tags...).
#
# Paso final: list_to_map convierte la lista en un mapa usando una clave
# compuesta "vpc_key/subnet_key" — necesario porque for_each requiere un mapa,
# no una lista, para garantizar claves unicas y estables en el estado.

locals {
  # ── Paso 1-2-3: flatten del mapa anidado ─────────────────────────────────
  subnets_flat = flatten([
    for vpc_key, vpc in var.vpc_config : [
      for subnet_key, subnet in vpc.subnets : {
        # Clave compuesta: identifica univocamente cada subred en el estado
        key               = "${vpc_key}/${subnet_key}"
        vpc_key           = vpc_key
        subnet_key        = subnet_key
        vpc_cidr          = vpc.cidr_block
        cidr_block        = subnet.cidr_block
        availability_zone = subnet.availability_zone
        public            = subnet.public
        department_tags   = subnet.department_tags
      }
    ]
  ])

  # ── Paso 4: convertir la lista plana en mapa para for_each ───────────────
  subnets_map = {
    for subnet in local.subnets_flat : subnet.key => subnet
  }

  # ══════════════════════════════════════════════════════════════════════════
  # MERGE PATTERN — fusion de etiquetas corporativas y de departamento
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Las etiquetas corporativas (company_tags) son obligatorias en todos los
  # recursos y ya se aplican globalmente via default_tags del provider.
  # Las etiquetas de departamento son especificas de cada subred y se
  # fusionan en runtime con merge().
  #
  # merge() da precedencia al ultimo argumento en caso de colision de claves,
  # lo que permite que las etiquetas de departamento sobreescriban las
  # corporativas si fuera necesario (por ejemplo, un BillingCode especifico).
  #
  # Las etiquetas resultantes se usan en los recursos de subred.

  subnet_tags = {
    for key, subnet in local.subnets_map : key => merge(
      # Capa 1 — etiquetas de departamento especificas de la subred
      {
        Department  = subnet.department_tags.department
        Team        = subnet.department_tags.team
        BillingCode = subnet.department_tags.billing_code
        Tier        = subnet.public ? "public" : "private"
      },
      # Capa 2 — etiquetas de identificacion del recurso
      # (estas sobreescriben la capa 1 si hay colision)
      {
        Name = "${var.project}-${key}"
      }
    )
  }

  # Mapa de VPCs unicas para crear aws_vpc (sin duplicados del flatten)
  vpcs_map = {
    for vpc_key, vpc in var.vpc_config : vpc_key => vpc
  }

  # Mapa de VPCs que tienen al menos una subred publica — usado para crear
  # IGWs y route tables solo donde son necesarios.
  vpcs_with_public_subnets = {
    for vpc_key, vpc in local.vpcs_map : vpc_key => vpc
    if anytrue([
      for subnet in local.subnets_flat :
      subnet.public if subnet.vpc_key == vpc_key
    ])
  }

  # Mapa de subredes publicas (subconjunto de subnets_map)
  public_subnets_map = {
    for k, subnet in local.subnets_map : k => subnet
    if subnet.public
  }

  # ══════════════════════════════════════════════════════════════════════════
  # try() Y can() — acceso seguro a valores opcionales y potencialmente nulos
  # ══════════════════════════════════════════════════════════════════════════
  #
  # try(expresion, fallback): evalua la expresion y, si produce cualquier
  # error (atributo nulo, indice fuera de rango, tipo incompatible...),
  # devuelve el valor fallback en lugar de abortar.
  #
  # can(expresion): devuelve true si la expresion se puede evaluar sin error,
  # false en caso contrario. Es un try() booleano — util en condiciones.
  #
  # Caso de uso principal en este lab: calcular de forma segura si la alarma
  # de monitoreo debe activarse, incluso cuando alarm_email podria ser null
  # o cuando monitoring_config no ha sido especificado por el operador.

  # try() — extrae el email de alarma de forma segura.
  # Si monitoring_config no tiene alarm_email o es null, devuelve null
  # sin producir un error de acceso a atributo nulo.
  monitoring_alarm_email = try(var.monitoring_config.alarm_email, null)

  # can() — booleano que indica si la alarma debe activarse.
  # Equivale a "monitoring_config.alarm_email existe y no es null",
  # pero de forma defensiva: si la estructura cambia en el futuro y
  # alarm_email desaparece, can() devuelve false en lugar de abortar.
  monitoring_alarm_enabled = (
    var.monitoring_config.enabled &&
    can(var.monitoring_config.alarm_email) &&
    local.monitoring_alarm_email != null
  )

  # try() para el codigo de facturacion — si por alguna razon department_tags
  # no tiene billing_code (por ejemplo, en configuraciones heredadas o en
  # subredes anadidas manualmente al estado), devuelve "UNTAGGED" en lugar
  # de un error de atributo inexistente.
  subnet_billing_codes = {
    for key, subnet in local.subnets_map :
    key => try(subnet.department_tags.billing_code, "UNTAGGED")
  }
}
