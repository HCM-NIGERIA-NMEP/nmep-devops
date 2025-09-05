variable "lambda_function_name" {
  default = "lambda_rds_stop"
}

variable "s3_tfstate_name"{
  default = "terraform.tfstate"
}

variable "s3_backend_region" {
  default = "af-south-1"
}