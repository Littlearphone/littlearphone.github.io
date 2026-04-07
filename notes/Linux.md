# Linux 学习记录

## 1. systemctl 的用法

`systemctl` 是 Linux 系统中用于管理 **systemd**（系统和服务管理器）的核心命令。它几乎取代了旧版本的 `service` 和 `chkconfig`，是目前**事实上**的服务程序管理标准。

以下是按照使用场景分类的常用指令指南：

### 1.1. 管理服务（最常用）

假设服务名为 `nginx`：

- **启动服务**：`systemctl start nginx`
  
  > 在`.service`脚本中至少需要有`ExecStart=`的配置，否则无法正常使用 Systemd 服务。
  >
  > 执行时如果卡住一直不结束，最可能的原因是`.service`脚本中`Type=`配置写错了：
  >
  > - 当`Type=simple`时，不等待程序（或脚本）启动完成，只要执行了启动指令那么就完成了（绝对不会卡住）。
  > - 当`Type=exec`时，会等待程序（或脚本）加载到内存才完成，但在 v240 版本开始才引入的类型（绝对不会卡住）。
  > - 当`Type=forking`时，等待程序（或脚本）执行完成，并且 Systemd 捕获到了子进程 **PID** 时就完成了（捕获不到会卡住）。
  > - 当`Type=oneshot`时，程序启动并且执行完成后推出才会结束，单次任务模式（如果任务阻塞那就会卡住）。
  > - 当`Type=notify`时，等待程序（或脚本）启动完成后向系统发送完成通知（未收到通知信号会卡住）。
  >
  > 通常我们用的都是`simple`和`forking`，对于 Java 程序来说如果直接执行`java -jar xxx.jar`那么就应该使用`simple`；如果是异步启动，例如使用`jsvc`包装程序的情况就应该使用`forking`。
  >
  > 这两种方式启动时都不需要程序主动生成 PID 文件，前者是由 Systemd 主动 Fork 进程实现，后者会由 CGroup 自动捕获子进程 PID。如果程序本身有生成 PID 文件的需求也可以在`.service`中指定`PIDFile=`路径参数，这样能节省 Systemd 的检测时间（副作用是 PID 记录错误时可能会有奇怪的现象，例如没启动的程序显示启动或者杀了不该杀的程序，类似的情况在 Rose 热备环境下容易出现）。
  
- **停止服务**：`systemctl stop nginx`
  
  > 执行`stop`如果卡住，有可能有下面几个原因：
  > - 程序退出逻辑太重导致耗时太久（例如保存大量数据到硬盘上）。
  >
  > - 僵尸进程或 D 状态（不可中断睡眠，例如读取损坏的硬盘）进程。
  >
  > - 停止超时设置得太长或是停止指令写得有问题（KillMode 为`none`或脚本挂起了）。
  >
  > ------
  >
  > 要确认卡住的情况可以做如下几个步骤的排查：
  >
  > - 使用`journalctl -f -u 服务名`查看详细日志，检查是否有`Stoppping...`之后的日志。
  > - 使用`ps -ef | grep 关键字`查看进程是否存在或`ps aux | awk '$8=="T"'`查看进程是否挂起。
  > - 检查`.service`脚本里`KillMode`是否设置为 `none`或`process`导致 systemd 不杀死残留进程。
  > - 检查`.service`脚本的`ExecStop`定义的停止指令存在`sleep`或`read`等阻塞逻辑。
  > - 使用`jobs`查看当前终端窗口里被挂起或在后台的任务。
  >
  > ------
  >
  > 排查结束后的处理方法：
  >
  > - 确定了进程 pid 并且希望立刻停止时可以手动执行`kill -9 <pid>`结束进程。
  > - 如果是`.service`脚本的`KillMode`问题可以改成`control-group`（默认值）或`mixed`。
  > - 如果是退出慢导致的，那可以考虑修改程序逻辑（也可能是修改退出脚本）加快程序的退出速度。
  > - 如果不方便修改程序但依旧希望尽快结束进程可以修改`.service`的`TimeoutStopSec`为较短的时间（默认是 90 秒）。
  >
  > ------
  >
  > 关于 `TimeoutStopSec` 的补充：在`.service`脚本中**不强制填写单位**（默认就是秒），直接写 `TimeoutStopSec=60` 和写 `TimeoutStopSec=60s` 在系统看来是一模一样的。
  >
  > 不过，这里有两个容易踩的**坑**建议你留意：
  >
  > 1. **默认值并非无限**：如果你不写这个配置，systemd 默认通常是 **90秒**（取决于系统全局配置 `DefaultTimeoutStopSec`）。如果你的程序关机时需要处理大量数据（比如数据库刷盘），90秒不够用，程序就会被 `SIGKILL` 强杀。
  >2. **设置为 0 的含义**：如果你写 `TimeoutStopSec=0`，这并不代表“立即杀死”，而是代表**“永不超时”**（infinity）。systemd 会一直等下去，直到进程自己退出。这在系统关机时可能会导致整个操作系统卡在关机界面。
  
