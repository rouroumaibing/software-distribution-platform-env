#!/bin/bash

set -e

PROJECT_ROOT=$(cd `dirname $0/`;pwd)
cd ${PROJECT_ROOT}
COMPONENTS=(console hub harbor)


for component in "${COMPONENTS[@]}"; do
    bash ${PROJECT_ROOT}/self-signed-ca-cert.sh --service ${component} --namespace sdp-workflow --domainname sdpworkflow.com
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
        popd
    fi
done


