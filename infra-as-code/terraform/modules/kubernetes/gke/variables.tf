variable "project_id" {
  description = "project id"
}

variable "region" {
  description = "region"
}

variable "gke_username" {
  description = "gke username"
}

variable "gke_password" {
  description = "gke password"
}

variable "min_node_count" {
  description = "mininum number of gke nodes"
}

variable "max_node_count" {
  description = "maximum number of gke nodes"
}

variable "machine_type" {
  description = "machine type"
}

variable "initial_node_count" {
  description = "initial node count"
}

variable "cidr_range" {
  description = "cidr_range"
}

variable "flow_logs" {
  description = "Enable VPC Flow Logs for the GKE subnet"
  default     = false
}

variable "flow_logs_sampling" {
  description = "Flow log sampling rate for the GKE subnet"
  default     = 0.5
}

variable "flow_logs_metadata" {
  description = "Metadata setting for the GKE subnet flow logs"
  default     = "INCLUDE_ALL_METADATA"
}

variable "cluster_resource_labels" {
  description = "Resource labels to apply to the GKE cluster"
  type        = map(string)
  default     = {}
}

variable "node_disk_type" {
  description = "Boot disk type for GKE nodes"
  default     = "pd-standard"
}

variable "boot_disk_kms_key" {
  description = "Customer-managed encryption key for GKE node boot disks"
  default     = null
}
