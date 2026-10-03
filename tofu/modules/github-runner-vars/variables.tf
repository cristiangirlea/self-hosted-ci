variable "repos" {
  description = "Repositories whose Linux CI jobs run on the cluster's runners: the REPOS in config.mk."
  type        = list(string)
  default     = []
}

variable "prefix" {
  description = "Prefix of the runner scale set names; each repo's CI_RUNNER is <prefix>-<repo>, matching RUNNER_PREFIX in the Makefile."
  type        = string
  default     = "lab"
}

variable "windows_repos" {
  description = "Private repositories whose Windows CI jobs run on a runner from runners/windows/install-runner.ps1. Install the runner for a repo before adding it."
  type        = list(string)
  default     = []
}

variable "windows_label" {
  description = "The label install-runner.ps1 gives the Windows runner; each listed repo's CI_RUNNER_WINDOWS."
  type        = string
  default     = "lab-windows"
}
