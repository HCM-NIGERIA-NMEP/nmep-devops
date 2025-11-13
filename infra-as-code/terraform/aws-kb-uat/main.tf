terraform {
  backend "s3" {
    bucket = "ng-upgrade-terraform-bucket"
    key    = "terraform-setup/terraform.tfstate"
    region = "af-south-1"
    # The below line is optional depending on whether you are using DynamoDB for state locking and consistency
#     dynamodb_table = "kebbi-prod-terraform-bucket"
    # The below line is optional if your S3 bucket is encrypted
    encrypt = true
  }
  required_providers {
    kubectl = {
      source  = "alekc/kubectl"
      version = ">= 2.0.2"
    }
    kubernetes = {
      source = "hashicorp/kubernetes"
      version = "2.37.1"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.10.1, < 3.0.0"
    }
  }
}

locals {
  az_to_find           = var.availability_zones[0] 
  az_index_in_network  = index(var.network_availability_zones, local.az_to_find)
  ami_type_map = {
    x86_64 = "BOTTLEROCKET_x86_64"
    arm64  = "BOTTLEROCKET_ARM_64"
  }

  # Use user-specified instance_types if provided, else choose from map
  selected_instance_types = length(var.instance_types) > 0 ? var.instance_types : var.instance_types_map[var.architecture]
}

module "network" {
  source             = "../modules/kubernetes/aws/network"
  vpc_cidr_block     = "${var.vpc_cidr_block}"
  cluster_name       = "${var.cluster_name}"
  availability_zones = "${var.network_availability_zones}"
}

# PostGres DB
module "db" {
  source                        = "../modules/db/aws"
  subnet_ids                    = "${module.network.private_subnets}"
  vpc_security_group_ids        = ["${module.network.rds_db_sg_id}"]
  availability_zone             = "${element(var.availability_zones, 0)}"
  instance_class                = "db.t4g.medium"  ## postgres db instance type
  engine_version                = "14.17"   ## postgres version
  storage_type                  = "gp3"
  storage_gb                    = "30" 
  backup_retention_days         = "7"
  administrator_login           = "${var.db_username}"
  administrator_login_password  = "${var.db_password}"
  identifier                    = "${var.cluster_name}-db"
  db_name                       = "${var.db_name}"
  environment                   = "${var.cluster_name}"
}

data "aws_caller_identity" "current" {}

data "tls_certificate" "thumb" {
  url = "${data.aws_eks_cluster.cluster.identity.0.oidc.0.issuer}"
}

resource "aws_iam_role" "eks_iam" {
  name = "${var.cluster_name}-eks"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Sid = "EKSWorkerAssumeRole"
        Effect = "Allow",
        Principal = {
          Federated = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:oidc-provider/${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}"
        },
        Action = "sts:AssumeRoleWithWebIdentity",
        Condition = {
          StringEquals = {
            "${replace(data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer, "https://", "")}:sub" = "system:serviceaccount:kube-system:ebs-csi-controller-sa"
          }
        }
      }
    ]
  })
}

module "eks" {
  source          = "terraform-aws-modules/eks/aws"
  version         = "~> 21.0"
  name    = var.cluster_name
  kubernetes_version = var.kubernetes_version
  vpc_id          = module.network.vpc_id
  # enable_cluster_creator_admin_permissions = true
  create_iam_role = false
  iam_role_arn    = "arn:aws:iam::022499048165:role/ng-upgrade-uat2025040205302058500000000b"
  endpoint_public_access  = true
  endpoint_private_access = true
  endpoint_public_access_cidrs = ["13.244.166.52/32", "45.118.156.19/32"]
  authentication_mode = "API_AND_CONFIG_MAP"
  subnet_ids      = concat(module.network.private_subnets, module.network.public_subnets)
  node_security_group_additional_rules = {
    ingress_self_ephemeral = {
      description = "Node to node communication"
      protocol    = "-1"
      from_port   = 0
      to_port     = 0
      type        = "ingress"
      self        = true
    }
  }

  addons = {
    vpc-cni = {
      most_recent              = true
      before_compute           = true
      configuration_values = jsonencode({
        env = {
          # Reference docs https://docs.aws.amazon.com/eks/latest/userguide/cni-increase-ip-addresses.html
          ENABLE_PREFIX_DELEGATION           = "true"
        }
      })
    }
  }
  node_security_group_tags = {
    "karpenter.sh/discovery" = var.cluster_name
  }
  timeouts = {
    create = "30m"
    delete = "15m"
    update = "60m"
  }
  compute_config = {
    enabled    = false
  }
  tags = {
    "KubernetesCluster" = var.cluster_name
    "Name"              = var.cluster_name
  }
}

