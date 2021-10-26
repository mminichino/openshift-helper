#
# Connect to NSX-T
terraform {
  required_providers {
    nsxt = {
      source = "vmware/nsxt"
    }
  }
}

provider "nsxt" {
  host = var.nsxt_manager
  username = var.nsxt_user
  password = var.nsxt_password
  allow_unverified_ssl = true
}

data "nsxt_policy_lb_app_profile" "default-tcp-lb-app-profile" {
  type         = "TCP"
  display_name = "default-tcp-lb-app-profile"
}

data "nsxt_policy_lb_persistence_profile" "default-source-ip-lb-persistence-profile" {
  type         = "SOURCE_IP"
  display_name = "default-source-ip-lb-persistence-profile"
}

resource "nsxt_lb_tcp_monitor" "ocp4-admin" {
  description  = "ocp4-admin provisioned by Terraform"
  display_name = "ocp4-admin"
  fall_count   = 3
  interval     = 5
  monitor_port = 6443
  rise_count   = 3
  timeout      = 5
}

resource "nsxt_lb_tcp_monitor" "ocp4-config" {
  description  = "ocp4-config provisioned by Terraform"
  display_name = "ocp4-config"
  fall_count   = 3
  interval     = 5
  monitor_port = 22623
  rise_count   = 3
  timeout      = 5
}

resource "nsxt_lb_tcp_monitor" "ocp4-http" {
  description  = "ocp4-http provisioned by Terraform"
  display_name = "ocp4-http"
  fall_count   = 3
  interval     = 5
  monitor_port = 80
  rise_count   = 3
  timeout      = 5
}

resource "nsxt_lb_tcp_monitor" "ocp4-https" {
  description  = "ocp4-https provisioned by Terraform"
  display_name = "ocp4-https"
  fall_count   = 3
  interval     = 5
  monitor_port = 443
  rise_count   = 3
  timeout      = 5
}

#
# Master Group
resource "nsxt_policy_group" "ocp4-master" {
  display_name = "${var.cluster_name}-master"
  description = "Terraform provisioned Group"

  criteria {
    ipaddress_expression {
      ip_addresses = "${var.master_list}"
    }
  }
}

#
# Worker Group
resource "nsxt_policy_group" "ocp4-worker" {
  display_name = "${var.cluster_name}-worker"
  description = "Terraform provisioned Group"

  criteria {
    ipaddress_expression {
      ip_addresses = "${var.worker_list}"
    }
  }
}

# Admin Pool
resource "nsxt_policy_lb_pool" "ocp4-admin" {
  display_name = "${var.cluster_name}-api-admin"
  description = "Terraform provisioned LB Pool"
  algorithm = "ROUND_ROBIN"
  active_monitor_path = "/infra/lb-monitor-profiles/ocp4-admin"

  member_group {
    group_path = nsxt_policy_group.ocp4-master.path
    allow_ipv4 = true
    allow_ipv6 = false
  }
}

# Config Pool
resource "nsxt_policy_lb_pool" "ocp4-config" {
  display_name = "${var.cluster_name}-api-config"
  description = "Terraform provisioned LB Pool"
  algorithm = "ROUND_ROBIN"
  active_monitor_path = "/infra/lb-monitor-profiles/ocp4-config"

  member_group {
    group_path = nsxt_policy_group.ocp4-master.path
    allow_ipv4 = true
    allow_ipv6 = false
  }
}

# HTTP Pool
resource "nsxt_policy_lb_pool" "ocp4-http" {
  display_name = "${var.cluster_name}-http"
  description = "Terraform provisioned LB Pool"
  algorithm = "IP_HASH"
  active_monitor_path = "/infra/lb-monitor-profiles/ocp4-http"

  member_group {
    group_path = nsxt_policy_group.ocp4-worker.path
    allow_ipv4 = true
    allow_ipv6 = false
  }
}

# HTTPS Pool
resource "nsxt_policy_lb_pool" "ocp4-https" {
  display_name = "${var.cluster_name}-https"
  description = "Terraform provisioned LB Pool"
  algorithm = "IP_HASH"
  active_monitor_path = "/infra/lb-monitor-profiles/ocp4-https"

  member_group {
    group_path = nsxt_policy_group.ocp4-worker.path
    allow_ipv4 = true
    allow_ipv6 = false
  }
}

data "nsxt_policy_edge_cluster" "edge-cluster" {
  display_name = "${var.edge_cluster}"
}

resource "nsxt_policy_tier1_gateway" "ocp4-t1-gw" {
  display_name = "${var.cluster_name}-t1-gw"
  description = "Terraform provisioned Tier-1 Gateway"
  failover_mode = "NON_PREEMPTIVE"
  edge_cluster_path = data.nsxt_policy_edge_cluster.edge-cluster.path
  route_advertisement_types = [
    "TIER1_STATIC_ROUTES",
    "TIER1_CONNECTED",
    "TIER1_NAT",
    "TIER1_LB_VIP",
    "TIER1_LB_SNAT",
    "TIER1_IPSEC_LOCAL_ENDPOINT"]
  pool_allocation = "LB_SMALL"
}

