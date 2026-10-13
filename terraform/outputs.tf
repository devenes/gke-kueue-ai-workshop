output "cluster_name" {
  description = "GKE Cluster Name"
  value       = google_container_cluster.workshop.name
}

output "region" {
  description = "GCP Region"
  value       = var.region
}

output "zone" {
  description = "GCP Zone"
  value       = var.zone
}

output "get_credentials_command" {
  description = "Command to configure kubectl credentials for the GKE cluster"
  value       = "gcloud container clusters get-credentials ${google_container_cluster.workshop.name} --zone ${var.zone} --project ${var.project_id}"
}
