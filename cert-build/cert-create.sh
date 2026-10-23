#!/bin/bash

set -e

PROJECT_ROOT=$(cd `dirname $0/`;pwd)
cd ${PROJECT_ROOT}
COMPONENTS=(console hub harbor hub-keycloak-http)
NAMESPACE="${NAMESPACE:-sdp-workflow}"
DOMAINNAME="${DOMAINNAME:-sdpworkflow.com}"

for component in "${COMPONENTS[@]}"; do
    bash ${PROJECT_ROOT}/self-signed-ca-cert.sh --service ${component} --namespace ${NAMESPACE} --domainname ${DOMAINNAME}
    sleep 1
    # 检查一下是否有kubectl，然后生成secret yaml

    if command -v kubectl >/dev/null 2>&1; then
        pushd "${PROJECT_ROOT}/certs/"
        kubectl create secret generic ${component}-server-secret \
                --from-file=server.key=${component}.key \
                --from-file=server.crt=${component}.crt \
                --from-file=ca.crt=ca.crt \
                --dry-run=client -o yaml > ${component}-server-secret.yaml
        kubectl create secret generic ${component}-client-secret \
                --from-file=client.key=${component}-client.key \
                --from-file=client.crt=${component}-client.crt \
                --dry-run=client -o yaml > ${component}-client-secret.yaml
        # hub chart 的 keycloak 子 chart 按固定名 hub-keycloak-tls、键位 tls.crt/tls.key
        # 引用后端证书（挂载点 /etc/keycloak-tls，args 显式 --https-certificate-file）；
        # SAN 由 service 名 hub-keycloak-http 覆盖 <svc>.<ns>.svc.cluster.local 链，
        # 与 BackendTLSPolicy 的 validation.hostname 一致。
        if [[ "${component}" == "hub-keycloak-http" ]]; then
            kubectl create secret generic hub-keycloak-tls \
                    --from-file=ca.crt=ca.crt \
                    --from-file=tls.crt=${component}.crt \
                    --from-file=tls.key=${component}.key \
                    --dry-run=client -o yaml > hub-keycloak-tls.yaml
        fi
        popd
    fi
done


