variable "project_id" {
  description = "GCP project ID."
  type        = string
  default     = "bradjobe-dev"
}

variable "region" {
  description = "Primary region for all regional resources."
  type        = string
  default     = "northamerica-northeast1"
}

variable "zone" {
  description = "Zone for the (zonal) GKE cluster, the ccaas VM, and the GPU node pool."
  type        = string
  default     = "northamerica-northeast1-a"
}

variable "domain" {
  description = "Root domain served by the main load balancer."
  type        = string
  default     = "bradjobe.dev"
}

variable "llm_subdomain" {
  description = "Subdomain the GKE-hosted Qwen LLM demo is served on, fronted by its own GKE Ingress."
  type        = string
  default     = "llm.bradjobe.dev"
}

variable "github_owner" {
  description = "GitHub org/user that owns every app repo this connects to."
  type        = string
  default     = "ScradFTW"
}

variable "app_repos" {
  description = "Every application repo Cloud Build needs a connection to, keyed by short name."
  type        = set(string)
  default = [
    "bradjobe.dev",
    "demos-ui",
    "llm-testing-deploy",
    "pose-tracker",
    "ccaas",
    "qwen-llm-gke",
  ]
}

variable "ccaas_machine_type" {
  description = "Machine type for the ccaas GCE VM (needs a real Docker daemon; not Cloud-Run-able)."
  type        = string
  default     = "e2-medium"
}

variable "llm_gpu_node_count" {
  description = "Fixed size of the GPU node pool serving the Qwen LLM demo. \"At least two\" per requirements; kept fixed (no autoscaler) so Spot cost stays predictable."
  type        = number
  default     = 2
}

variable "llm_gpu_type" {
  description = "Cheapest GPU SKU available on GCP as of authoring; T4 is roughly a third the on-demand hourly cost of the next tier up (L4) and is more than enough for a 0.5B quantized model."
  type        = string
  default     = "nvidia-tesla-t4"
}

variable "llm_gpu_machine_type" {
  description = "Smallest N1 machine type (T4 only attaches to N1 or G2 families) with enough headroom for llama.cpp + the CORS sidecar."
  type        = string
  default     = "n1-standard-2"
}
