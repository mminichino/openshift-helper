##

terraform {
  required_providers {
    ignition = {
      source = "terraform-providers/ignition"
    }
    vsphere = {
      source = "hashicorp/vsphere"
    }
  }
}

provider "vsphere" {
  user           = var.vsphere_user
  password       = var.vsphere_password
  vsphere_server = var.vsphere_server
  allow_unverified_ssl = true
}

data "vsphere_datacenter" "dc" {
  name = var.vsphere_datacenter
}

data "vsphere_resource_pool" "pool" {
  name          = "${var.vsphere_cluster}/Resources"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_datastore" "datastore" {
  name          = var.vsphere_datastore
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_distributed_virtual_switch" "dvs" {
  name          = var.vsphere_dvs_switch
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_network" "network" {
  name          = var.vsphere_network
  datacenter_id = data.vsphere_datacenter.dc.id
  distributed_virtual_switch_uuid = data.vsphere_distributed_virtual_switch.dvs.id
}

data "vsphere_virtual_machine" "bootstrap_template" {
  name          = "rhcos-bootstrap"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "master_template" {
  name          = "rhcos-master"
  datacenter_id = data.vsphere_datacenter.dc.id
}

data "vsphere_virtual_machine" "worker_template" {
  name          = "rhcos-worker"
  datacenter_id = data.vsphere_datacenter.dc.id
}

resource "vsphere_tag_category" "Id" {
  name        = "terraform-role-category"
  cardinality = "SINGLE"
  description = "Managed by Terraform"

  associable_types = [
    "VirtualMachine",
  ]
}

resource "vsphere_tag" "Id" {
  name        = "${var.infra_id}"
  category_id = "${vsphere_tag_category.Id.id}"
  description = "OpenShift Infrastructure ID"
}

data "vsphere_folder" "folder" {
  path = "/${var.vsphere_datacenter}/vm/${var.cluster_name}"
}

data "local_file" "bootstrap_ignition" {
  filename = "${var.install_dir}/bootstrap.ign"
}

data "local_file" "master_ignition" {
  filename = "${var.install_dir}/master.ign"
}

data "local_file" "worker_ignition" {
  filename = "${var.install_dir}/worker.ign"
}

#locals {
#  bootstrap_encoded = "data:text/plain;charset=utf-8;base64,${base64encode(data.local_file.bootstrap_ignition)}"
#}

#locals {
#  master_encoded = "data:text/plain;charset=utf-8;base64,${base64encode(data.local_file.master_ignition)}"
#}

#locals {
#  worker_encoded = "data:text/plain;charset=utf-8;base64,${base64encode(data.local_file.worker_ignition)}"
#}

data "ignition_file" "bootstrap_ip" {
  for_each = var.bootstrap_spec
  path = "/etc/sysconfig/network-scripts/ifcfg-ens192"
  mode = "420"
  filesystem = "root"

  content {
    content = templatefile("${path.module}/ifcfg.tmpl", {
      dns_addresses  = var.ip_dns,
      ip_prefix      = var.ip_prefix
      ip_address     = each.value.ip_address
      cluster_domain = "${var.cluster_name}.${var.domain_name}"
      gateway        = var.ip_route
    })
  }
}

data "ignition_file" "master_ip" {
  for_each = var.master_spec
  path     = "/etc/sysconfig/network-scripts/ifcfg-ens192"
  mode     = "420"
  filesystem = "root"

  content {
    content = templatefile("${path.module}/ifcfg.tmpl", {
      dns_addresses  = var.ip_dns,
      ip_prefix      = var.ip_prefix
      ip_address     = each.value.ip_address
      cluster_domain = "${var.cluster_name}.${var.domain_name}"
      gateway        = var.ip_route
    })
  }
}

data "ignition_file" "worker_ip" {
  for_each = var.worker_spec
  path     = "/etc/sysconfig/network-scripts/ifcfg-ens192"
  mode     = "420"
  filesystem = "root"

  content {
    content = templatefile("${path.module}/ifcfg.tmpl", {
      dns_addresses  = var.ip_dns,
      ip_prefix      = var.ip_prefix
      ip_address     = each.value.ip_address
      cluster_domain = "${var.cluster_name}.${var.domain_name}"
      gateway        = var.ip_route
    })
  }
}

data "ignition_config" "bootstrap_ign" {
  for_each = var.bootstrap_spec

  append {
    source = data.local_file.bootstrap_ignition.content
  }

  files = [
#    data.ignition_file.hostname[each.key].rendered,
    data.ignition_file.bootstrap_ip[each.key].rendered,
  ]
}

data "ignition_config" "master_ign" {
  for_each = var.master_spec

  append {
    source = data.local_file.master_ignition.content
  }

  files = [
    #    data.ignition_file.hostname[each.key].rendered,
    data.ignition_file.master_ip[each.key].rendered,
  ]
}

data "ignition_config" "worker_ign" {
  for_each = var.worker_spec

  append {
    source = data.local_file.worker_ignition.content
  }

  files = [
    #    data.ignition_file.hostname[each.key].rendered,
    data.ignition_file.worker_ip[each.key].rendered,
  ]
}

resource "vsphere_virtual_machine" "bootstrap_node" {
  for_each         = var.bootstrap_spec
  name             = "${each.key}"
  num_cpus         = 4
  memory           = 16384
  datastore_id     = data.vsphere_datastore.datastore.id
  resource_pool_id = data.vsphere_resource_pool.pool.id
  guest_id         = data.vsphere_virtual_machine.bootstrap_template.guest_id
  scsi_type        = data.vsphere_virtual_machine.bootstrap_template.scsi_type
  folder           = data.vsphere_folder.folder.path

  wait_for_guest_net_timeout  = "0"
  wait_for_guest_net_routable = "false"

  network_interface {
    network_id = data.vsphere_network.network.id
  }

  disk {
    label = "disk0"
    size = data.vsphere_virtual_machine.bootstrap_template.disks.0.size
    thin_provisioned = data.vsphere_virtual_machine.bootstrap_template.disks.0.thin_provisioned
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.bootstrap_template.id
  }

  extra_config = {
    "guestinfo.ignition.config.data"           = base64encode(data.ignition_config.bootstrap_ign[each.key].rendered)
    "guestinfo.afterburn.initrd.network-kargs" = "ip=${each.value.ip_address}::${var.ip_route}:${var.ip_mask}:${each.key}:ens192:off ${join(" ", formatlist("nameserver=%v", var.ip_dns))}"
  }

  tags = ["${vsphere_tag.Id.id}"]
}

resource "vsphere_virtual_machine" "master_node" {
  for_each         = var.master_spec
  name             = "${each.key}"
  num_cpus         = 4
  memory           = 16384
  datastore_id     = data.vsphere_datastore.datastore.id
  resource_pool_id = data.vsphere_resource_pool.pool.id
  guest_id         = data.vsphere_virtual_machine.master_template.guest_id
  scsi_type        = data.vsphere_virtual_machine.master_template.scsi_type
  folder           = data.vsphere_folder.folder.path

  wait_for_guest_net_timeout  = "0"
  wait_for_guest_net_routable = "false"

  network_interface {
    network_id = data.vsphere_network.network.id
  }

  disk {
    label = "disk0"
    size = data.vsphere_virtual_machine.master_template.disks.0.size
    thin_provisioned = data.vsphere_virtual_machine.master_template.disks.0.thin_provisioned
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.master_template.id
  }

  extra_config = {
    "guestinfo.ignition.config.data"           = base64encode(data.ignition_config.master_ign[each.key].rendered)
    "guestinfo.afterburn.initrd.network-kargs" = "ip=${each.value.ip_address}::${var.ip_route}:${var.ip_mask}:${each.key}:ens192:off ${join(" ", formatlist("nameserver=%v", var.ip_dns))}"
  }

  tags = ["${vsphere_tag.Id.id}"]
  depends_on = [vsphere_virtual_machine.bootstrap_node]
}

resource "vsphere_virtual_machine" "worker_node" {
  for_each         = var.worker_spec
  name             = "${each.key}"
  num_cpus         = 4
  memory           = 16384
  datastore_id     = data.vsphere_datastore.datastore.id
  resource_pool_id = data.vsphere_resource_pool.pool.id
  guest_id         = data.vsphere_virtual_machine.worker_template.guest_id
  scsi_type        = data.vsphere_virtual_machine.worker_template.scsi_type
  folder           = data.vsphere_folder.folder.path

  wait_for_guest_net_timeout  = "0"
  wait_for_guest_net_routable = "false"

  network_interface {
    network_id = data.vsphere_network.network.id
  }

  disk {
    label = "disk0"
    size = data.vsphere_virtual_machine.worker_template.disks.0.size
    thin_provisioned = data.vsphere_virtual_machine.worker_template.disks.0.thin_provisioned
  }

  clone {
    template_uuid = data.vsphere_virtual_machine.worker_template.id
  }

  extra_config = {
    "guestinfo.ignition.config.data"           = base64encode(data.ignition_config.worker_ign[each.key].rendered)
    "guestinfo.afterburn.initrd.network-kargs" = "ip=${each.value.ip_address}::${var.ip_route}:${var.ip_mask}:${each.key}:ens192:off ${join(" ", formatlist("nameserver=%v", var.ip_dns))}"
  }

  tags = ["${vsphere_tag.Id.id}"]
  depends_on = [vsphere_virtual_machine.master_node]
}
