#!/bin/sh
#
# 作者：qinguanri 
# 时间：2017-03-11
# 描述：
#
###################################################

CONF=/etc/skyha.d/ha.conf
BIN=/usr/local/bin/skyha
LOG=/var/log/skyha.log
BACKUP_DIR=/backup
RPM=/usr/lib/skyha/rpm
WORK_DIR=$(cd `dirname $0`; pwd)

# image 的名称
IMAGE_NAME_BEANSTALKD="skylar_beanstalkd"
IMAGE_NAME_MAIN="skylar_main"
IMAGE_NAME_REDIS="skylar_redis"
IMAGE_NAME_POSTGRES="skylar_pg"

# 容器的名称
CONTAINER_NAME_REDIS="redis"
CONTAINER_NAME_MAIN="main"
CONTAINER_NAME_POSTGRES="pg"
CONTAINER_NAME_BEANSTALKD="beanstalkd"

# 监控命令
MONITOR_CMD_BEANSTALKD="supervisorctl status beanstalkd | grep RUNNING"
MONITOR_CMD_MAIN="supervisorctl status nginx | grep RUNNING"
MONITOR_CMD_REDIS="redis-cli time >/dev/null"
MONITOR_CMD_POSTGRES="su postgres -c \"psql -U postgres -Atc \\\"select now();\\\"\""

log_info()  {
    _log "INFO" "$1"
}

log_warn()  { 
    _log "WARN" "$1" 
}

log_error() { 
    _log "ERROR" "$1" 
}

_log() { 
    echo "$2"; echo "`date` $1 $2" >> $LOG 
}

usage() {
    cat <<END
skyha build a High Availabe system for postgresql/redis/beanstalkd.

usage: skyha <command> [<args>]

The most commonly used skyha commands are:
    help        Show usage.
    install     Install a ha system. $0 install
    show        Show HA status.
    switch-master-slave Switch the role of master and slave. This command can only do on master node.

See log at $LOG_FILE.
END
}

# 检查配置文件的配置是否正确，配置文件默认为 /etc/skyha/ha.conf
# 在启动服务之前，务必先要检查配置的正确性
check_conf() {
    log_info '--> Checking configs ...'

    if ! -f $CONF; then
        log_error "Cannot find config file: $CONF"
        return 1
    fi

    if ! check_ip_valid "$MASTER_IP"; then
        log_error "MASTER_IP:$MASTER_IP is invalid"
        return 1
    fi

    ping -c 1 "$MASTER_IP" >> /dev/null
    if [ $? -ne 0 ]; then
        log_error 'ping MASTER_IP:$MASTER_IP failed.'
        return 1
    fi

    if ! check_ip_valid "$SLAVE_IP"; then
        log_error "SLAVE_IP:$SLAVE_IP is invalid"
        return 1
    fi

    ping -c 1 "$SLAVE_IP" >> /dev/null
    if [ $? -ne 0 ]; then
        log_error 'ping SLAVE_IP:$SLAVE_IP failed'
        return 1
    fi

    fdisk -l | grep "$LOGIC_VOLUME" >> /dev/null
    if [ $? -ne 0 ]; then
        log_error 'LOGIC_VOLUME:$LOGIC_VOLUME is invalid'
        return 1
    fi
}

# 安装 rpm 包，需要安装的主件有：
# 1. pacemaker，HA 的核心组件，完成资源的监控、故障自动切换等功能。
# 2. drbd，数据存储管理组件，实现数据主从自动同步，网络版的raid 1。
# 3. nfs，对外提供nfs服务，解决数据共享问题。
install_rpms() {
    # **** 安装 pacemaker。
    # 安装之前先停止服务，删除旧的配置文件，目的是避免残留的进程或配置影响组件的正常安装。
    systemctl stop pacemaker.service >> /dev/null
    [ -f /var/lib/pacemaker/cib/cib.xml ] && rm -rf /var/lib/pacemaker/cib/cib*
    [ -f /etc/corosync/corosync.conf ] && rm -f /etc/corosync/corosync.conf

    is_installed "pacemaker" "pcs" "psmisc" "policycoreutils"
    if [ $? -ne 0 ]; then
        yum install -y pacemaker; sleep 2
        yum install -y pcs; sleep 2
        yum install -y psmisc; sleep 2
        yum install -y policycoreutils-python; sleep 2
    fi

    # **** 安装 drbd 组件
    drbdadm secondary all >> /dev/null
    drbdadm down skydata >> /dev/null
    is_installed "kmod-drbd84" "drbd84-utils"
    if [ $? -ne 0 ]; then
        yum install -y kmod-drbd84; sleep 2
        yum install -y drbd84-utils;
    fi

    # **** 安装 nfs 组件
    systemctl stop nfs-server.service >> /dev/null
    is_installed "nfs-utils" "rpcbind"
    if [ $? -ne 0 ]; then
        yum install -y nfs-utils rpcbind; sleep 1
    fi
}

