#!/bin/bash


## Create Manila Secrets and Keypair
TMP_DIR='/tmp'
TENANT_PASSWORD='BLUF90210!'


source /opt/genestack/scripts/genestack.rc
pip install python-manilaclient
#/opt/genestack/scripts/create-manila-secrets.sh


mkdir -p "${TMP_DIR}/manila-service-image-build"
cd "${TMP_DIR}/manila-service-image-build"
git clone https://opendev.org/openstack/manila-image-elements
kubectl -n openstack get secrets/manila-service-keypair \
--template={{.data.public_key}} | base64 -d >> "${TMP_DIR}/manila-service-image-build/manila-image-elements/manila-service-keypair.pub"

openstack keypair create --public \
"${TMP_DIR}/manila-service-image-build/manila-image-elements/manila-service-keypair.pub" \
manila-service-keypair

#### Install System Dependencies to Build Manila Service Image

sudo DEBIAN_FRONTEND=noninteractive apt -yq install qemu-system qemu-system-arm qemu-system-mips \
qemu-system-ppc qemu-system-sparc qemu-system-x86 \
qemu-system-s390x qemu-system-misc debootstrap tox

##### Create new virtualenv and activate
deactivate
cd "${TMP_DIR}/manila-service-image-build"
python3 -m venv manila-tox-image-build
source manila-tox-image-build/bin/activate

##### Pip install requirements
cd manila-image-elements
pip3 install -r requirements.txt -r test-requirements.txt

cd "${TMP_DIR}/manila-service-image-build/manila-image-elements/bin/"

sed -i 's/MANILA_IMG_OS_VER=${MANILA_IMG_OS_VER:-".*"}/MANILA_IMG_OS_VER=${MANILA_IMG_OS_VER:-"noble"}/' manila-image-create
sed -i 's/MANILA_IMG_NAME=${MANILA_IMG_NAME:-".*"}/MANILA_IMG_NAME=${MANILA_IMG_NAME:-"RS_manila_service_image"}/' manila-image-create


cd "${TMP_DIR}/manila-service-image-build/manila-image-elements/data/docker/"

echo "Adding the correct Samba packages"
sed -i 's/samba \\/a^      samba-common \\/' Dockerfile
sed -i 's/samba-common \\/a^      samba-common-bin \\/' Dockerfile
sed -i '/      samba \\/d' Dockerfile
sed -i 's/^\^//' Dockerfile

cd "${TMP_DIR}/manila-service-image-build/manila-image-elements/elements/manila-ssh"

if ! egrep -q 'curl' package-installs.yaml;then
    echo "curl:" >> package-installs.yaml
fi
echo "Added curl to package-installs.yaml"

deactivate
source /opt/genestack/scripts/genestack.rc
MANILA_ADMIN_PASSWORD=$(kubectl -n openstack get secrets/manila-admin --template={{.data.password}} | base64 -d)
deactivate

cd "${TMP_DIR}/manila-service-image-build"
source manila-tox-image-build/bin/activate
cd manila-image-elements

export MANILA_PASSWORD="$MANILA_ADMIN_PASSWORD"
export MANILA_USER_AUTHORIZED_KEYS="${TMP_DIR}/manila-service-image-build/manila-image-elements/manila-service-keypair.pub"
export MANILA_IMG_NAME='RS_manila_service_image'
export DHCP_TIMEOUT=900

tox -e buildimage
deactivate

cd "${TMP_DIR}"
source /opt/genestack/scripts/genestack.rc

openstack image create \
--disk-format qcow2 \
--container-format bare \
--private \
--file "${TMP_DIR}/manila-service-image-build/manila-image-elements/RS_manila_service_image.qcow2" \
--progress "RS_manila_service_image"

ADMIN_PROJECT_ID=$(openstack project show admin -f json | jq -r '. | .id')
SERVICE_PROJECT_ID=$(openstack project show service -f json | jq -r '. | .id')
MANILA_SERVICE_IMAGE_ID=$(openstack image show RS_manila_service_image -f json | jq -r '. | .id')
openstack image set --project $ADMIN_PROJECT_ID --shared $MANILA_SERVICE_IMAGE_ID
openstack image set --project $ADMIN_PROJECT_ID --shared $MANILA_SERVICE_IMAGE_ID
openstack image add project $MANILA_SERVICE_IMAGE_ID $SERVICE_PROJECT_ID
openstack image set --project $SERVICE_PROJECT_ID --accept $MANILA_SERVICE_IMAGE_ID
openstack image add project $MANILA_SERVICE_IMAGE_ID $ADMIN_PROJECT_ID
openstack image set --project $ADMIN_PROJECT_ID --accept $MANILA_SERVICE_IMAGE_ID
openstack image member list $MANILA_SERVICE_IMAGE_ID


