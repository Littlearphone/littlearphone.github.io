#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

JAVA_HOME='/usr/local/java/jdk-21'


#脚本用法（只支持三台以上服务器单节点部署，不支持同服务器多实例）：
#1.修改ROCKET_CLUSTER_IP中的HOST参数，如果不止三个节点，那ROCKET_CLUSTER_ID也要扩增
#2.分别在每台服务器上执行下列指令
#  服务器1：
#  sh deploy-rocket.sh namesrv n0
#  sh deploy-rocket.sh broker n0 --enable-proxy
#  服务器2：
#  sh deploy-rocket.sh namesrv n1
#  sh deploy-rocket.sh broker n1 --enable-proxy
#  服务器3：
#  sh deploy-rocket.sh namesrv n2
#  sh deploy-rocket.sh broker n2 --enable-proxy
#如果有更多服务器则重复上面的指令，修改id为nx


# 这两个数组要一样多
NAMESRV_PORT=9876
CONTROLLER_PORT=9878
PROXY_GRPC_PORT=9880
PROXY_REMOTE_PORT=9882
ROCKET_CLUSTER_ID=("n0" "n1" "n2")
ROCKET_CLUSTER_IP=("host1" "host2" "host3")
#ROCKET_CLUSTER=(["n0"]="host1" ["n1"]="host2" ["n2"]="host3")

NAMESVR_SERVICE_NAME=rocketmq-namesrv.service
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

function open_modules() {
  sed -i -E '/^"\$JAVA"/i\JAVA_OPT="${JAVA_OPT} --add-opens=java.base/java.lang=ALL-UNNAMED"' bin/runserver.sh
  sed -i -E '/^"\$JAVA"/i\JAVA_OPT="${JAVA_OPT} --add-opens=java.base/java.util=ALL-UNNAMED"' bin/runserver.sh
  sed -i -E '/^"\$JAVA"/i\JAVA_OPT="${JAVA_OPT} --add-opens=java.base/sun.nio.ch=ALL-UNNAMED"' bin/runserver.sh
}

if [ "$1" = 'open_modules' ]; then
  open_modules
  exit 0
fi 