is_installed() {
    soft_list=$@
    for item in ${soft_list[@]}
    do
        installed=`yum list installed | grep "$item" |grep -v grep | wc -l`
        if [ "$installed" == "0" ]; then
            return 1
        fi
    done

    return 0
}

# 配置 pacemaker、drbd、nfs 等服务的配置文件、启动参数
config_services() {
    # **** 更新 resouce agent
    # 我们修改了官方 resource agent: docker 的源码，来满足我们的业务需求。
    # 因此在启动 pacemaker 之前，先要做一次散文件替换。
    HEARTBEAT_RSC_DIR="/usr/lib/ocf/resource.d/heartbeat"
    rm $HEARTBEAT_RSC_DIR/docker
    cp $WORK_DIR/dependent/docker $HEARTBEAT_RSC_DIR/docker
    chmod 755 $HEARTBEAT_RSC_DIR/docker

    # **** 配置 drbd 的配置文件
    sed -i 's/usage-count yes/usage-count no/g' /etc/drbd.d/global_common.conf
    # 定义一个 drbd 的资源 skydata
    # 这里配置了 drbd 主从同步的速率、同步方式、占用端口、校验算法、脑裂处理方式
    # 这是 drbd 的最重要的配置文件 
    echo "resource skydata {
    protocol C;
    meta-disk internal;
    device /dev/drbd1;
    net {
        verify-alg crc32c;
        csums-alg crc32c;
        max-buffers 10000;
        max-epoch-size 10000;
        sndbuf-size 0;
        rcvbuf-size 0;
        after-sb-0pri discard-zero-changes;
        after-sb-1pri discard-secondary;
        after-sb-2pri disconnect;
    }
    disk {
        al-extents 3389;
        on-io-error detach;
        c-plan-ahead 15;
        c-fill-target 2M;
        c-min-rate 50M;
        c-max-rate 720M;
        resync-rate 720M;
    }
    on $MASTER_HOSTNAME {
        disk $LOGIC_VOLUME;
        address $MASTER_IP:7789;
    }
    on $SLAVE_HOSTNAME {
        disk $LOGIC_VOLUME;
        address $SLAVE_IP:7789;
    }
}" > /etc/drbd.d/skydata.res

    # **** 配置 nfs server，散文件替换 nfsserver 资源文件
    rm $HEARTBEAT_RSC_DIR/nfsserver
    cp $WORK_DIR/dependent/nfsserver $HEARTBEAT_RSC_DIR/nfsserver
    chmod 755 $HEARTBEAT_RSC_DIR/nfsserver
    echo "" > /etc/exports
}

# 启动服务
startup_services() {
    systemctl start pcsd.service
    systemctl enable pcsd.service
    echo hacluster | passwd hacluster --stdin

    log_info "--> semanage permissive -a drbd_t, please wait seconds ..."
    semanage permissive -a drbd_t
    drbdadm create-md skydata
    modprobe drbd
    drbdadm up skydata

    systemctl start rpcbind.service

    systemctl start nfs-server.service
    if [ $? -ne 0 ]; then
        log_error "systemctl start nfs-server.service failed."
        return 1
    fi
}

# 停止容器。在拷贝data目录到drbd目录前，务必先要停止容器，停止业务的读写请求。
stop_containers() {
    container_list=$@
    for container in ${container_list[@]}
    do
        docker stop "$container"
    done
}