module "eks_managed_node_group" {
  source = "terraform-aws-modules/eks/aws//modules/eks-managed-node-group"
  version         = "~> 21.0"
  name            = "${var.cluster_name}"
  ami_type        = local.ami_type_map[var.architecture]
  cluster_name    = var.cluster_name
  kubernetes_version = var.kubernetes_version
  subnet_ids      = [module.network.private_subnets[local.az_index_in_network]]
  vpc_security_group_ids  = [module.eks.node_security_group_id]
  cluster_service_cidr = module.eks.cluster_service_cidr
  use_custom_launch_template = true
  launch_template_name = "${var.cluster_name}-lt"
  block_device_mappings = {
    xvda = {
      device_name = "/dev/xvda"
      ebs = {
        volume_size           = 100
        volume_type           = "gp3"
        delete_on_termination = true
      }
    }
  }
  min_size     = var.min_worker_nodes
  max_size     = var.max_worker_nodes
  desired_size = var.desired_worker_nodes
  instance_types = local.selected_instance_types
  capacity_type  = "ON_DEMAND"
  ebs_optimized  = "true"
  enable_monitoring = "true"
  iam_role_additional_policies = {
    CSI_DRIVER_POLICY = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    SQS_POLICY                   = "arn:aws:iam::aws:policy/AmazonSQSFullAccess"
  }
  update_config = {
    "max_unavailable_percentage": 10
  }
  labels = {
    Environment = var.cluster_name
  }
  tags = {
    "KubernetesCluster" = var.cluster_name
    "Name"              = var.cluster_name
  }
}

module "ebs_csi_driver_irsa" {
  depends_on = [module.eks]
  source  = "terraform-aws-modules/iam/aws//modules/iam-role-for-service-accounts-eks"
  version = "~> 5.20"
  role_name_prefix = "ebs-csi-driver-"
  attach_ebs_csi_policy = true
  oidc_providers = {
    main = {
      provider_arn               = module.eks.oidc_provider_arn
      namespace_service_accounts = ["kube-system:ebs-csi-controller-sa"]
    }
  }
  tags = {
    "KubernetesCluster" = var.cluster_name
    "Name"              = var.cluster_name
  }
}

module "bastion" {
  source                        = "../modules/kubernetes/aws/bastion"
  cluster_name                  = var.cluster_name
  public_subnet_id              = module.network.public_subnets[0]
  vpc_id                        = module.network.vpc_id  
}

# resource "kubernetes_service_account" "ebs_csi_controller_sa" {
#   metadata {
#     name      = "ebs-csi-controller-sa"
#     namespace = "kube-system"
#   }
# } 

# resource "kubernetes_annotations" "example" {
#   api_version = "v1"
#   kind        = "ServiceAccount"
#   depends_on  = ["kubernetes_service_account.ebs_csi_controller_sa"]
#   metadata {
#     name = "ebs-csi-controller-sa"
#     namespace = "kube-system"
#   }
#   annotations = {
#     # "eks.amazonaws.com/role-arn" = "arn:aws:iam::022499048165:role/ng-upgrade-uat-eks"
#     "eks.amazonaws.com/role-arn" = "${aws_iam_role.eks_iam.arn}"
#   }
# }

resource "aws_iam_role_policy_attachment" "cluster_AmazonEBSCSIDriverPolicy" {
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
  role       = "${aws_iam_role.eks_iam.name}"
}

resource "aws_iam_role_policy_attachment" "cluster_AmazonEC2FullAccess" {
  policy_arn = "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
  role       = "${aws_iam_role.eks_iam.name}"
}

# resource "aws_iam_openid_connect_provider" "eks_oidc_provider" {
#   client_id_list = ["sts.amazonaws.com"]
#   thumbprint_list = ["${data.tls_certificate.thumb.certificates.0.sha1_fingerprint}"] # This should be empty or provide certificate thumbprints if needed
#   url            = "${data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer}" # Replace with the OIDC URL from your EKS cluster details

# }
resource "aws_security_group_rule" "rds_db_ingress_workers" {
  description              = "Allow node groups to communicate with RDS database"
  from_port                = 5432
  to_port                  = 5432
  protocol                 = "tcp"
  security_group_id        = module.network.rds_db_sg_id
  source_security_group_id = module.eks.node_security_group_id
  type                     = "ingress"
}

data "aws_iam_openid_connect_provider" "oidc_arn" {
  depends_on = [module.eks_managed_node_group]
  url = data.aws_eks_cluster.cluster.identity.0.oidc.0.issuer
}

# Fetching EKS Cluster Data after its creation
data "aws_eks_cluster" "cluster" {
  depends_on = [module.eks_managed_node_group]
  name = var.cluster_name
}

data "aws_eks_cluster_auth" "cluster" {
  depends_on = [module.eks_managed_node_group]
  name = var.cluster_name
}

