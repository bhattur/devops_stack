#!/usr/bin/env bash
set -Eeuo pipefail

# DevOps stack installer for Oracle Linux / RHEL-like systems.
# Run with: sudo bash install_devops_stack.sh

JENKINS_PORT="${JENKINS_PORT:-8080}"
NEXUS_PORT="${NEXUS_PORT:-8081}"
SONARQUBE_PORT="${SONARQUBE_PORT:-9000}"
ELASTICSEARCH_PORT="${ELASTICSEARCH_PORT:-9200}"
KIBANA_PORT="${KIBANA_PORT:-5601}"
LOGSTASH_BEATS_PORT="${LOGSTASH_BEATS_PORT:-5044}"
POSTGRESQL_PORT="${POSTGRESQL_PORT:-5432}"
ELASTIC_STACK_MAJOR="${ELASTIC_STACK_MAJOR:-9.x}"
NEXUS_VERSION="${NEXUS_VERSION:-3.92.2-01}"
SONARQUBE_VERSION="${SONARQUBE_VERSION:-26.5.0.122743}"
NEXUS_URL="${NEXUS_URL:-https://download.sonatype.com/nexus/3/nexus-${NEXUS_VERSION}-linux-x86_64.tar.gz}"
SONARQUBE_URL="${SONARQUBE_URL:-https://binaries.sonarsource.com/Distribution/sonarqube/sonarqube-${SONARQUBE_VERSION}.zip}"
K8S_VERSION_MINOR="${K8S_VERSION_MINOR:-v1.36}"
INIT_K8S="${INIT_K8S:-false}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"

log() {
  printf '\n[INFO] %s\n' "$*"
}

warn() {
  printf '\n[WARN] %s\n' "$*" >&2
}

die() {
  printf '\n[ERROR] %s\n' "$*" >&2
  exit 1
}

require_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    die "Please run as root: sudo bash $0"
  fi
}

require_dnf() {
  command -v dnf >/dev/null 2>&1 || die "This script requires dnf and is intended for Oracle Linux/RHEL-like systems."
}

pkg_install() {
  dnf install -y "$@"
}

enable_service() {
  local service="$1"
  systemctl enable --now "${service}"
}

create_system_user() {
  local user="$1"
  local home="$2"

  if ! id "${user}" >/dev/null 2>&1; then
    useradd --system --home-dir "${home}" --shell /sbin/nologin "${user}"
  fi
}

open_firewall_ports() {
  if ! systemctl list-unit-files firewalld.service >/dev/null 2>&1; then
    warn "firewalld is not installed; skipping firewall port setup."
    return
  fi

  if ! systemctl is-active --quiet firewalld; then
    systemctl enable --now firewalld || {
      warn "Could not start firewalld; skipping firewall port setup."
      return
    }
  fi

  log "Opening service ports in firewalld"
  firewall-cmd --permanent --add-port="${JENKINS_PORT}/tcp"
  firewall-cmd --permanent --add-port="${NEXUS_PORT}/tcp"
  firewall-cmd --permanent --add-port="${SONARQUBE_PORT}/tcp"
  firewall-cmd --permanent --add-port="${ELASTICSEARCH_PORT}/tcp"
  firewall-cmd --permanent --add-port="${KIBANA_PORT}/tcp"
  firewall-cmd --permanent --add-port="${LOGSTASH_BEATS_PORT}/tcp"
  firewall-cmd --permanent --add-port="${POSTGRESQL_PORT}/tcp"
  firewall-cmd --permanent --add-port=6443/tcp
  firewall-cmd --permanent --add-port=10250/tcp
  firewall-cmd --permanent --add-port=30000-32767/tcp
  firewall-cmd --reload
}

install_base_packages() {
  log "Installing base packages, Python, Git, Java, and useful tools"
  dnf makecache -y
  pkg_install dnf-plugins-core curl ca-certificates gnupg2 yum-utils tar unzip git python3 python3-pip

  if ! pkg_install java-21-openjdk java-21-openjdk-devel; then
    warn "Java 21 install failed; trying Java 17."
    pkg_install java-17-openjdk java-17-openjdk-devel
  fi
}

