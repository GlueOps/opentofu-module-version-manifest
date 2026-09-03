# A nested local call, so the manifest shows a child key ("local_path.nested").
module "nested" {
  source = "./nested"
}

output "text" { value = "local module -> ${module.nested.text}" }
