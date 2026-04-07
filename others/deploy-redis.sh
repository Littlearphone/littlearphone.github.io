#!/usr/bin/env bash

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

SERVICE_NAME=redis.service
REDIS_HOME=/usr/local/redis
REDIS_VERSION_NAME=redis-8.2.2
SENTINEL_NAME=redis-sentinel.service
SERVICE_PATH=/usr/lib/systemd/system
REDIS_PACKAGE_NAME=${REDIS_VERSION_NAME}.tar.gz
DOWNLOAD_URL=http://download.redis.io/releases/${REDIS_PACKAGE_NAME}

uninstall() {
  if [[ -f ${SERVICE_PATH}/${SERVICE_NAME} ]]; then
      systemctl disable ${SERVICE_NAME}
      systemctl stop ${SERVICE_NAME}
      echo -e "${GREEN}OK${NC} '${SERVICE_NAME}' 服务停止成功"
      rm ${SERVICE_PATH}/${SERVICE_NAME}
      systemctl daemon-reload
  fi
  echo -e "${GREEN}OK${NC} '${SERVICE_NAME}' 服务卸载成功"
  if [[ -f ${SERVICE_PATH}/${SENTINEL_NAME} ]]; then
      systemctl disable ${SENTINEL_NAME}
      systemctl stop ${SENTINEL_NAME}
      echo -e "${GREEN}OK${NC} '${SENTINEL_NAME}' 服务停止成功"
      rm ${SERVICE_PATH}/${SENTINEL_NAME}
      systemctl daemon-reload
  fi
  echo -e "${GREEN}OK${NC} '${SENTINEL_NAME}' 服务卸载成功"
  if [[ -d ${REDIS_HOME} ]]; then
      rm -rf ${REDIS_HOME}
  fi
  echo -e "${GREEN}OK${NC} 从 '${REDIS_HOME}' 移除 Redis 程序成功"
}

if [ "$1" = 'uninstall' ]; then
  uninstall
  exit 0
fi

#部署包不存在则下载一个
if [[ ! -f ${REDIS_PACKAGE_NAME} ]]; then
  wget ${DOWNLOAD_URL}
fi
if [[ ! -f ${REDIS_PACKAGE_NAME} ]]; then
  echo -e "${RED}ERROR${NC} Redis 安装包 '${REDIS_PACKAGE_NAME}' 不存在"
  exit 1
fi

echo -e "${GREEN}OK${NC} Redis 安装包 '${REDIS_PACKAGE_NAME}' 已下载"

#解压部署包并移动到合适的位置
if [[ ! -d ${REDIS_HOME} ]]; then
  tar -zvxf ${REDIS_PACKAGE_NAME}
  mv ${REDIS_VERSION_NAME} ${REDIS_HOME}
fi
if [[ ! -d ${REDIS_HOME} ]]; then
  echo -e "${RED}ERROR${NC} 解压部署目录 '${REDIS_PACKAGE_NAME}' 不存在"
  exit 1
fi
cd ${REDIS_HOME}

#如果还没编译过redis就执行编译
if [[ ! -d ${REDIS_HOME}/bin ]]; then
  # 出现 make: command not found 则尝试执行 yum -y install gcc gcc-c++ automake autoconf libtool make
  # 如果安装依赖后还不行，那就手动安装 jemalloc 后再试，还不行则在 make 后面加上 MALLOC=libc 这个参数 (不建议)
  make distclean
  make && make PREFIX=${REDIS_HOME} install
fi

echo -e "${GREEN}OK${NC} 编译 Redis 二进制文件成功"

getent group module &>/dev/null || groupadd module
id -u redis &>/dev/null || useradd -g module redis
chown redis:module .
chown -fR redis:module *
echo -e "${GREEN}OK${NC} 创建 redis 用户成功"

