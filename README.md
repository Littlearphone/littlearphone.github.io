# littlearphone.github.io
<div id="header" align="center">
  <img src="https://media.giphy.com/media/M9gbBd9nbDrOTu1Mqx/giphy.gif" width="100"/>
</div>

------------------------------------------------------------------

在时间正确的服务器上执行这个指令可以给远程主机同步时间
```
ssh -p端口 远程IP date -s @$(date -u +"%s")
```
再参考 [这个链接](https://linuxize.com/post/how-to-set-or-change-timezone-in-linux/) 修改时区信息

------------------------------------------------------------------

linux 服务器上的`/etc/profie`文件或`/etc/profie.d`里的文件，可能会有`TMOUT`参数限制登录用户的连接时长，注释掉或设为 0 可以让 SSH 长期不断线。

如果上面两处都找不到这个参数，那还可以试试在`~/.bashrc`或`~/.bash_profile`里面找。

------------------------------------------------------------------

查看监听的端口
```
netstat -lnpt
```

允许调试端口通过防火墙
```
firewall-cmd --zone=public --add-port=5556/tcp --permanent
```
重新加载防火墙配置
```
firewall-cmd --reload
```
禁止指定端口通过防火墙
```
firewall-cmd --zone=public --remove-port=5556/tcp --permanent
```
查看所有开放的端口
```
firewall-cmd --zone=public --list-ports
```
查看防火墙状态
```
firewall-cmd --state
```
关闭防火墙
```
systemctl stop firewalld.service
```

------------------------------------------------------------------

使用firewalld防火墙限制白名单访问
屏蔽所有IP使用tcp访问9200端口
```
firewall-cmd --permanent --add-rich-rule='rule family="ipv4" port protocol="tcp" port="9200" drop'
# firewall-cmd --permanent --remove-rich-rule='rule family="ipv4" port protocol="tcp" port="9200" drop'
```
白名单IP（例如10.1.1.5/32）
```
firewall-cmd --zone=trusted --add-source=10.8.0.0/16 --permanent
# firewall-cmd --zone=trusted --remove-source=10.8.0.0/16 --permanent
```
添加的规则使用`firewall-cmd --list-all`查看
重新加载配置，使其生效
```
firewall-cmd --reload
```

------------------------------------------------------------------

使用如下指令展开压缩包里的指定内容到搜索出的多个不同路径下
```
yes | find /home -name 'video-???' -type d | xargs -L 1 -t -I {} unzip xxx.zip "video/*" -d {}/bin/
```
- 此处示例前半段表示从/home路径下搜索video-xxx的目录
- 后半段表示将前半段输出的每一行以参数填充到预设指令中
- -L 1表示管道里每行作为一个参数，也可以多行作为一个参数，连接符为\n
- -I {}表示参数的占位符，预设指令中出现该占位符的地方会被替换
- -t 表示输出具体执行的完整指令，管道有多输出就可能会显示多条指令
- 从unzip开始的都是预设指令，在管道输出方式下就能实现多输出

------------------------------------------------------------------

最小化安装Redhat时，可能会没有网络，需要通过主机终端先启用网络服务。

在安装网络服务前，先去修改网络脚本文件里的ONBOOT配置项为yes，让网卡可以随服务启用。

网卡配置参考路径为`/etc/sysconfig/network-scripts/ifcfg-enp1s0`，多网卡可能有多个文件。

网卡配置文件后半段为网卡名称，文件里的配置名需要和这部分名称保持一致，启用网卡时注意区分名称。

默认情况下配置文件里应该是dhcp模式，需要指定IP的话参考 [此文](https://blog.csdn.net/hjxloveqsx/article/details/120529147)

修改完网卡配置还需要在`/etc/sysconfig/network`里加一行`NETWORKING=yes`后保存退出

接着去挂载安装镜像，`lsblk`可以看到**sr**为前缀的设备信息，选择正确的用`mount /dev/srx /mnt`挂载。

挂载后会显示只读，此时进入`/mnt/BaseOS/Packages`找网络服务包使用 rpm 指令进行安装。

不同版本的系统镜像带的包版本可能有所不同，根据实际的安装就行，这里的包肯定是最合适的。

```
rpm -ivh ipcalc-0.2.4-4.el8.x86_64.rpm bc-1.07.1-5.el8.x86_64.rpm network-scripts-10.00.18-1.el8.x86_64.rpm
```
安装完网络服务包就可以使用网络服务了，以防万一可以重启下网络服务，促使网卡启用
```
service network restart
```
默认应该也没有ifconfig指令，需要安装net-tools包才能使用，此外unzip也能在镜像里面找到
```
rpm -ivh net-tools-2.0-0.52.20160912git.el8.x86_64.rpm
```

------------------------------------------------------------------

使用`systemctl list-units`查到的 not-found 状态服务可以使用`systemctl reset-failed`清理

------------------------------------------------------------------

使用`journalctl --vacuum-size=1G`可以限制系统日志的存储上限
使用`journalctl --vacuum-time=2d`可以限制系统日志的存储时限

------------------------------------------------------------------

`du -h <dir> | grep '[0-9\.]\+G'`可以分析指定路径下的空间占用
在 -h 之前增加 --exclude=PATTERN 可以排除某些路径提高分析速度

------------------------------------------------------------------

通过 http://ip:port/_alias 可以列出 ES 所有的索引别名
通过 http://ip:port/_cat/indices/keyword*?v 可以筛选 ES 的索引
筛选地址末尾的v参数用来显示返回结果列的标题

------------------------------------------------------------------

使用ImageMagick可以把svg或多张普通图片转换为自适应大小的ico图标
```
convert -density 256x256 -background transparent favicon.svg -define icon:auto-resize -colors 256 favicon.ico
```

------------------------------------------------------------------

获取chrome mini版本安装包的方法参考 [此文](https://stackoverflow.com/questions/54927496/how-to-download-older-versions-of-chrome-from-a-google-official-site)

------------------------------------------------------------------

在服务器上的服务启动参数追加
```
-Xdebug -Xrunjdwp:transport=dt_socket,suspend=n,server=y,address=0.0.0.0:5556
```
然后在IDEA中新建remote启动项，通过配置中的address连接到远程服务
```
-agentlib:jdwp=transport=dt_socket,address=10.19.84.88:5556,server=y,suspend=n
```

------------------------------------------------------------------
