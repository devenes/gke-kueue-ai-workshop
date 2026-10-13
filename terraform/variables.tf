variable "project_id" {
  description = "GCP Project ID"
  type        = string
  default     = "enes-turan-demo"
}

variable "region" {
  description = "GCP Region (for VPC and Subnet)"
  type        = string
  default     = "europe-west1"
}

variable "zone" {
  description = "GKE Zonal Cluster Location"
  type        = string
  default     = "europe-west1-b"
}

variable "cluster_name" {
  description = "GKE Cluster Name"
  type        = string
  default     = "gke-kueue-workshop"
}
