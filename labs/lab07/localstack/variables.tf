variable "bucket_name" {
  type    = string
  default = "terraform-state-labs"
}

variable "table_name" {
  type    = string
  default = "terraform-state-lock"
}
