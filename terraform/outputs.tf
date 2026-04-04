output "cluster_name" {
  description = "EKS cluster name"
  value       = aws_eks_cluster.main.name
}

output "cluster_endpoint" {
  description = "EKS cluster API endpoint"
  value       = aws_eks_cluster.main.endpoint
}

output "cluster_certificate_authority_data" {
  description = "Base64-encoded CA certificate for kubectl"
  value       = aws_eks_cluster.main.certificate_authority[0].data
  sensitive   = true
}

output "eso_role_arn" {
  description = "IAM role ARN for External Secrets Operator Pod Identity"
  value       = aws_iam_role.rag_eso.arn
}

output "alb_controller_role_arn" {
  description = "IAM role ARN for ALB Controller Pod Identity"
  value       = aws_iam_role.rag_alb_controller.arn
}
