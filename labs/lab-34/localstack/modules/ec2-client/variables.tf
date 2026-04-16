variable "project" {
  type = string
}

variable "tags" {
  type = map(string)
}

variable "vpc_id" {
  type = string
}

variable "subnet_id" {
  type = string
}

variable "ebs_iops" {
  type    = number
  default = 6000
}

variable "ebs_throughput" {
  type    = number
  default = 400
}

variable "ebs_size_gb" {
  type    = number
  default = 100
}
