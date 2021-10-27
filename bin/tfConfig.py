#!/usr/bin/env python

'''
Read OpenShift Install Config and Build Terraform Files
'''

import os
import sys
import argparse
import json
import yaml
import dns.resolver
import re
import dns.reversename
import getpass
import ipaddress
from pyVim.connect import SmartConnectNoSSL, Disconnect
from pyVmomi import vim, vmodl, VmomiSupport
from jinja2 import Template
import base64

class osConfig(object):

    def __init__(self):
        self.configuration = {}
        self.parse_args()

        if not self.outputDir:
            print("Terraform directory is required.")
            sys.exit(1)

        if not self.templateFile:
            homeDir = os.environ['HOME']
            self.templateFile = homeDir + "/.rhcos/rhcos-vmware.x86_64.ova"

        if self.getValue:
            self.getVarValue()
        elif self.cfgFile:
            if self.installDir and self.infraId:
                self.generateConfigs()
            else:
                print("Install directory and infrastructure ID are required.")
                sys.exit(1)
        elif self.nsxCfgFile:
            self.generateNsxConfig()
        elif self.setKey:
            if self.setValue:
                self.updateConfig()

    def updateIgn(self, hostname, role, prefix = [], address = [], domain = None, route = None, dns = []):
        ignFile = self.installDir + '/' + role + '.ign'
        outFile = self.installDir + '/' + hostname + '.ign'
        storageBlock = []
        ifcfg_a = """TYPE=Ethernet
BOOTPROTO=none
NAME=ens192
DEVICE=ens192
ONBOOT=yes
IPADDR={{ ip_address }}
PREFIX={{ ip_prefix }}
{%- if nics == 1 %}
GATEWAY={{ gateway }}
{%- endif %}
DOMAIN={{ domain_name }}
{% for item in dns_list -%}
DNS{{ loop.index }}={{ item }}{{ "
" if not loop.last }}
{%- endfor %}
"""
        ifcfg_b = """TYPE=Ethernet
BOOTPROTO=none
NAME=ens224
DEVICE=ens224
ONBOOT=yes
IPADDR={{ ip_address }}
PREFIX={{ ip_prefix }}
{%- if nics > 1 %}
GATEWAY={{ gateway }}
{%- endif %}
"""

        t = Template(ifcfg_a)
        ifcfgBlock = t.render(ip_address=address[0], ip_prefix=prefix[0], gateway=route, domain_name=domain, dns_list=dns, nics=len(address))
        block_bytes = ifcfgBlock.encode('ascii')
        base64_bytes = base64.b64encode(block_bytes)

        firstNic = {}
        firstNic['filesystem'] = 'root'
        firstNic['path'] = '/etc/sysconfig/network-scripts/ifcfg-ens192'
        firstNic['mode'] = 420
        firstNic['contents'] = {}
        firstNic['contents']['source'] = 'data:text/plain;charset=utf-8;base64,' + base64_bytes.decode('ascii')
        storageBlock.append(firstNic)

        if len(address) > 1:
            t = Template(ifcfg_b)
            ifcfgBlock = t.render(ip_address=address[1], ip_prefix=prefix[1], gateway=route, nics=len(address))
            block_bytes = ifcfgBlock.encode('ascii')
            base64_bytes = base64.b64encode(block_bytes)

            secondNic = {}
            secondNic['filesystem'] = 'root'
            secondNic['path'] = '/etc/sysconfig/network-scripts/ifcfg-ens224'
            secondNic['mode'] = 420
            secondNic['contents'] = {}
            secondNic['contents']['source'] = 'data:text/plain;charset=utf-8;base64,' + base64_bytes.decode('ascii')
            storageBlock.append(secondNic)

        try:
            with open(ignFile, 'r') as jsonFile:
                ignData = json.load(jsonFile)
            jsonFile.close()
        except OSError as e:
            print("Can not open ignition file: %s" % str(e))
            sys.exit(1)

        if 'storage' not in ignData:
            ignData['storage'] = {}
            ignData['storage']['files'] = []
        ignData['storage']['files'].extend(storageBlock)

        try:
            with open(outFile, 'w') as jsonFile:
                json.dump(ignData, jsonFile, indent=2)
                jsonFile.write("\n")
                jsonFile.close()
        except OSError as e:
            print("Can not write to new ignition file: %s" % str(e))
            sys.exit(1)

    def generateConfigs(self):
        variableJson = {}
        variableJson['variable'] = {}
        variableJson['variable'].update({'install_dir': {'default': self.installDir}})
        variableJson['variable'].update({'infra_id': {'default': self.infraId}})
        variableJson['variable'].update({'ova_file': {'default': self.templateFile}})
        variableSaveFile = self.outputDir + '/variables.tf.json'
        foundMaster = False
        foundWorker = False
        foundBootstrap = False
        masterCount = 0
        workerCount = 0
        prefix_list = []
        cfgYaml = None

        try:
            with open(self.cfgFile, 'r') as cfgYamlFile:
                cfgYaml = yaml.safe_load(cfgYamlFile)
        except OSError as e:
                print("Can not open install config file: %s" % str(e))
                sys.exit(1)

        for key in cfgYaml:
            if key == 'platform':
                variableJson['variable'].update({'vsphere_user': {'default': cfgYaml['platform']['vsphere']['username']}})
                variableJson['variable'].update({'vsphere_password': {'default': cfgYaml['platform']['vsphere']['password']}})
                variableJson['variable'].update({'vsphere_server': {'default': cfgYaml['platform']['vsphere']['vCenter']}})
                variableJson['variable'].update({'vsphere_datacenter': {'default': cfgYaml['platform']['vsphere']['datacenter']}})
                variableJson['variable'].update({'vsphere_cluster': {'default': cfgYaml['platform']['vsphere']['cluster']}})
                variableJson['variable'].update({'vsphere_datastore': {'default': cfgYaml['platform']['vsphere']['defaultDatastore']}})
                variableJson['variable'].update({'vsphere_network': {}})
                variableJson['variable']['vsphere_network']['type'] = 'map'
                variableJson['variable']['vsphere_network']['default'] = {}
                variableJson['variable']['vsphere_network']['default']['nic1'] = {}
                variableJson['variable']['vsphere_network']['default']['nic1'].update({'network': cfgYaml['platform']['vsphere']['network']})
            if key == 'compute':
                variableJson['variable'].update({'num_worker': {'default': cfgYaml['compute'][0]['replicas']}})
            if key == 'controlPlane':
                variableJson['variable'].update({'num_master': {'default': cfgYaml['controlPlane']['replicas']}})
            if key == 'baseDomain':
                variableJson['variable'].update({'domain_name': {'default': cfgYaml['baseDomain']}})
            if key == 'metadata':
                variableJson['variable'].update({'cluster_name': {'default': cfgYaml['metadata']['name']}})

        si = SmartConnectNoSSL(host=variableJson['variable']['vsphere_server']['default'],
                               user=variableJson['variable']['vsphere_user']['default'],
                               pwd=variableJson['variable']['vsphere_password']['default'],
                               port=443)

        content = si.RetrieveContent()
        datacenter = None
        container = content.viewManager.CreateContainerView(content.rootFolder, [vim.Datacenter], True)
        for c in container.view:
            if c.name == variableJson['variable']['vsphere_datacenter']['default']:
                datacenter = c
                break
        container.Destroy()

        folder = datacenter.networkFolder
        dvsList = []
        container = content.viewManager.CreateContainerView(folder, [vim.dvs.VmwareDistributedVirtualSwitch], True)
        for managed_object_ref in container.view:
            dvsList.append(managed_object_ref.name)
        container.Destroy()

        pgList = []
        container = content.viewManager.CreateContainerView(folder, [vim.dvs.DistributedVirtualPortgroup], True)
        for managed_object_ref in container.view:
            pgList.append(managed_object_ref.name)
        container.Destroy()
        pgList = sorted(set(pgList))

        while True:
            for i in range(len(dvsList)):
                print(" %d) %s" % (i+1,dvsList[i]))
            switchSelection = input("Virtual Switch [%d-%d]: " % (1, len(dvsList)))
            try:
                int(switchSelection)
            except ValueError:
                continue
            if int(switchSelection) < 1 or int(switchSelection) > len(dvsList):
                continue
            break

        variableJson['variable'].update({'vsphere_dvs_switch': {'default': dvsList[int(switchSelection)-1]}})

        networkMask = cfgYaml['networking']['machineNetwork'][0]['cidr']
        machineNetwork = ipaddress.IPv4Network(networkMask)

        prefix_list.append(str(machineNetwork.prefixlen))

        if self.dualNic:
            while True:
                for i in range(len(pgList)):
                    print(" %d) %s" % (i+1,pgList[i]))
                pgSelection = input("Virtual Switch [%d-%d]: " % (1, len(pgList)))
                try:
                    int(pgSelection)
                except ValueError:
                    continue
                if int(pgSelection) < 1 or int(pgSelection) > len(pgList):
                    continue
                break
            variableJson['variable']['vsphere_network']['default']['nic2'] = {}
            variableJson['variable']['vsphere_network']['default']['nic2'].update({'network': pgList[int(pgSelection)-1]})
            while True:
                network_bits = input("Network Prefix Length for second interface: ")
                try:
                    int(network_bits)
                except ValueError:
                    continue
                if int(network_bits) < 1 or int(network_bits) > 30:
                    continue
                break
            prefix_list.append(network_bits)

        variableJson['variable'].update({'ip_broadcast': {'default': str(machineNetwork.broadcast_address)}})
        variableJson['variable'].update({'ip_mask': {'default': str(machineNetwork.netmask)}})
        variableJson['variable'].update({'ip_prefix': {'default': str(machineNetwork.prefixlen)}})

        variableJson['variable'].update({'bootstrap_spec': {}})
        variableJson['variable']['bootstrap_spec']['type'] = 'map'
        variableJson['variable']['bootstrap_spec']['default'] = {}

        variableJson['variable'].update({'master_spec': {}})
        variableJson['variable']['master_spec']['type'] = 'map'
        variableJson['variable']['master_spec']['default'] = {}

        variableJson['variable'].update({'worker_spec': {}})
        variableJson['variable']['worker_spec']['type'] = 'map'
        variableJson['variable']['worker_spec']['default'] = {}

        domain = variableJson['variable']['cluster_name']['default'] + '.' + variableJson['variable']['domain_name']['default']
        try:
            soa_answer = dns.resolver.query(domain, "SOA", tcp=True)
            soa_host = soa_answer[0].mname

            master_answer = dns.resolver.query(soa_host, "A", tcp=True)
            master_addr = master_answer[0].address

            xfr_answer = dns.query.xfr(master_addr, domain)
            zone = dns.zone.from_xfr(xfr_answer)

            variableJson['variable'].update({'ip_dns': {}})
            variableJson['variable']['ip_dns']['type'] = 'list(string)'
            variableJson['variable']['ip_dns']['default'] = []
            for name, ttl, rdata in zone.iterate_rdatas("NS"):
                dnsServerIp = dns.resolver.query(rdata.to_text(), "A", tcp=True)
                dnsServerIp = dnsServerIp[0].address
                variableJson['variable']['ip_dns']['default'].append(dnsServerIp)

            zone_records = zone.iterate_rdatas("A")
            zone_list = {}
            for name, ttl, rdata in zone_records:
                zone_list.update({name.to_text(): rdata.to_text()})
        except Exception as e:
            print("Could not query domain %s: %s" % (domain, str(e)))
            sys.exit(1)

        defaultRouter=None
        if self.dualNic:
            if 'bootstrap-lb' in zone_list:
                defaultRouter = '.'.join(zone_list['bootstrap-lb'].split('.')[:-1] + ["1"])
            else:
                print("Error: Dual NIC requires hostname-lb DNS entries: bootstrap-lb not found.")
                sys.exit(1)
        else:
            if 'bootstrap' in zone_list:
                defaultRouter = '.'.join(zone_list['bootstrap'].split('.')[:-1]+["1"])
            else:
                print("Error: Cluster configuration requires DNS entries: bootstrap not found.")
                sys.exit(1)

        routeAnswer = input("Default router [%s]: " % defaultRouter)
        if routeAnswer:
            defaultRouter = routeAnswer

        variableJson['variable'].update({'ip_route': {'default': defaultRouter}})

        if 'bootstrap' in zone_list:
            foundBootstrap = True
            address_list = []
            hostBlock = {'bootstrap': {}}
            hostBlock['bootstrap']['host_name'] = 'bootstrap'
            hostBlock['bootstrap']['nic1'] = {}
            hostBlock['bootstrap']['nic1']['ip_address'] = zone_list['bootstrap']
            address_list.append(zone_list['bootstrap'])
            if self.dualNic:
                if 'bootstrap-lb' in zone_list:
                    hostBlock['bootstrap']['nic2'] = {}
                    hostBlock['bootstrap']['nic2']['ip_address'] = zone_list['bootstrap-lb']
                    address_list.append(zone_list['bootstrap-lb'])
            variableJson['variable']['bootstrap_spec']['default'].update(hostBlock)
            self.updateIgn('bootstrap', 'bootstrap', prefix_list, address_list,
                           domain, defaultRouter, variableJson['variable']['ip_dns']['default'])

        index = -1
        while True:
            index = index + 1
            node_name = "master" + str(index)
            if node_name in zone_list:
                foundMaster = True
                masterCount = masterCount + 1
                address_list = []
                hostBlock = {node_name: {}}
                hostBlock[node_name]['host_name'] = node_name
                hostBlock[node_name]['nic1'] = {}
                hostBlock[node_name]['nic1']['ip_address'] = zone_list[node_name]
                address_list.append(zone_list[node_name])
                if self.dualNic:
                    lb_node_name = node_name + '-lb'
                    if lb_node_name in zone_list:
                        hostBlock[node_name]['nic2'] = {}
                        hostBlock[node_name]['nic2']['ip_address'] = zone_list[lb_node_name]
                        address_list.append(zone_list[lb_node_name])
                variableJson['variable']['master_spec']['default'].update(hostBlock)
                self.updateIgn(node_name, 'master', prefix_list, address_list,
                               domain, defaultRouter, variableJson['variable']['ip_dns']['default'])
            else:
                break

            index = -1
            while True:
                index = index + 1
                node_name = "worker" + str(index)
                if node_name in zone_list:
                    foundWorker = True
                    workerCount = workerCount + 1
                    address_list = []
                    hostBlock = {node_name: {}}
                    hostBlock[node_name]['host_name'] = node_name
                    hostBlock[node_name]['nic1'] = {}
                    hostBlock[node_name]['nic1']['ip_address'] = zone_list[node_name]
                    address_list.append(zone_list[node_name])
                    if self.dualNic:
                        lb_node_name = node_name + '-lb'
                        if lb_node_name in zone_list:
                            hostBlock[node_name]['nic2'] = {}
                            hostBlock[node_name]['nic2']['ip_address'] = zone_list[lb_node_name]
                            address_list.append(zone_list[lb_node_name])
                    variableJson['variable']['worker_spec']['default'].update(hostBlock)
                    self.updateIgn(node_name, 'worker', prefix_list, address_list,
                                   domain, defaultRouter, variableJson['variable']['ip_dns']['default'])
                else:
                    break

            variableJson['variable'].update({'master_count': {'default': masterCount}})
            variableJson['variable'].update({'worker_count': {'default': workerCount}})


            if not foundMaster or not foundWorker or not foundBootstrap:
                print("Could not find all required nodes for domain %s." % domain)
                sys.exit(1)

            try:
                with open(variableSaveFile, 'w') as saveFile:
                    json.dump(variableJson, saveFile, indent=4)
                    saveFile.write("\n")
                    saveFile.close()
            except OSError as e:
                    print("Could not write variable file: %s" % str(e))
                    sys.exit(1)

    def getVarValue(self):
        variableFile = self.outputDir + '/variables.tf.json'

        try:
            with open(variableFile, 'r') as tfVars:
                tfVarJson = json.load(tfVars)
                for key in tfVarJson['variable']:
                    if key == self.getValue:
                        print(tfVarJson['variable'][key]['default'])
        except OSError as e:
            print("Can not open terraform variable file: %s" % str(e))
            sys.exit(1)

    def generateNsxConfig(self):
        variableJson = {}
        variableJson['variable'] = {}
        variableSaveFile = self.outputDir + '/variables.tf.json'
        foundMaster = False
        foundWorker = False
        foundBootstrap = False

        useranswer = input("NSX Admin User: ")
        useranswer = useranswer.rstrip("\n")

        passanswer = getpass.getpass()
        passanswer = passanswer.rstrip("\n")

        mgranswer = input("NSX Manager: ")
        mgranswer = mgranswer.rstrip("\n")

        ecName = input("Edge Cluster Name: ")
        ecName = ecName.rstrip("\n")

        segmentName = input("Segment Name: ")
        segmentName = segmentName.rstrip("\n")

        addressName = input("Gateway Service Address: ")
        addressName = addressName.rstrip("\n")

        routerName = input("Gateway Default Router: ")
        routerName = routerName.rstrip("\n")

        try:
            with open(self.nsxCfgFile, 'r') as cfgYamlFile:
                cfgYaml = yaml.safe_load(cfgYamlFile)
                for key in cfgYaml:
                    if key == 'platform':
                        variableJson['variable'].update({'api_vip': {'default': cfgYaml['platform']['vsphere']['apiVIP']}})
                        variableJson['variable'].update({'apps_vip': {'default': cfgYaml['platform']['vsphere']['ingressVIP']}})
                    if key == 'baseDomain':
                        variableJson['variable'].update({'domain_name': {'default': cfgYaml['baseDomain']}})
                    if key == 'metadata':
                        variableJson['variable'].update({'cluster_name': {'default': cfgYaml['metadata']['name']}})

                variableJson['variable'].update({'nsxt_user': {'default': useranswer}})
                variableJson['variable'].update({'nsxt_password': {'default': passanswer}})
                variableJson['variable'].update({'nsxt_manager': {'default': mgranswer}})
                variableJson['variable'].update({'edge_cluster': {'default': ecName}})
                variableJson['variable'].update({'segment_name': {'default': segmentName}})
                variableJson['variable'].update({'segment_address': {'default': addressName}})
                variableJson['variable'].update({'segment_router': {'default': routerName}})

                domain = variableJson['variable']['cluster_name']['default'] + '.' + variableJson['variable']['domain_name']['default']
                try:
                    soa_answer = dns.resolver.query(domain, "SOA", tcp=True)
                    soa_host = soa_answer[0].mname

                    master_answer = dns.resolver.query(soa_host, "A", tcp=True)
                    master_addr = master_answer[0].address

                    xfr_answer = dns.query.xfr(master_addr, domain)
                    zone = dns.zone.from_xfr(xfr_answer)

                    variableJson['variable'].update({'master_list': {}})
                    variableJson['variable']['master_list']['type'] = 'list(string)'
                    variableJson['variable']['master_list']['default'] = []
                    variableJson['variable'].update({'worker_list': {}})
                    variableJson['variable']['worker_list']['type'] = 'list(string)'
                    variableJson['variable']['worker_list']['default'] = []
                    for name, ttl, rdata in zone.iterate_rdatas("A"):
                        pattern = re.compile("^master[0-9]+$")
                        if pattern.match(name.to_text()):
                            foundMaster = True
                            variableJson['variable']['master_list']['default'].append(rdata.to_text())
                        pattern = re.compile("^bootstrap$")
                        if pattern.match(name.to_text()):
                            foundBootstrap = True
                            variableJson['variable']['master_list']['default'].append(rdata.to_text())
                        pattern = re.compile("^worker[0-9]+$")
                        if pattern.match(name.to_text()):
                            foundWorker = True
                            variableJson['variable']['worker_list']['default'].append(rdata.to_text())

                except Exception as e:
                    print("Could not query domain %s: %s" % (domain, str(e)))
                    sys.exit(1)

                if not foundMaster or not foundWorker or not foundBootstrap:
                    print("Could not find all required nodes for domain %s." % domain)
                    sys.exit(1)

                try:
                    with open(variableSaveFile, 'w') as saveFile:
                        json.dump(variableJson, saveFile, indent=4)
                        saveFile.write("\n")
                        saveFile.close()
                except OSError as e:
                        print("Could not write variable file: %s" % str(e))
                        sys.exit(1)
        except OSError as e:
            print("Can not open install config file: %s" % str(e))
            sys.exit(1)

    def updateConfig(self):
        variableFile = self.outputDir + '/variables.tf.json'
        varFileJson = {}

        try:
            with open(variableFile, 'r') as varFile:
                varFileJson = json.load(varFile)
            varFile.close()
        except OSError as e:
            print("Can not open variable file: %s" % str(e))
            sys.exit(1)

        varFileJson['variable'].update({self.setKey: {}})
        varFileJson['variable'][self.setKey]['default'] = self.setValue

        try:
            with open(variableFile, 'w') as varFile:
                json.dump(varFileJson, varFile, indent=4)
                varFile.write("\n")
                varFile.close()
        except OSError as e:
            print("Can not open variable file: %s" % str(e))
            sys.exit(1)

    def parse_args(self):
        parser = argparse.ArgumentParser()
        parser.add_argument('--file', action='store')
        parser.add_argument('--dir', action='store')
        parser.add_argument('--get', action='store')
        parser.add_argument('--nsx', action='store')
        parser.add_argument('--set', action='store')
        parser.add_argument('--value', action='store')
        parser.add_argument('--install', action='store')
        parser.add_argument('--id', action='store')
        parser.add_argument('--template', action='store')
        parser.add_argument('--dual', action='store_true')
        self.args = parser.parse_args()
        self.cfgFile = self.args.file
        self.outputDir = self.args.dir
        self.getValue = self.args.get
        self.nsxCfgFile = self.args.nsx
        self.setKey = self.args.set
        self.setValue = self.args.value
        self.installDir = self.args.install
        self.infraId = self.args.id
        self.templateFile = self.args.template
        self.dualNic = self.args.dual

def main():
    osConfig()

if __name__ == '__main__':

    try:
        main()
    except SystemExit as e:
        if e.code == 0:
            os._exit(0)
        else:
            os._exit(e.code)