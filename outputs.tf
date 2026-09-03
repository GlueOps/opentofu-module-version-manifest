output "manifest" {
  description = "The version manifest as an object, for use elsewhere in the configuration."
  value       = local.manifest
}

output "manifest_json" {
  description = "The version manifest as a JSON string, identical to what is stored in state."
  value       = jsonencode(local.manifest)
}
