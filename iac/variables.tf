variable "aws_region" {
  description = "AWS region to deploy resources in"
  type        = string
  default     = "us-east-1"
}

variable "s3_bucket_name" {
  description = "Name of the S3 bucket for ingested data"
  type        = string
}

variable "firehose_stream_name" {
  description = "Name for the Kinesis Firehose delivery stream"
  type        = string
  default     = "ingest-firehose-stream"
}

variable "lambda_function_name" {
  description = "Name of the data-transform Lambda function"
  type        = string
  default     = "transform-data"
}

variable "api_name" {
  description = "Name of the API Gateway REST API"
  type        = string
  default     = "clickstream-ingest-poc"
}

variable "athena_database" {
  description = "Athena database for the ingested data"
  type        = string
  default     = "my_analysis_db"
}

variable "athena_table" {
  description = "Athena table for streaming data"
  type        = string
  default     = "my_ingested_data"
}