resource "nsxt_policy_tier1_gateway_interface" "ocp4-t1-gw-if1" {
  display_name           = "${var.cluster_name}-if1"
  description            = "Terraform provisioned Tier-1 Gateway Service Interface"
  gateway_path           = nsxt_policy_tier1_gateway.ocp4-t1-gw.path
  segment_path           = "/infra/segments/${var.segment_name}"
  subnets                = ["${var.segment_address}"]
  mtu                    = 1500
  depends_on = [nsxt_policy_tier1_gateway.ocp4-t1-gw]
}

resource "nsxt_policy_static_route" "ocp4-t1-gw-default-route" {
  display_name = "${var.cluster_name}-default-route"
  gateway_path = nsxt_policy_tier1_gateway.ocp4-t1-gw.path
  network      = "0.0.0.0/0"

  next_hop {
    admin_distance = "1"
    ip_address     = "${var.segment_router}"
  }
  depends_on = [nsxt_policy_tier1_gateway.ocp4-t1-gw]
}

resource "nsxt_policy_lb_service" "ocp4-lb" {
  display_name      = "ocp4-lb"
  description       = "Terraform provisioned Service"
  connectivity_path = nsxt_policy_tier1_gateway.ocp4-t1-gw.path
  size              = "SMALL"
  enabled           = true
  error_log_level   = "INFO"
  depends_on = [nsxt_policy_tier1_gateway_interface.ocp4-t1-gw-if1]
}

# Create Admin Virtual Server
resource "nsxt_policy_lb_virtual_server" "ocp4-api-admin" {
  display_name = "${var.cluster_name}-api-admin"
  description = "Terraform provisioned Virtual Server"
  access_log_enabled = false
  application_profile_path = data.nsxt_policy_lb_app_profile.default-tcp-lb-app-profile.path
  enabled = true
  ip_address = var.api_vip
  ports = ["6443"]
  default_pool_member_ports = ["6443"]
  service_path = nsxt_policy_lb_service.ocp4-lb.path
  pool_path = nsxt_policy_lb_pool.ocp4-admin.path
}

# Create Config Virtual Server
resource "nsxt_policy_lb_virtual_server" "ocp4-api-config" {
  display_name = "${var.cluster_name}-api-config"
  description = "Terraform provisioned Virtual Server"
  access_log_enabled = false
  application_profile_path = data.nsxt_policy_lb_app_profile.default-tcp-lb-app-profile.path
  enabled = true
  ip_address = var.api_vip
  ports = ["22623"]
  default_pool_member_ports = ["22623"]
  service_path = nsxt_policy_lb_service.ocp4-lb.path
  pool_path = nsxt_policy_lb_pool.ocp4-config.path
}

# Create Config Virtual Server
resource "nsxt_policy_lb_virtual_server" "ocp4-http" {
  display_name = "${var.cluster_name}-http"
  description = "Terraform provisioned Virtual Server"
  access_log_enabled = false
  application_profile_path = data.nsxt_policy_lb_app_profile.default-tcp-lb-app-profile.path
  enabled = true
  ip_address = var.apps_vip
  ports = ["80"]
  default_pool_member_ports = ["80"]
  service_path = nsxt_policy_lb_service.ocp4-lb.path
  pool_path = nsxt_policy_lb_pool.ocp4-http.path
  persistence_profile_path = data.nsxt_policy_lb_persistence_profile.default-source-ip-lb-persistence-profile.path
}

# Create Config Virtual Server
resource "nsxt_policy_lb_virtual_server" "ocp4-https" {
  display_name = "${var.cluster_name}-https"
  description = "Terraform provisioned Virtual Server"
  access_log_enabled = false
  application_profile_path = data.nsxt_policy_lb_app_profile.default-tcp-lb-app-profile.path
  enabled = true
  ip_address = var.apps_vip
  ports = ["443"]
  default_pool_member_ports = ["443"]
  service_path = nsxt_policy_lb_service.ocp4-lb.path
  pool_path = nsxt_policy_lb_pool.ocp4-https.path
  persistence_profile_path = data.nsxt_policy_lb_persistence_profile.default-source-ip-lb-persistence-profile.path
}

output "configuration" {
  value = {
    lb = {
      http = {
        admin = nsxt_policy_lb_virtual_server.ocp4-api-admin
        config = nsxt_policy_lb_virtual_server.ocp4-api-config
        http = nsxt_policy_lb_virtual_server.ocp4-http
        https = nsxt_policy_lb_virtual_server.ocp4-https
      }
    }
  }
}