## Patch gateway listener
cd /etc/genestack/gateway-api/listeners
kubectl patch -n envoy-gateway gateway flex-gateway --type='json' --patch-file manila-https.json

## Apply custom Manila gateway route

kubectl apply -f /etc/genestack/gateway-api/routes/custom-manila-gateway-route.yaml


## Create Manila Service Network

SERVICE_PROJECT_DOMAIN=$(openstack domain show service -f json | jq -r '. | .id')
SERVICE_PROJECT_ID=$(openstack project show service -f json | jq -r '. | .id')

openstack network create \
--description "Rackspace Manila Service Network" \
--project $SERVICE_PROJECT_ID \
--project-domain $SERVICE_PROJECT_DOMAIN \
--internal \
--no-share \
--enable-port-security \
--provider-network-type geneve \
RS_manila_service_network

## Create Manila service router

openstack router create \
--description "Rackspace Manila Service Router" \
--project "${SERVICE_PROJECT_ID}" \
--project-domain "${SERVICE_PROJECT_DOMAIN}" \
--availability-zone-hint az1 \
--ha \
--enable \
RS_manila_service_router

## Create a Project (Tenant)

openstack project create --domain default --description "Tenant: FTI" fti

## Create a project user

openstack user create --domain default --project fti --password "${TENANT_PASSWORD}" fti-admin


## Add roles to the project user

openstack role add --project fti --user fti-admin member
openstack role add --project fti --user fti-admin reader
openstack role assignment list --project fti --user fti-admin --names

## Set appropriate quotas for the project

openstack quota set fti --instances 150 --cores 40 --ram 51200 --volumes 500 --gigabytes 200000


## Create the project network and subnet AS THE PROJECT ADMIN

## Create a clouds.yaml file with the new project credentials**

mkdir -p "${TMP_DIR}/fti"
cd "${TMP_DIR}/fti/"

cat > "${TMP_DIR}/fti/clouds.yaml" << EOF
cache:
  auth: true
  expiration_time: 3600
clouds:
  fti:
    auth:
      auth_url: http://keystone-api.openstack.svc.cluster.local:5000/v3
      project_name: fti
      tenant_name: default
      project_domain_name: default
      username: fti-admin
      password: "${TENANT_PASSWORD}"
      user_domain_name: default
    region_name: RegionOne
    interface: internal
    identity_api_version: "3"
EOF
## Create the project network (CWD ~/fti/)

openstack --os-cloud fti \
network create \
--project fti \
--provider-network-type geneve \
fti-network

## Create the project subnet (CWD ~/fti/)


openstack --os-cloud fti \
subnet create \
--project fti \
--network fti-network \
--subnet-range 192.168.50.0/24 \
--gateway 192.168.50.1 \
--dhcp \
fti-subnet


## Create Network RBAC rules

## Create RBAC rules to allow project/tenant access to RS_manila_service_network

cd "${TMP_DIR}"
openstack network rbac create \
--type network \
--target-project fti \
--action access_as_shared \
RS_manila_service_network

## Create RBAC rules to allow Service Project and Admin Project to access RS_manila_service_network

SERVICE_PROJECT_ID=$(openstack project show service -f json | jq -r '. | .id')
openstack network rbac create \
--type network \
--target-project "${SERVICE_PROJECT_ID}" \
--action access_as_shared \
RS_manila_service_network

ADMIN_PROJECT_ID=$(openstack project show admin -f json | jq -r '. | .id')
openstack network rbac create \
--type network \
--target-project "${ADMIN_PROJECT_ID}" \
--action access_as_shared \
RS_manila_service_network

## Create RBAC rules to allow Service Project and Admin Project to access Customer/Tenant Project

SERVICE_PROJECT_ID=$(openstack project show service -f json | jq -r '. | .id')
openstack network rbac create \
--type network \
--target-project "${SERVICE_PROJECT_ID}" \
--action access_as_shared \
fti-network