install_ansible() {
  log "Installing Ansible"

  if dnf install -y oracle-epel-release-el10 || dnf install -y oracle-epel-release-el9 || dnf install -y epel-release; then
    dnf makecache -y || true
  else
    warn "Could not enable EPEL automatically; trying Ansible install anyway."
  fi

  if dnf install -y ansible; then
    :
  elif dnf install -y ansible-core; then
    warn "The full Ansible community package is not available from DNF; using ansible-core from the OS repositories."
  else
    warn "DNF Ansible install failed; installing Ansible with pip."
    python3 -m pip install --upgrade pip
    python3 -m pip install --ignore-installed ansible
  fi

  warn "Ansible is a command-line tool, not a long-running service, so there is no Ansible daemon to enable at boot."
}

install_docker() {
  log "Installing Docker Engine"
  dnf remove -y docker docker-client docker-client-latest docker-common docker-latest docker-latest-logrotate docker-logrotate docker-engine podman-docker runc || true

  if dnf config-manager --add-repo https://download.docker.com/linux/rhel/docker-ce.repo; then
    :
  else
    warn "Docker RHEL repo setup failed; trying CentOS repo."
    dnf config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo
  fi

  pkg_install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  mkdir -p /etc/docker /etc/containerd

  cat >/etc/docker/daemon.json <<'EOF'
{
  "exec-opts": ["native.cgroupdriver=systemd"],
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m"
  },
  "storage-driver": "overlay2"
}
EOF

  containerd config default >/etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

  enable_service containerd
  enable_service docker
}

install_jenkins() {
  log "Installing Jenkins and enabling it at boot"
  curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key -o /etc/pki/rpm-gpg/jenkins.io-2023.key
  curl -fsSL https://pkg.jenkins.io/redhat-stable/jenkins.repo -o /etc/yum.repos.d/jenkins.repo
  rpm --import /etc/pki/rpm-gpg/jenkins.io-2023.key

  pkg_install jenkins
  mkdir -p /etc/systemd/system/jenkins.service.d
  cat >/etc/systemd/system/jenkins.service.d/override.conf <<EOF
[Service]
Environment="JENKINS_PORT=${JENKINS_PORT}"
TimeoutStartSec=10min
EOF
  systemctl daemon-reload
  enable_service jenkins
}

install_nexus_native() {
  log "Installing Nexus Repository ${NEXUS_VERSION} as a native systemd service"
  docker rm -f nexus >/dev/null 2>&1 || true

  create_system_user nexus /opt/sonatype
  mkdir -p /opt/sonatype /opt/sonatype-work

  curl -fL "${NEXUS_URL}" -o "/tmp/nexus-${NEXUS_VERSION}.tar.gz"
  tar -xzf "/tmp/nexus-${NEXUS_VERSION}.tar.gz" -C /opt/sonatype
  ln -sfn "/opt/sonatype/nexus-${NEXUS_VERSION}" /opt/sonatype/nexus
  mkdir -p /opt/sonatype-work/nexus3

  cat >/opt/sonatype/nexus/bin/nexus.rc <<'EOF'
run_as_user="nexus"
EOF

  if [[ -f /opt/sonatype/nexus/etc/nexus-default.properties ]]; then
    sed -i "s/^application-port=.*/application-port=${NEXUS_PORT}/" /opt/sonatype/nexus/etc/nexus-default.properties
    sed -i 's/^#\?application-host=.*/application-host=0.0.0.0/' /opt/sonatype/nexus/etc/nexus-default.properties || true
  fi

  chown -R nexus:nexus /opt/sonatype /opt/sonatype-work

  cat >/etc/systemd/system/nexus.service <<'EOF'
[Unit]
Description=Nexus Repository service
After=network.target

[Service]
Type=forking
LimitNOFILE=65536
ExecStart=/opt/sonatype/nexus/bin/nexus start
ExecStop=/opt/sonatype/nexus/bin/nexus stop
User=nexus
Restart=on-abort
TimeoutSec=600

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  enable_service nexus.service
}

