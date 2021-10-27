# openshift-helper

Toolset to deploy a User Provides Infrastructure (UPI) cluster on vSphere.

Note: The Ansible Helper is a prerequisite to create the RHCOS template: [ansible-helper](https://github.com/mminichino/ansible-helper). Terraform is also a prerequisite.

1. Download the pull secret, install binary, and oc CLI and put them in the shell PATH
2. Create the OCP install config template
````
$ cd openshift-helper
$ bin/prepOpenShift.sh -c
````
3. Download the latest OVA and create a RHCOS template if one does not already exist
````
$ bin/prepOpenShift.sh -g
````
4. Create the cluster
````
$ bin/prepOpenShift.sh
````

###Delete the Cluster
````
$ bin/prepOpenShift.sh -r
````

###Reset the Configuration
To erase the current configuration and start over:
````
$ bin/prepOpenShift.sh -w
````

###Optional NSX Configuration
Create load balancer in NSX (create the install config template first)
````
$ cd openshift-helper
$ bin/tfConfig.py --nsx /home/user/install-config-template.yaml --dir /home/user/openshift-helper/nsxt
$ cd nsxt
$ terraform init
$ terraform apply
````
