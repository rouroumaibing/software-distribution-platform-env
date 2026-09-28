#!/bin/bash 

WORKPATH=`pwd`
CERTPATH=${WORKPATH}/certs
TMPPATH=${WORKPATH}/certs/tmp

mkdir -p ${TMPPATH}

set -ex

usage() {
    cat <<EOF

usage: ${0} [OPTIONS]

The following flags are required.

       --service          Service name of webhook.
       --namespace        Namespace where webhook service and secret reside.
       --domainname       Pubilc Domain Name. like："*.demo.com"-> "--domainname demo.com"
       --ip               IP whitelist
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case ${1} in
        --service)
            service="$2"
            shift
            ;;
        --namespace)
            namespace="$2"
            shift
            ;;
        --domainname)
            domainname="$2"
            shift
            ;;
        --ip)
            ip="$2"
            shift
            ;;
        *)
            usage
            ;;
    esac
    shift
done

[ -z ${service} ] && echo "ERROR: --service flag is required" && exit 1
[ -z ${namespace} ] && namespace=default
[ -z ${domainname} ] && domainname="${service}.com" 
[ -z ${ip} ] && ip=127.0.0.1

if [ ! -x "$(command -v openssl)" ]; then
    echo "openssl not found"
    exit 1
fi

# server csr
# [alt_names][IP.1] IP address to access the webhook service
cat <<EOF > ${TMPPATH}/server-csr.conf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name

[req_distinguished_name]
countryName = CN
stateOrProvinceName = HZ
localityName = YH
organizationName = server
commonName = ${service}.${namespace}.svc
commonName_max = 64

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = ${service}
DNS.2 = ${service}.${namespace}
DNS.3 = ${service}.${namespace}.svc
DNS.4 = ${service}.${namespace}.svc.cluster
DNS.5 = ${service}.${namespace}.svc.cluster.local
DNS.6 = *.${domainname}
DNS.7 = ${domainname}
IP.1 = ${ip}
EOF

# client csr
cat <<EOF > ${TMPPATH}/client-csr.conf
[req]
req_extensions = v3_req
distinguished_name = req_distinguished_name

[req_distinguished_name]
countryName = CN
stateOrProvinceName = HZ
localityName = YH
organizationName = client
commonName = ${service}.${namespace}.svc
commonName_max = 64

[ v3_req ]
basicConstraints = CA:FALSE
keyUsage = nonRepudiation, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
EOF



# 1. Create CA key and CA cert (only once, shared by all components)
if [ ! -f ${CERTPATH}/ca.key ] || [ ! -f ${CERTPATH}/ca.crt ]; then
    openssl genrsa -out ${CERTPATH}/ca.key 2048
    openssl req -x509 -new -nodes -key ${CERTPATH}/ca.key -subj "/CN=${domainname}-ROOT-CA" -days 10000 -out ${CERTPATH}/ca.crt 
fi

# 2. Create server key, server csr, sign the server csr, and save the signed server cert
openssl genrsa -out ${CERTPATH}/${service}.key 2048 
openssl req -new -key ${CERTPATH}/${service}.key -subj "/CN=${service}.${namespace}.svc" -out ${TMPPATH}/${service}.csr -config ${TMPPATH}/server-csr.conf
openssl x509 -req -CA ${CERTPATH}/ca.crt -CAkey ${CERTPATH}/ca.key -CAcreateserial -in ${TMPPATH}/${service}.csr  -days 10000  -out ${CERTPATH}/${service}.crt  -extfile ${TMPPATH}/server-csr.conf -extensions v3_req 

# 3. Create client key, client csr, sign the client csr, and save the signed client cert
openssl genrsa -out ${CERTPATH}/${service}-client.key 2048
openssl req -new -key ${CERTPATH}/${service}-client.key -subj "/CN=${service}.${namespace}.svc" -out ${TMPPATH}/${service}-client.csr -config ${TMPPATH}/client-csr.conf
openssl x509 -req -CA ${CERTPATH}/ca.crt -CAkey ${CERTPATH}/ca.key -CAcreateserial -in ${TMPPATH}/${service}-client.csr  -days 10000  -out ${CERTPATH}/${service}-client.crt  -extfile ${TMPPATH}/client-csr.conf -extensions v3_req
openssl pkcs12 -export -clcerts -in ${CERTPATH}/${service}-client.crt -inkey ${CERTPATH}/${service}-client.key -out ${CERTPATH}/${service}-client.pfx -passout pass:""


