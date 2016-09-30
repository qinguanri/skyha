#!/bin/sh
#
# This is a script to auto run test case for HA system.
# The script will run at the third computer, 
# and it will auto run install command to install master and slave, 
# do failover and check result, and output test result. 
#
# Authors:      Qin Guanri
# Copyright:    2016 403709339@qq.com

#enable_auto_test=true
enable_auto_test=false

if [ "$enable_auto_test" == false ]; then
	echo "Auto test is disable. Do nothing."
	return 0
fi

# install the ha system.
do_install() {
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

main() {
	do_install
	do_failover
	output_test_result
}

test_case_1() {
	return 0
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
	return 0
}


#
main
