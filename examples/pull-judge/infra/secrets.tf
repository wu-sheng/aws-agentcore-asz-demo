# Credentials are delivered through Secrets Manager, not exposed in task/runtime
# environment-variable configuration. Local state is ignored and must stay private.
resource "random_password" "pull_token" {
  length  = 48
  special = false
}

resource "aws_secretsmanager_secret" "ingest" {
  name_prefix             = "${local.name}/ingest-"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "ingest" {
  secret_id     = aws_secretsmanager_secret.ingest.id
  secret_string = random_password.asz_ingest_token.result
}

resource "aws_secretsmanager_secret" "server" {
  name_prefix             = "${local.name}/server-"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "server" {
  secret_id = aws_secretsmanager_secret.server.id
  secret_string = jsonencode({
    config = local.asz_config
    tokens = "developer ${sha256(random_password.pull_token.result)}\n"
    cert   = file(var.tls_cert_file)
    key    = file(var.tls_key_file)
  })
}

resource "aws_iam_role_policy" "execution_secrets" {
  name = "read-asz-server-config"
  role = aws_iam_role.task_execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = aws_secretsmanager_secret.server.arn
    }]
  })
}
