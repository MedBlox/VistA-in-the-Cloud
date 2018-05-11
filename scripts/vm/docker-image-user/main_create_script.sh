#!/bin/bash
#
# set -x

# Each Organization needing to use ITCP needs a different resource group; so these have to be adjusted.
# Specify -g in order to change it to something else.
export vm_group_name="ITCP-USR-OSEHRA"
export vm_subnet_number="7"
ad_vm_name="ITCP-C-DC1"
dc_servers="10.1.1.4,10.1.1.5"
common_vnet="ITCP-Common-RG-vnet"
common_rg="ITCP-Common-RG"
shared_vnet="itcpSHAREDVNET"
shared_rg="ITCP-Common-RG"
ME=$(basename "$0")

print_usage ()
{
    printf "\n"
    printf "Usage: "
    printf "\t%s [OPTIONS]\n" "$ME"
    printf "Available options\n\n"
    printf "  -h | --help                           : Print help text\n"
    printf "  -a | --ad-name <AD NAME>              : Name of the Domain Controller 1 VM, Default: $ad_vm_name\n"
    printf "  -c | --common-vent <COMMON VNET NAME> : Name of the Common VNET where the Domain Controllers are located, Default: $common_vnet\n"
    printf "  -d | --dc-servers <IP,ADDRESSES>      : Comma seperated list of the domain controller IP's, Default: $dc_servers\n"
    printf "  -e | --enterprise                     : Flag to add a sandbox to an Enterprise setup\n"
    printf "  -g | --group <GROUP NAME>             : Name of ResourceGroup (default: $vm_group_name), Default: $vm_group_name\n"
    printf "  -n | --common-rg <COMMON RG NAME>     : Name of the Common Resource group where the Domain Controllers are located, Default: $common_rg\n"
    printf "  -p | --password                       : Option to enter a password for Active Directory User\n"
    printf "  -s | --shared-vnet <SHARED VNET NAME> : Name of the Shared VNET Name, Default: $shared_vnet\n"
    printf "  -r | --shared-rg <SHARED RG NAME>     : Name of the Shared Resource Group, Default $shared_rg\n"
    printf "  -o | --octet <SECOND CIDR OCTET>      : Octet number under 10.X, Default: $vm_subnet_number\n"
    printf "\n\n"
}

while [[ $1 =~ ^- ]]; do
    case $1 in
        -h  | --help )                 print_usage
                                       exit 0
                                       ;;
        -a  | --ad-name )              shift
                                       ad_vm_name=$1
                                       ;;
        -c  | --common-vnet )          shift
                                       common_vnet=$1
                                       ;;
        -d  | --dc-servers )           shift
                                       dc_servers=$1
                                       ;;
        -e  | --enterprise )           shift
                                       enterprise=true
                                       ;;
        -g  | --group )                shift
                                       group_name=$1
                                       ;;
        -n  | --common-rg )            shift
                                       common_rg=$1
                                       ;;
        -p  | --password )             shift
                                       windows_password=true
                                       ;;
        -r  | --shared-rg )            shift
                                       shared_rg=$1
                                       ;;
        -s  | --shared-vnet )          shift
                                       shared_vnet=$1
                                       ;;
        -o  | --octet )                shift
                                       vm_subnet_number=$1
                                       ;;
        * )                            echo "Unknown option $1"
                                       print_usage
                                       exit 1
    esac
    shift
done

if [[ $group_name ]]; then
    vm_group_name="ITCP-USR-${group_name}"
fi

# The reset needs to stay constant
export vnet_name="ITCP-USR-${group_name}-vnet"
export subnet_name="ITCP-${group_name}-subnet"
export storage_group_name="ITCP-Storage-Blobs"
export storage_account_name="itcpstorageblobs"

# Get required user information
win_password=""
ad_password=""

ask_for_password() {
    echo "**NOTE** Password shall meet the following criteria:"
    echo "Be at least 12 characters long"
    echo "Contain at least 1 Uppercase Letter"
    echo "Contain at least 1 Lowercase Letter"
    echo "Contain at least 1 Number"
    echo "Contain at least 1 Special Character (!@#$%^&*())"
}

