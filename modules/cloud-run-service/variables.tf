variable "project_id" {
  type = string
}

variable "region" {
  type = string
}

variable "name" {
  description = "Cloud Run service name. Also used to derive the runtime service account id."
  type        = string
}

variable "env" {
  description = "Plain (non-secret) environment variables for the container."
  type        = map(string)
  default     = {}
}

variable "cpu" {
  type    = string
  default = "1"
}

variable "memory" {
  type    = string
  default = "256Mi"
}

variable "max_instance_count" {
  type    = number
  default = 3
}

variable "security_policy_id" {
  description = "Optional Cloud Armor security policy to attach to this service's backend service."
  type        = string
  default     = null
}
