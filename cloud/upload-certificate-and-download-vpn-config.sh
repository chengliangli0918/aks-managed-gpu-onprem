helpFunction() {
    echo "Usage: "
    echo "  -n <certificate name>: name to be given to the uploaded certificate (required)"
    echo "  -c <certificate data>: base64 encoded certificate data to be uploaded (required)"
}

if [ "$#" -eq 0 ]; then
    helpFunction
    exit -1;
fi


while getopts "hn:c:" OPTION
do 
   case $OPTION in
    n)
        CERT_NAME=$OPTARG
        ;;

    c) 
        CERT_DATA=$OPTARG
        ;;

    h)
        # if -h, print help function and exit
        helpFunction
        exit 0
        ;;

    ?)
        echo "ERROR: unknown option"
        helpFunction
        exit -1
        ;;
    esac
done

if [[ -z "$CERT_NAME" ]]; then
   echo "Missing certificate name (-n) parameter"
   helpFunction
   exit -1
fi

if [[ -z "$CERT_DATA" ]]; then
   echo "Missing certificate data (-c) parameter"
   helpFunction
   exit -1
fi

echo "Installing unzip"

sudo apt -y install unzip

# Create decoded certificate file as directly passing in base64 encoded data doesn't work (Azure CLI bug?)
TMP_FILE="/tmp/""$CERT_NAME""cert"
echo "$CERT_DATA" | base64 -d > "$TMP_FILE"

# Upload root certificate
echo "Uploading root certificate to VPN gateway"
az network vnet-gateway root-cert create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$CERT_NAME" \
    --gateway-name "Gateway" \
    --public-cert-data "$TMP_FILE"

rm "$TMP_FILE"

# Generate URL to download VPN configuration files from
echo "Generating URL to download VPN configuration files from"
VPN_CONFIG_URL="$(az network vnet-gateway vpn-client generate \
    --authentication-method "EAPTLS" \
    --name "P2SGateway" \
    --resource-group "$RESOURCE_GROUP" | tr -d '\"')"

# Download VPN configuration, move only OpenVPN file to current directory
echo "Downloading VPN configuration file"
wget $VPN_CONFIG_URL -O "/tmp/vpnconfig.zip"
mkdir -p "/tmp/vpnconfig"
unzip "/tmp/vpnconfig.zip" -d "/tmp/vpnconfig"
cp "/tmp/vpnconfig/OpenVPN/vpnconfig.ovpn" "vpnconfig.ovpn"
rm -rf "/tmp/vpnconfig"
rm "/tmp/vpnconfig.zip"

echo "OpenVPN configuration file 'vpnconfig.ovpn' created"