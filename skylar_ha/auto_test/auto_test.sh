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
enable_auto_test=true
#enable_auto_test=false
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

WORK_DIR=$(cd `dirname $0`; cd ../; pwd)

begin_time=`date +%s`
end_time=`date +%s`

# install the ha system.
do_install() {
    touch $WORK_DIR/auto_test/auto_test.log
    echo "do_install" > $WORK_DIR/auto_test/auto_test.log
    date >> $WORK_DIR/auto_test/auto_test.log

    # pull code and stop service.
    ssh root@$master_ip "cd $code_dir; git pull; systemctl stop pacemaker.service; drbdadm down skydata" >>/dev/null
    ssh root@$slave_ip "cd $code_dir; git pull; systemctl stop pacemaker.service; drbdadm down skydata" >>/dev/null
    
    echo "login $master_ip to run install command ..."
    ssh root@$master_ip "$code_dir/skyha install master_ip=$master_ip slave_ip=$slave_ip vip_master=$vip_master data_dir=$data_dir master_hostname=$master_hostname slave_hostname=$slave_hostname drbd_size=$drbd_size"    
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
    echo -e "\033[32m 执行测试用例 \033[0m"
    begin_time=`date +%s`; test_case_1; print_test_result
    begin_time=`date +%s`; test_case_2; print_test_result
    begin_time=`date +%s`; test_case_3; print_test_result
    return 0
}

recover_ha_status() {
    return 0
}

check_master_status() {
    result=0
    ERROR_INFO=""
    get_current_master_slave_ip
    ssh root@$cur_master_ip "ip addr | grep $vip_master" >>/dev/null
    if [ $? -ne 0 ]; then
        ERROR_INFO="$ERROR_INFO+ERROR. vip_master error."
        result=1
    fi

    ssh root@$cur_master_ip "cat /proc/drbd | grep Primary" >> /dev/null
    if [ $? -ne 0 ]; then
        ERROR_INFO="$ERROR_INFO+ERROR. drbd process error." >> /dev/null
        result=1
    fi

    processes=("postgres" "redis" "beanstalkd")
    for pro in ${processes[@]}
    do
        ssh root@$cur_master_ip "ps -ef | grep $pro" >>/dev/null
        if [ $? -ne 0 ]; then 
            ERROR_INFO="$ERROR_INFO+ERROR. process $pro status error."
            result=1
        fi
    done

    
    resources=("skyfs" "vip-master" "postgres" "redis" "bstkd" "nfs-daemon" "nfs-root")
    for res in ${resources[@]}
    do
         
        ssh root@$cur_master_ip "crm_mon -Afr -1 | grep $res | grep Started" >>/dev/null
        if [ $? -ne 0 ]; then
            ERROR_INFO="$ERROR_INFO+ERROR. pacemaker resource $res status error."
            result=1
        fi
    done


    return $result
}

check_status() {
    sleep 5   # 等待切换完成
    try=0
    while [ $try -lt 60 ]
    do  
        sleep 1
        if check_master_status; then
            return 0
        fi
        let "try++"
    done
    return 1
}

main() {
    #do_install
    do_failover
    output_test_result
}

get_current_master_slave_ip() {
    cur_master_ip=$master_ip
    cur_slave_ip=$slave_ip
    ssh root@$master_ip "ip addr | grep $vip_master" >> /dev/null
    if [ $? -ne 0 ]; then 
        cur_master_ip=$slave_ip
        cur_slave_ip=$master_ip
    fi
    #echo "cur_master_ip=$cur_master_ip, cur_slave_ip=$cur_slave_ip"
}

print_test_case_unpass() {
    end_time=`date +%s`
    let used_time=$end_time-$begin_time
    echo -e "\033[31m unpass. time used: $used_time seconds. error info:$ERROR_INFO \033[0m"
    
    echo "Detail info:"
    cat /proc/drbd
    crm_mon -Afr -1
    
    exit 1
}

print_test_case_pass() {
    end_time=`date +%s`
    let used_time=$end_time-$begin_time
    echo -e "\033[32m pass. time used: $used_time seconds \033[0m"
}

print_test_result() {
    if ! check_status; then
        print_test_case_unpass
    fi
    print_test_case_pass
    echo "----"
}

test_case_1() {
    echo -e "\033[32m master上的pg容器异常退出 \033[0m"
    get_current_master_slave_ip
    ssh root@$cur_master_ip "docker stop pg" >>/dev/null
}

test_case_2() {
    echo -e "\033[32m master上的redis容器异常退出 \033[0m"
    get_current_master_slave_ip
    ssh root@$cur_master_ip "docker stop redis" >>/dev/null

}

test_case_3() {
    echo -e "\033[32m master上的beanstalkd容器异常退出 \033[0m"
    get_current_master_slave_ip
    ssh root@$cur_master_ip "docker stop beanstalkd" >>/dev/null
}

output_test_result() {
    echo -e "\033[32m Done. \033[0m"
    return 0
}


#
main
