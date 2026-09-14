NETWORK_INTERFACE="tun0"

helpFunction() {
    echo "Usage: "
    echo "  -v <network interface>: specify the network interface to use for node internal IP. Default is $NETWORK_INTERFACE"
}

while getopts "hv:" OPTION
do 
   case $OPTION in
    h)
        # if -h, print help function and exit
        helpFunction
        exit 0
        ;;
    v)
        # -v requires an argument 
        NETWORK_INTERFACE=$OPTARG
        ;;
    esac
done

SET_INTERNAL_IP=$(grep -oP "\--node-ip=\K\w+.\w+.\w+.\w+" /etc/systemd/system/kubelet.service)
CURRENT_INTERNAL_IP=$(ip -json addr show $NETWORK_INTERFACE |   jq -r '.[] | .addr_info[] | select(.family == "inet") | .local')

if [ "$SET_INTERNAL_IP" != "$CURRENT_INTERNAL_IP" ]; then
  if [ -z "$SET_INTERNAL_IP" ]; then
    # node-ip isn't set
    sed -i -e 's/\/usr\/local\/bin\/kubelet \\/\/usr\/local\/bin\/kubelet \\\n        --node-ip='$CURRENT_INTERNAL_IP' \\/' /etc/systemd/system/kubelet.service
  else
    # node-ip is set
    sed -i -e 's/'$SET_INTERNAL_IP'/'$CURRENT_INTERNAL_IP'/' /etc/systemd/system/kubelet.service
  fi
  systemctl daemon-reload && systemctl restart kubelet --now
fi