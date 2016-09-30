#!/bin/sh
#
# This is a script to auto run test case for HA system.
# The script will run at the third computer, 
# and it will auto run install command to install master and slave, 
# do failover and check result, and output test result. 
#
# Authors:      Qin Guanri
# Copyright:    2016 403709339@qq.com
#
#########################################################################


#-------------------------------
#enable_auto_test=true
enable_auto_test=false
#-------------------------------

if [ "$enable_auto_test" == false ]; then
    echo "Auto test is disable. Do nothing."
    return 0
fi


master_ip=192.168.83.128
slave_ip=192.168.83.130
vip_master=192.168.83.140
data_dir=/data
master_hostname=db1
slave_hostname=db2
drbd_size=1000

code_dir=/root/skyha/skylar_ha
cur_master_ip=0.0.0.0
cur_slave_ip=0.0.0.0
ERROR_INFO=""

WORK_DIR=$(cd `dirname $0`; pwd)

# install the ha system.
do_install() {
    echo "do_install" > $WORK_DIR/auto_test/auto_test.log
    date >> $WORK_DIR/auto_test/auto_test.log

    # pull code and stop service.
    ssh root@$master_ip "cd $code_dir; git pull; systemctl stop pacemaker.service; drbdadm down skydata" >>/dev/null
    ssh root@$slave_ip "cd $code_dir; git pull; systemctl stop pacemaker.service; drbdadm down skydata" >>/dev/null

    ssh root@master_ip "$code_dir/skyha install master_ip=$master_ip slave_ip=$slave_ip vip_master=$vip_master data_dir=$data_dir master_hostname=$master_hostname slave_hostname=$slave_hostname drbd_size=$drbd_size" > $WORK_DIR/auto_test/auto_test.log
    ret=$?

    date >> $WORK_DIR/auto_test/auto_test.log

    if [ $ret -ne 0 ]; then
        echo "ERROR. do_install failed."
        exit 1
    fi

    return 0
}

# run the auto test case
do_failover() {
    test_case_1
    test_case_2
    test_case_3
    test_case_4
    return 0
}

recover_ha_status() {
    return 0
}

check_master_status() {
    result=0
    ERROR_INFO=""

    get_current_master_slave_ip
    ssh root@$cur_master_ip "ip addr | grep $vip_master"
    if [ $? -ne 0 ]; then
        ERROR_INFO="$ERROR_INFO+ERROR. vip_master error."
        result=1
    fi

    ssh root@$cur_master_ip "cat /proc/drbd | grep Primary"
    if [ $? -ne 0 ]; then
        ERROR_INFO="$ERROR_INFO+ERROR. drbd process error."
        result=1
    fi

    ssh root@$cur_master_ip "ps -ef | grep postgres"
    if [ $? -ne 0 ]; then 
        ERROR_INFO="$ERROR_INFO+ERROR. pg process error."
        result=1
    fi

    ssh root@$cur_master_ip "ps -ef | grep redis"
    if [ $? -ne 0 ]; then
        ERROR_INFO="$ERROR_INFO+ERROR. redis process error."
        result=1
    fi

    ssh root@$cur_master_ip "ps -ef | grep beanstalkd"
    if [ $? -ne 0 ]; then
        ERROR_INFO="$ERROR_INFO+ERROR. beanstalkd process error."
        result=1
    fi

    return $result
}

check_status() {
    try=0
    while [ $try -lt 5 ]
    do
        if check_master_status; then
            return 0
        fi
        sleep 5
        let "try++"
    done
    return 1
}

main() {
    do_install
    do_failover
    output_test_result
}

get_current_master_slave_ip() {
    cur_master_ip=$master_ip
    cur_slave_ip=$slave_ip
    ssh root@$master_ip "ip addr | grep $vip_master"
    if [ $? -ne 0 ]; then 
        cur_master_ip=$slave_ip
        cur_slave_ip=$master_ip
    fi
    ssh root@$slave_ip "ip addr | grep $vip_master"
    if [ $? -ne 0 ]; then
        cur_master_ip=0.0.0.0
        cur_slave_ip=0.0.0.0
        echo "ERROR. get master and slave ip failed."
        exit 1
    fi
    #echo "cur_master_ip=$cur_master_ip, cur_slave_ip=$cur_slave_ip"
}

print_test_case_unpass() {
    echo "unpass. error info:$ERROR_INFO"
    exit 1
}

print_test_case_pass() {
    echo "pass."
}
test_case_1() {
    echo "测试用例：master上的pg容器异常退出"
    get_current_master_slave_ip
    ssh root@$cur_master_ip "docker stop pg"
    if ! check_status; then
        print_test_case_unpass
    fi

    print_test_case_pass
}

test_case_2() {
    return 0
}

test_case_3() {
    return 0
}

test_case_4() {
    return 0
}

output_test_result() {
    echo "Done."
    return 0
}


#
main