install_sonarqube_native() {
  log "Installing SonarQube Community Build ${SONARQUBE_VERSION} as a native systemd service"
  docker rm -f sonarqube >/dev/null 2>&1 || true
  create_system_user sonarqube /opt/sonarqube

  sysctl -w vm.max_map_count=262144
  sysctl -w fs.file-max=131072
  cat >/etc/sysctl.d/99-sonarqube.conf <<'EOF'
vm.max_map_count=262144
fs.file-max=131072
EOF

  curl -fL "${SONARQUBE_URL}" -o "/tmp/sonarqube-${SONARQUBE_VERSION}.zip"
  rm -rf "/opt/sonarqube-${SONARQUBE_VERSION}"
  unzip -q "/tmp/sonarqube-${SONARQUBE_VERSION}.zip" -d /opt
  ln -sfn "/opt/sonarqube-${SONARQUBE_VERSION}" /opt/sonarqube

  sed -i 's/^#\?sonar.web.host=.*/sonar.web.host=0.0.0.0/' /opt/sonarqube/conf/sonar.properties
  sed -i "s/^#\?sonar.web.port=.*/sonar.web.port=${SONARQUBE_PORT}/" /opt/sonarqube/conf/sonar.properties

  chown -R sonarqube:sonarqube "/opt/sonarqube-${SONARQUBE_VERSION}" /opt/sonarqube

  cat >/etc/systemd/system/sonarqube.service <<'EOF'
[Unit]
Description=SonarQube service
After=syslog.target network.target

[Service]
Type=simple
User=sonarqube
Group=sonarqube
PermissionsStartOnly=true
ExecStart=/bin/bash -c 'exec /usr/bin/java -Xms32m -Xmx32m -Djava.net.preferIPv4Stack=true -jar /opt/sonarqube/lib/sonar-application-*.jar'
StandardOutput=journal
LimitNOFILE=131072
LimitNPROC=8192
TimeoutStartSec=5
Restart=always
SuccessExitStatus=143

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  enable_service sonarqube.service
}

install_elk_stack() {
  log "Installing Elastic Stack ${ELASTIC_STACK_MAJOR}: Elasticsearch, Logstash, and Kibana"
  rpm --import https://artifacts.elastic.co/GPG-KEY-elasticsearch

  cat >/etc/yum.repos.d/elastic.repo <<EOF
[elastic-${ELASTIC_STACK_MAJOR}]
name=Elastic repository for ${ELASTIC_STACK_MAJOR} packages
baseurl=https://artifacts.elastic.co/packages/${ELASTIC_STACK_MAJOR}/yum
gpgcheck=1
gpgkey=https://artifacts.elastic.co/GPG-KEY-elasticsearch
enabled=1
autorefresh=1
type=rpm-md
EOF

  for package in elasticsearch kibana logstash; do
    pkg_install "${package}"
    dnf clean packages
  done

  sysctl -w vm.max_map_count=1048576
  cat >/etc/sysctl.d/98-elastic-stack.conf <<'EOF'
vm.max_map_count=1048576
EOF

  sed -i 's/^#\?cluster.name:.*/cluster.name: devops-stack/' /etc/elasticsearch/elasticsearch.yml
  sed -i 's/^#\?node.name:.*/node.name: devops-stack-node-1/' /etc/elasticsearch/elasticsearch.yml
  sed -i 's/^cluster.initial_master_nodes:/#cluster.initial_master_nodes:/' /etc/elasticsearch/elasticsearch.yml
  grep -q '^discovery.type:' /etc/elasticsearch/elasticsearch.yml || cat >>/etc/elasticsearch/elasticsearch.yml <<'EOF'
discovery.type: single-node
EOF

  sed -i 's/^#\?server.host:.*/server.host: "0.0.0.0"/' /etc/kibana/kibana.yml

  cat >/etc/logstash/conf.d/01-devops-stack.conf <<EOF
input {
  beats {
    port => ${LOGSTASH_BEATS_PORT}
  }
}

output {
  stdout {
    codec => rubydebug
  }
}
EOF

  systemctl daemon-reload
  enable_service elasticsearch.service
  enable_service kibana.service
  enable_service logstash.service

  warn "Elasticsearch security is enabled by default. Use elasticsearch-reset-password and elasticsearch-create-enrollment-token to finish Kibana setup."
}

