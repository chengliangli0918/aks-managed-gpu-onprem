# Run this file with e.g. `source environment-setup.sh`

export USER="charlili"
export SUBSCRIPTION=$(az account show --query id --output tsv)
export RESOURCE_GROUP="${USER}rg"
export CLUSTER_NAME="${USER}aks"
# choose a region close to your edge nodes, eastus2 as an example
export REGION="westus3"
# no overlap with the address space used by arbitrary machines
export POD_CIDR=10.244.0.0/16

# The following are used in the bash script but not bicep
export VNET_ID="${USER}vnet"
export SUBNET_ID="node-subnet"
# no overlap with the address space used by arbitrary machines
export VNET_CIDR=10.224.0.0/16
# no overlap with the address space used by arbitrary machines
export NODE_SUBNET_CIDR=10.224.0.0/24
# no overlap with the address space used by arbitrary machines
export CLUSTER_SERVICE_CIDR=10.245.2.0/24
export CLUSTER_DNS_SERVER=10.245.2.10
# ensure no overlap with local networking address space
export GATEWAY_SUBNET_CIDR=10.224.255.0/27
