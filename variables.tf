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
  description = "Zone for the (zonal) GKE cluster, the ccaas VM, and the GPU node pool. Must be -c: that's the only zone in this region with nvidia-tesla-t4 capacity (confirmed via `gcloud compute accelerator-types list` — -a and -b don't have it)."
  type        = string
  default     = "northamerica-northeast1-c"
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

variable "enable_llm_gpu_pool" {
  description = <<-EOT
    Whether to create the GPU node pool at all. Defaults to false: this
    fresh project's "GPUs (all regions)" quota is 0
    (compute.googleapis.com/gpus_all_regions) — a global cap, separate
    from and more fundamental than the regional NVIDIA T4 quota below —
    and self-service override tops out at 0, so node creation fails no
    matter what node_count is set to until Google approves a real
    increase. Rather than block every other resource in this repo behind
    that manual review, the pool stays opt-in until it's approved. See
    README.md "GPU quota".
  EOT
  type        = bool
  default     = false
}

variable "llm_gpu_node_count" {
  description = <<-EOT
    Fixed size of the GPU node pool serving the Qwen LLM demo. "At least
    two" per requirements; kept fixed (no autoscaler) so Spot cost stays
    predictable. Irrelevant while enable_llm_gpu_pool is false.

    Also check the regional quota once the global one is approved: this
    project's self-service Preemptible NVIDIA T4 GPU quota in
    northamerica-northeast1 is separately capped at 1 (new-project
    default) — a real increase to 2 also needs Google's manual review
    (`gcloud alpha services quota list --service=compute.googleapis.com
    --consumer=projects/bradjobe-dev --filter=metric:NVIDIA_T4_GPUS` to check).
  EOT
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
