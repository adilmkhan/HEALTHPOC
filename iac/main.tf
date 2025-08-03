terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.0"
    }
  }
  required_version = ">= 1.2.0"
}

provider "aws" {
  region = var.aws_region
}

# 1. IAM Policy & Role for API Gateway → Firehose
resource "aws_iam_policy" "api_firehose" {
  name        = "API-Firehose"
  description = "Allow API Gateway to put records to Kinesis Firehose"
  policy      = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowFirehosePutRecord"
      Effect = "Allow"
      Action = "firehose:PutRecord"
      Resource = "*"
    }]
  })
}

resource "aws_iam_role" "api_gateway_firehose" {
  name = "APIGateway-Firehose"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "attach_api_firehose" {
  role       = aws_iam_role.api_gateway_firehose.name
  policy_arn = aws_iam_policy.api_firehose.arn
}

# 2. S3 Bucket for Raw Data
resource "aws_s3_bucket" "data_bucket" {
  bucket = var.s3_bucket_name

  lifecycle_rule {
    enabled = true
    expiration {
      days = 30
    }
    noncurrent_version_expiration {
      days = 30
    }
  }
}

# 3. Lambda Function for Firehose Transformation
resource "aws_iam_role" "lambda_exec" {
  name = "lambda-transform-exec"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_lambda_function" "transform_data" {
  function_name = var.lambda_function_name
  role          = aws_iam_role.lambda_exec.arn
  handler       = "index.lambda_handler"
  runtime       = "python3.8"
  filename      = "${path.module}/lambda/transform_data.zip"
  timeout       = 10

  # You will need to zip your Python code into lambda/transform_data.zip
}

# 4. Kinesis Data Firehose Delivery Stream
resource "aws_kinesis_firehose_delivery_stream" "firehose" {
  name        = var.firehose_stream_name
  destination = "s3"

  s3_configuration {
    role_arn           = aws_iam_role.api_firehose.arn
    bucket_arn         = aws_s3_bucket.data_bucket.arn
    buffering_interval = 60
    buffering_size     = 5
    compression_format = "UNCOMPRESSED"
    prefix             = "{timestamp:yyyy/MM/dd/HH}/"
  }

  dynamic "processing_configuration" {
    for_each = [aws_lambda_function.transform_data.arn]
    content {
      enabled = true
      processors {
        type = "Lambda"
        parameters {
          parameter_name  = "LambdaArn"
          parameter_value = aws_lambda_function.transform_data.arn
        }
      }
    }
  }
}

# 5. API Gateway REST API
resource "aws_api_gateway_rest_api" "api" {
  name        = var.api_name
  description = "Ingest endpoint for front-end to send health data"
}

resource "aws_api_gateway_resource" "poc" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  parent_id   = aws_api_gateway_rest_api.api.root_resource_id
  path_part   = "poc"
}

resource "aws_api_gateway_method" "post_poc" {
  rest_api_id   = aws_api_gateway_rest_api.api.id
  resource_id   = aws_api_gateway_resource.poc.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "post_poc_integration" {
  rest_api_id             = aws_api_gateway_rest_api.api.id
  resource_id             = aws_api_gateway_resource.poc.id
  http_method             = aws_api_gateway_method.post_poc.http_method
  integration_http_method = "POST"
  type                    = "AWS"
  uri                     = "arn:aws:apigateway:${var.aws_region}:firehose:path//"
  credentials             = aws_iam_role.api_gateway_firehose.arn

  request_templates = {
    "application/json" = <<EOF
{
  "DeliveryStreamName": "${aws_kinesis_firehose_delivery_stream.firehose.name}",
  "Record": {
    "Data": "$util.base64Encode($util.escapeJavaScript($input.json('$')).replace('\\', ''))"
  }
}
EOF
  }
}

resource "aws_api_gateway_deployment" "deployment" {
  rest_api_id = aws_api_gateway_rest_api.api.id
  triggers = {
    redeployment = sha1(jsonencode(aws_api_gateway_rest_api.api))
  }
  depends_on = [aws_api_gateway_integration.post_poc_integration]
}

# 6. Athena Database & Table
resource "aws_athena_database" "analytics_db" {
  name   = var.athena_database
  bucket = aws_s3_bucket.data_bucket.bucket
}

resource "aws_athena_table" "ingested_data" {
  name          = var.athena_table
  database_name = aws_athena_database.analytics_db.name

  bucket        = aws_s3_bucket.data_bucket.bucket
  s3_prefix     = "/"

  # Use your modified SQL DDL:
  // Note: Terraform's aws_athena_table currently does not support full DDL inline.
  // You can instead run the DDL via aws_glue_catalog_table or a null_resource with local-exec:
}

resource "null_resource" "create_athena_table" {
  provisioner "local-exec" {
    command = <<EOC
aws athena start-query-execution \
  --query-string "CREATE EXTERNAL TABLE ${var.athena_table} (
    firstname STRING,
    lastname STRING,
    dmhid STRING,
    diastolic INT,
    systolic INT,
    dateofservice STRING,
    dischargedate STRING,
    claim decimal(8,2)
  )
  PARTITIONED BY (datehour STRING)
  ROW FORMAT SERDE 'org.openx.data.jsonserde.JsonSerDe'
  WITH SERDEPROPERTIES ('paths'='firstname,lastname,dmhid,diastolic,systolic,dateofservice,dischargedate,claim')
  LOCATION 's3://${var.s3_bucket_name}/'
  TBLPROPERTIES (
    'projection.enabled' = 'true',
    'projection.datehour.type' = 'date',
    'projection.datehour.format' = 'yyyy/MM/dd/HH',
    'projection.datehour.range' = '2021/01/01/00,NOW',
    'projection.datehour.interval' = '1',
    'projection.datehour.interval.unit' = 'HOURS',
    'storage.location.template' = 's3://${var.s3_bucket_name}/${datehour}/'
  );" \
  --result-configuration "OutputLocation=s3://${var.s3_bucket_name}/athena-results/"
EOC
  }
}
