#!/bin/sh
#
# 作者：qinguanri 
# 时间：2017-03-11
# 描述：
#
###################################################

CONF=/etc/skyha/ha.conf
BIN=/usr/local/bin/skyha
LOG=/var/log/skyha.log
BACKUP_DIR=/backup
RPM=/usr/lib/skyha/rpm
WORK_DIR=$(cd `dirname $0`; pwd)

IMAGE_NAME_BEANSTALKD="skylar_beanstalkd"
IMAGE_NAME_MAIN="skylar_main"
IMAGE_NAME_REDIS="skylar_redis"
BEANSTALKD_MONITOR_CMD="supervisorctl status beanstalkd | grep RUNNING"
MAIN_MONITOR_CMD="supervisorctl status nginx | grep RUNNING"
REDIS_MONITOR_CMD="redis-cli time >/dev/null"
POSTGRES_MONITOR_CMD="su postgres -c \"psql -U postgres -Atc \\\"select now();\\\"\""

source $CONF
my_ip="$MASTER_IP"
hostname -I | grep "$SLAVE_IP"
if [ $? -eq 0 ]; then
    my_ip="$SLAVE_IP"
fi

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

# 检查配置文件的配置是否正确，配置文件默认为 /etc/skyha/ha.conf
# 在启动服务之前，务必先要检查配置的正确性
check_conf() {
    log_info '--> checking configs ...'

    ping -c 1 "$MASTER_IP" >> /dev/null
    if [ $? -ne 0 ]; then
        log_error 'MASTER_IP is invalid'
        return 1
    fi

    ping -c 1 "$SLAVE_IP" >> /dev/null
    if [ $? -ne 0 ]; then
        log_error 'SLAVE_IP is invalid'
        return 1
    fi

    fdisk -l | grep "$LOGIC_VOLUME" >> /dev/null
    if [ $? -ne 0 ]; then
        log_error 'LOGIC_VOLUME is invalid'
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
config_service() {
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
startup_service() {
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

    log_info "--> Copy data from /data/ to /drbd/ ..."
    cp -rf /data/* /drbd/

    umount /dev/drbd1
    drbdadm secondary skydata
}

config_ha_resources() {
    cidr_netmask=`ip addr | grep $MASTER_IP | grep '/' |awk {'print $2'} | awk -F '/' {'print $2'}`
    MIN=0
    MAX=32
    if [ "$cidr_netmask" -lt "$MIN" ] || [ "$cidr_netmask" -gt "$MAX" ]; then
        log_error "ERROR. cidr_netmask error. use default"
        cidr_netmask="24"
    fi
 
    cd $WORK_DIR
    rm -f resource_cfg
    pcs cluster cib resource_cfg

    # 在pacemaker级别忽略quorum
    pcs -f resource_cfg property set no-quorum-policy="ignore"

    # 禁用STONITH
    pcs -f resource_cfg property set stonith-enabled="false"

    # 设置资源粘性，防止节点在故障恢复后发生迁移
    pcs -f resource_cfg resource defaults resource-stickiness="INFINITY"

    # 设置多少次失败后迁移
    pcs -f resource_cfg resource defaults migration-threshold="3" 
    pcs -f resource_cfg resource defaults failure-timeout="10s"

    # 设置master节点虚ip
    pcs -f resource_cfg resource create vip-master IPaddr2 ip="$VIP_MASTER" cidr_netmask="$cidr_netmask"\
        op start   timeout="60s" interval="0s"  on-fail="restart"\
        op monitor timeout="60s" interval="5s"  on-fail="restart"\
        op stop    timeout="60s" interval="0s"  on-fail="block"

    # 设置 drbd 以及 filesystem 资源，使用逻辑卷挂载
    pcs -f resource_cfg resource create skydata ocf:linbit:drbd drbd_resource=skydata op monitor interval=30s
    pcs -f resource_cfg resource master drbd-cluster skydata master-max=1 master-node-max=1 clone-max=2 clone-node-max=1 notify=true
    pcs -f resource_cfg resource create skyfs Filesystem device="/dev/drbd/by-res/skydata" directory="/drbd" fstype="xfs" options="noatime,nodiratime,noexec"

    # 设置 nfs
    pcs -f resource_cfg resource create nfs-daemon nfsserver \
        nfs_shared_infodir=/drbd/nfsshare/nfsinfo nfs_no_notify=true \
        lockd_udp_port=32769 lockd_tcp_port=32803 mountd_port=892 \
        rquotad_port=875 statd_port=662 nfsd_args="-G 10 -L 10"

    pcs -f resource_cfg resource create nfs-root exportfs \
        clientspec=* options=rw,sync,all_squash \
        directory=/drbd/nfsshare/exports fsid=0

    # 添加nfsnotify， 兼容NFSv3. 
    pcs -f resource_cfg resource create nfs-notify nfsnotify \
            source_host=$vip_master

    for container in ${CONTAINER_LIS[@]}
    do
        IMAGE_NAME=
        MONITOR_CMD=""

        if [ "$container" == "beanstalkd" ]; then
            IMAGE_NAME=$BEANSTLKD_IMAGE_NAME
            MONITOR_CMD=$MONITOR_BEANSTALKD_CMD

            
        elif [ "$container" == "redis" ]; then
        elif [ "$container" == "pg" ]; then
        elif [ "$container" == "main" ]; then
        else

        fi
    done
    

    for file in $WORK_DIR/resource/*
    do
        if [ -f $file ]; then
            $file "failover"
            if [ $? -ne 0 ]; then
                log_error "ERROR. execute $file failover failed."
                return 1
            fi
        fi
    done

    # HA组件分组:
    pcs -f resource_cfg resource group add master-group skyfs vip-master postgres redis bstkd nfs-daemon nfs-root nfs-notify

    ## HA组件运行位置约束： [vip+drbd-cluster-master+skyfs+pg-cluster-master+bstkd+redis+nfs]  都运行在一台机器上
    pcs -f resource_cfg constraint colocation add master-group with drbd-cluster INFINITY with-rsc-role=Master

    ## HA组件启动顺序约束：
    pcs -f resource_cfg constraint order promote drbd-cluster then start master-group score=INFINITY

    ## HA 首次启动位置约束
    pcs -f resource_cfg constraint location drbd-cluster prefers $MASTER_HOSTNAME=10

    pcs cluster cib-push resource_cfg
    rm -f resource_cfg

    sleep 2
    pcs cluster unstandby --all

    if [ "$mode" == "STANDALONE" ]; then
        $WORK_DIR/resource/pg check_master_status
        if [ $? -ne 0 ]; then
            log_error "ERROR. PG master status is error."
            return 1
        fi
        install_finished
        return 0
    fi

    check_ha_status
    check_ha_status
    check_ha_status
    if [ $? -ne 0 ]; then
        log_error "ERROR. config failed."
        return 1  
    fi

}
check()

clean()

reset()

# 检查配置文件，如果配置错误，则直接退出程序
if ! check_conf; then
    log_error "Configs are invalid. See $CONF."
    exit 1
fi

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
    #boot)                    boot;;
    install)                 install_all $@;;
    #config)                  config $@;;
    #standalone)              failover STANDALONE;;
    #enable)                  enable $2;;
    #disable)                 disable $2;;
    #brain)                   solve_split_brain;;
    #show)                    show_status;;
    #show_xml)                show_status_as_xml;;
    #switch-master-slave)     switch;;
    #setup)                   setup $@;;
    version|-v|--version)    version;;
    help|usage|-h|--help)    usage;;
    *)                       usage;;
esac