- **重启服务**：`systemctl restart nginx`

  > 从效果上来看类似，但实际上和`stop`+`start`的组合有所不同：
  >
  > - 对于有依赖的服务来说，`stop`+`start`的组合会导致依赖服务被停止，但是后续的启动操作并不会主动拉起依赖服务，相对应的`restart`只会重启指定的服务不会破坏依赖服务的状态。
  > - 会自动分析依赖链，然后计算执行的流程，且操作更加原子性，对于停止或启动条件会自动判断是否可继续进行，同时会清除失败计数，为服务提供干净的启动环境。
  >
  > ------
  >
  > 在`.service`脚本中有一个`Restart=`参数可以配置自动重启策略用于应对程序意外退出的情况。
  >
  > `Restart=` 的取值决定了 systemd 在什么“死法”下会拉起进程：
  >
  > | 取值              | 退出原因       | 状态码               | 是否重启 | 场景                             |
  > | :---------------- | :------------- | :------------------- | :------- | :------------------------------- |
  > | **`no`** (默认)   | 任何情况       | 任何                 | **否**   | 手动运行，挂了就挂了             |
  > | **`on-success`**  | 正常退出       | 0                    | **是**   | 任务完成了想再跑一遍             |
  > | **`on-failure`**  | 非正常退出     | 非 0、被杀、超时     | **是**   | **最常用**，排除正常关闭后的重启 |
  > | **`on-abnormal`** | 异常终止       | 信号(SIGILL等)、超时 | **是**   | 排除状态码报错，只管崩溃         |
  > | **`on-abort`**    | 收到未捕获信号 | SIGABRT 等           | **是**   | 只管程序崩溃                     |
  > | **`always`**      | **任何情况**   | 任何                 | **是**   | 只要进程没了，就必须拉起来       |
  >
  > **特别注意：** 如果是你手动执行 `stop`或`restart`，以上任何配置都**不会**触发重启。systemd 知道这是管理员的操作，不会“自作聪明”。
  >
  > ------
  >
  > 如果程序一直失败，systemd 也不会无限重启，会根据**`StartLimitBurst=`** (最大尝试次数，默认 5 次) 和**`StartLimitIntervalSec=`** (统计时间窗口，默认 10 秒) 切断重启。
  >
  > 对于达到重启限制的服务，可以执行`systemctl reset-failed <服务名>`重置重启尝试计数。

- **重新加载配置**（不停止服务）：`systemctl reload nginx`

  > 与 `restart` 有本质区别，它需要在`.service`脚本中增加`ExecReload`指令才能使用，例如`/path/xxx -reload`，这就要求程序本身得实现相关的重载逻辑。
  >
  > 重载本身不会停止服务，主要用于更新配置，但如果程序愿意也可以实现为功能模块的加载与切换，例如`Nginx`重载时父进程收到了通知，会根据新配置启动新的子进程然后替换掉旧的子进程。
  >
  > 在 Java 程序中可以写如下一段代码来监听重载信号：
  >
  > ```java
  > // 监听 SIGHUP 信号 (信号量 1)
  > // 使用 sun.misc.Signal 类
  > SignalHandler.handle(new Signal("HUP"), signal -> {
  >     System.out.println("收到重载信号，开始重新读取配置文件...");
  >     // loadConfig(); // 你自己写的重载逻辑
  > });
  > ```
  >
  > 然后在`.service`脚本中增加重载指令：
  >
  > ```sh
  > # 当执行 systemctl reload 时，向 Java 进程发送 HUP 信号
  > ExecReload=/bin/kill -HUP $MAINPID
  > ```

- **查看服务状态**：`systemctl status nginx`
  - *用于查看服务是否在运行、最近的日志以及主进程 PID。*

一个标准的`.service`脚本大概长这样：

