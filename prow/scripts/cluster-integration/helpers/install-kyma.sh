#!/usr/bin/env bash

#Description: Installs Kyma in a given GKE cluster
#
#Expected vars:
# - GATEWAY_IP_ADDRESS: static IP for gateway
# - DOCKER_PUSH_REPOSITORY: name of the docker registry where images are pushed
# - KYMA_SOURCES_DIR: absolute path for kyma sources directory
# - DOCKER_PUSH_DIRECTORY: directory for docker images where it should be pushed
# - GOOGLE_APPLICATION_CREDENTIALS - GCP Service Account key file path
# - STANDARIZED_NAME: a variation of cluster name
# - REPO_OWNER: Kyma repository owner
# - REPO_NAME: name of the Kyma repository
# - CURRENT_TIMESTAMP: Current timestamp which is computed as $(date +%Y%m%d)
# - DOMAIN: Combination of gcloud managed-zones and cluster name "${DNS_SUBDOMAIN}.${DNS_DOMAIN%?}"

# shellcheck source=prow/scripts/lib/log.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/log.sh"
# shellcheck source=prow/scripts/lib/utils.sh
source "${TEST_INFRA_SOURCES_DIR}/prow/scripts/lib/utils.sh"

function installKyma() {

    requiredVars=(
		DOCKER_PUSH_REPOSITORY
        KYMA_SOURCES_DIR
        DOCKER_PUSH_DIRECTORY
        GOOGLE_APPLICATION_CREDENTIALS
        STANDARIZED_NAME
        REPO_OWNER
        REPO_NAME
        CURRENT_TIMESTAMP
        GCR_PUSH_GOOGLE_APPLICATION_CREDENTIALS
        GATEWAY_IP_ADDRESS
        DOMAIN
	)

	utils::check_required_vars "${requiredVars[@]}"

    # shellcheck disable=SC2153
    KYMA_RESOURCES_DIR="${KYMA_SOURCES_DIR}/installation/resources"
    INSTALLER_YAML="${KYMA_RESOURCES_DIR}/installer.yaml"
    INSTALLER_CR="${KYMA_RESOURCES_DIR}/installer-cr-cluster.yaml.tpl"

    export KYMA_INSTALLER_IMAGE="${DOCKER_PUSH_REPOSITORY}${DOCKER_PUSH_DIRECTORY}/${STANDARIZED_NAME}/${REPO_OWNER}/${REPO_NAME}:${CURRENT_TIMESTAMP}"

    log::info "Build Kyma-Installer Docker image"

    createImage

    log::info "Apply Kyma config"
    sed -e 's;image: eu.gcr.io/kyma-project/.*/installer:.*$;'"image: ${KYMA_INSTALLER_IMAGE};" "${INSTALLER_YAML}" \
    | kubectl apply -f-

    utils::generate_letsencrypt_cert "${DOMAIN}"

    cat << EOF > "$PWD/kyma_istio_operator"
apiVersion: install.istio.io/v1alpha1
kind: IstioOperator
metadata:
  namespace: istio-system
spec:
  components:
    ingressGateways:
      - name: istio-ingressgateway
        k8s:
          service:
            loadBalancerIP: ${GATEWAY_IP_ADDRESS}
            type: LoadBalancer
EOF

    "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-config-map-file.sh" --name "istio-overrides" \
        --label "component=istio" \
        --file "$PWD/kyma_istio_operator"

    "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-config-map.sh" --name "installation-config-overrides" \
        --data "global.domainName=${DOMAIN}" \
        --data "global.loadBalancerIP=${GATEWAY_IP_ADDRESS}"

    "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-config-map.sh" --name "cluster-certificate-overrides" \
        --data "global.tlsCrt=${TLS_CERT}" \
        --data "global.tlsKey=${TLS_KEY}"

    "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-config-map.sh" --name "core-test-ui-acceptance-overrides" \
        --data "test.acceptance.ui.logging.enabled=true" \
        --label "component=core"

    "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-config-map.sh" --name "application-registry-overrides" \
        --data "application-registry.deployment.args.detailedErrorResponse=true" \
        --label "component=application-connector"

    waitUntilInstallerApiAvailable

    log::info "Trigger installation"

    sed -e "s/__VERSION__/0.0.1/g" "${INSTALLER_CR}"  | sed -e "s/__.*__//g" | kubectl apply -f-
    "${KYMA_SCRIPTS_DIR}"/is-installed.sh --timeout 30m
}

function createImage() {
    log::info "Kyma Installer Image: ${KYMA_INSTALLER_IMAGE}"
    # shellcheck disable=SC1090
    source "${TEST_INFRA_CLUSTER_INTEGRATION_SCRIPTS}/create-image.sh"
}

function waitUntilInstallerApiAvailable() {
    log::info "Waiting for Installer API"

    attempts=5
    for ((i=1; i<=attempts; i++)); do
        numberOfLines=$(kubectl api-versions | grep -c "installer.kyma-project.io")
        if [[ "$numberOfLines" == "1" ]]; then
            echo "API found"
            break
        elif [[ "${i}" == "${attempts}" ]]; then
            echo "ERROR: API not found, exit"
            exit 1
        fi

        echo "Sleep for 3 seconds"
        sleep 3
    done
}

installKyma
