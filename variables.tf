variable "node_location" {
type = string
}

variable "resource_prefixes" {
type = string
}

variable "node_address_space" {
default = ["1.0.0.0/16"]
}

#variable for network range

variable "node_address_prefixes" {
default = ["1.0.1.0/24"]
}

#variable for Environment
variable "environment" {
type = string
}

variable "node_count" {
type = number
}

variable "client_secret" {
  description = "client secret"
  type        = string
}
