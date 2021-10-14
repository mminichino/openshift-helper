##

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

    customize {
      linux_options {
        host_name = "${each.key}"
        domain    = "${var.domain_name}"
      }
      network_interface {
        ipv4_address = each.value.ip_address
        ipv4_netmask = each.value.ip_mask
      }
    }
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

    customize {
      linux_options {
        host_name = "${each.key}"
        domain    = "${var.domain_name}"
      }
      network_interface {
        ipv4_address = each.value.ip_address
        ipv4_netmask = each.value.ip_mask
      }
    }
  }

  tags = ["${vsphere_tag.Id.id}"]
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

    customize {
      linux_options {
        host_name = "${each.key}"
        domain    = "${var.domain_name}"
      }
      network_interface {
        ipv4_address = each.value.ip_address
        ipv4_netmask = each.value.ip_mask
      }
    }
  }

  tags = ["${vsphere_tag.Id.id}"]
}