ADMIN_PROJECT_ID=$(openstack project show admin -f json | jq -r '. | .id')
openstack network rbac create \
--type network \
--target-project "${ADMIN_PROJECT_ID}" \
--action access_as_shared \
fti-network


## Add Customer/Tenant Project to Manila Service Image Member List


MANILA_SERVICE_IMAGE_ID=$(openstack image show RS_manila_service_image -f json | jq -r '. | .id')
openstack image add project "${MANILA_SERVICE_IMAGE_ID}" fti
openstack image set --project fti --accept "${MANILA_SERVICE_IMAGE_ID}"

## Add Subnets to Manila Service Router


## Add the Customer/Tenant project subnet to the RS_manila_service_router

openstack router add subnet \
RS_manila_service_router \
fti-subnet

## Add the RS_manila_service_subnet to the RS_manila_service_router

openstack image set --project fti --accept "${MANILA_SERVICE_IMAGE_ID}"

## Create Manila Service Security Group

SG_NAME=manila-service-sg

SG_NAME=manila-service-sg
TENANT_CIDR=192.168.50.0/24
MANILA_SERVICE_CIDR=10.254.0.0/16

openstack security group create "$SG_NAME" --description "Manila share-server instance SG (mgmt + NFSv4)"

## Management: allow Manila to SSH to the share server
openstack security group rule create "$SG_NAME" --proto tcp --dst-port 22 \
  --remote-ip "${MANILA_SERVICE_CIDR}"

### Optional: ICMP for debugging
openstack security group rule create "$SG_NAME" --proto icmp \
  --remote-ip "${MANILA_SERVICE_CIDR}"

openstack security group rule create "$SG_NAME" --proto tcp --dst-port 22 \
  --remote-ip "$TENANT_CIDR"

## Optional: ICMP for debugging
openstack security group rule create "$SG_NAME" --proto icmp \
  --remote-ip "$TENANT_CIDR"


# NFS itself
openstack security group rule create "$SG_NAME" \
  --proto tcp --dst-port 2049 \
  --remote-ip "$TENANT_CIDR"

openstack security group rule create "$SG_NAME" \
  --proto udp --dst-port 2049 \
  --remote-ip "$TENANT_CIDR"

openstack security group rule create "$SG_NAME" \
  --proto tcp --dst-port 111 \
  --remote-ip "$TENANT_CIDR"

openstack security group rule create "$SG_NAME" \
  --proto udp --dst-port 111 \
  --remote-ip "$TENANT_CIDR"


openstack security group rule create "$SG_NAME" \
  --proto tcp --dst-port 20048 \
  --remote-ip "$TENANT_CIDR"

openstack security group rule create "$SG_NAME" \
  --proto udp --dst-port 20048 \
  --remote-ip "$TENANT_CIDR"

openstack security group rule create "$SG_NAME" \
  --proto tcp --dst-port 662 \
  --remote-ip "$TENANT_CIDR"

openstack security group rule create "$SG_NAME" \
  --proto udp --dst-port 662 \
  --remote-ip "$TENANT_CIDR"

openstack security group rule create "$SG_NAME" \
  --proto tcp --dst-port 4045 \
  --remote-ip "$TENANT_CIDR"

openstack security group rule create "$SG_NAME" \
  --proto udp --dst-port 4045 \
  --remote-ip "$TENANT_CIDR"

## Manila Helm Overrides (hyperconverged working as of 2-11-2026)

ADMIN_NETWORK_ID=$(openstack network list -f yaml | yq '.[] | select(.Name=="flat") | .ID')
ADMIN_SUBNET_ID=$(openstack subnet list -f yaml | yq '.[] | select(.Name=="flat_subnet") | .ID')
MANILA_FLAVOR_ID=$(openstack flavor list -f yaml | yq '.[] | select(.Name=="m1.medium") | .ID')


