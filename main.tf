module "aws" {
  source  = "astronomer/astronomer-aws/aws"
  version = "1.1.29"
  # source                        = "../terraform-aws-astronomer-aws"
  deployment_id                 = var.deployment_id
  admin_email                   = var.email
  route53_domain                = var.route53_domain
  vpc_id                        = var.vpc_id
  private_subnets               = var.private_subnets
  enable_bastion                = var.enable_bastion
  enable_windows_box            = var.enable_windows_box
  tags                          = var.tags
  extra_sg_ids_for_eks_security = var.security_groups_to_whitelist_on_eks_api
  min_cluster_size              = var.min_cluster_size
  max_cluster_size              = var.max_cluster_size
  ten_dot_what_cidr             = var.ten_dot_what_cidr
  cluster_type                  = "private"
  # It makes the installation easier to leave
  # this public, then just flip it off after
  # everything is deployed.
  # Otherwise, you have to have some way to
  # access the kube api from terraform:
  # - bastion with proxy
  # - execute terraform from VPC
  management_api = var.management_api
}

# Get the AWS_REGION used by the aws provider
data "aws_region" "current" {}

# install tiller, which is the server-side component
# of Helm, the Kubernetes package manager
module "system_components" {
  dependencies = [module.aws.depended_on]
  source       = "astronomer/astronomer-system-components/kubernetes"
  version      = "0.1.3"
  # source       = "../terraform-kubernetes-astronomer-system-components"
  enable_istio                  = false
  enable_aws_cluster_autoscaler = true
  cluster_name                  = module.aws.cluster_name
  aws_region                    = data.aws_region.current.name
}

module "astronomer" {
  dependencies = [module.system_components.depended_on]
  source       = "astronomer/astronomer/kubernetes"
  version      = "1.0.8"
  # source                = "../terraform-kubernetes-astronomer"
  cluster_type          = "private"
  private_load_balancer = true
  astronomer_version    = "0.9.6"
  base_domain           = module.aws.base_domain
  db_connection_string  = module.aws.db_connection_string
  tls_cert              = module.aws.tls_cert
  tls_key               = module.aws.tls_key
}

data "aws_lambda_invocation" "elb_name" {
  depends_on    = [module.astronomer]
  function_name = "${module.aws.elb_lookup_function_name}"
  input         = "{}"
}

data "aws_elb" "nginx_lb" {
  name = data.aws_lambda_invocation.elb_name.result_map["Name"]
}

data "aws_route53_zone" "selected" {
  name = "${var.route53_domain}."
}

resource "aws_route53_record" "astronomer" {
  zone_id = "${data.aws_route53_zone.selected.zone_id}"
  name    = "*.${var.deployment_id}.${data.aws_route53_zone.selected.name}"
  type    = "CNAME"
  ttl     = "30"
  records = [data.aws_elb.nginx_lb.dns_name]
}
