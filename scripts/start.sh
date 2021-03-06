#!/bin/bash

[[ ${DEBUG} = true ]] && set -x
set -euo pipefail

readonly KUBECTL=${KUBECTL:-kubectl}
readonly CWD=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
readonly DNS_NAME=${DNS_NAME:-ota.local}
export   SERVER_NAME=${SERVER_NAME:-ota.ce}
readonly SERVER_DIR=${SERVER_DIR:-${CWD}/../generated/${SERVER_NAME}}
readonly DEVICES_DIR=${DEVICES_DIR:-${SERVER_DIR}/devices}

readonly NAMESPACE=${NAMESPACE:-default}
readonly PROXY_PORT=${PROXY_PORT:-8200}
readonly DB_PASS=${DB_PASS:-root}

readonly SKIP_CLIENT=${SKIP_CLIENT:-false}
readonly SKIP_WEAVE=${SKIP_WEAVE:-false}


check_dependencies() {
  for cmd in ${DEPENDENCIES:-bash curl make http jq openssl kubectl kops}; do
    [[ $(command -v "${cmd}") ]] || { echo "Please install '${cmd}'."; exit 1; }
  done
}

retry_command() {
  local name=${1}
  local command=${@:2}
  local n=0
  local max=100
  while true; do
    eval "${command}" &>/dev/null && return 0
    [[ $((n++)) -gt $max ]] && return 1
    echo >&2 "Waiting for ${name}"
    sleep 5s
  done
}

http_2xx_or_4xx() {
    local cmd=$*
    
    if eval "http ${cmd}"; then
        return $?
    else
        local ec=$?
        if [[ $ec -eq 4 ]] || [[ $ec -eq 2 ]]; then
            return 0
        else
            return $ec
        fi
    fi
}

first_pod() {
  local app=${1}
  ${KUBECTL} get pods --selector=app="${app}" --output jsonpath='{.items[0].metadata.name}'
}

wait_for_pods() {
  local app=${1}
  retry_command "${app}" "[[ true = \$(${KUBECTL} get pods --selector=app=${app} --output json \
    | jq --exit-status '(.items | length > 0) and ([.items[].status.containerStatuses[].ready] | all)') ]]"
  first_pod "${app}"
}

print_hosts() {
  retry_command "ingress" "${KUBECTL} get ingress -o json \
    | jq --exit-status '.items[0].status.loadBalancer.ingress'"
  ${KUBECTL} get ingress -o json  | jq -r '.items[].spec.rules[].host' | awk -v ip=$(minikube ip) '{print ip " " $1}'
}

kill_pid() {
  local pid=${1}
  kill -0 "${pid}" 2>/dev/null || return 0
  kill -9 "${pid}"
}

skip_ingress() {
    local local_yaml=""
    [ -f config/local.yaml ] && local_yaml="config/local.yaml"

  value=$(cat config/config.yaml \
      config/images.yaml \
      config/resources.yaml \
      config/secrets.yaml \
      $local_yaml | grep ^create_ingress | tail -n1)
  echo $value | grep "false"
}

make_template() {
  local template=$1
  local output="${CWD}/../generated/${template}"
  local extra=""
  [ -f config/local.yaml ] && extra="--values config/local.yaml"
  mkdir -p "$(dirname "${output}")"
  kops toolbox template \
    --template "${template}" \
    --values config/config.yaml \
    --values config/images.yaml \
    --values config/resources.yaml \
    --values config/secrets.yaml \
    ${extra} \
    --output "${output}"
}

apply_template() {
  local template=$1
  make_template "${template}"
  ${KUBECTL} apply --filename "${CWD}/../generated/${template}"
}

generate_templates() {
  skip_ingress || make_template templates/ingress
  make_template templates/infra
  make_template templates/services
}

