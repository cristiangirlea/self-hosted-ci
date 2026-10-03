variable "domain" {
  description = "The lab domain, for example lab.example.com: its zone must be in the Cloudflare account."
  type        = string
}

variable "comment" {
  description = "Comment on the DNS record, so whoever looks at the zone knows what manages it."
  type        = string
  default     = "Local Kubernetes lab; managed by OpenTofu."
}
