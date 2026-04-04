terraform {
  backend "s3" {
    bucket = "ai-rag-terraform-state"
    key    = "ai-rag-gitops/terraform.tfstate"
    region = "us-east-1"
  }
}

provider "aws" {
  region = var.region
}
