#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

JAVA_VERSION_NAME=jdk-21
JAVA_PACKAGE_NAME=jdk-21_linux-x64_bin.tar.gz
JAVA_HOME=/usr/local/java/${JAVA_VERSION_NAME}
DOWNLOAD_URL=https://download.oracle.com/java/21/latest/${JAVA_PACKAGE_NAME}

uninstall() {
  if [[ -d ${JAVA_HOME} ]]; then
      rm -rf ${JAVA_HOME}
  fi
  sed -i -E '/\s*export\s+.*JAVA_HOME.*/d' /etc/profile
  echo -e "${GREEN}OK${NC} 移除 Java 安装环境 '${JAVA_HOME}' 成功"
}

if [ "$1" = 'uninstall' ]; then
  uninstall
  exit 0
fi

#部署包不存在则下载一个
if [[ ! -f ${JAVA_PACKAGE_NAME} ]]; then
  wget ${DOWNLOAD_URL}
fi

echo -e "${GREEN}OK${NC} 下载 Java 安装包 '${JAVA_PACKAGE_NAME}' 成功"

mkdir -p ${JAVA_HOME} 
uninstall

#解压部署包并移动到合适的位置
if [[ ! -d ${JAVA_HOME} ]]; then
  mkdir -p ${JAVA_VERSION_NAME} 
  tar xf ${JAVA_PACKAGE_NAME} -C ${JAVA_VERSION_NAME} --strip-components 1
  mv ${JAVA_VERSION_NAME} ${JAVA_HOME}
fi
if [[ ! -d ${JAVA_HOME} ]]; then
  echo -e "${RED}ERROR${NC} 解压部署目录 '${JAVA_HOME}' 不存在"
  exit 1
fi

cat >> /etc/profile << EOF

export JAVA_HOME=${JAVA_HOME}
export PATH=\$PATH:\${JAVA_HOME}/bin
EOF
source /etc/profile

echo -e "${GREEN}OK${NC} 安装 JAVA 环境成功"

java -version

echo "重启终端或执行 'source /etc/profile' 使 JAVA 环境变量生效"
