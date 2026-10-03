# The switch that sends a repository's CI jobs to these runners. Workflows read it as
#   runs-on: ${{ vars.CI_RUNNER || 'ubuntu-latest' }}                (Linux, the cluster)
#   runs-on: ${{ vars.CI_RUNNER_WINDOWS || 'windows-latest' }}       (Windows, install-runner.ps1)
# Remove a repository from a list and its next run goes back to GitHub-hosted runners.
resource "github_actions_variable" "ci_runner" {
  for_each = toset(var.repos)

  repository    = each.value
  variable_name = "CI_RUNNER"
  value         = "${var.prefix}-${each.value}"
}

resource "github_actions_variable" "ci_runner_windows" {
  for_each = toset(var.windows_repos)

  repository    = each.value
  variable_name = "CI_RUNNER_WINDOWS"
  value         = var.windows_label
}
