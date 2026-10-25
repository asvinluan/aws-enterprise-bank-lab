############################################################################
# EKS: AWS running Kubernetes for you (Module 11.4)
# "If ECR is the cupboard, EKS is the kitchen." Your Lambda is a CONSUMER of
# this service, not an operator of it.
#
# COST: the control plane bills every hour, plus the nodes, plus a load balancer.
# Everything in this file is created only when enable_eks = true.
############################################################################
locals {
  eks_on = var.enable_eks ? 1 : 0
}

data "aws_iam_policy_document" "eks_cluster_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "eks_node_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "cluster" {
  count              = local.eks_on
  name               = "${var.prefix}-eks-cluster-role"
  assume_role_policy = data.aws_iam_policy_document.eks_cluster_trust.json
}

resource "aws_iam_role_policy_attachment" "cluster" {
  count      = local.eks_on
  role       = aws_iam_role.cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_iam_role" "node" {
  count              = local.eks_on
  name               = "${var.prefix}-eks-node-role"
  assume_role_policy = data.aws_iam_policy_document.eks_node_trust.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = var.enable_eks ? toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ]) : toset([])

  role       = aws_iam_role.node[0].name
  policy_arn = each.value
}

resource "aws_eks_cluster" "this" {
  count    = local.eks_on
  name     = var.cluster_name
  version  = var.eks_version
  role_arn = aws_iam_role.cluster[0].arn

  vpc_config {
    # The control plane's own network interfaces go in these subnets.
    subnet_ids              = concat(var.private_subnet_ids, var.public_subnet_ids)
    endpoint_private_access = true
    endpoint_public_access  = true
    public_access_cidrs     = var.public_access_cidrs
  }

  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # THE COST GUARD. The default is EXTENDED: when this version's standard
  # support ends, AWS keeps the cluster running and bills 0.60 USD/hour instead
  # of 0.10. STANDARD makes AWS upgrade the cluster instead of billing 6x.
  upgrade_policy {
    support_type = "STANDARD"
  }

  depends_on = [aws_iam_role_policy_attachment.cluster]
}

resource "aws_eks_node_group" "this" {
  count           = local.eks_on
  cluster_name    = aws_eks_cluster.this[0].name
  node_group_name = "${var.prefix}-nodes"
  node_role_arn   = aws_iam_role.node[0].arn

  # privateNetworking: nodes get no public address. They pull images from ECR
  # through the VPC endpoints and reach the internet for updates through the NAT.
  subnet_ids = var.private_subnet_ids

  ami_type       = "AL2023_x86_64_STANDARD"
  instance_types = [var.node_instance_type]
  capacity_type  = "ON_DEMAND"

  scaling_config {
    desired_size = var.node_desired
    min_size     = 1
    max_size     = var.node_desired + 1
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}
