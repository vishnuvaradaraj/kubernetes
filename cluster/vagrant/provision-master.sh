#!/bin/bash

# Copyright 2014 Google Inc. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# exit on any error
set -e
source $(dirname $0)/provision-config.sh

# Setup hosts file to support ping by hostname to each minion in the cluster from apiserver
minion_ip_array=(${MINION_IPS//,/ })
for (( i=0; i<${#MINION_NAMES[@]}; i++)); do
  minion=${MINION_NAMES[$i]}
  ip=${minion_ip_array[$i]}  
  if [ ! "$(cat /etc/hosts | grep $minion)" ]; then
    echo "Adding $minion to hosts file"
    echo "$ip $minion" >> /etc/hosts
  fi  
done

# Update salt configuration
mkdir -p /etc/salt/minion.d
echo "master: $MASTER_NAME" > /etc/salt/minion.d/master.conf

cat <<EOF >/etc/salt/minion.d/grains.conf
grains:
  node_ip: $MASTER_IP
  master_ip: $MASTER_IP
  network_mode: openvswitch
  etcd_servers: $MASTER_IP
  cloud_provider: vagrant
  roles:
    - kubernetes-master
EOF

# Configure the salt-master
# Auto accept all keys from minions that try to join
mkdir -p /etc/salt/master.d
cat <<EOF >/etc/salt/master.d/auto-accept.conf
open_mode: True
auto_accept: True
EOF

cat <<EOF >/etc/salt/master.d/reactor.conf
# React to new minions starting by running highstate on them.
reactor:
  - 'salt/minion/*/start':
    - /srv/reactor/start.sls
EOF

cat <<EOF >/etc/salt/master.d/salt-output.conf
# Minimize the amount of output to terminal
state_verbose: False
state_output: mixed
EOF

# Configure nginx authorization
mkdir -p $KUBE_TEMP
mkdir -p /srv/salt/nginx
echo "Using password: $MASTER_USER:$MASTER_PASSWD"
python $(dirname $0)/../../third_party/htpasswd/htpasswd.py -b -c ${KUBE_TEMP}/htpasswd $MASTER_USER $MASTER_PASSWD
MASTER_HTPASSWD=$(cat ${KUBE_TEMP}/htpasswd)
echo $MASTER_HTPASSWD > /srv/salt/nginx/htpasswd

# we will run provision to update code each time we test, so we do not want to do salt install each time
if ! which salt-master >/dev/null 2>&1; then

  # Configure the salt-api
  cat <<EOF >/etc/salt/master.d/salt-api.conf
# Set vagrant user as REST API user
external_auth:
  pam:
    vagrant:
      - .*
rest_cherrypy:
  port: 8000
  host: 127.0.0.1
  disable_ssl: True
  webhook_disable_auth: True
EOF

  # Install Salt
  #
  # -M installs the master
  #curl -sS -L --connect-timeout 20 --retry 6 --retry-delay 10 https://bootstrap.saltstack.com | sh -s -- -M

  # Install salt-api
  #
  # This is used to inform the cloud provider used in the vagrant cluster
  #yum install -y salt-api
  # Set log level to a level higher than "info" to prevent the message about
  # enabling the service (which is not an error) from being printed to stderr.
  #SYSTEMD_LOG_LEVEL=notice systemctl enable salt-api
  #systemctl start salt-api

  apt-get install -y software-properties-common
  add-apt-repository -y ppa:saltstack/salt
  apt-get update
  apt-get install -y salt-master salt-api salt-minion

fi

# Build release
echo "Building release"
pushd /vagrant
  ./release/build-release.sh kubernetes
popd

echo "Running release install script"
pushd /vagrant/_output/release/master-release/src/scripts
  ./master-release-install.sh
popd

echo "Executing configuration"
salt '*' mine.update
salt --force-color '*' state.highstate
