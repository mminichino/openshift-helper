output infra-id {
  value = "${var.infra_id}"
}

output "master_nodes" {
  value = [
  for instance in vsphere_virtual_machine.master_node:
  instance.name
  ]
}

output "worker_nodes" {
  value = [
  for instance in vsphere_virtual_machine.worker_node:
  instance.name
  ]
}
