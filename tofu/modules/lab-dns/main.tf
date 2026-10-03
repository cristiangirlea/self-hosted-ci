# The lab domain splits into its first label and the zone: "lab.example.com" is the label "lab"
# in the zone "example.com".
locals {
  label = split(".", var.domain)[0]
  zone  = join(".", slice(split(".", var.domain), 1, length(split(".", var.domain))))
}

data "cloudflare_zone" "lab" {
  filter = {
    name = local.zone
  }
}

# Every *.<domain> name points at loopback: real hostnames in the browser, no hosts-file edits, and
# the record is harmless to anyone else who resolves it.
resource "cloudflare_dns_record" "lab_wildcard" {
  zone_id = data.cloudflare_zone.lab.id
  name    = "*.${local.label}"
  type    = "A"
  content = "127.0.0.1"
  ttl     = 300
  proxied = false
  comment = var.comment
}