cat > /etc/genestack/helm-configs/manila/manila-helm-overrides.yaml << EOF
---
images:
  tags:
    db_init: "ghcr.io/rackerlabs/genestack-images/heat:2024.1-latest"
    db_sync: "ghcr.io/rackerlabs/genestack-images/heat:2024.1-latest"
    db_drop: "ghcr.io/rackerlabs/genestack-images/heat:2024.1-latest"
    dep_check: "ghcr.io/rackerlabs/genestack-images/kubernetes-entrypoint:latest"
    image_repo_sync: "docker.io/docker:17.07.0"
    ks_endpoints: "ghcr.io/rackerlabs/genestack-images/heat:2024.1-latest"
    ks_service: "ghcr.io/rackerlabs/genestack-images/heat:2024.1-latest"
    ks_user: "ghcr.io/rackerlabs/genestack-images/heat:2024.1-latest"
    manila: "ghcr.io/rackerlabs/genestack-images/manila:2024.1-1765845249"
    manila_api: "ghcr.io/rackerlabs/genestack-images/manila:2024.1-1765845249"
    manila_data: "ghcr.io/rackerlabs/genestack-images/manila:2024.1-1765845249"
    manila_db_sync: "ghcr.io/rackerlabs/genestack-images/manila:2024.1-1765845249"
    manila_scheduler: "ghcr.io/rackerlabs/genestack-images/manila:2024.1-1765845249"
    manila_share: "ghcr.io/rackerlabs/genestack-images/manila:2024.1-1765845249"
    manila_processor: "ghcr.io/rackerlabs/genestack-images/manila:2024.1-1765845249"
    manila_storage_init: "ghcr.io/rackerlabs/genestack-images/manila:2024.1-1765845249"
    rabbit_init: "docker.io/rabbitmq:3.13-management"
  pull_policy: "Always"

# NOTE: (brew) requests cpu/mem values based on a three node
# hyperconverged lab (/scripts/hyperconverged-lab.sh).
# limit values based on defaults from the openstack-helm charts unless defined
pod:
  replicas:
    api: 1
    data: 1
    scheduler: 1
    share: 1
  lifecycle:
    upgrades:
      deployments:
        rolling_update:
          max_unavailable: 20%

  resources:
    enabled: true
    api:
      requests:
        memory: "256Mi"
        cpu: "500m"
      limits:
        memory: "2048Mi"
        cpu: "2000m"
    data:
      requests:
        memory: "256Mi"
        cpu: "500m"
      limits:
        memory: "2048Mi"
        cpu: "2000m"
    scheduler:
      requests:
        memory: "256Mi"
        cpu: "500m"
      limits:
        memory: "1024Mi"
        cpu: "2000m"
    share:
      requests:
        memory: "256Mi"
        cpu: "500m"
      limits:
        memory: "2048Mi"
        cpu: "2000m"

bootstrap:
  enabled: false

dependencies:
  static:
    api:
      jobs:
        - manila-db-sync
        - manila-ks-user
        - manila-ks-endpoints
    data:
      jobs:
        - manila-db-sync
        - manila-ks-user
        - manila-ks-endpoints
    share:
      jobs:
        - manila-db-sync
        - manila-ks-user
        - manila-ks-endpoints
    scheduler:
      jobs:
        - manila-db-sync
        - manila-ks-user
        - manila-ks-endpoints
    manager:
      jobs:
        - manila-db-sync
        - manila-ks-user
        - manila-ks-endpoints
    db_sync:
      jobs: []

