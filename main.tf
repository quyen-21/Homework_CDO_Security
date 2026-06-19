terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# ==============================================================================
# Variables
# ==============================================================================

variable "aws_region" {
  type        = string
  default     = "ap-southeast-1" # Singapore region (phù hợp cho Việt Nam)
  description = "AWS Region to deploy resources"
}

variable "bucket_name" {
  type        = string
  default     = "cdo-security-sensitive-data-bucket"
  description = "Tên duy nhất của S3 Bucket chứa dữ liệu cần quét"
}

variable "alert_email" {
  type        = string
  default     = "hanguyet034@gmail.com"
  description = "Địa chỉ email nhận thông báo từ Amazon SNS"
}

# ==============================================================================
# 1. Amazon S3 Bucket
# ==============================================================================

resource "aws_s3_bucket" "sensitive_data" {
  bucket        = var.bucket_name
  force_destroy = true # Hỗ trợ xoá bucket dễ dàng khi test xong

  tags = {
    Name        = "Sensitive Data Storage"
    Environment = "Security-Demo"
  }
}

# Chặn hoàn toàn truy cập public vào S3 Bucket
resource "aws_s3_bucket_public_access_block" "block_public" {
  bucket = aws_s3_bucket.sensitive_data.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Mã hóa dữ liệu tĩnh (Server-Side Encryption) bằng khóa mặc định SSE-S3
resource "aws_s3_bucket_server_side_encryption_configuration" "encryption" {
  bucket = aws_s3_bucket.sensitive_data.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# ==============================================================================
# 2. Amazon Macie Account Enabler (Bật thủ công trên Console nếu gặp lỗi Subscription)
# ==============================================================================

# resource "aws_macie2_account" "macie" {
#   finding_publishing_frequency = "FIFTEEN_MINUTES"
#   status                       = "ENABLED"
# }

# ==============================================================================
# 3. Amazon SNS Topic & Email Subscription
# ==============================================================================

resource "aws_sns_topic" "macie_alerts" {
  name         = "macie-sensitive-data-alerts"
  display_name = "MacieAlert"
}

resource "aws_sns_topic_subscription" "email_sub" {
  topic_arn = aws_sns_topic.macie_alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# Cấp quyền cho dịch vụ EventBridge ghi tin nhắn vào SNS Topic
resource "aws_sns_topic_policy" "allow_eventbridge" {
  arn    = aws_sns_topic.macie_alerts.arn
  policy = data.aws_iam_policy_document.sns_topic_policy.json
}

data "aws_iam_policy_document" "sns_topic_policy" {
  statement {
    effect  = "Allow"
    actions = ["SNS:Publish"]

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    resources = [
      aws_sns_topic.macie_alerts.arn
    ]
  }
}

# ==============================================================================
# 4. Amazon EventBridge Rule & Target
# ==============================================================================

# Tạo Rule để bắt sự kiện từ Amazon Macie
resource "aws_cloudwatch_event_rule" "macie_findings" {
  name        = "capture-macie-findings"
  description = "Gui canh bao den SNS khi Macie phat hien du lieu nhay cam"

  event_pattern = jsonencode({
    source      = ["aws.macie"]
    detail-type = ["Macie Finding"]
  })
}

# Chỉ định Target cho EventBridge Rule là SNS Topic
resource "aws_cloudwatch_event_target" "sns_target" {
  rule      = aws_cloudwatch_event_rule.macie_findings.name
  target_id = "SendToSNS"
  arn       = aws_sns_topic.macie_alerts.arn

  # Tùy chọn: Định dạng lại cấu trúc email để trực quan hơn
  input_transformer {
    input_paths = {
      finding_type = "$.detail.type"
      severity     = "$.detail.severity.description"
      bucket_name  = "$.detail.resourcesAffected.s3Bucket.name"
      object_key   = "$.detail.resourcesAffected.s3Object.key"
      finding_arn  = "$.detail.arn"
    }

    input_template = "\"Canh bao Bao mat: Amazon Macie da phat hien du lieu nhay cam tai S3 Bucket: <bucket_name>!\\n\\n- Loai phat hien (Type): <finding_type>\\n- Muc do nghiem trong (Severity): <severity>\\n- Tep tin bi lo (Object Key): <object_key>\\n- Chi tiet Finding ARN: <finding_arn>\\n\\nVui long truy cap AWS Console de xu ly ngay lap tuc.\""
  }
}

# ==============================================================================
# Outputs
# ==============================================================================

output "s3_bucket_name" {
  value       = aws_s3_bucket.sensitive_data.id
  description = "Ten cua S3 Bucket"
}

output "sns_topic_arn" {
  value       = aws_sns_topic.macie_alerts.arn
  description = "ARN cua SNS Topic"
}
