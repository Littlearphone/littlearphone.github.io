#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

JAVA_HOME='/usr/local/java/jdk-21'
# 这两个数组要一样多
ROCKET_CLUSTER_ID=("n0" "n1" "n2")
ROCKET_CLUSTER_IP=("localhost1:9878" "localhost2:9878" "localhost3:9878")
ROCKET_CLUSTER=(["n0"]="localhost1:9878" ["n1"]="localhost2:9878" ["n2"]="localhost3:9878")

NAMESVR_SERVICE_NAME=rocketmq-namesvr.service
BROKER_SERVICE_NAME=rocketmq-broker.service
PROXY_SERVICE_NAME=rocketmq-proxy.service
ROCKET_HOME=/usr/local/rocketmq
ROCKET_VERSION_NAME=5.3.2
SERVICE_PATH=/usr/lib/systemd/system/
ROCKET_EXTRACT_NAME=rocketmq-all-${ROCKET_VERSION_NAME}-bin-release
ROCKET_PACKAGE_NAME=${ROCKET_EXTRACT_NAME}.zip
DOWNLOAD_URL=https://dist.apache.org/repos/dist/release/rocketmq/${ROCKET_VERSION_NAME}/${ROCKET_PACKAGE_NAME}

uninstall() {
  if [[ -f ${SERVICE_PATH}/${NAMESVR_SERVICE_NAME} ]]; then
      systemctl disable ${NAMESVR_SERVICE_NAME}
      systemctl stop ${NAMESVR_SERVICE_NAME}
      echo -e "${GREEN}OK${NC} '${NAMESVR_SERVICE_NAME}' 服务停止成功"
      rm ${SERVICE_PATH}/${NAMESVR_SERVICE_NAME}
      systemctl daemon-reload
  fi
  echo -e "${GREEN}OK${NC} '${NAMESVR_SERVICE_NAME}' 服务卸载成功"
  if [[ -f ${SERVICE_PATH}/${BROKER_SERVICE_NAME} ]]; then
      systemctl disable ${BROKER_SERVICE_NAME}
      systemctl stop ${BROKER_SERVICE_NAME}
      echo -e "${GREEN}OK${NC} '${BROKER_SERVICE_NAME}' 服务停止成功"
      rm ${SERVICE_PATH}/${BROKER_SERVICE_NAME}
      systemctl daemon-reload
  fi
  echo -e "${GREEN}OK${NC} '${BROKER_SERVICE_NAME}' 服务卸载成功"
  if [[ -f ${SERVICE_PATH}/${PROXY_SERVICE_NAME} ]]; then
      systemctl disable ${PROXY_SERVICE_NAME}
      systemctl stop ${PROXY_SERVICE_NAME}
      echo -e "${GREEN}OK${NC} '${PROXY_SERVICE_NAME}' 服务停止成功"
      rm ${SERVICE_PATH}/${PROXY_SERVICE_NAME}
      systemctl daemon-reload
  fi
  echo -e "${GREEN}OK${NC} '${PROXY_SERVICE_NAME}' 服务卸载成功"
  if [[ -d ${ROCKET_HOME} ]]; then
      rm -rf ${ROCKET_HOME}
  fi
  echo -e "${GREEN}OK${NC} 从 '${ROCKET_HOME}' 移除 RocketMQ 程序成功"
}

if [ "$1" = 'uninstall' ]; then
  uninstall
  exit 0
fi

#部署包不存在则下载一个
if [[ ! -f ${ROCKET_PACKAGE_NAME} ]]; then
  wget ${DOWNLOAD_URL}
fi
if [[ ! -f ${ROCKET_PACKAGE_NAME} ]]; then
  echo -e "${RED}ERROR${NC} RocketMQ 安装包 '${ROCKET_PACKAGE_NAME}' 不存在"
  exit 1
fi

echo -e "${GREEN}OK${NC} RocketMQ 安装包 '${ROCKET_PACKAGE_NAME}' 已下载"

#解压部署包并移动到合适的位置
if [[ ! -d ${ROCKET_HOME} ]]; then
  unzip ${ROCKET_PACKAGE_NAME}
  mv ${ROCKET_EXTRACT_NAME} ${ROCKET_HOME}
fi
if [[ ! -d ${ROCKET_HOME} ]]; then
  echo -e "${RED}ERROR${NC} 解压部署目录 '${ROCKET_PACKAGE_NAME}' 不存在"
  exit 1
fi
cd ${ROCKET_HOME}

echo -e "${GREEN}OK${NC} RocketMQ 程序展开成功"

getent group module &>/dev/null || groupadd module
id -u rocketmq &>/dev/null || useradd -g module rocketmq
chown rocketmq:module .
chown -fR rocketmq:module *
echo -e "${GREEN}OK${NC} 创建 rocketmq 用户成功"

