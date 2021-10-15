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

    def updateIgn(self, hostname, role, prefix, address, domain, route, dns = []):
        ignFile = self.installDir + '/' + role + '.ign'
        outFile = self.installDir + '/' + hostname + '.ign'
        storageBlock = {}
        ifcfg = """TYPE=Ethernet
BOOTPROTO=none
NAME=ens192
DEVICE=ens192
ONBOOT=yes
IPADDR={{ ip_address }}
PREFIX={{ ip_prefix }}
GATEWAY={{ gateway }}
DOMAIN={{ domain_name }}
{% for item in dns_list -%}
DNS{{ loop.index }}={{ item }}{{ "
" if not loop.last }}
{%- endfor %}
"""

        t = Template(ifcfg)
        ifcfgBlock = t.render(ip_address=address, ip_prefix=prefix, gateway=route, domain_name=domain, dns_list=dns)
        block_bytes = ifcfgBlock.encode('ascii')
        base64_bytes = base64.b64encode(block_bytes)

        storageBlock['filesystem'] = 'root'
        storageBlock['path'] = '/etc/sysconfig/network-scripts/ifcfg-ens192'
        storageBlock['mode'] = 420
        storageBlock['contents'] = {}
        storageBlock['contents']['source'] = 'data:text/plain;charset=utf-8;base64,' + base64_bytes.decode('ascii')

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
        ignData['storage']['files'].append(storageBlock)

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
        variableSaveFile = self.outputDir + '/variables.tf.json'
        foundMaster = False
        foundWorker = False
        foundBootstrap = False
        masterCount = 0
        workerCount = 0

        try:
            with open(self.cfgFile, 'r') as cfgYamlFile:
                cfgYaml = yaml.safe_load(cfgYamlFile)
                for key in cfgYaml:
                    if key == 'platform':
                        variableJson['variable'].update({'vsphere_user': {'default': cfgYaml['platform']['vsphere']['username']}})
                        variableJson['variable'].update({'vsphere_password': {'default': cfgYaml['platform']['vsphere']['password']}})
                        variableJson['variable'].update({'vsphere_server': {'default': cfgYaml['platform']['vsphere']['vCenter']}})
                        variableJson['variable'].update({'vsphere_datacenter': {'default': cfgYaml['platform']['vsphere']['datacenter']}})
                        variableJson['variable'].update({'vsphere_cluster': {'default': cfgYaml['platform']['vsphere']['cluster']}})
                        variableJson['variable'].update({'vsphere_datastore': {'default': cfgYaml['platform']['vsphere']['defaultDatastore']}})
                        variableJson['variable'].update({'vsphere_network': {'default': cfgYaml['platform']['vsphere']['network']}})
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

                defaultRouter = '.'.join(str(machineNetwork.network_address).split('.')[:-1]+["1"])
                routeAnswer = input("Default router for network %s [%s]: " % (str(machineNetwork.network_address), defaultRouter))
                if routeAnswer:
                    defaultRouter = routeAnswer

                variableJson['variable'].update({'ip_broadcast': {'default': str(machineNetwork.broadcast_address)}})
                variableJson['variable'].update({'ip_mask': {'default': str(machineNetwork.netmask)}})
                variableJson['variable'].update({'ip_prefix': {'default': str(machineNetwork.prefixlen)}})
                variableJson['variable'].update({'ip_route': {'default': defaultRouter}})

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

                    for name, ttl, rdata in zone.iterate_rdatas("A"):
                        pattern = re.compile("^master[0-9]+$")
                        if pattern.match(name.to_text()):
                            foundMaster = True
                            masterCount = masterCount + 1
                            variableJson['variable']['master_spec']['default'].update({name.to_text(): {}})
                            variableJson['variable']['master_spec']['default'][name.to_text()].update({'ip_address': rdata.to_text()})
                            variableJson['variable']['master_spec']['default'][name.to_text()].update({'host_name': name.to_text()})
                            self.updateIgn(name.to_text(), 'master', str(machineNetwork.prefixlen), rdata.to_text(),
                                           domain, defaultRouter, variableJson['variable']['ip_dns']['default'])
                        pattern = re.compile("^bootstrap$")
                        if pattern.match(name.to_text()):
                            foundBootstrap = True
                            variableJson['variable']['bootstrap_spec']['default'].update({name.to_text(): {}})
                            variableJson['variable']['bootstrap_spec']['default'][name.to_text()].update({'ip_address': rdata.to_text()})
                            variableJson['variable']['bootstrap_spec']['default'][name.to_text()].update({'host_name': name.to_text()})
                            self.updateIgn(name.to_text(), 'bootstrap', str(machineNetwork.prefixlen), rdata.to_text(),
                                           domain, defaultRouter, variableJson['variable']['ip_dns']['default'])
                        pattern = re.compile("^worker[0-9]+$")
                        if pattern.match(name.to_text()):
                            foundWorker = True
                            workerCount = workerCount + 1
                            variableJson['variable']['worker_spec']['default'].update({name.to_text(): {}})
                            variableJson['variable']['worker_spec']['default'][name.to_text()].update({'ip_address': rdata.to_text()})
                            variableJson['variable']['worker_spec']['default'][name.to_text()].update({'host_name': name.to_text()})
                            self.updateIgn(name.to_text(), 'worker', str(machineNetwork.prefixlen), rdata.to_text(),
                                           domain, defaultRouter, variableJson['variable']['ip_dns']['default'])

                    variableJson['variable'].update({'master_count': {'default': masterCount}})
                    variableJson['variable'].update({'worker_count': {'default': workerCount}})
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

        gwName = input("T1 Gateway Name: ")
        gwName = gwName.rstrip("\n")

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
                variableJson['variable'].update({'gateway_name': {'default': gwName}})

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
        self.args = parser.parse_args()
        self.cfgFile = self.args.file
        self.outputDir = self.args.dir
        self.getValue = self.args.get
        self.nsxCfgFile = self.args.nsx
        self.setKey = self.args.set
        self.setValue = self.args.value
        self.installDir = self.args.install
        self.infraId = self.args.id

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