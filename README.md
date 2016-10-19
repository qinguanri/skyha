#skyha 

![Version Status](https://img.shields.io/badge/release-v1.0.0-orange.svg)
[![License](https://img.shields.io/badge/LICENSE-Apache2.0-ff69b4.svg)](http://www.apache.org/licenses/LICENSE-2.0.html)

 +------------------+        +--------------------+
 |                  |        |                    |
 |  +------------+  |        |   +-------------+  |
 |  |  Beanstalkd|  |        |   |  Beanstalkd |  |
 |  +------------+  |        |   +-------------+  |
 |  +------------+  |        |   +-------------+  |
 |  |   Redis    |  |        |   |    Redis    |  |
 |  +------------+  |        |   +-------------+  |
 |  +------------+  |        |   +-------------+  |
 |  |  Postgres  |  |        |   |  Postgres   |  |
 |  +------------+  |        |   +-------------+  |
 |                  |        |                    |
 |  +------------+  |        |   +-------------+  |
 |  |    DRBD    |  |        |   |    DRBD     |  |
 |  |   Master   |--+--------+-->|    Slave    |  |
 |  +------------+  |        |   +-------------+  |
 |    MASTER        |        |       SLAVE        |
 +------------------+        +--------------------+

   Pacemaker HOST 1             Pacemaker HOST 2


# PG+Redis+Beanstalkd高可用部署

本文集成pacemaker、drbd、docker、nfs，搭建pg、redis、beanstalkd容器的双机热备。

* pacemaker是监控、调度容器运行的核心组件
* drbd用于实现主从数据同步
* nfs用于共享数据

## 一、安装步骤
-------

### 1. 环境准备

1. 备份数据。将主机上的数据文件做好备份。CentOS7.2主机，已安装docker 1.9以上版本。本例中master ip为192.168.142.171，slave ip为192.168.142.172

2. 上传文件：

    上传skylar_ha.tar.gz至master主机的/opt目录下，解压：

    ```
    # cd /opt
    # tar xzvf skylar_ha.tar.gz
    ```

    上传skylar_ha.tar.gz至slave主机的/opt目录下，解压：

    ```
    # cd /opt
    # tar xzvf skylar_ha.tar.gz
    ```

3. 配置ssh免密码登录。安装程序将基于ssh进行远程命令操作。

    1. 在master上,生成密钥：

        ```
        # ssh-keygen -t rsa  # 该命令提示设置密码，直接按enter，不设置密码
        ```

    2. 在slave上,生成密钥：

        ```
        # ssh-keygen -t rsa  # 该命令提示设置密码，直接按enter，不设置密码
        ```

    3. 登录master主机，将密钥拷贝到slave主机（192.168.142.172）的/root/.ssh目录：

        ```
        # scp /root/.ssh/id_rsa.pub root@192.168.142.172:/root/.ssh/authorized_keys
        ```

    4.  登录slave主机，将密钥拷贝到master主机（192.168.142.171）的/root/.ssh目录：

        ```
        # scp /root/.ssh/id_rsa.pub root@192.168.142.171:/root/.ssh/authorized_keys
        ```

    5. 在slave主机远程登录master主机，验证是否可以免密码登录。如果设置正确，则ssh命令之后不需要输入密码。注意：登录成功后，请退出当前会话。

        ```
        # ssh root@192.168.142.171
        ```

### 2. 安装

**请严格按照以下安装顺序实施。**

1. 在master主机上执行安装命令。安装命令大约运行10分钟，请耐心等待。postgres登录密码：postgres。安装命令如下：

    ```
    # /opt/skylar_ha/skyha install \
         master_ip=192.168.142.171 \
         slave_ip=192.168.142.172 \
         vip_master=192.168.142.191 \
         data_dir=/data \
         master_hostname=db1 \
         slave_hostname=db2 \
         drbd_size=1000 
    ```
     
    必填参数说明：
    * master_ip，master主机的IP；
    * slave_ip，slave主机的IP；
    * vip_master，虚拟IP；
    * data_dir，数据文件路径，建议为/data；
    * master_hostname,master主机的hostname；
    * slave_hostname，slave主机的hostname。

    可选参数说明：
    
    * drbd_size，drbd镜像块的大小（单位MB），默认值为1000
    * losetup_dev, drbd挂载的设备，取值范围一般为/dev/loop2 ~ /dev/loop99之间空闲的设备。 ``` losetup -a ``` 命令查看已占用的设备。默认为/dev/loop9


2. 在master和slave两台主机上，修改pg_hba.conf文件。在pg_hba.conf文件末尾 添加控制台IP（这里假设是192.168.142.140，请按实际情况修改ip）。pg_hba.conf文件路径为：$data_dir/pg/pg_hba.conf。访问pg的权限：

    ```
    # echo "host     all             all             192.168.142.140/32             trust" >> /data/pg/pg_hba.conf
    # cat /data/pg/pg_hba.conf          （打印pg_hba.conf文件， 检查修改是否正确）
    ```

## 二、检验安装结果
-----------

1. 在master主机上执行如下命令，查看双机热备状态：

```
    [root@db1 home]# /opt/skylar_ha/skyha show
  [root@db1 skylar_ha]# ./skyha show

Base Info:
  * vip: 192.168.142.191
  * db1: 192.168.142.171
  * db2: 192.168.142.172

Space Info:
* Node db1:
164M    /data/drbd.img
133M    /data/recover
20K     /drbd/nfsshare
99M     /drbd/pg
61M     /drbd/redis
0       /drbd/test
* Node db2:
164M    /data/drbd.img
205M    /data/recover
16K     /drbd/nfsshare
98M     /drbd/pg
37M     /drbd/redis

NFS Info:
Export list for 192.168.142.191:
/drbd/nfsshare/exports *

Last updated: Tue Oct 11 16:46:14 2016          Last change: Tue Oct 11 16:43:57 2016 by hacluster via crmd on db1
Stack: corosync
Current DC: db1 (version 1.1.13-10.el7_2.2-44eb2dd) - partition with quorum
2 nodes and 9 resources configured

Online: [ db1 db2 ]

Full list of resources:

 Master/Slave Set: drbd-cluster [skydata]
     Masters: [ db1 ]
     Slaves: [ db2 ]
 Resource Group: master-group
     skyfs      (ocf::heartbeat:Filesystem):    Started db1
     vip-master (ocf::heartbeat:IPaddr2):       Started db1
     postgres   (ocf::heartbeat:docker):        Started db1
     redis      (ocf::heartbeat:docker):        Started db1
     bstkd      (ocf::heartbeat:docker):        Started db1
     nfs-daemon (ocf::heartbeat:nfsserver):     Started db1
     nfs-root   (ocf::heartbeat:exportfs):      Started db1

Node Attributes:
* Node db1:
    + master-skydata                    : 10000     
* Node db2:
    + master-skydata                    : 10000     

Migration Summary:
* Node db1:
* Node db2:
```

上面的信息中，分别列出了IP、磁盘占用、NFS挂载点、主从角色等信息：
* ```Online: [ db1 db2 ]```表示db1 和 db2 ，两个主机都正常在线。如果出现offline或standby标示， 则表示对应的主机状态异常。
* ```Full list of resources:```列出了当前热备系统中的资源状态，列出了redis、beanstalkd、pg、drbd的双机热备状态。本例子中显示db1是master。
* ```Node Attributes```列出了双机热备中数据同步状态。当master节点上的```pgsql-data-status : LATEST```， slave节点上的```pgsql-data-status : STREAMING|SYNC```时，表示pg的数据同步正常。当master节点上显示```master-skydata : 10000```，slave节点上显示```master-skydata : 10000```时，表示drbd数据同步正常。

## 三、故障切换测试
-----------

1.  模拟redis master主机异常，检验IP漂移、自动切换效果：

    在master主机上停止redis容器：

    ```
    # docker stop redis
    ```

2. (完成自动切换大约需要30秒）检查是否自动切换主备，检查redis是否正常提供服务：

    ~~~
    #  /opt/skylar_ha/skyha show
    ~~~

## 四、故障修复

1. 首先做好数据备份。然后定位故障，在故障主机上使用命令：```skyha show```， 查看当前双机热备状态，检查是哪个组件异常。使用命令：```docker ps```查看容器运行状态。使用命令```cat /proc/drbd```命令，检查drbd运行状态。

    ~~~
    # /opt/skylar_ha/skyha show
    # docker ps
    # cat /proc/drbd
    ~~~

2. 如果redis、bstkd容器运行异常，尝试手工启动容器,例如：```docker start redis```。如果pg容器异常，需要使用命令：```/opt/skylar_ha/skyha recover pg incr```修复。如果drbd异常，参考《drbd搭建方式》中设置主节点步骤，完成drbd主备的配置。

    ~~~
    # /opt/skylar_ha/skyha recover
    ~~~

3. 修复故障后，在故障节点上，执行```skyha show```命令查看主备状态。如果这时故障的主机处于standby状态，执行命令：```pcs cluster unstandby --all```,将节点设为Online。
        
    ~~~
    #  /opt/skylar_ha/skyha show
    # pcs cluster unstandby --all
    ~~~

4. 使用命令：```skyha show```,检查双机热备状态。
    
    ~~~
    # /opt/skylar_ha/skyha show
    ~~~

5. 检查drbd同步状态。

    > 当出现如下信息时（cs:Connected），drbd同步正常。当出现cs:stdalone或者cs:WFconnection情况时，drbd连接异常，需要修复drbd，参考第五章第3节drbd同步异常处理流程。

    ~~~
    [root@db1 skylar_ha]# cat /proc/drbd
    version: 8.4.7-1 (api:1/proto:86-101)
    GIT-hash: 3a6a769340ef93b1ba2792c6461250790795db49 build by phil@Build64R7, 2016-01-12 14:29:40

     1: cs:Connected ro:Secondary/Primary ds:UpToDate/UpToDate C r-----
     ns:0 nr:26415 dw:26415 dr:0 al:0 bm:0 lo:0 pe:0 ua:0 ap:0 ep:1 wo:f oos:0
    ~~~


------------------------------
------------------------------

# 高可用运维

## 一、日志

1. /var/log/skyha_recover.log。 主机重启后自动恢复pg双机热备日志。
2. /var/log/cluster/corosync.log。 pacemaker组件日志。

## 二、升级（待完善）

## 三、备份（待完善）

1. 备份文件路径： $data_dir/recover/，默认为/data/recover. 
2. 备份策略：每次故障修复前，进行pg、redis的数据文件备份，各自最多保留5份备份文件。
3. nfs挂载的目录文件过大，不对这些目录提供备份。
4. 重装、故障修复前，请管理员先拷贝备份文件，防止数据丢失。

## 四、重装（待完善）

### 1. 全新安装slave主机。

全新安装slave主机的前提条件是，master主机正在正常提供服务。

全新安装slave主机操作如下：

(0) 在master和slave主机间配置ssh免密码登录。

（1）将代码包拷贝到/opt目录，解压缩：
      
```
# cd /opt
# tar xzvf skylar_ha.tar.gz
```

    (2) 执行安装命令：

```
# /opt/skylar_ha/skyha reset
# /opt/skylar_ha/skyha master_ip=192.168.142.171 slave_ip=192.168.142.172 vip_master=192.168.142.191 data_dir=/data master_hostname=db1 slave_hostname=db2 drbd_size=1000
```

### 2. 全新安装master主机和slave主机。


## 五、常见问题解答
-----------

### 1. 日常巡检中，如何做主从切换？交换主从的角色。

登录当前处于master角色的主机，执行如下命令：

```
# /opt/skylar_ha/skyha switch-master-slave
```

### 2. 故障修复时，有哪些命令可以帮助快速定位？

1. ```skyha show```. 查看双机热备状态。处于```offline```、```pending```、```standby```的主机状态都是异常状态。
2. ```docker ps ```。查看容器状态。

### 3. DRBD出现脑裂，DRBD同步异常，如何处理？

使用```cat /proc/drbd```查看drbd进程运行状态。当连接状态为WFConnection时，说明master和slave之间的DRBD连接异常。如下，"ro:Primary/Unknown"表示当前drbd运行的节点是master节点。

```
[root@pcmk3 ~]# cat /proc/drbd
version: 8.4.7-1 (api:1/proto:86-101)
GIT-hash: 3a6a769340ef93b1ba2792c6461250790795db49 build by phil@Build64R7, 2016-01-12 14:29:40

1: cs:WFConnection ro:Primary/Unknown ds:UpToDate/DUnknown C r-----
ns:0 nr:0 dw:26412 dr:38552 al:4 bm:0 lo:0 pe:0 ua:0 ap:0 ep:1 wo:f oos:75096
```

出现以上状态时，需要在slave上执行如下命令。注意：这里的slave是故障的机器:

```
#/opt/skylar_ha/skyha brain            # 自动修复drbd脑裂问题
```

如果仍然存在drbd脑裂问题，则手工执行如下操作：

>该命令重新建立连接,该命令会丢弃slave节点上DRBD管理的数据文件，并重新从master节点上同步数据文件：

```
# drbdadm secondary all 
# drbdadm disconnect all 
# drbdadm -- --discard-my-data connect all
```

然后在master上执行如下命令：

```
# drbdadm primary all 
# drbdadm disconnect all 
# drbdadm connect all
```

最后查看drbd同步状态：

```
# cat /proc/drbd
```

### 4. 如何进行版本升级？或者将主机从双机热备中下线？

在要升级的主机上执行：

```
# pcs cluster standby db2   (db2是要升级的主机名，将db2从online状态调到standby状态）
# systemctl stop pacemaker.service
```
更换数据文件、更换软件完成后，将主机重新加入双机热备状态,操作如下：

```
# losetup /dev/loop9 /drbd/drbd.img         (挂载虚拟块设备）
# /opt/skylar_ha/skyha recover
# pcs cluster unstandby --all
```

### 5. 如何重置主机状态？

执行如下命令，清空本机中pacemaker、drbd、rsyncd的配置文件，删除pg、redis、beanstalkd的images。备份pg的数据文件到/data/pg_bakup目录。将主机重置到安装双机热备前的状态。

```
# /opt/skylar_ha/skyha reset
```

### 6. 如果天擎的docker镜像包有更新，如何安装？

当前redis、pg、beanstalkd的镜像包分别为skylar_pg_6.0.0.2100.tar，skylar_redis_6.0.0.2000.tar，skylar_beanstalkd_6.0.0.2000.tar，如果需要更新tar包，需要进行tar文件替换，用新的tar文件替换/opt/skylar_ha/dependent目录下的tar文件，最后再运行第2节中的安装操作。注意，（1）如果pg数据库的版本不变，保持pg9.5，就直接替换文件，不用改配置；（2）如果pg版本变化，比如从9.5升级到9.6，就需要修改部署脚本，更新部署代码包。


### 7. 开启自动修复故障

安装完成双机热备后，若主机重启，默认自动修复故障，自动恢复双机热备状态。但是自动修复并不保证100%修复成功，某些场景（e.g:硬盘损坏，空间不足，...）仍然需要人工介入修复。如果要禁用自动修复功能，则在需要禁用自动修复的主机上使用命令：

```
# /opt/skylar_ha/skyha disable auto_recovery       
```

反之，如果要启用自动修复，则运行命令：

```
# /opt/skylar_ha/skyha enable auto_recovery       
```

## changelog
-----------

|version|date|download|descript|
|:--:|:--:|:--:|:--:|
|v1.0|2016-06-13||支持高可用|
