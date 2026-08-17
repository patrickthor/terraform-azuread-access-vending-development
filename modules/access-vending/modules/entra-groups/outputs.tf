output "group_object_ids" {
  description = "Entra object ID per group key."
  value       = { for k, g in azuread_group.this : k => g.object_id }
}

output "group_names" {
  description = "display_name per group key. The lookup key for the access-package repo."
  value       = { for k, g in azuread_group.this : k => g.display_name }
}

output "groups" {
  description = "Combined object per group key with id, name, and mail_nickname."
  value = {
    for k, g in azuread_group.this : k => {
      object_id     = g.object_id
      display_name  = g.display_name
      mail_nickname = g.mail_nickname
    }
  }
}