```sh
[Unit]
Description=My Java Service
After=network.target

[Service]
# --- 核心改进：使用 simple 模式可以避免 PID 追踪失败 ---
Type=simple
# 执行用户，用于限定执行程序的权限，不写就是 root（最高权限）
User=java
# 执行用户组，用于限定执行程序的权限
Group=java

# --- 启动命令：不要使用 nohup 或 & ---
ExecStart=/usr/bin/java -Xms2g -Xmx2g -jar /path/to/app.jar

# --- 判定启动成功：等待端口开启 (可选) ---
ExecStartPost=/usr/bin/timeout 30s sh -c 'until nc -z localhost 8080; do sleep 1; done'

# --- 重载操作：主要用于重新加载配置（可选） ---
# MAINPID 是主进程的 PID 变量
ExecReload=/bin/kill -HUP $MAINPID 

# --- 停止操作：执行指定脚本来停止程序（可选，不写会给程序发送 KillSignal 所配置的信号）---
ExecStop=/home/user/script -stop

# --- 停止优化：解决卡死与全杀风险 ---
# 1. 缩短强杀超时时间（默认90s太长）
TimeoutStopSec=10s
# 2. 模式设为 control-group，确保精准清理 cgroup 内进程，不误伤其他服务
KillMode=control-group
# 3. 允许优雅退出信号，也可以设为 SIGKILL，这样会直接强杀进程，有数据丢失的风险
KillSignal=SIGTERM

# --- 自动重启 ---
Restart=on-failure
# 自动重启间隔
RestartSec=5s
# 5 分钟内最多重启 3 次，超过就放弃。不同系统版本放置位置可能有差异。
# 如果发现这两个参数写在 [Service] 块中无效时可以尝试移至 [Unit]。
StartLimitIntervalSec=300s
StartLimitBurst=3

[Install]
# 启动模式，“多用户模式”启动时跟着启动，还有“graphical.target”类型，在图形界面启动后才启动
# 不写启动模式的话，执行 enable 操作的时候会报错，因为无法确定要挂载到哪个启动阶段
WantedBy=multi-user.target
```

### 1.2. 设置开机自启

- **启用开机自启**：`systemctl enable nginx`
- **禁用开机自启**：`systemctl disable nginx`
- **检查是否开机自启**：`systemctl is-enabled nginx`

### 1.3. 查看系统状态

- **列出所有正在运行的服务**：`systemctl list-units --type=service`
  > 如果不加 --state= 参数的话，默认就是加载`loaded`和`active`两种状态的服务。可以选择加`--all`参数显示所有状态的服务，也可以选择使用`--failed`参数只看失败的。
  >
  > --type 参数常用的就是`service`，但它实际上共有 11 种不同类型：
  >
  > 1. 核心执行类（干活的）
  >    1. **Service (.service)**：管理后台进程（最常用，如 Nginx、Java）。
  >    2. **Mount (.mount)**：管理文件系统挂载（挂载硬盘、分区）。
  >    3. **Swap (.swap)**：管理内存交换分区（虚拟内存）。
  >
  > 2. 自动化触发类（定闹钟/看大门的）
  >    1. **Timer (.timer)**：基于时间触发任务（替代 Crontab）。
  >    2. **Socket (.socket)**：基于网络流量或进程通信触发服务（按需启动）。
  >    3. **Path (.path)**：基于文件或目录的变化（修改、删除）触发任务。
  >    4. **Automount (.automount)**：当用户访问某个目录时才实时挂载磁盘。
  >
  > 3. 系统组织与环境类（搭框架的）
  >    1. **Target (.target)**：逻辑集合，用于分组服务或定义启动阶段（如关机、图形模式）。
  >    2. **Device (.device)**：对硬件设备的识别（由内核/udev 暴露，通常由系统自动创建）。
  >
  > 4. 资源控制与高级管理类（管预算的）
  >    1. **Slice (.slice)**：将进程分组并进行资源限制（限制 CPU、内存配额）。 
  >    2. **Scope (.scope)**：管理由外部程序（非 systemd）派生的进程组（如用户登录的会话）。
  >
  > ------
  >
  > - `Device` 和 `Scope` 通常是系统自动生成的，不需要人工写配置文件。
  > - `Slice` 通常在需要做容器化或严格限制进程资源时才会手动去调。