# 把 /data 目录下的数据复制到 drbd 块设备上。
# /data 目录下的数据文件，应该是 docker 容器运行时挂载数来的数据卷。
# /data 目录下，一般会有 pg、redis、nginx 等文件夹。
# 由于添加HA后，还需要使用data目录下的数据文件，因此需要先把data目录拷贝到drbd挂载点。
# 最后drbd运行时，要把挂载点设置为data。这样就可以在原来的数据上运行HA。
copy_data_to_drbd() {
    sleep 2
    cat /proc/drbd | grep 'cs:Connected' | grep 'ro:Secondary/Secondary' >>/dev/null
    if [ $? -ne 0 ]; then
        log_error "drbd are not connected between master and slave."
        return 1
    fi

    drbdadm primary --force skydata

    try=0
    while [ $try -le 3600 ]
    do
        cat /proc/drbd | grep 'cs:Connected' | grep 'ds:UpToDate/UpToDate' | grep 'Primary' >> /dev/null
        if [ $? -eq 0 ]; then
            break
        fi

        clear
        cat /proc/drbd
        log_info "--> Initialize DRBD. Please wait minutes ..."
        sleep 1
        let "try++"
    done

    mkfs.xfs -f /dev/drbd1

    mkdir -p /drbd
    mount /dev/drbd1 /drbd
    cd /

    mkdir -p /drbd/nfsshare
    mkdir -p /drbd/nfsshare/exports
    chmod 776 /drbd/nfsshare
    chmod -R 776 /drbd/nfsshare/exports
    chown -R nfsnobody:nfsnobody /drbd/nfsshare/exports

    stop_containers "$CONTAINER_LIST"
    log_info "--> Copy data from /data/ to /drbd/ ..."
    cp -rf /data/* /drbd/

    umount /dev/drbd1
    drbdadm secondary skydata
}

# 配置HA的资源，在pacemaker中，被管理的业务叫做“资源”。我们这里的资源包含drbd、filesystem、docker容器等。
# 这个函数中，我们添加资源，并且配置资源的监控命令、启动顺序、位置约束
config_ha_resources() {
    # **** 首先停止残留进程，清楚残留配置
    pacemaker_proc=`ps -ef | grep pacemaker| grep -v grep | wc -l`
    if [ $pacemaker_proc -gt 0 ]; then
        kill -9 $(ps -ef | grep pacemaker| grep -v grep | awk {'print $2'})
    fi
    sleep 1

    systemctl stop pacemaker.service
    rm -rf /var/lib/pacemaker/cib/cib*

    cd $WORK_DIR
    rm -f resource_cfg
    pcs cluster cib resource_cfg

    # **** 开始配置pacemaker资源
    # 在pacemaker级别忽略quorum
    pcs -f resource_cfg property set no-quorum-policy="ignore"

    # 禁用STONITH
    pcs -f resource_cfg property set stonith-enabled="false"

    # 设置资源粘性，防止节点在故障恢复后发生迁移
    pcs -f resource_cfg resource defaults resource-stickiness="INFINITY"

    # 设置多少次失败后迁移
    pcs -f resource_cfg resource defaults migration-threshold="3" 
    pcs -f resource_cfg resource defaults failure-timeout="10s"

    # 获取子网
    cidr_netmask=`ip addr | grep $MASTER_IP | grep '/' |awk {'print $2'} | awk -F '/' {'print $2'}`
    MIN=0
    MAX=32
    if [ "$cidr_netmask" -lt "$MIN" ] || [ "$cidr_netmask" -gt "$MAX" ]; then
        log_error "ERROR. cidr_netmask error. use default"
        cidr_netmask="24"
    fi

    # 设置master节点虚ip
    pcs -f resource_cfg resource create vip-master IPaddr2 ip="$VIP_MASTER" cidr_netmask="$cidr_netmask"\
        op start   timeout="60s" interval="0s"  on-fail="restart"\
        op monitor timeout="60s" interval="5s"  on-fail="restart"\
        op stop    timeout="60s" interval="0s"  on-fail="block"

    # 设置 drbd 以及 filesystem 资源，使用逻辑卷挂载
    pcs -f resource_cfg resource create skydata ocf:linbit:drbd \
        drbd_resource=skydata op monitor interval=30s

    pcs -f resource_cfg resource master drbd-cluster skydata \
        master-max=1 master-node-max=1 clone-max=2 clone-node-max=1 notify=true

    pcs -f resource_cfg resource create skyfs Filesystem \
        device="/dev/drbd/by-res/skydata" directory="/drbd" fstype="xfs" options="noatime,nodiratime,noexec"

    # 设置 nfs
    pcs -f resource_cfg resource create nfs-daemon nfsserver \
        nfs_shared_infodir=/drbd/nfsshare/nfsinfo nfs_no_notify=true \
        lockd_udp_port=32769 lockd_tcp_port=32803 mountd_port=892 \
        rquotad_port=875 statd_port=662 nfsd_args="-G 10 -L 10"

    pcs -f resource_cfg resource create nfs-root exportfs \
        clientspec=* options=rw,sync,all_squash \
        directory=/drbd/nfsshare/exports fsid=0

    # 添加nfsnotify， 兼容NFSv3. NFSv3 需要一个notify信号，否则容易hung住。
    pcs -f resource_cfg resource create nfs-notify nfsnotify \
            source_host=$vip_master

    # 添加容器。容器中运行的是我们的业务逻辑。我们的任务主要是保证应用容器的高可用。
    for container in ${CONTAINER_LIST[@]}
    do
        docker inspect "$container" >> /dev/null
        if [ $? -ne 0 ]; then
            log_error "There's not such a container:$container running on docker."
            return 1
        fi

        IMAGE_NAME=""
        MONITOR_CMD=""
        CONTAINER_NAME=""
        if [ "$container" == "beanstalkd" ]; then
            IMAGE_NAME=$IMAGE_NAME_BEANSTALKD
            MONITOR_CMD=$MONITOR_CMD_BEANSTLKD
            CONTAINER_NAME=$CONTAINER_NAME_BEANSTALKD
        elif [ "$container" == "redis" ]; then
            IMAGE_NAME=$IMAGE_NAME_REDIS
            MONITOR_CMD=$MONITOR_CMD_REDIS
            CONTAINER_NAME=$CONTAINER_NAME_REDIS
        elif [ "$container" == "pg" ]; then
            IMAGE_NAME=$IMAGE_NAME_POSTGRES
            MONITOR_CMD=$MONITOR_CMD_POSTGRES
            CONTAINER_NAME=$CONTAINER_NAME_POSTGRES
        elif [ "$container" == "main" ]; then
            IMAGE_NAME=$IMAGE_NAME_MAIN
            MONITOR_CMD=$MONITOR_CMD_MAIN
            CONTAINER_NAME=$CONTAINER_NAME_MAIN
        else
            log_error "Unexpected container: $container"
            return 1
        fi

        # 添加容器资源。注意这里使用参数 ‘reuse=true’，这样可以复用已有的容器，包括容器的启动命令、数据卷等参数。
        pcs -f resource_cfg resource create $CONTAINER_NAME docker image=$IMAGE_NAME:latest \
            name="$CONTAINER_NAME"\
            monitor_cmd="$MONITOR_CMD" \
            reuse=true \
            op start timeout="60s" interval="0s" on-fail="restart" \
            op monitor timeout="60s" interval="10s" on-fail="restart" \
            op stop timeout="60s" interval="0s" on-fail="block"
    done

    # HA组件分组:
    pcs -f resource_cfg resource group add master-group skyfs vip-master "$CONTAINER_LIST" nfs-daemon nfs-root nfs-notify

    # HA组件运行位置约束： [vip+drbd-cluster-master+skyfs+pg-cluster-master+bstkd+redis+nfs]  都运行在一台机器上
    pcs -f resource_cfg constraint colocation add master-group with drbd-cluster INFINITY with-rsc-role=Master

    # HA组件启动顺序约束：
    pcs -f resource_cfg constraint order promote drbd-cluster then start master-group score=INFINITY

    # HA 首次启动位置约束
    pcs -f resource_cfg constraint location drbd-cluster prefers $MASTER_HOSTNAME=10

    # **** 提交配置
    pcs cluster cib-push resource_cfg
    rm -f resource_cfg
}

check_ha_status() {
    TRY=1
    while [ $TRY -lt 60 ]
    do
        if check_status; then
            log_info "OK. HA status is correct."
            return 0
        fi

        systemctl status pacemaker.service >>/dev/null
        if [ $? -ne 0 ]; then
            systemctl start pacemaker.service
            sleep 2
        fi

        pcs cluster unstandby --all

        sleep 1
        let "TRY++"
    done
    log_error "HA status is incorrect."
    return 1
}

print_finished() {
    echo '
                                 
            Skylar  High  Available
                Powered by Gary

              ___.-~"~-._   __....__
            .`    `    \ ~"~        ``-.
           /` _      )  `\              `\
          /`  a)    /     |               `\
         :`        /      |                 \
    <`-._|`  .-.  (      /   .            `;\\
     `-. `--`_.`-.;\___/`   .      .       | \\
  _     /:--`     |        /     /        .`  \\
 ("\   /`/        |       `     `         /    :`;
 `\`\_/`/         .\     /`~`--.:        /     ``
   `._.`          /`\    |      `\      /(
                 /  /\   |        `Y   /  \
                J  /  Y  |         |  /`\  \
               /  |   |  |         |  |  |  |
              "---"  /___|        /___|  /__|
                     `"""         `"""  `"""
'

    log_info "Congratulations! Installation completed!"
}

check()

clean()

reset()

show_version() {
    echo "version:1.0.1"
}

install() {
    if ! install_rpms; then
        log_error "Install rpms failed."
        exit 1
    fi

    if ! config_service; then
        log_error "Config services failed."
        exit 1
    fi

    enable "auto_recovery"
}

run() {
    if ! startup_services; then
        log_error "Start up service failed."
        exit 1
    fi

    if ! config_ha_resources; then
        log_error "Config HA resources failed."
        exit 1
    fi

    # **** 检查HA状态，阻塞在这里，直到HA状态正确。
    # 连续调用3次的目的是：ha状态不对时，耐心等待3次。如果ha状态正确，能立即返回。
    check_ha_status
    check_ha_status
    check_ha_status
    if [ $? -ne 0 ]; then
        log_error "ERROR. config failed."
        exit 1
    fi

    print_finished
}

boot() {
    sleep 5
    systemctl start docker.service
    systemctl start pacemaker.service
    pcs cluster unstandby
    sleep 30
    pcs cluster unstandby
}

# 检查ip格式是否正确
check_ip_valid() {
    echo $1|grep "^[0-9]\{1,3\}\.\([0-9]\{1,3\}\.\)\{2\}[0-9]\{1,3\}$" > /dev/null; 
    if [ $? -ne 0 ]; then 
        return 1 
    fi
    ipaddr=$1 
    a=`echo $ipaddr|awk -F . '{print $1}'`  #以"."分隔，取出每个列的值 
    b=`echo $ipaddr|awk -F . '{print $2}'` 
    c=`echo $ipaddr|awk -F . '{print $3}'` 
    d=`echo $ipaddr|awk -F . '{print $4}'` 
    for num in $a $b $c $d 
    do
        if [ $num -gt 255 ] || [ $num -lt 0 ]; then 
            return 1 
        fi 
    done
    return 0
}

# 启用开机自动恢复功能。主要思想是在rc.local里添加开机启动脚本。
enable() {
    arg=$1
    if [ "$arg" == "auto_recovery" ]; then
        cat /etc/rc.d/rc.local | grep 'skyha boot'
        if [ $? -eq 0 ]; then
            return 0
        fi
        echo "/usr/local/bin/skyha boot >> $LOG &" >> /etc/rc.d/rc.local
        chmod +x /etc/rc.local /etc/rc.d/rc.local
    fi
}

# 禁用开机自动恢复功能
disable() {
    arg=$1
    if [ "$arg" == "auto_recovery" ]; then
        sed -i '/skyha/d' /etc/rc.d/rc.local
    fi
}

# 释放rpm包、释放可执行文件，放入指定目录
extract_files() {
    # 获取系统平台型号，目前暂时只支持centos7.2和redhat7.0两种
    OS_PLATFORM="centos"
    cat /etc/os-release | grep 'VERSION_ID="7.0"' >>/dev/null
    if [ $? -eq 0 ]; then
        OS_PLATFORM="rhel"
    fi

    # 释放rpm包
    RPM=/usr/lib/skyha/rpm
    mkdir -p "$RPM"
    rm -rf /usr/lib/skyha/rpm/*
    if [ "$OS_PLATFORM" == "centos" ]; then
        cp -rf $WORK_DIR/deps/rh_7_0/* "$RPM/"
    elif [ "$OS_PLATFORM" == "rhel" ]; then
        cp -rf $WORK_DIR/deps/centos_7_2/* "$RPM/"
    fi

    # 释放配置文件
    mkdir -p /etc/skyha.d
    cp -f $WORK_DIR/conf/ha.conf.example /etc/skyha.d

    # 释放可执行程序
    mkdir -p /usr/local/bin
    cp -f ./skyha.sh "$BIN"
    chmod +x "$BIN"
}

source $CONF
my_ip="$MASTER_IP"
hostname -I | grep "$SLAVE_IP"
if [ $? -eq 0 ]; then
    my_ip="$SLAVE_IP"
fi

# 检查配置文件，如果配置错误，则直接退出程序
if ! check_conf; then
    log_error "Configs are invalid. See $CONF."
    exit 1
fi

extract_files

# 设置本机的 hostname
if [ "$my_ip" == "$MASTER_IP" ]; then
    hostnamectl set-hostname "$MASTER_HOSTNAME"
else
    hostnamectl set-hostname "$SLAVE_HOSTNAME"
fi

case "$1" in
    #failover)                failover;;
    #args_parse)              args_parse $@;;
    #prepare)                 prepare;;    
    #reset)                   reset;;
    #recover)                 recover $2;;
    boot)                    boot;;
    install)                 install $@;;
    run)                     run $@;;
    #config)                  config $@;;
    #standalone)              failover STANDALONE;;
    #enable)                  enable $2;;
    #disable)                 disable $2;;
    #brain)                   solve_split_brain;;
    #show)                    show_status;;
    #show_xml)                show_status_as_xml;;
    #switch-master-slave)     switch;;
    #setup)                   setup $@;;
    version|-v|--version)    show_version;;
    help|usage|-h|--help)    usage;;
    *)                       usage;;
esac