resource "aws_eks_addon" "kube_proxy" {
  depends_on = [module.eks_managed_node_group]
  cluster_name      = var.cluster_name
  addon_name        = "kube-proxy"
  resolve_conflicts_on_create = "OVERWRITE"
}
resource "aws_eks_addon" "core_dns" {
  depends_on = [module.eks_managed_node_group]
  cluster_name      = var.cluster_name
  addon_name        = "coredns"
  resolve_conflicts_on_create = "OVERWRITE"
}
resource "aws_eks_addon" "aws_ebs_csi_driver" {
  depends_on = [module.eks_managed_node_group]
  cluster_name      = var.cluster_name
  addon_name        = "aws-ebs-csi-driver"
  service_account_role_arn = module.ebs_csi_driver_irsa.iam_role_arn
  resolve_conflicts_on_create = "OVERWRITE"
  resolve_conflicts_on_update = "OVERWRITE"
}

resource "aws_eks_addon" "eks-pod-identity-agent" {
  count = var.enable_karpenter ? 1 : 0
  depends_on = [module.eks_managed_node_group]
  cluster_name      = var.cluster_name
  addon_name        = "eks-pod-identity-agent"
  resolve_conflicts_on_create = "OVERWRITE"
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
    command     = "aws"
  }
}

# resource "kubernetes_annotations" "gp2_default" {
#   annotations = {
#     "storageclass.kubernetes.io/is-default-class" : "false"
#   }
#   api_version = "storage.k8s.io/v1"
#   kind        = "StorageClass"
#   metadata {
#     name = "gp2"
#   }

#   force = true
#   depends_on = [aws_eks_addon.aws_ebs_csi_driver]
# }

resource "kubernetes_storage_class" "ebs_csi_encrypted_gp3_storage_class" {
  metadata {
    name = "gp3"
    annotations = {
      "storageclass.kubernetes.io/is-default-class" : "true"
    }
  }

  storage_provisioner    = "ebs.csi.aws.com"
  reclaim_policy         = "Delete"
  allow_volume_expansion = true
  volume_binding_mode    = "WaitForFirstConsumer"
  parameters = {
    fsType    = "ext4"
    encrypted = true
    type      = "gp3"
  }

  # depends_on = [kubernetes_annotations.gp2_default]
}

provider "helm" {
  kubernetes {
    host                   = data.aws_eks_cluster.cluster.endpoint
    cluster_ca_certificate = base64decode(data.aws_eks_cluster.cluster.certificate_authority[0].data)
    # token                  = data.aws_eks_cluster_auth.cluster.token
    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
      command     = "aws"
    }
  }
}

provider "kubectl" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    args        = ["eks", "get-token", "--cluster-name", var.cluster_name]
    command     = "aws"
  }              
}

resource "aws_iam_role_policy" "karpenter_policy" {
  count = var.enable_karpenter ? 1 : 0
  depends_on = [module.eks_managed_node_group]
  name   = "karpenter-policy"
  role   = module.eks_managed_node_group.iam_role_name
  policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [
      {
        "Effect": "Allow",
        "Action": [
          "ec2:DescribeSpotPriceHistory",
          "pricing:GetProducts",
          "ec2:DescribeInstanceTypeOfferings",
          "iam:CreateInstanceProfile",
          "iam:AddRoleToInstanceProfile",
          "ec2:DescribeImages",
          "iam:PassRole",
          "ec2:DescribeLaunchTemplates",
          "ec2:CreateLaunchTemplate",
          "iam:GetInstanceProfile",
          "iam:TagInstanceProfile",
          "ec2:CreateTags",
          "ec2:CreateFleet",
          "ec2:RunInstances",
          "ec2:DeleteLaunchTemplate",
          "ec2:TerminateInstances",
          "iam:RemoveRoleFromInstanceProfile",
          "iam:DeleteInstanceProfile"
        ],
        "Resource": "*"
      }
    ]
  })
}

module "karpenter" {
  count = var.enable_karpenter ? 1 : 0
  version = "21.3.1"
  source = "terraform-aws-modules/eks/aws//modules/karpenter"
  cluster_name = module.eks.cluster_name

  create_node_iam_role = false
  node_iam_role_arn    = module.eks_managed_node_group.iam_role_arn

  # Since the node group role will already have an access entry
  create_access_entry = false

  tags = {
    Environment = var.cluster_name
    Terraform   = "true"
    "KubernetesCluster" = var.cluster_name
  }
}

resource "helm_release" "karpenter-crd" {
  count = var.enable_karpenter ? 1 : 0
  namespace           = "kube-system"
  name                = "karpenter-crd"
  repository          = "oci://public.ecr.aws/karpenter"
  chart               = "karpenter-crd"
  version             = "1.8.1"
  wait                = true
  values = []
}