- **列出所有已安装的服务（包括禁用的）**：`systemctl list-unit-files --type=service`
  > 和`list-units`类似，都支持 --type 和 --all，但两者关注的维度不同：
  > - `list-units`关注内存中服务状态，支持如下几种状态：
  >    - **`active`**：正在运行或处于激活状态。
  >    - **`inactive`**：已停止或未启动。
  >    - **`failed`**：启动失败、崩溃或以非零状态码退出（排查问题最常用）。
  >    - **`running`**：服务正在运行（通常指 `Service` 类型的子状态）。
  >    - **`exited`**：任务已执行完毕并正常退出（常见于 `oneshot` 类型的脚本）。
  >    - **`plugged`**：设备已插入（常见于 `Device` 类型）。
  >    - **`mounted`**：文件系统已挂载（常见于 `Mount` 类型）。
  > - `list-unit-files`关注磁盘上文件状态，支持如下几种状态：
  >    - **`enabled`**：已启用。系统开机时会**自动启动**。
  >    - **`disabled`**：未启用。系统开机时**不会**自动启动，但可以手动启动。
  >    - **`static`**：静态。它没有 `[Install]` 部分，无法设置开机自启，通常作为其他服务的依赖项被拉起。
  >    - **`masked`**：被屏蔽。这是最高级别的禁用，类似于“软链接到 /dev/null”，无法通过手动或自动方式启动，除非先 `unmask`。
  >    - **`alias`**：别名。该文件是另一个单元文件的软链接（别名）。
  >    - **`generated`**：生成的。是由程序（如 `fstab` 解析器）动态生成的单元文件，不是手动编写的。
  >    - **`transient`**：瞬时的。通过 `systemd-run` 动态创建的临时单元。
- **列出启动失败的服务**：`systemctl --failed`，这个指令等价于**`systemctl list-units --state=failed`**。

### 1.4. 系统控制（电源管理）

- **重启机器**：`systemctl reboot`，通常等价于执行`reboot`，如果因为服务卡住导致无法重启，可以加上`-f`参数强制结束卡住的服务（`-ff`参数是更极端的操作，几乎等同于机箱上的重启键，有较大造成文件损坏的风险）。
- **关机**：`systemctl poweroff`，通常等价于执行`poweroff`，会关闭系统并断电，内存数据会丢失。
- **暂停（待机）**：`systemctl suspend`，通常等价于执行`suspend`，进入待机状态，内存数据还在，但是断电会丢失数据。
- **休眠**：`systemctl hibernate`，通常等价于执行`hibernate`，进入休眠状态，内存数据刷入磁盘中，下次启动从磁盘读取到内存。如果`swap`分区不够大会休眠失败。

### 1.5. 进阶技巧

- **屏蔽服务**：`systemctl mask nginx`
  - *这比 `disable` 更彻底，它会让服务无法被手动启动，除非执行 `unmask`。*
  - 已经处于运行中的服务执行了`mask`以后并不会被停止，改变的只有**磁盘上的配置**。
  - *`mask` 的本质是**软链接锁定**。它只是把服务配置文件（`.service` 文件）链接到 `/dev/null`。*
  - 要检查`mask`是否生效，可以使用`status`指令查看是否有 `loaded: masked (/dev/null; bad)`相关输出。
- **查看服务依赖**：`systemctl list-dependencies nginx`
- **重新加载 systemd 核心配置**：`systemctl daemon-reload`
  - *当你修改了 `.service` 配置文件后，必须运行这个命令才能生效。*

### 1.6. 日志查询（配合 journalctl）

虽然 `systemctl status` 能看简要日志，但完整日志需要配合 `journalctl`：

- **查看某个服务的详细日志**：`journalctl -u nginx`
- **实时滚动查看日志**：`journalctl -f -u nginx`

### 1.7. 扩展用法（模板化）

如果你想用一个`.service`脚本文件实现启动多次程序实例，那么可以在文件名最后加`@`符号让脚本模板化，例如`app@.service`。

这样一来就可以使用`systemctl start app@8080.service`来指定实例启动，跟在`@`后面的内容可以作为参数在`.service`脚本中使用：

```bash
[Unit]
Description=My App Instance %i
After=network.target

[Service]
Type=simple
# 通过 %i 动态指定不同的端口、日志路径或配置文件
ExecStart=/usr/bin/java -jar /path/to/app.jar --server.port=%i --logging.file=/var/log/app-%i.log
Restart=on-failure

[Install]
WantedBy=multi-user.target
```

实例启动时如果`@`后面的参数一致，那么 systemd 会保证你`start`操作的幂等性（重复执行）。另外，通过这种方式启动的服务实例是相互隔离的。

例如，想要停止具体的实例，那么可以执行`systemctl stop app@8080.service`。如果要停止所有实例，可以执行`systemctl stop app@*.service`。

# Linux 问题记录

## 1. 每次重启我 mount 的分区都会掉

