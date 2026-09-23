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

variable "secret_env" {
  description = "Environment variables sourced from Secret Manager, as { ENV_NAME = secret_id }. Always reads the latest version; the module grants the runtime service account access to each secret."
  type        = map(string)
  default     = {}
}

variable "cloudsql_instances" {
  description = "Cloud SQL instance connection names to expose as unix sockets under /cloudsql/<connection-name>."
  type        = list(string)
  default     = []
}

variable "project_roles" {
  description = "Extra project-level roles for the runtime service account (e.g. roles/cloudsql.client). Granted before the service is created."
  type        = set(string)
  default     = []
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