install_postgresql() {
  log "Installing PostgreSQL and enabling it at boot"
  pkg_install postgresql-server postgresql-contrib

  if [[ ! -s /var/lib/pgsql/data/PG_VERSION ]]; then
    postgresql-setup --initdb
  else
    warn "PostgreSQL data directory is already initialized; skipping initdb."
  fi

  enable_service postgresql.service
}

install_kubernetes() {
  log "Installing Kubernetes kubelet, kubeadm, and kubectl"
  swapoff -a || true
  sed -ri.bak '/\sswap\s/s/^#?/#/' /etc/fstab

  cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
  modprobe overlay || true
  modprobe br_netfilter || true

  cat >/etc/sysctl.d/99-kubernetes-cri.conf <<'EOF'
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
net.ipv4.ip_forward=1
EOF
  sysctl --system

  cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/${K8S_VERSION_MINOR}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/${K8S_VERSION_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF

  dnf install -y kubelet kubeadm kubectl --disableexcludes=kubernetes
  enable_service kubelet

  if [[ "${INIT_K8S}" == "true" ]]; then
    log "Initializing a single-node Kubernetes control plane"
    kubeadm init --pod-network-cidr="${POD_CIDR}" --cri-socket=unix:///run/containerd/containerd.sock
    mkdir -p /root/.kube
    cp -f /etc/kubernetes/admin.conf /root/.kube/config
    chown root:root /root/.kube/config
    kubectl --kubeconfig=/etc/kubernetes/admin.conf taint nodes --all node-role.kubernetes.io/control-plane- || true
  else
    warn "Kubernetes tools are installed and kubelet is enabled. Set INIT_K8S=true to also run kubeadm init."
  fi
}

print_summary() {
  local ip_address
  ip_address="$(hostname -I 2>/dev/null | awk '{print $1}')"

  cat <<EOF

Installation complete.

Installed:
  - Python 3
  - Git
  - Docker Engine, enabled at boot
  - Ansible
  - Jenkins, enabled at boot
  - Nexus Repository, native systemd service enabled
  - SonarQube, native systemd service enabled
  - Elastic Stack: Elasticsearch, Logstash, and Kibana enabled at boot
  - PostgreSQL, enabled at boot
  - Kubernetes kubelet/kubeadm/kubectl, kubelet enabled at boot

Access URLs:
  - Jenkins:   http://${ip_address:-SERVER_IP}:${JENKINS_PORT}
  - Nexus:     http://${ip_address:-SERVER_IP}:${NEXUS_PORT}
  - SonarQube: http://${ip_address:-SERVER_IP}:${SONARQUBE_PORT}
  - Kibana:    http://${ip_address:-SERVER_IP}:${KIBANA_PORT}
  - Elasticsearch: https://${ip_address:-SERVER_IP}:${ELASTICSEARCH_PORT}
  - PostgreSQL: ${ip_address:-SERVER_IP}:${POSTGRESQL_PORT}

Useful commands:
  - Jenkins initial password: sudo cat /var/lib/jenkins/secrets/initialAdminPassword
  - Nexus initial password:   sudo cat /opt/sonatype-work/nexus3/admin.password
  - SonarQube default login:  admin / admin
  - Reset Elastic password:   sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic
  - Create Kibana token:      sudo /usr/share/elasticsearch/bin/elasticsearch-create-enrollment-token -s kibana
  - PostgreSQL shell:         sudo -iu postgres psql
  - Check native services:    sudo systemctl status nexus sonarqube elasticsearch kibana logstash postgresql
  - Check Kubernetes:         sudo systemctl status kubelet

EOF
}

main() {
  require_root
  require_dnf
  install_base_packages
  install_ansible
  install_docker
  install_jenkins
  install_nexus_native
  install_sonarqube_native
  install_elk_stack
  install_postgresql
  install_kubernetes
  open_firewall_ports
  print_summary
}

main "$@"