这是因为在 Linux 中，直接使用 `mount` 命令进行的挂载是**临时**的，系统重启后内存中的挂载信息会被清空。

要实现**永久自动挂载**，你需要将挂载信息配置到系统的 `/etc/fstab` 文件中。以下是标准操作流程：

------

### 1.1. 获取分区的 UUID

建议使用 **UUID**（通用唯一识别码）而非设备名（如 `/dev/sdb1`），因为重启后磁盘顺序可能会变，导致挂载失败。

- 执行命令：`blkid`
- 找到你的分区，记录下 `UUID="..."` 中的字符串。

------

### 1.2. 编辑配置文件

使用 root 权限编辑 `fstab`：

```bash
sudo nano /etc/fstab
```

------

### 1.3. 添加挂载行

在文件末尾添加一行（按以下格式，各列用空格或 Tab 分隔）：`[UUID] [挂载点] [文件系统类型] [挂载选项] [dump] [pass]`。其中**文件系统类型**参考`blkid`执行结果里显示的`TYPE`项。

**示例（假设挂载到 `/mnt/data`，文件系统是 `ext4`）：**

```
UUID=你的UUID字符串  /mnt/data  ext4  defaults  0  2
```

- **defaults**: 使用默认挂载参数（rw, suid, dev, exec, auto, nouser, async）。
- **0**: 不进行 dump 备份。
- **2**: 开机自检顺序（根目录为 1，其他分区通常为 2）。

------

### 1.4. 测试配置（关键）

**非常重要：** 在重启前一定要测试，配置写错可能导致系统无法正常启动。

- 执行命令：`sudo mount -a`
- 如果没有报错，且分区已成功挂载（通过 `df -h` 查看），说明配置正确。

------

### 1.5. **常见排查建议**

- **云服务器用户**：如果是 Azure 或 AWS 的数据盘，注意设备名（如 `/dev/sdc`）常在重启后改变，**必须**使用 UUID 挂载。
- **挂载点权限**：确保挂载点目录（如 `/mnt/data`）已经提前创建好。

你目前的分区是 **Windows NTFS** 格式还是 **Linux ext4/xfs** 格式？如果是移动硬盘或双系统分区，挂载参数可能需要额外调整。

## 2. Redhat 最小化安装的网络配置

最小化安装Redhat时，可能会没有网络，需要通过主机终端先启用网络服务。

- 在安装网络服务前，先去修改网络脚本文件里的ONBOOT配置项为yes，让网卡可以随服务启用。
- 网卡配置参考路径为`/etc/sysconfig/network-scripts/ifcfg-enp1s0`，多网卡可能有多个文件。
- 网卡配置文件后半段为网卡名称，文件里的配置名需要和这部分名称保持一致，启用网卡时注意区分名称。
- 默认情况下配置文件里应该是dhcp模式，需要指定IP的话参考 [此文](https://blog.csdn.net/hjxloveqsx/article/details/120529147)。
- 修改完网卡配置还需要在`/etc/sysconfig/network`里加一行`NETWORKING=yes`后保存退出。
- 接着去挂载安装镜像，`lsblk`可以看到**sr**为前缀的设备信息，选择正确的用`mount /dev/srx /mnt`挂载。
- 挂载后会显示只读，此时进入`/mnt/BaseOS/Packages`找网络服务包使用 rpm 指令进行安装。
- 不同版本的系统镜像带的包版本可能有所不同，根据实际的安装就行，这里的包肯定是最合适的。

```sh
rpm -ivh ipcalc-0.2.4-4.el8.x86_64.rpm bc-1.07.1-5.el8.x86_64.rpm network-scripts-10.00.18-1.el8.x86_64.rpm
```

安装完网络服务包就可以使用网络服务了，以防万一可以重启下网络服务，促使网卡启用

```sh
service network restart
```

默认应该也没有ifconfig指令，需要安装net-tools包才能使用，此外unzip也能在镜像里面找到

```sh
rpm -ivh net-tools-2.0-0.52.20160912git.el8.x86_64.rpm
```

- 挂载的硬盘使用lsblk可以查看到，此时应该是disk类型，fdisk -l指令也可以查看
- 使用fdisk /dev/vdb可以进入分区模式（vdb是盘名），单盘全分的话输入n，然后一路默认
- 创建结束后输入w保存分配结果并退出分配模式，默认创建的为第一个分区，后缀为1，此时就可以挂载了

```sh
mkfs.ext4 /dev/vdb1
mount /dev/vdb1 /opt
```