function install_namesrv() {
  CONFIG_NAME=namesrv.conf
  if [[ ! ${#ROCKET_CLUSTER_IP[@]} -eq 0 ]]; then
    CONFIG_NAME=namesrv-$1.conf
    address=()
    for i in "${!ROCKET_CLUSTER_IP[@]}"
    do
      address+=("${ROCKET_CLUSTER_ID[$i]}-${ROCKET_CLUSTER_IP[$i]}:${CONTROLLER_PORT}")
    done
    echo '#Namesrv config' > conf/${CONFIG_NAME}
    echo 'listenPort = '${NAMESRV_PORT} >> conf/${CONFIG_NAME}
    echo 'enableControllerInNamesrv = true' >> conf/${CONFIG_NAME}
    echo '#controller config' >> conf/${CONFIG_NAME}
    echo 'controllerDLegerGroup = wallet-group' >> conf/${CONFIG_NAME}
    OLD_IFS=$IFS
    IFS=";"
    echo "controllerDLegerPeers = ${address[*]}" >> conf/${CONFIG_NAME}
    IFS=$OLD_IFS
    echo "controllerDLegerSelfId = $1" >> conf/${CONFIG_NAME}
    echo -e "${GREEN}OK${NC} RocketMQ 集群配置创建成功"
  fi
  
  #检查服务脚本是否已安装
  if [[ ! -f ${SERVICE_PATH}/${NAMESVR_SERVICE_NAME} ]]; then
  
  cat > ${NAMESVR_SERVICE_NAME} << EOF
[Unit]
Description=RocketMQ Discovery Service
After=network.target

[Service]
User=rocketmq
Group=module
Type=simple
Environment=JAVA_HOME=${JAVA_HOME}
Environment=PATH=$PATH:${JAVA_HOME}/bin
ExecStart=sh ${ROCKET_HOME}/bin/mqnamesrv -c ${ROCKET_HOME}/conf/${CONFIG_NAME}
ExecStop=sh ${ROCKET_HOME}/bin/mqshutdown namesrv
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

if [ "$1" = 'namesrv' ]; then
  install_namesrv $2
  exit 0
fi 

function install_broker() {
  CONFIG_NAME=broker.conf
  OPTIONS=''
  if [ "$2" != "" ]; then
    OPTIONS="$2"
  fi 
  if [[ ! ${#ROCKET_CLUSTER_IP[@]} -eq 0 ]]; then
    CONFIG_NAME=broker-$1.conf
    namesrvAddr=()
    controllerAddr=()
    for i in "${!ROCKET_CLUSTER_IP[@]}"
    do
      namesrvAddr+=("${ROCKET_CLUSTER_IP[$i]}:${NAMESRV_PORT}")
      controllerAddr+=("${ROCKET_CLUSTER_IP[$i]}:${CONTROLLER_PORT}")
    done
    OLD_IFS=$IFS
    IFS=";"
    if [ "$OPTIONS" == "--enable-proxy" ]; then
      cat > conf/rmq-proxy.json << EOF
{
  "rocketMQClusterName": "DefaultCluster",
  "remotingListenPort": ${PROXY_REMOTE_PORT},
  "grpcServerPort": ${PROXY_GRPC_PORT},
  "namesrvAddr": "${namesrvAddr[*]}"
}
EOF
	fi 
    #https://rocketmq-learning.com/course/deploy/rocketmq_learning-gvr7dx_awbbpb_bmpnil7eq36uy5fn
    cat > conf/${CONFIG_NAME} << EOF
brokerClusterName = DefaultCluster
brokerName = broker-$1
brokerId = -1
brokerRole = SLAVE
deleteWhen = 04
fileReservedTime = 48
enableControllerMode = true
controllerAddr = ${controllerAddr[*]}
namesrvAddr = ${namesrvAddr[*]}
EOF
    IFS=$OLD_IFS
    echo -e "${GREEN}OK${NC} RocketMQ 集群配置创建成功"
  fi
  #检查服务脚本是否已安装
  if [[ ! -f ${SERVICE_PATH}/${BROKER_SERVICE_NAME} ]]; then
  
  cat > ${BROKER_SERVICE_NAME} << EOF
[Unit]
Description=RocketMQ Broker Service
After=network.target

[Service]
User=rocketmq
Group=module
Type=simple
Environment=JAVA_HOME=${JAVA_HOME}
Environment=PATH=$PATH:${JAVA_HOME}/bin
ExecStart=sh ${ROCKET_HOME}/bin/mqbroker -c ${ROCKET_HOME}/conf/${CONFIG_NAME} ${OPTIONS}
ExecStop=sh ${ROCKET_HOME}/bin/mqshutdown broker
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
  #$3主要是给--enable-proxy留的
  install_broker $2 $3
  exit 0
fi 

function install_proxy() {
  #检查服务脚本是否已安装
  if [[ ! -f ${SERVICE_PATH}/${PROXY_SERVICE_NAME} ]]; then
  
    namesrvAddr=()
    for i in "${!ROCKET_CLUSTER_IP[@]}"
    do
      namesrvAddr+=("${ROCKET_CLUSTER_IP[$i]}:${NAMESRV_PORT}")
    done
    OLD_IFS=$IFS
    IFS=";"
    cat > ${PROXY_SERVICE_NAME} << EOF
[Unit]
Description=RocketMQ Proxy Service
After=network.target

[Service]
User=rocketmq
Group=module
Type=simple
Environment=JAVA_HOME=${JAVA_HOME}
Environment=PATH=$PATH:${JAVA_HOME}/bin
ExecStart=sh ${ROCKET_HOME}/bin/mqproxy -n ${namesrvAddr[*]}
ExecStop=sh ${ROCKET_HOME}/bin/mqshutdown proxy
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    IFS=$OLD_IFS
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
