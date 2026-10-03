# An example root that uses both modules. A repository that builds on this one can use this root
# with its own terraform.tfvars, or call the modules from its own root.
module "runner_vars" {
  source = "./modules/github-runner-vars"

  repos         = var.ci_runner_repos
  prefix        = var.ci_runner_prefix
  windows_repos = var.ci_runner_windows_repos
  windows_label = var.ci_runner_windows_label
}

module "lab_dns" {
  source = "./modules/lab-dns"
  count  = var.manage_dns ? 1 : 0

  domain = var.domain
}