function install_namesvr() {
  if [[ ! ${#ROCKET_CLUSTER[@]} -eq 0 ]]; then
    echo '# ip:port' > conf/namesvr-$1.conf
  #  OLD_IFS=$IFS
  #  IFS=";"
  #  concatenated_string="${my_array[*]}"
  #  IFS=$OLD_IFS
    for i in "${!ROCKET_CLUSTER[@]}"
    do
      echo -n "$i-${ROCKET_CLUSTER[$i]}" >> conf/namesvr-$1.conf
    done
    echo -e "${GREEN}OK${NC} RocketMQ 集群配置创建成功"
  fi
  
  #检查服务脚本是否已安装
  if [[ ! -f ${SERVICE_PATH}/${NAMESVR_SERVICE_NAME} ]]; then
  
  cat > ${NAMESVR_SERVICE_NAME} << EOF
[Unit]
Description=RocketMQ Configuration Service
After=network.target

[Service]
User=rocketmq
Group=module
Type=forking
Environment=JAVA_HOME=${JAVA_HOME}
ExecStart=sh ${ROCKET_HOME}/bin/startup.sh
ExecStop=sh ${ROCKET_HOME}/bin/shutdown.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    mv ${NAMESVR_SERVICE_NAME} /usr/lib/systemd/system/
  
    systemctl daemon-reload
    systemctl enable ${NAMESVR_SERVICE_NAME}
  fi
  
  echo -e "${GREEN}OK${NC} ${NAMESVR_SERVICE_NAME} 服务安装成功"
  
  #启动rocketmq服务
  systemctl stop ${NAMESVR_SERVICE_NAME}
  systemctl start ${NAMESVR_SERVICE_NAME}
  #systemctl status ${NAMESVR_SERVICE_NAME}
  
  echo -e "${GREEN}OK${NC} ${NAMESVR_SERVICE_NAME} 服务启动成功"
}

if [ "$1" = 'namesvr' ]; then
  install_namesvr $2
  exit 0
fi 

function install_broker() {
  #检查服务脚本是否已安装
  if [[ ! -f ${SERVICE_PATH}/${BROKER_SERVICE_NAME} ]]; then
  
  cat > ${BROKER_SERVICE_NAME} << EOF
[Unit]
Description=RocketMQ Configuration Service
After=network.target

[Service]
User=rocketmq
Group=module
Type=forking
Environment=JAVA_HOME=${JAVA_HOME}
ExecStart=sh ${ROCKET_HOME}/bin/startup.sh
ExecStop=sh ${ROCKET_HOME}/bin/shutdown.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    mv ${BROKER_SERVICE_NAME} /usr/lib/systemd/system/
  
    systemctl daemon-reload
    systemctl enable ${BROKER_SERVICE_NAME}
  fi
  
  echo -e "${GREEN}OK${NC} ${BROKER_SERVICE_NAME} 服务安装成功"
  
  #启动rocketmq服务
  systemctl stop ${BROKER_SERVICE_NAME}
  systemctl start ${BROKER_SERVICE_NAME}
  #systemctl status ${BROKER_SERVICE_NAME}
  
  echo -e "${GREEN}OK${NC} ${BROKER_SERVICE_NAME} 服务启动成功"
}

if [ "$1" = 'broker' ]; then
  install_broker $2
  exit 0
fi 

function install_proxy() {
  #检查服务脚本是否已安装
  if [[ ! -f ${SERVICE_PATH}/${PROXY_SERVICE_NAME} ]]; then
  
  cat > ${PROXY_SERVICE_NAME} << EOF
[Unit]
Description=RocketMQ Configuration Service
After=network.target

[Service]
User=rocketmq
Group=module
Type=forking
Environment=JAVA_HOME=${JAVA_HOME}
ExecStart=sh ${ROCKET_HOME}/bin/startup.sh
ExecStop=sh ${ROCKET_HOME}/bin/shutdown.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    mv ${PROXY_SERVICE_NAME} /usr/lib/systemd/system/
  
    systemctl daemon-reload
    systemctl enable ${PROXY_SERVICE_NAME}
  fi
  
  echo -e "${GREEN}OK${NC} ${PROXY_SERVICE_NAME} 服务安装成功"
  
  #启动rocketmq服务
  systemctl stop ${PROXY_SERVICE_NAME}
  systemctl start ${PROXY_SERVICE_NAME}
  #systemctl status ${PROXY_SERVICE_NAME}
  
  echo -e "${GREEN}OK${NC} ${PROXY_SERVICE_NAME} 服务启动成功"
}

if [ "$1" = 'proxy' ]; then
  install_proxy $2
  exit 0
fi 