validate_win_password() {
    win_password_special=${win_password//[^!@#$%^&*()+=-]}
    if [[ ${#win_password} -ge 12 && "${#win_password_special}" -ge 1 && "$win_password" == *[A-Z]* && "$win_password" == *[a-z]* && "$win_password" == *[0-9]* ]]; then
        echo ""
        echo "Password matches the criteria."
    else
        echo ""
        ask_for_win_password
        validate_win_password
    fi
}

ask_for_win_password() {
    echo ""
    echo "Please enter a password for the Organization Active Directory User"
    ask_for_password
    read -s -p "Organization Active Directory User Password: " win_password
}

validate_ad_password() {
    ad_password_special=${ad_password//[^!@#$%^&*()+=-]}
    if [[ ${#ad_password} -ge 12 && "${#ad_password_special}" -ge 1 && "$ad_password" == *[A-Z]* && "$ad_password" == *[a-z]* && "$ad_password" == *[0-9]* ]]; then
        echo ""
        echo "Password matches the criteria."
    else
        echo ""
        ask_for_ad_password
        validate_ad_password
    fi
}

ask_for_ad_password() {
    echo ""
    echo "Please enter a password for the Active Directory Admin"
    ask_for_password
    read -s -p "AD Admin Password: " ad_password
}

if [[ $windows_password ]]; then
    ask_for_win_password
    validate_win_password
fi

if [[ -z $windows_password ]]; then
    win_password=$(</dev/urandom LC_ALL=C tr -dc 'A-Za-z0-9!@#$%^&*()+=-' | head -c 32)
fi

if [[ $enterprise ]]; then
    ask_for_ad_password
    validate_ad_password

    org_username_default="$group_name.admin"
    read -p "Organization AD Username [$org_username_default]: " org_username
    org_username="${org_username:-$org_username_default}"
    org_firstName_default="Org"
    read -p "Organization AD User First Name [$org_firstName_default]: " org_firstName
    org_firstName="${org_firstName:-$org_firstName_default}"
    org_lastName_default="Admin"
    read -p "Organization AD User Last Name [$org_lastName_default]: " org_lastName
    org_lastName="${org_lastName:-$org_lastName_default}"
fi

# Login and Create Resource Group
az cloud set --name AzureCloud
if [[ $(az account list | grep login) ]]; then
    az login
fi
echo "Creating Organization Resource Group"
az group create --name $vm_group_name --location eastus > /dev/null

# Query for existing 10.7, or supplied vm_subnet_number, vnets
last_vnet=$(az network vnet list --query "[].addressSpace.addressPrefixes[0]|[?contains(@, '10.${vm_subnet_number}')]|[-1]"|cut -d . -f3)

# Check if any vnet with the first two octets exist
if [[ -z $last_vnet ]]; then
    vnet_prefix="10.${vm_subnet_number}.0.0/24"
else
    vnet_prefix=$(echo $last_vnet|awk '{print "10.'${vm_subnet_number}'."$1 + 1".0/24"}')
fi

# Create Network
subnet_prefix=$(echo $(echo ${vnet_prefix}|cut -d / -f1)|awk '{print $1"/26"}')
echo "Creating Organization VNET"
az network vnet create -g $vm_group_name -n $vnet_name --address-prefix $vnet_prefix --subnet-name $subnet_name --subnet-prefix $subnet_prefix > /dev/null

if [[ $enterprise ]]; then
    # Get the id for my vnet.
    vnet_id=$(az network vnet show --resource-group $vm_group_name  --name $vnet_name --query id --out tsv)

    # Get the id for Common resources vnet.
    shared_vnet_id=$(az network vnet show --resource-group $shared_rg  --name $shared_vnet --query id --out tsv)

    common_vnet_id=$(az network vnet show --resource-group $common_rg  --name $common_vnet --query id --out tsv)

    # Add peering to itcpSHAREDResources network to reach Vivian and CDash
    echo "Peering Shared RG to Organization RG"
    az network vnet peering create -g $shared_rg     -n shared-to-consumer-${vm_group_name} --vnet-name $shared_vnet --remote-vnet-id $vnet_id        --allow-vnet-access > /dev/null
    echo "Peering Organization RG to Shared RG"
    az network vnet peering create -g $vm_group_name -n consumer-to-shared-${vm_group_name} --vnet-name $vnet_name   --remote-vnet-id $shared_vnet_id --allow-vnet-access > /dev/null

    # Add peering to ITCP-Common-RG to reach AD
    echo "Peering Common RG to Organization RG"
    az network vnet peering create -g $common_rg     -n common-to-consumer-${vm_group_name} --vnet-name $common_vnet --remote-vnet-id $vnet_id        --allow-vnet-access > /dev/null
    echo "Peering Organization RG to Common RG"
    az network vnet peering create -g $vm_group_name -n consumer-to-common-${vm_group_name} --vnet-name $vnet_name   --remote-vnet-id $common_vnet_id --allow-vnet-access > /dev/null

    # Update VNET DNS
    echo "Updated DNS Servers for the VNET"
    az network vnet update -g $vm_group_name -n $vnet_name --dns-servers $(echo ${dc_servers//,/ }) > /dev/null

    # Create Organization OU in AD
    echo "Adding Organization OU in AD"
    echo "**Warning** This can take about 5 minutes"
    az vm extension set --publisher Microsoft.Compute --name CustomScriptExtension --version 1.8 --settings "{'commandToExecute':'powershell.exe -ExecutionPolicy Unrestricted -File C:\\scripts\\createOrgOU.ps1 \"${ad_password}\" \"${group_name}\"'}" --vm-name $ad_vm_name --resource-group $common_rg > /dev/null
    extension_id=$(az vm extension list -g $common_rg --vm-name $ad_vm_name --query "[0].id" -otsv)
    echo "Cleaning up AD Update Extension"
    az vm extension delete --ids $extension_id > /dev/null

    ./scripts/addUserToOU.sh $org_username $org_firstName $org_lastName $group_name $common_rg $ad_vm_name $win_password
fi

# Not required for enterprise/standard with all parts open source
# # Tie storage to network
# ./add_storage_network_rule.sh

# Linux VM
linux_ip=$(echo $(echo ${vnet_prefix}|cut -d . -f1-3)|awk '{print $1".4"}')
./create_vista_host.sh $linux_ip $group_name $win_password

if [[ $enterprise ]]; then
    # Configure Linux VM SSH settings
    ./scripts/ssh_config.sh $vm_group_name "itcpVistAUser-$group_name"

    # Join Linux VM to Domain
    ./scripts/joinLinuxToDomain.sh $vm_group_name "itcpVistAUser-$group_name" $ad_password $group_name

    # Update Linux VM sssd config
    ./scripts/sssd_config.sh $vm_group_name "itcpVistAUser-$group_name"
fi

# Configure VistA Docker
./scripts/docker_config.sh $group_name

# Create Windows VM
./create_windows_vm.sh $win_password $(echo $(echo ${vnet_prefix}|cut -d . -f1-3)|awk '{print $1".5"}') $group_name

win_vm_name_base="itcpWin-${group_name}"
win_vm_name=$(echo $win_vm_name_base | awk '{print substr($0,0,15)}')

# storage_group_name="ITCP-Storage-Blobs"
# AZURE_STORAGE_ACCOUNT="itcpstorageblobs"
# container_name="itcp-scripts"
# EXPIRE_DATE=$(date -v +5d +%Y-%m-%d)
# NOW=$(date +%Y-%m-%dT%TZ)
# AZURE_STORAGE_SAS_TOKEN=$(az storage account generate-sas --start $NOW --services b --resource-types o --permissions r --expiry $EXPIRE_DATE --account-name $AZURE_STORAGE_ACCOUNT --query "@" -otsv)

# END_URL=$(az storage account show -g $storage_group_name -n $AZURE_STORAGE_ACCOUNT --query "primaryEndpoints.blob" -otsv)

# FILE_URI=$END_URL$container_name/installPutty.ps1?$AZURE_STORAGE_SAS_TOKEN"&sr=b"

# echo "Configuring Windows VM"
# echo "**Warning** This can take about 15 minutes"
# az vm extension set --publisher Microsoft.Compute --name CustomScriptExtension --version 1.8 --settings "{\"fileUris\": [\"$FILE_URI\"], \"commandToExecute\":\"powershell.exe -ExecutionPolicy Unrestricted -File .\\installPutty.ps1 $linux_ip \"}" --vm-name $win_vm_name --resource-group $vm_group_name > /dev/null
# extension_id=$(az vm extension list -g $vm_group_name --vm-name $win_vm_name --query "[0].id" -otsv)
# echo "Cleaning up Windows VM Extension"
# az vm extension delete --ids $extension_id > /dev/null

# Configure Windows VM to talk to VistA
# ./scripts/configure_windows.sh $linux_ip $group_name

if [[ $enterprise ]]; then
    # Join Windows VM to Domain
    ./scripts/joinWindowsToDomain.sh $vm_group_name $win_vm_name $ad_password $win_password $group_name

    # Update Windows Remote Desktop Users local group to allow non-admins to login
    ./scripts/updateWindowsGroup.sh $vm_group_name $win_vm_name
fi

echo "Active Directory Username:"
echo $org_username
echo "Setup Summary:"
if [[ -z $windows_password ]]; then
    echo "Your windows admin password is: " $win_password
fi
echo "Linux VM Private IP:"
echo $linux_ip
vm_name=$(echo "itcpWin-${group_name}" | awk '{print substr($0,0,15)}')
ipaddr=$(az vm list-ip-addresses -g ${vm_group_name} -n "${vm_name}" --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" -otsv)
echo "Windows VM Public IP:"
echo $ipaddr