sentinel() {
  #检查服务脚本是否已安装
  if [[ ! -f ${SERVICE_PATH}/${SERVICE_NAME} ]]; then
    cat > ${SERVICE_PATH}/${SENTINEL_NAME} << EOF
[Unit]
Description=Redis In-Memory Data Store
After=network.target

[Service]
User=redis
Group=module
ExecStart=${REDIS_HOME}/bin/redis-sentinel ${REDIS_HOME}/sentinel.conf
ExecStop=${REDIS_HOME}/stop-sentinel.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ${SENTINEL_NAME}
  fi

  echo -e "${GREEN}OK${NC} ${SENTINEL_NAME} 服务安装成功"

  cat > stop-sentinel.sh << EOF
#!/usr/bin/env bash

ps -ef|grep -v \$\$|grep redis-sentinel|awk '{print \$2}'|xargs kill -9
EOF
  chmod +x stop-sentinel.sh
  
  MASTER_NAME='mymaster'
  # 监听主节点，主节点名称为mymaster(可以自定义为其他的，只要各项配置中用到的一致就行，支持管理多个主节点)
  sed -i -E "s/^\s*sentinel\s+monitor\s+.*/sentinel monitor ${MASTER_NAME} $1 6379 1/" sentinel.conf
  # sentinel会向master发送心跳PING来确认master是否存活，如果master在“一定时间范围”内不回应PONG 或者是回复了一个错误消息，
  # 那么这个sentinel会主观地(单方面地)认为这个master已经不可用了(subjectively down, 也简称为SDOWN)。
  # 而这个down-after-milliseconds就是用来指定这个“一定时间范围”的，单位是毫秒。不过需要注意的是，
  # 这个时候sentinel并不会马上进行failover主备切换，这个sentinel还需要参考sentinel集群中其他sentinel的意见，
  # 如果超过某个数量的sentinel也主观地认为该master死了，那么这个master就会被客观地(注意哦，这次不是主观，是客观，
  # 与刚才的subjectively down相对，这次是objectively down，简称为ODOWN)认为已经死了。需要一起做出决定的sentinel数量在上一条配置中进行配置。
  sed -i -E "s/^\s*sentinel\s+down-after-milliseconds\s+.*/sentinel down-after-milliseconds ${MASTER_NAME} 60000/" sentinel.conf
  # 执行failover的间隔，单位为毫秒
  sed -i -E "s/^\s*sentinel\s+failover-timeout\s+.*/sentinel failover-timeout ${MASTER_NAME} 180000/" sentinel.conf
  # 在发生failover主备切换时，这个选项指定了最多可以有多少个slave同时对新的master进行同步，这个数字越小，
  # 完成failover所需的时间就越长，但是如果这个数字越大，就意味着越多的slave因为replication而不可用。
  # 可以通过将这个值设为 1 来保证每次只有一个slave处于不能处理命令请求的状态。
  sed -i -E "s/^\s*sentinel\s+parallel-syncs\s+.*/sentinel parallel-syncs ${MASTER_NAME} 1/" sentinel.conf
  #设置进程pid文件存放的位置，用冒号是因为路径有斜杠避免冲突
  sed -i -E "s:^pidfile\s+.*:pidfile ${REDIS_HOME}/redis_26379.pid:" sentinel.conf
  #启动redis服务
  systemctl stop ${SENTINEL_NAME}
  systemctl start ${SENTINEL_NAME}
  #systemctl status ${SENTINEL_NAME}
  
  echo -e "${GREEN}OK${NC} ${SENTINEL_NAME} 服务启动成功"
}

if [ "$1" = 'sentinel' ]; then
  sentinel $2
  exit 0
fi 

install() {
  #检查服务脚本是否已安装
  if [[ ! -f ${SERVICE_PATH}/${SERVICE_NAME} ]]; then
    cat > ${SERVICE_PATH}/${SERVICE_NAME} << EOF
[Unit]
Description=Redis In-Memory Data Store
After=network.target

[Service]
User=redis
Group=module
ExecStart=${REDIS_HOME}/bin/redis-server ${REDIS_HOME}/redis.conf
ExecStop=${REDIS_HOME}/stop-redis.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable ${SERVICE_NAME}
  fi
  
  echo -e "${GREEN}OK${NC} ${SERVICE_NAME} 服务安装成功"
  
  cat > stop-redis.sh << EOF
#!/usr/bin/env bash

ps -ef|grep -v \$\$|grep redis-server|awk '{print \$2}'|xargs kill -9
EOF
  chmod +x stop-redis.sh
  
  #打开远程监听，如果不想监听所有地址就改成想监听的地址
  sed -i -E 's/^bind\s+.*/bind 0.0.0.0 -::/' redis.conf
  #要改启动端口的话打开这行并修改为想监听的端口
  #sed -i -E 's/^port\s+.*/port 6379/' redis.conf
  #服务脚本使用Type=forking时打开这行
  #sed -i -E 's/^daemonize\s+no.*/daemonize yes/' redis.conf
  #想要设置登录密码时打开这行
  #sed -i -E 's/^#?\s+requirepass\s+.*/requirepass newpassword/' redis.conf
  #打开保护模式，允许远程连接
  sed -i -E 's/^protected-mode\s+yes.*/protected-mode no/' redis.conf
  #设置进程pid文件存放的位置，用冒号是因为路径有斜杠避免冲突
  sed -i -E "s:^pidfile\s+.*:pidfile ${REDIS_HOME}/redis_6379.pid:" redis.conf
  #主从复制情况下增加该行配置
  if [ "$1" = 'slave' ]; then
    sed -i -E "s/^#?\s+replicaof\s+.*/replicaof $2 6379/" redis.conf
  fi 
  #启动redis服务
  systemctl stop ${SERVICE_NAME}
  systemctl start ${SERVICE_NAME}
  #systemctl status ${SERVICE_NAME}
  
  echo -e "${GREEN}OK${NC} ${SERVICE_NAME} 服务启动成功"
}

install $1 $2
