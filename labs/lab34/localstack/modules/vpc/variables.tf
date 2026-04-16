variable "project" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "cidr_block" {
  type    = string
  default = "10.30.0.0/16"
}

variable "private_subnets" {
  type        = map(string)
  description = "Mapa AZ → CIDR de las subnets privadas"
}
