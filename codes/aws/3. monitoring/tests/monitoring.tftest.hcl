mock_provider "aws" {
  mock_data "aws_eks_node_groups" {
    defaults = { names = ["test-web", "test-was"] }
  }
  mock_data "aws_eks_node_group" {
    defaults = { resources = [{ autoscaling_groups = [{ name = "eks-managed-asg" }] }] }
  }
  mock_data "aws_cloudwatch_log_groups" {
    defaults = { log_group_names = [] }
  }
}
mock_provider "aws" { alias = "us_east_1" }
mock_provider "archive" {}
variables { eks_cluster_name = "test-eks" }
run "alarm_uses_discovered_asgs" {
  command = plan
  assert {
    condition     = alltrue([for name in local.node_asg_names : name == "eks-managed-asg"]) && length(local.node_asg_names) == 2
    error_message = "Node health metrics must refer to EKS-managed ASGs."
  }
}
