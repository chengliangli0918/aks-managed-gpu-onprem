USERNAME=$(hostnamectl --static)

sudo apt install openssl -y
openssl genrsa -out caKey.pem 2048
openssl req -x509 -new -nodes -key caKey.pem -subj "/CN=VPN CA" -days 3650 -out caCert.pem

# Generate a private key
openssl genrsa -out "${USERNAME}Key.pem" 2048

# Generate a CSR (Certificate Sign Request)
openssl req -new -key "${USERNAME}Key.pem" -out "${USERNAME}Req.pem" -subj "/CN=${USERNAME}"

# Sign the CSR using the CA certificate and CA key
openssl x509 -req -days 365 -in "${USERNAME}Req.pem" -CA caCert.pem -CAkey caKey.pem -CAcreateserial -out "${USERNAME}Cert.pem" -extfile <(echo -e "subjectAltName=DNS:${USERNAME}\nextendedKeyUsage=clientAuth")

# Verify the client certificate with
openssl verify -CAfile caCert.pem caCert.pem "${USERNAME}Cert.pem"

echo ""
echo "Certificate data:"

openssl x509 -in caCert.pem -outform der | base64 -w0 && echo