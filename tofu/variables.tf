variable "github_owner" {
  description = "The GitHub user or organization that owns the repositories: the GITHUB_OWNER in config.mk."
  type        = string
}

variable "domain" {
  description = "The lab domain: the DOMAIN in config.mk."
  type        = string
  default     = "lab.example.test"
}

variable "manage_dns" {
  description = "Create the *.<domain> -> 127.0.0.1 record in Cloudflare (needs CLOUDFLARE_API_TOKEN)."
  type        = bool
  default     = false
}

variable "ci_runner_repos" {
  description = "Repositories whose Linux CI jobs run on the cluster's runners: the REPOS in config.mk."
  type        = list(string)
  default     = []
}

variable "ci_runner_prefix" {
  description = "Prefix of the runner scale set names, matching RUNNER_PREFIX in the Makefile."
  type        = string
  default     = "lab"
}

variable "ci_runner_windows_repos" {
  description = "Private repositories whose Windows CI jobs run on an install-runner.ps1 runner."
  type        = list(string)
  default     = []
}

variable "ci_runner_windows_label" {
  description = "The label install-runner.ps1 gives the Windows runner."
  type        = string
  default     = "lab-windows"
}
