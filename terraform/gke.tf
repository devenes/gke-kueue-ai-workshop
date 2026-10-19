# 1. GKE Standard Zonal Cluster
resource "google_container_cluster" "workshop" {
  name     = var.cluster_name
  project  = var.project_id
  location = var.zone

  remove_default_node_pool = true
  initial_node_count       = 1
  deletion_protection      = false

  network         = google_compute_network.vpc.id
  subnetwork      = google_compute_subnetwork.subnet.id
  networking_mode = "VPC_NATIVE"

  release_channel {
    channel = "REGULAR"
  }

  workload_identity_config {
    workload_pool = "${var.project_id}.svc.id.goog"
  }

  addons_config {
    gcs_fuse_csi_driver_config {
      enabled = true
    }
  }

  ip_allocation_policy {
    cluster_secondary_range_name  = "pods-range"
    services_secondary_range_name = "services-range"
  }

  depends_on = [
    google_project_iam_member.gke_nodes_default
  ]
}

# 2. System Node Pool (For Control-Plane Operators: Kueue & JobSet - 1x e2-standard-2)
resource "google_container_node_pool" "system_pool" {
  name       = "system-pool"
  project    = var.project_id
  location   = var.zone
  cluster    = google_container_cluster.workshop.name
  node_count = 1

  node_config {
    machine_type    = "e2-standard-2"
    disk_size_gb    = 30
    disk_type       = "pd-balanced"
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      "workload" = "system"
    }
  }
}

# 3. On-Demand TAS Node Pools (1x e2-standard-4 each for rack-1 and rack-2 = 8 vCPUs total)
resource "google_container_node_pool" "on_demand_tas" {
  for_each   = toset(["rack-1", "rack-2"])
  name       = "on-demand-${each.key}"
  project    = var.project_id
  location   = var.zone
  cluster    = google_container_cluster.workshop.name
  node_count = 1

  node_config {
    machine_type    = "e2-standard-4"
    disk_size_gb    = 40
    disk_type       = "pd-balanced"
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      "tier"                       = "on-demand"
      "workshop.ai/topology-block" = "block-1"
      "workshop.ai/topology-rack"  = each.key
    }
  }
}

# 4. Atomic Autoscaling Spot Node Pool (0 -> 3x e2-standard-4)
resource "google_container_node_pool" "spot_atomic_pool" {
  name     = "spot-atomic-pool"
  project  = var.project_id
  location = var.zone
  cluster  = google_container_cluster.workshop.name

  initial_node_count = 0

  autoscaling {
    min_node_count  = 0
    max_node_count  = 3
    location_policy = "ANY"
  }

  node_config {
    machine_type    = "e2-standard-4"
    spot            = true
    disk_size_gb    = 40
    disk_type       = "pd-balanced"
    service_account = google_service_account.gke_nodes.email
    oauth_scopes    = ["https://www.googleapis.com/auth/cloud-platform"]

    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    labels = {
      "tier" = "spot"
    }

    taint {
      key    = "spot-only"
      value  = "true"
      effect = "NO_SCHEDULE"
    }
  }
}