new_client() {
  export DEVICE_UUID=${DEVICE_UUID:-$(uuidgen | tr "[:upper:]" "[:lower:]")}
  local device_id=${DEVICE_ID:-${DEVICE_UUID}}
  local device_dir="${DEVICES_DIR}/${DEVICE_UUID}"
  mkdir -p "${device_dir}"

  # This is a tag for including a chunk of code in the docs. Don't remove. tag::genclientkeys[]
  openssl ecparam -genkey -name prime256v1 | openssl ec -out "${device_dir}/pkey.ec.pem"
  openssl pkcs8 -topk8 -nocrypt -in "${device_dir}/pkey.ec.pem" -out "${device_dir}/pkey.pem"
  openssl req -new -key "${device_dir}/pkey.pem" \
    -config <(sed "s/\$ENV::DEVICE_UUID/${DEVICE_UUID}/g" "${CWD}/certs/client.cnf") \
    -out "${device_dir}/${device_id}.csr"
  openssl x509 -req -days 365 -extfile "${CWD}/certs/client.ext" -in "${device_dir}/${device_id}.csr" \
    -CAkey "${DEVICES_DIR}/ca.key" -CA "${DEVICES_DIR}/ca.crt" -CAcreateserial -out "${device_dir}/client.pem"
  cat "${device_dir}/client.pem" "${DEVICES_DIR}/ca.crt" > "${device_dir}/${device_id}.chain.pem"
  ln -s "${SERVER_DIR}/server_ca.pem" "${device_dir}/ca.pem" || true
  openssl x509 -in "${device_dir}/client.pem" -text -noout
  # end::genclientkeys[]

  ${KUBECTL} proxy --port "${PROXY_PORT}" &
  local pid=$!
  trap "kill_pid ${pid}" EXIT
  sleep 3s

  local api="http://localhost:${PROXY_PORT}/api/v1/namespaces/${NAMESPACE}/services"
  http --ignore-stdin PUT "${api}/device-registry/proxy/api/v1/devices" credentials=@"${device_dir}/client.pem" \
    uuid="${DEVICE_UUID}" deviceId="${device_id}" deviceName="${device_id}" deviceType=Other
  kill_pid "${pid}"

  [[ ${SKIP_CLIENT} == true ]] && return 0

  local gateway=${GATEWAY_ADDR:-$(${KUBECTL} get nodes --output jsonpath \
    --template='{.items[0].status.addresses[?(@.type=="InternalIP")].address}')}
  local addr=${DEVICE_ADDR:-localhost}
  local port=${DEVICE_PORT:-2222}
  local options="-o StrictHostKeyChecking=no"

  ssh ${options} "root@${addr}" -p "${port}" "echo \"${gateway} ota.ce\" >> /etc/hosts"
  # TODO: is this the correct server/root CA cert?
  scp -P "${port}" ${options} "${SERVER_DIR}/server_ca.pem" "root@${addr}:/var/sota/import/root.crt"
  scp -P "${port}" ${options} "${device_dir}/client.pem" "root@${addr}:/var/sota/import/client.pem"
  scp -P "${port}" ${options} "${device_dir}/pkey.pem" "root@${addr}:/var/sota/import/pkey.pem"
  scp -P "${port}" ${options} "${SERVER_DIR}/autoprov.url" "root@${addr}:/var/sota/import/gateway.url"
}

new_server() {
  ${KUBECTL} get secret gateway-tls &>/dev/null && return 0
  mkdir -p "${SERVER_DIR}" "${DEVICES_DIR}"

  # This is a tag for including a chunk of code in the docs. Don't remove. tag::genserverkeys[]
  openssl ecparam -genkey -name prime256v1 | openssl ec -out "${SERVER_DIR}/ca.key"
  openssl req -new -x509 -days 3650 -config "${CWD}/certs/server_ca.cnf" -key "${SERVER_DIR}/ca.key" \
    -out "${SERVER_DIR}/server_ca.pem"

  openssl ecparam -genkey -name prime256v1 | openssl ec -out "${SERVER_DIR}/server.key"
  openssl req -new -key "${SERVER_DIR}/server.key" \
    -config <(sed "s/\$ENV::SERVER_NAME/${SERVER_NAME}/g" "${CWD}/certs/server.cnf") \
    -out "${SERVER_DIR}/server.csr"
  openssl x509 -req -days 3650 -in "${SERVER_DIR}/server.csr" -CAcreateserial \
    -extfile <(sed "s/\$ENV::SERVER_NAME/${SERVER_NAME}/g" "${CWD}/certs/server.ext") \
    -CAkey "${SERVER_DIR}/ca.key" -CA "${SERVER_DIR}/server_ca.pem" -out "${SERVER_DIR}/server.crt"
  cat "${SERVER_DIR}/server.crt" "${SERVER_DIR}/server_ca.pem" > "${SERVER_DIR}/server.chain.pem"

  openssl ecparam -genkey -name prime256v1 | openssl ec -out "${DEVICES_DIR}/ca.key"
  openssl req -new -x509 -days 3650 -key "${DEVICES_DIR}/ca.key" -config "${CWD}/certs/device_ca.cnf" \
    -out "${DEVICES_DIR}/ca.crt"
  # end::genserverkeys[]

  ${KUBECTL} create secret generic gateway-tls \
    --from-file "${SERVER_DIR}/server.key" \
    --from-file "${SERVER_DIR}/server.chain.pem" \
    --from-file "${SERVER_DIR}/devices/ca.crt"
}

create_databases() {
  local pod
  pod=$(wait_for_pods mysql)
  ${KUBECTL} cp "${CWD}/sql" "${pod}:/tmp/"
  ${KUBECTL} exec "${pod}" -- bash -c "mysql -p${DB_PASS} < /tmp/sql/install_plugins.sql || true" 2>/dev/null
  ${KUBECTL} exec "${pod}" -- bash -c "mysql -p${DB_PASS} < /tmp/sql/create_databases.sql"
}

start_weave() {
  [[ ${SKIP_WEAVE} == true ]] && return 0;
  local version=$(${KUBECTL} version | base64 | tr -d '\n')
  ${KUBECTL} apply -f "https://cloud.weave.works/k8s/net?k8s-version=${version}"
}

