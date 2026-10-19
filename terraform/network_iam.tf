# 1. Required GCP APIs
resource "google_project_service" "apis" {
  for_each = toset([
    "compute.googleapis.com",
    "container.googleapis.com",
    "iam.googleapis.com",
    "storage.googleapis.com"
  ])

  project            = var.project_id
  service            = each.key
  disable_on_destroy = false
}

data "google_project" "current" {
  project_id = var.project_id
  depends_on = [google_project_service.apis]
}

# 2. Workshop Custom VPC Network
resource "google_compute_network" "vpc" {
  name                    = "${var.cluster_name}-vpc"
  project                 = var.project_id
  auto_create_subnetworks = false
  depends_on              = [google_project_service.apis]
}

# 3. Subnet with Secondary CIDR Ranges for Pods and Services
resource "google_compute_subnetwork" "subnet" {
  name          = "${var.cluster_name}-subnet"
  project       = var.project_id
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.10.0.0/20"

  secondary_ip_range {
    range_name    = "pods-range"
    ip_cidr_range = "10.20.0.0/16"
  }

  secondary_ip_range {
    range_name    = "services-range"
    ip_cidr_range = "10.30.0.0/20"
  }
}

# 4. Least-Privilege GKE Node Service Account
resource "google_service_account" "gke_nodes" {
  account_id   = "${var.cluster_name}-node-sa"
  display_name = "GKE Kueue Workshop Node SA"
  project      = var.project_id
  depends_on   = [google_project_service.apis]
}

resource "google_project_iam_member" "gke_nodes_default" {
  project = var.project_id
  role    = "roles/container.defaultNodeServiceAccount"
  member  = "serviceAccount:${google_service_account.gke_nodes.email}"
}

# 5. Lab 10: Cloud Storage Bucket with Hierarchical Namespace (HNS) for AI Model Caching & Checkpointing
resource "google_storage_bucket" "ai_storage" {
  name                        = "${var.project_id}-kueue-ai-storage"
  project                     = var.project_id
  location                    = var.region
  storage_class               = "STANDARD"
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"
  force_destroy               = false

  hierarchical_namespace {
    enabled = true
  }

  labels = {
    "workshop"  = "gke-kueue-ai"
    "component" = "lab10-gcsfuse-hns"
    "managed"   = "terraform"
  }

  depends_on = [google_project_service.apis]
}

# 6. Direct Workload Identity Federation IAM Grant (Zero GSA Annotation Required)
resource "google_storage_bucket_iam_member" "lab10_ksa_object_user" {
  bucket = google_storage_bucket.ai_storage.name
  role   = "roles/storage.objectUser"
  member = "principal://iam.googleapis.com/projects/${data.google_project.current.number}/locations/global/workloadIdentityPools/${var.project_id}.svc.id.goog/subject/ns/team-a/sa/lab10-gcsfuse-sa"

  depends_on = [
    google_container_cluster.workshop
  ]
}

