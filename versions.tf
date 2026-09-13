terraform {
  required_version = ">= 1.9.0"

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.15"
    }
    time = {
      source  = "hashicorp/time"
      version = "~> 0.13"
    }
  }

  # Bootstrapped once, by hand, before this repo's Cloud Build pipeline can
  # run terraform at all — see README.md "Bootstrap" section. Nobody applies
  # this configuration from a laptop: pushes to main run `terraform apply`
  # inside Cloud Build using the `terraform-infra` service account (see
  # cloudbuild-terraform.yaml + iam.tf), so this bucket is the only place
  # state ever lives.
  backend "gcs" {
    bucket = "bradjobe-dev-tfstate"
    prefix = "terraform/state"
  }
}
