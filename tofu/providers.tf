# Credentials come from the environment, never from files in this repo:
#   CLOUDFLARE_API_TOKEN  a token scoped to DNS edit on the one zone
#   GITHUB_TOKEN          `gh auth token` (repo scope; writes the Actions variables)
provider "cloudflare" {}

provider "github" {
  owner = var.github_owner
}
