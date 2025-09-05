terraform {
  backend "s3" {
    bucket = "rds-lambda-terraform-bucket"
    key    = "terraform.tfstate"
    region = "af-south-1"
  }
}


data "aws_iam_policy_document" "assume_role_lambda" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

data "aws_iam_policy_document" "assume_role_eventbridge" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "iam_for_lambda" {
  name               = "iam_for_lambda"
  assume_role_policy = data.aws_iam_policy_document.assume_role_lambda.json
}

resource "aws_iam_role" "iam_for_eventbridge" {
  name               = "iam_for_eventbridge"
  assume_role_policy = data.aws_iam_policy_document.assume_role_eventbridge.json
}

# Permissions policy: full RDS access
data "aws_iam_policy_document" "lambda_rds_access" {
  statement {
    effect = "Allow"

    actions = [
        "rds:DescribeDBClusterParameters",
        "rds:StartDBCluster",
        "rds:StopDBCluster",
        "rds:StopDBInstance",
        "rds:StartDBInstance",
        "rds:ListTagsForResource",
        "rds:DescribeDBInstances",
        "rds:DescribeSourceRegions",
        "rds:DescribeDBClusterEndpoints",
        "rds:DescribeDBClusters",
        "rds:ModifyDBInstance",
        "logs:CreateLogStream",
        "logs:PutLogEvents"
    ]

    resources = ["*"]
  }
}

data "aws_iam_policy_document" "eventbridge_lambda_access" {
  statement {
    effect = "Allow"

    actions = [
        "lambda:InvokeFunction"
    ]

    resources = ["*"]
  }
}

# Create IAM policy from the above document
resource "aws_iam_policy" "lambda_rds_policy" {
  name   = "lambda_rds_full_access"
  policy = data.aws_iam_policy_document.lambda_rds_access.json
}

resource "aws_iam_policy" "eventbridge_lambda_policy" {
  name   = "eventbridge_lambda_access"
  policy = data.aws_iam_policy_document.eventbridge_lambda_access.json
}

# Attach the RDS access policy to the Lambda role
resource "aws_iam_role_policy_attachment" "lambda_rds_policy_attach" {
  role       = aws_iam_role.iam_for_lambda.name
  policy_arn = aws_iam_policy.lambda_rds_policy.arn
}

resource "aws_iam_role_policy_attachment" "eventbridge_lambda_policy_attach" {
  role       = aws_iam_role.iam_for_eventbridge.name
  policy_arn = aws_iam_policy.eventbridge_lambda_policy.arn
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "rds_stop.py"
  output_path = "rds_stop_code.zip"
}

resource "aws_lambda_function" "lambda_rds_stop" {
  filename      = "rds_stop_code.zip"
  function_name = "${var.lambda_function_name}"
  role          = aws_iam_role.iam_for_lambda.arn
  handler       = "rds_stop.lambda_handler"  # <filename>.<function_name>
  timeout = 900

  source_code_hash = data.archive_file.lambda.output_base64sha256

  runtime = "python3.13"
  depends_on = [
    aws_iam_role_policy_attachment.lambda_rds_policy_attach,
    aws_cloudwatch_log_group.lambda_rds_stop_log_group,
  ]

}

resource "aws_cloudwatch_log_group" "lambda_rds_stop_log_group" {
  name = "/aws/lambda/${var.lambda_function_name}"
  retention_in_days= 30  
}



module "eventbridge" {
  source = "terraform-aws-modules/eventbridge/aws"
  # bus_name = "default"
  create_bus = false
  

  attach_lambda_policy = true
  lambda_target_arns   = ["${aws_lambda_function.lambda_rds_stop.arn}"]

  schedules = {
    lambda-cron = {
      description         = "Trigger for Lambda"
      schedule_expression = "rate(1 day)"
      arn                 = "${aws_lambda_function.lambda_rds_stop.arn}"
      input               = jsonencode({ "job" : "cron-by-rate" })
      role_arn = aws_iam_role.iam_for_eventbridge.arn
    }
  }
}