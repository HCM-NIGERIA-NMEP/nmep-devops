provider "aws" {
  region = "af-south-1"
}

resource "aws_s3_bucket" "terraform_state" {
  bucket = "jigawa-prod-terraform-bucket"

  versioning {
    enabled = true
  }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_dynamodb_table" "terraform_state_lock" {
  name           = "jigawa-prod-terraform-bucket"
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }
}