resource "helm_release" "karpenter" {
  count = var.enable_karpenter ? 1 : 0
  depends_on = [ helm_release.karpenter-crd ]
  namespace           = "kube-system"
  name                = "karpenter"
  repository          = "oci://public.ecr.aws/karpenter"
  chart               = "karpenter"
  version             = "1.8.1"
  wait                = false
  skip_crds           = true

  values = [
    <<-EOT
    logLevel: info
    serviceAccount:
      name: ${var.enable_karpenter ? module.karpenter[0].service_account : ""}
    settings:
      clusterName: ${module.eks.cluster_name}
      clusterEndpoint: ${module.eks.cluster_endpoint}
      interruptionQueue: ${var.enable_karpenter ? module.karpenter[0].queue_name : ""}
    EOT
  ]
}

resource "kubectl_manifest" "karpenter_node_class" {
  count = var.enable_karpenter ? 1 : 0
  yaml_body = <<-YAML
    apiVersion: karpenter.k8s.aws/v1
    kind: EC2NodeClass
    metadata:
      name: default
    spec:
      amiFamily: Bottlerocket
      amiSelectorTerms:
      - id: ami-004f5306b98d06eff
      role: ${module.eks_managed_node_group.iam_role_name}
      subnetSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}
      securityGroupSelectorTerms:
        - tags:
            karpenter.sh/discovery: ${module.eks.cluster_name}
      tags:
        KubernetesCluster: ${var.cluster_name}
        karpenter.sh/discovery: ${module.eks.cluster_name}
    status:
  amis:
  - id: var.ami_id.id
    name: var.ami_id.name
    requirements:
    - key: kubernetes.io/arch
      operator: In
      values:
      - amd64
  YAML

  depends_on = [
    helm_release.karpenter
  ]
}

resource "kubectl_manifest" "karpenter_node_pool" {
  count = var.enable_karpenter ? 1 : 0
  yaml_body = <<-YAML
    apiVersion: karpenter.sh/v1
    kind: NodePool
    metadata:
      name: default
    spec:
      template:
        spec:
          nodeClassRef:
            name: default
            group: karpenter.k8s.aws  # Updated since only a single version will be served
            kind: EC2NodeClass
          requirements:
            - key: "karpenter.k8s.aws/instance-category"
              operator: In
              values: ["r"]
            - key: "karpenter.k8s.aws/instance-family"
              operator: In
              values: ["r6i"]
            - key: "node.kubernetes.io/instance-type"
              operator: Exists
              values: ["r6i.large"]
            - key: "karpenter.k8s.aws/instance-cpu"
              operator: In
              values: ["2"]
            - key: "kubernetes.io/arch"
              operator: In
              values: ["amd64"]
            - key: "karpenter.sh/capacity-type"
              operator: In
              values: ["on-demand"]
            - key: "karpenter.k8s.aws/instance-generation"
              operator: In
              values: ["6"]
      disruption:
        consolidationPolicy: WhenEmptyOrUnderutilized
        consolidateAfter: 1m
        budgets:
        - nodes: "80%"
          reasons: 
          - "Empty"
          - "Drifted"
        - nodes: "50%"
          reasons: 
          - "Underutilized"
  YAML

  depends_on = [
    kubectl_manifest.karpenter_node_class
  ]
}

module "eks-cluster-autoscaler" {
  count = var.enable_ClusterAutoscaler ? 1 : 0
  source  = "lablabs/eks-cluster-autoscaler/aws"
  version = "3.1.0"
  cluster_name = var.cluster_name
  cluster_identity_oidc_issuer = data.aws_eks_cluster.cluster.identity[0].oidc[0].issuer
  cluster_identity_oidc_issuer_arn = data.aws_iam_openid_connect_provider.oidc_arn.arn
  irsa_role_name = var.cluster_name
  namespace = "autoscaler"
  service_account_name = "cluster-autoscaler"
  service_account_namespace = "autoscaler"
  values = yamlencode({
    extraArgs = {
      logtostderr: true
      stderrthreshold: "info"
      v: 4
      scale-down-utilization-threshold: 0.6
    }
  })
}




module "es-master" {

  source = "../modules/storage/aws"
  storage_count = 3
  environment = "${var.cluster_name}"
  disk_prefix = "es-master"
  availability_zones = "${var.availability_zones}"
  storage_sku = "gp3"
  disk_size_gb = "10"
  
}
module "es-data" {

  source = "../modules/storage/aws"
  storage_count = 3
  environment = "${var.cluster_name}"
  disk_prefix = "es-data"
  availability_zones = "${var.availability_zones}"
  storage_sku = "gp3"
  disk_size_gb = "100"
  
}

module "kafka-kraft" {

  source = "../modules/storage/aws"
  storage_count = 3
  environment = "${var.cluster_name}"
  disk_prefix = "kafka-kraft"
  availability_zones = "${var.availability_zones}"
  storage_sku = "gp3"
  disk_size_gb = "100"
  
}


