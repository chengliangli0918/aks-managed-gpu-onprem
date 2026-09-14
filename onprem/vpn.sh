export clientCertFileName=$(hostname)Cert.pem
echo "cert name: "$clientCertFileName
sudo sed -i -e "/CLIENTCERTIFICATE/{r $clientCertFileName" -e "d}" vpnconfig.ovpn
export clientpriKeyFileName=$(hostname)Key.pem
echo "cert name: "$clientpriKeyFileName
sudo sed -i -e "/PRIVATEKEY/{r $clientpriKeyFileName" -e "d}" vpnconfig.ovpn

# install openvpn
sudo apt-get -y update
sudo apt-get -y install openvpn
sudo apt-get -y install network-manager-openvpn
sudo service NetworkManager restart

sudo sed -i -e 's/\#AUTOSTART="all"/AUTOSTART="all"/g' /etc/default/openvpn
# copy vpnconfig.ovpn to /etc/openvpn/vpnconfig.conf.
sudo cp vpnconfig.ovpn /etc/openvpn/vpnconfig.conf
# reload and restart
sudo systemctl daemon-reload
sudo service openvpn restart