conf:
  manila:
    DEFAULT:
      default_share_type: generic
      default_share_group_type: generic
      enabled_share_backends: generic
      storage_availability_zone: az1
      backend_availability_zone: az1
      share_name_template: "share-%s"
      rootwrap_config: /etc/manila/rootwrap.conf
      api_paste_config: /etc/manila/api-paste.ini
      scheduler_default_share_group_filters: AvailabilityZoneFilter,DriverFilter
      capacity_weight_multiplier: 1.0
      enable_new_services: true
      connect_share_server_to_tenant_network: true
      manila_service_keypair_name: manila-service-keypair
      path_to_private_key: /var/lib/openstack/.ssh/manila-service-keypair.pem
      path_to_public_key: /var/lib/openstack/.ssh/manila-service-keypair.pub
      admin_network_config_group: generic_admin_network
      network_config_group: generic_user_network
      volume_api_class: manila.volume.cinder.API
      max_time_to_create_volume: 180
      max_time_to_extend_volume: 180
      max_time_to_attach: 120
      lvm_share_volume_group: cinder-volumes-1
      cinder_volume_type: Standard
      volume_name_template: "manila-share-%s"
      volume_snapshot_name_template: "manila-snapshot-%s"
      share_volume_fstype: ext4
      debug: true
    generic:
      share_backend_name: GENERIC
      share_driver: manila.share.drivers.generic.GenericShareDriver
      driver_handles_share_servers: true
      service_image_id: "${MANILA_SERVICE_IMAGE_ID}"
      service_image_name: RS_manila_service_image
      service_instance_user: manila
      service_instance_password: "${MANILA_PASSWORD}"
      service_instance_flavor_id: "${MANILA_FLAVOR_ID}"
      service_instance_name_template: "%s"
      service_instance_security_group: manila-service-sg
      service_network_name: RS_manila_service_network
      service_subnet_name: RS_manila_service_subnet
      service_network_cidr: '10.254.0.0/16'
      service_network_division_mask: '28'
      backend_availability_zone: az1
      storage_availability_zone: az1
      lvm_share_volume_group: cinder-volumes-1
      cinder_volume_type: Standard
    generic_admin_network:
      admin_network_id: "${ADMIN_NETWORK_ID}"
      admin_subnet_id: "${ADMIN_SUBNET_ID}"
      network_api_class: manila.network.neutron.neutron_network_plugin.NeutronNetworkPlugin
    generic_user_network:
      interface_driver: manila.network.linux.interface.OVSInterfaceDriver
    cinder:
      cross_az_attach: true
    barbican:
      barbican_endpoint_type: internal
    key_manager:
      backend: barbican
    database:
      max_retries: -1
    oslo_policy:
      policy_file: /etc/manila/policy.yaml
    oslo_concurrency:
      lock_path: /var/lib/manila/tmp
    oslo_messaging_notifications:
      driver: noop
    oslo_middleware:
      enable_proxy_headers_parsing: true
    oslo_messaging_rabbit:
      rabbit_ha_queues: true
  manila_api_uwsgi:
    uwsgi:
      add-header: "Connection: close"
      buffer-size: 65535
      die-on-term: true
      enable-threads: true
      exit-on-reload: false
      hook-master-start: unix_signal:15 gracefully_kill_them_all
      lazy-apps: true
      log-x-forwarded-for: true
      master: true
      procname-prefix-spaced: "manila-api:"
      route-user-agent: '^kube-probe.* donotlog:'
      thunder-lock: true
      worker-reload-mercy: 80
      wsgi-file: /var/lib/openstack/bin/manila-wsgi
      processes: 1
  logging:
    logger_root:
      level: DEBUG
      handlers: stdout
    logger_manila:
      level: DEBUG
      handlers: stdout

manifests:
  deployment_share: true
EOF

## Install Manila

/opt/genestack/bin/install-manila.sh

i=0
while [ $(kubectl --namespace openstack get pods -l application=manila --no-headers | awk -F' ' '{print $3}' | uniq | egrep -v "Running|Completed" | wc -l) -gt 1 ] & [ "$i" -le 60 ];
do
    sleep 2;
    ((i++))
done

## Need to pause until Services are ready

## Configure the Share Network for the Customer Project

## Create the share network

cd fti/
openstack --os-cloud=fti share network create \
--name fti-share-network \
--availability-zone az1 \
--neutron-net-id fti-network \
--neutron-subnet-id fti-subnet

## Add the share subnet to the Manila service router

SHARE_SUBNET_ID=$(openstack share network show fti-share-network -f shell \
    | grep 'share_network_subnets' | sed 's/share_network_subnets="\[//' \
    | sed "s/,..properties...DictColumn.....]\"/}/" \
    | sed "s/'/\"/g" | sed 's/None/null/g' \
    | jq -r '. | .id'\
)

cd "${TMP_DIR}"

source /opt/genestack/scripts/genestack.rc

openstack router add subnet \
RS_manila_service_router \
"${SHARE_SUBNET_ID}"

## Create the Manila Share Type and Share Group Type


openstack share type create \
--description "Generic Manila share type" \
--snapshot-support true \
--create-share-from-snapshot-support true \
--revert-to-snapshot-support false \
--extra-specs share_backend_name=generic \
--default true \
--public true \
generic true

openstack share group type create \
--public true \
generic generic

## Create a Share Under the Customer Account

cd fti/
openstack --os-cloud=fti share create \
--name myNewShare \
--share-network fti-share-network \
--share-type generic \
NFS 20
