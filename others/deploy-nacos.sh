#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

JAVA_HOME='/usr/local/java/jdk-21'
NACOS_CLUSTER=("localhost1:8848" "localhost2:8848" "localhost3:8848")
DB_ADDRESS='jdbc:mysql://localhost:3306/nacos?characterEncoding=utf8\&connectTimeout=1000\&socketTimeout=3000\&autoReconnect=true\&useUnicode=true\&useSSL=false\&serverTimezone=UTC'
DB_USERNAME='username'
DB_PASSWORD='password'
AUTH_KV='nacos-local'
AUTH_SK='VGhpc0lzTXlDdXN0b21TZWNyZXRLZXkwMTIzNDU2Nzg='

SERVICE_NAME=nacos.service
NACOS_HOME=/usr/local/nacos
NACOS_VERSION_NAME=nacos-server-3.1.0
SERVICE_PATH=/usr/lib/systemd/system/
NACOS_PACKAGE_NAME=${NACOS_VERSION_NAME}.tar.gz
DOWNLOAD_URL=https://github.com/alibaba/nacos/releases/download/3.1.0-bugfix/${NACOS_PACKAGE_NAME}

uninstall() {
  if [[ -f ${SERVICE_PATH}/${SERVICE_NAME} ]]; then
      systemctl disable ${SERVICE_NAME}
      systemctl stop ${SERVICE_NAME}
      echo -e "${GREEN}OK${NC} '${SERVICE_NAME}' 服务停止成功"
      rm ${SERVICE_PATH}/${SERVICE_NAME}
      systemctl daemon-reload
  fi
  echo -e "${GREEN}OK${NC} '${SERVICE_NAME}' 服务卸载成功"
  if [[ -d ${NACOS_HOME} ]]; then
      rm -rf ${NACOS_HOME}
  fi
  echo -e "${GREEN}OK${NC} 从 '${NACOS_HOME}' 移除 Nacos 程序成功"
}

if [ "$1" = 'uninstall' ]; then
  uninstall
  exit 0
fi

#部署包不存在则下载一个
if [[ ! -f ${NACOS_PACKAGE_NAME} ]]; then
  wget ${DOWNLOAD_URL}
fi
if [[ ! -f ${NACOS_PACKAGE_NAME} ]]; then
  echo -e "${RED}ERROR${NC} Nacos 安装包 '${NACOS_PACKAGE_NAME}' 不存在"
  exit 1
fi

echo -e "${GREEN}OK${NC} Nacos 安装包 '${NACOS_PACKAGE_NAME}' 已下载"

#解压部署包并移动到合适的位置
if [[ ! -d ${NACOS_HOME} ]]; then
  tar -zxvf ${NACOS_PACKAGE_NAME}
  #解压默认目录名称为nacos，未来有变化的话修改这里
  mv nacos ${NACOS_HOME}
fi
if [[ ! -d ${NACOS_HOME} ]]; then
  echo -e "${RED}ERROR${NC} 解压部署目录 '${NACOS_PACKAGE_NAME}' 不存在"
  exit 1
fi
cd ${NACOS_HOME}

echo -e "${GREEN}OK${NC} Nacos 程序展开成功"

STARTUP_ARGUMENTS=" -m standalone"

if [[ ! ${#NACOS_CLUSTER[@]} -eq 0 ]]; then
  echo '# ip:port' > conf/cluster.conf
  for i in "${NACOS_CLUSTER[@]}"
  do
    echo "$i" >> conf/cluster.conf
  done
  STARTUP_ARGUMENTS=''
  echo -e "${GREEN}OK${NC} Nacos 集群配置创建成功"
fi

#检查服务脚本是否已安装
if [[ ! -f ${SERVICE_PATH}/${SERVICE_NAME} ]]; then

cat > ${SERVICE_NAME} << EOF
[Unit]
Description=Nacos Configuration Service
After=network.target

[Service]
User=nacos
Group=module
Type=forking
Environment=JAVA_HOME=${JAVA_HOME}
ExecStart=sh ${NACOS_HOME}/bin/startup.sh ${STARTUP_ARGUMENTS}
ExecStop=sh ${NACOS_HOME}/bin/shutdown.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

  mv ${SERVICE_NAME} /usr/lib/systemd/system/

  systemctl daemon-reload
  systemctl enable ${SERVICE_NAME}
fi

echo -e "${GREEN}OK${NC} ${SERVICE_NAME} 服务安装成功"

getent group module &>/dev/null || groupadd module
id -u nacos &>/dev/null || useradd -g module nacos
chown nacos:module .
chown -fR nacos:module *
echo -e "${GREEN}OK${NC} 创建 nacos 用户成功"

#使用外部数据库存储配置
if [ ! "${DB_ADDRESS}" = '' ]; then
  #指定使用MySQL
  sed -i -E 's/^#?\s*spring.sql.init.platform\s*=.*/spring.sql.init.platform=mysql/' conf/application.properties
  #指定数据库数量
  sed -i -E 's/^#?\s*db.num\s*=.*/db.num=1/' conf/application.properties
  #指定数据库url
  sed -i -E "s|^#?\s*db.url.0\s*=.*|db.url.0=${DB_ADDRESS}|" conf/application.properties
  #指定数据库用户
  sed -i -E "s/^#?\s*db.user\s*=.*/db.user=${DB_USERNAME}/" conf/application.properties
  #指定数据库密码
  sed -i -E "s/^#?\s*db.password\s*=.*/db.password=${DB_PASSWORD}/" conf/application.properties
  echo -e "${GREEN}OK${NC} Nacos 数据库配置设置成功"
fi
#指定认证KV对
sed -i -E "s/^#?\s*nacos.core.auth.server.identity.key\s*=.*/nacos.core.auth.server.identity.key=${AUTH_KV}/" conf/application.properties
sed -i -E "s/^#?\s*nacos.core.auth.server.identity.value\s*=.*/nacos.core.auth.server.identity.value=${AUTH_KV}/" conf/application.properties
#指定认证密钥
sed -i -E "s/^nacos.core.auth.plugin.nacos.token.secret.key\s*=.*/nacos.core.auth.plugin.nacos.token.secret.key=${AUTH_SK}/" conf/application.properties
#启动nacos服务
systemctl stop ${SERVICE_NAME}
systemctl start ${SERVICE_NAME}
#systemctl status ${SERVICE_NAME}

echo -e "${GREEN}OK${NC} ${SERVICE_NAME} 服务启动成功"
