resource "google_compute_disk" "default" {
  name  = "${var.disk_prefix}-${count.index}"
  type  = "${var.disk_type}"
  count = "${var.itemCount}"  
  zone  = "${var.region}"
  size = "${var.disk_size_gb}"

  dynamic "disk_encryption_key" {
    for_each = var.kms_key_self_link == null ? [] : [1]
    content {
      kms_key_self_link = var.kms_key_self_link
    }
  }

  labels = {
    environment = "${var.environment}"
  }
}
