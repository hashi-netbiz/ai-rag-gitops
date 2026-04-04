resource "aws_secretsmanager_secret" "backend" {
  name                    = "rag-project/backend"
  description             = "All backend runtime env vars for RAG RBAC Chatbot (10 keys as JSON)"
  recovery_window_in_days = 30
}