start_ingress() {
  skip_ingress && return 0;
  apply_template templates/ingress
}

start_infra() {
  apply_template templates/infra
  wait_for_pods kafka
  create_databases
}

start_services() {
  configure_db_encryption
  apply_template templates/services
  get_credentials
}

configure_db_encryption() {
  ${KUBECTL} get secret "tuf-keyserver-encryption" &>/dev/null && return 0

  local salt=$(openssl rand -base64 8)
  local key=$(LC_CTYPE=C tr -cd '[:alnum:]' < /dev/urandom | fold -w64 | head -n1)

  ${KUBECTL} create secret generic "tuf-keyserver-encryption" \
    --from-literal="DB_ENCRYPTION_SALT=${salt}" \
    --from-literal="DB_ENCRYPTION_PASSWORD=${key}"
}

get_credentials() {
  ${KUBECTL} get secret "user-keys" &>/dev/null && return 0

  ${KUBECTL} proxy --port "${PROXY_PORT}" &
  local pid=$!
  trap "kill_pid ${pid}" EXIT
  sleep 3s

  local namespace="x-ats-namespace:default"
  local api="http://localhost:${PROXY_PORT}/api/v1/namespaces/${NAMESPACE}/services"
  local keyserver="${api}/tuf-keyserver/proxy"
  local reposerver="${api}/tuf-reposerver/proxy"
  local director="${api}/director/proxy"
  local id
  local keys

  pod=$(wait_for_pods director-daemon)
  pod=$(wait_for_pods tuf-keyserver-daemon)
  retry_command "director" "[[ true = \$(http --print=b GET ${director}/health \
    | jq --exit-status '.status == \"OK\"') ]]"
  retry_command "keyserver" "[[ true = \$(http --print=b GET ${keyserver}/health \
    | jq --exit-status '.status == \"OK\"') ]]"
  retry_command "reposerver" "[[ true = \$(http --print=b GET ${reposerver}/health/dependencies \
    | jq --exit-status '.status == \"OK\"') ]]"

  http_2xx_or_4xx --ignore-stdin --check-status POST "${reposerver}/api/v1/user_repo" "${namespace}"

  sleep 5s
  id=$(http --ignore-stdin --check-status --print=h GET "${reposerver}/api/v1/user_repo/root.json" "${namespace}" | grep -i x-ats-tuf-repo-id | awk '{print $2}' | tr -d '\r')

  http_2xx_or_4xx --ignore-stdin --check-status POST "${director}/api/v1/admin/repo" "${namespace}"

  retry_command "keys" "http --ignore-stdin --check-status GET ${keyserver}/api/v1/root/${id}"
  keys=$(http --ignore-stdin --check-status GET "${keyserver}/api/v1/root/${id}/keys/targets/pairs")
  echo ${keys} | jq '.[0] | {keytype, keyval: {public: .keyval.public}}'   > "${SERVER_DIR}/targets.pub"
  echo ${keys} | jq '.[0] | {keytype, keyval: {private: .keyval.private}}' > "${SERVER_DIR}/targets.sec"

  retry_command "root.json" "http --ignore-stdin --check-status -d GET \
    ${reposerver}/api/v1/user_repo/root.json \"${namespace}\"" && \
    http --ignore-stdin --check-status -d -o "${SERVER_DIR}/root.json" GET \
    ${reposerver}/api/v1/user_repo/root.json "${namespace}"

  echo "http://tuf-reposerver.${DNS_NAME}" > "${SERVER_DIR}/tufrepo.url"
  echo "https://${SERVER_NAME}:30443" > "${SERVER_DIR}/autoprov.url"
  cat > "${SERVER_DIR}/treehub.json" <<END
{
    "no_auth": true,
    "ostree": {
        "server": "http://treehub.${DNS_NAME}/api/v3/"
    }
}
END

  zip --quiet --junk-paths ${SERVER_DIR}/{credentials.zip,autoprov.url,server_ca.pem,tufrepo.url,targets.pub,targets.sec,treehub.json,root.json}

  kill_pid "${pid}"
  ${KUBECTL} create secret generic "user-keys" --from-literal="id=${id}" --from-literal="keys=${keys}"
}


[ $# -lt 1 ] && { echo "Usage: $0 <command> [<args>]"; exit 1; }
command=$(echo "${1}" | sed 's/-/_/g')

case "${command}" in
  "start_all")
    check_dependencies
    start_weave
    new_server
    start_ingress
    start_infra
    start_services
    ;;
  "start_ingress")
    start_ingress
    ;;
  "start_infra")
    start_infra
    ;;
  "start_services")
    start_services
    ;;
  "new_client")
    new_client
    ;;
  "new_server")
    new_server
    ;;
  "print_hosts")
    print_hosts
    ;;
  "templates")
    generate_templates
    ;;
  *)
    echo "Unknown command: ${command}"
    exit 1
    ;;
esac
