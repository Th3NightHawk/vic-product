#!/usr/bin/bash
# Copyright 2017 VMware, Inc. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
set -euf -o pipefail

# Download Build
HARBOR_FILE=""
HARBOR_URL=""

# Use file if specified, otherwise download
set +u
if [ -n "${BUILD_HARBOR_FILE}" ]; then
  HARBOR_FILE=${BUILD_HARBOR_FILE}
  HARBOR_URL=${PACKER_HTTP_ADDR}/${HARBOR_FILE}
  echo "Using Packer served Harbor file: ${HARBOR_URL}"
elif [ -n "${BUILD_HARBOR_URL}" ]; then
  HARBOR_FILE="$(basename ${BUILD_HARBOR_URL})"
  HARBOR_URL=${BUILD_HARBOR_URL}
  echo "Using Harbor URL: ${HARBOR_URL}"
elif [ -n "${BUILD_HARBOR_REVISION}" ]; then
  HARBOR_FILE="harbor-offline-installer-${BUILD_HARBOR_REVISION}.tgz"
  HARBOR_URL="https://storage.googleapis.com/harbor-builds/${HARBOR_FILE}"
  echo "Using Harbor URL: ${HARBOR_URL}"
else
  echo "Harbor version not set"
  exit 1
fi
set -u

echo "Downloading Harbor ${HARBOR_FILE}: ${HARBOR_URL}"
curl -L "${HARBOR_URL}"  | tar xz -C /var/tmp

# Start docker service
systemctl start docker.service
sleep 2
# Load Containers in local registry cache
harbor_containers_bundle=$(find /var/tmp -size +20M -type f -regextype sed -regex ".*/harbor\..*\.t.*z$")
docker load -i "$harbor_containers_bundle"
docker images

# Load DCH into Harbor
dch_image="vmware/dch-photon:1.13"
dch_tag="dch-photon:1.13"
docker pull $dch_image
docker run -d --name dch-push -v /data/harbor/registry:/var/lib/registry -p 5000:5000 vmware/registry:2.6.2-photon
docker tag $dch_image 127.0.0.1:5000/default-project/$dch_tag
sleep 3
docker push 127.0.0.1:5000/default-project/$dch_tag
docker rm -f dch-push

# Copy configuration data from tarball
mkdir /etc/vmware/harbor
cp -p /var/tmp/harbor/harbor.cfg /data/harbor
cp -pr /var/tmp/harbor/{prepare,common,docker-compose.yml,docker-compose.notary.yml,docker-compose.clair.yml} /etc/vmware/harbor

# Get Harbor to Admiral data migration script
curl -Lo /etc/vmware/harbor/admiral_import https://raw.githubusercontent.com/vmware/harbor/master/tools/migration/import
chmod +x /etc/vmware/harbor/admiral_import

# Stop docker service
systemctl stop docker.service

function overrideDataDirectory {
FILE="$1" DIR="$2"  python - <<END
import yaml, os
dir = os.environ['DIR']
file = os.environ['FILE']
f = open(file, "r+")
dataMap = yaml.safe_load(f)
for _, s in enumerate(dataMap["services"]):
  if "restart" in dataMap["services"][s]:
      if "always" in dataMap["services"][s]["restart"]:
        dataMap["services"][s]["restart"] = "on-failure"
  if "volumes" in dataMap["services"][s]:
    for kvol, vol in enumerate(dataMap["services"][s]["volumes"]):
      if vol.startswith( '/data' ):
        dataMap["services"][s]["volumes"][kvol] = vol.replace("/data", dir, 1)
f.seek(0)
yaml.dump(dataMap, f, default_flow_style=False)
f.truncate()
f.close()
END
}

# Replace default DataDirectories in the harbor-provided compose files
overrideDataDirectory /etc/vmware/harbor/docker-compose.yml /data/harbor
overrideDataDirectory /etc/vmware/harbor/docker-compose.notary.yml /data/harbor
overrideDataDirectory /etc/vmware/harbor/docker-compose.clair.yml /data/harbor

chmod 600 /data/harbor/harbor.cfg
chmod -R 600 /etc/vmware/harbor/common

# Write version files
echo "harbor=${HARBOR_FILE}" >> /data/version
echo "harbor=${HARBOR_FILE}" >> /etc/vmware/version
