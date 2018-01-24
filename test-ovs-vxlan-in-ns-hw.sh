#!/bin/bash
#
# Bug SW #1262606: [ASAP MLNX OFED] vxlan dummy device has empty flower rules after cleaning ovs bridge
#

NIC=${1:-ens1f0}
VF1=${2:-ens1f2}
VF2=${3:-ens1f3}

my_dir="$(dirname "$0")"
. $my_dir/common.sh


VM1_IP="7.7.7.1"
VM2_IP="7.7.7.2"

local_tun="2.2.2.2"
remote_tun="2.2.2.3"

vm1_port=$VF1
vm1_port_rep=`get_rep 0`
vm2_port=$VF2
vm2_port_rep=`get_rep 1`

if [ `uname -r` = "3.10.0" ] || [ `uname -r` = "3.10.0-327.el7.x86_64" ];  then
    vxlan_device="dummy_4789"
else
    vxlan_device="vxlan_sys_4789"
fi

function cleanup() {
    echo "cleanup"
    start_clean_openvswitch
    ip l show type vxlan |xargs grep ip l del dev &> /dev/null
    ip netns del ns0 &> /dev/null

    for i in `seq 0 7`; do
        ip link del veth$i &> /dev/null
    done
}

cleanup
bind_vfs $NIC


for i in $vm1_port $vm1_port_rep $vm2_port $vm2_port_rep ; do
    test -e /sys/class/net/$i || fail "Cannot find interface $i"
done

echo "setup ns"

for i in $vm1_port $vm1_port_rep $vm2_port $vm2_port_rep ; do
    ip a flush dev $vm1_port
done

ifconfig $vm1_port $VM1_IP/24 up
ifconfig $vm1_port_rep up

ip netns add ns0
ip link set $vm2_port netns ns0
ip netns exec ns0 ifconfig $vm2_port $remote_tun/24 up

ip netns exec ns0 ip link add name vxlan42 type vxlan id 42 dev $vm2_port remote $local_tun dstport 4789
ip netns exec ns0 ifconfig vxlan42 $VM2_IP/24 up

ifconfig $vm2_port_rep $local_tun/24 up

echo "setup ovs"
ovs-vsctl add-br brv-1
ovs-vsctl add-port brv-1 $vm1_port_rep
ovs-vsctl add-port brv-1 vxlan0 -- set interface vxlan0 type=vxlan options:local_ip=$local_tun options:remote_ip=$remote_tun options:key=42 options:dst_port=4789


function check_offloaded_rules() {
    local count=$1
    title " - check for $count offloaded rules"
    RES="ovs-appctl dpctl/dump-flows type=offloaded | grep 0x0800"
    eval $RES
    RES=`eval $RES | wc -l`
    if (( RES == $count )); then success; else err; fi
}

function delete_vxlan_port_then_bridge() {
    title " - delete vxlan port"
    ovs-vsctl del-port brv-1 vxlan0
    if (( $? == 0 )); then success; else err; fi
    title " - delete bridge"
    ovs-vsctl del-br brv-1
    if (( $? == 0 )); then success; else err; fi
}

function check_empty_flower_rules() {
    title " - check for empty flower rules"
    RES="tc -s filter show dev $vxlan_device ingress"
    eval $RES
    RES=`eval $RES | wc -l`
    if (( RES == 0 )); then success; else err; fi
}

title "Test ping $VM1_IP -> $VM2_IP"
start_check_syndrome
ping -q -c 10 -i 0.2 -w 2 $VM2_IP && success || err

check_offloaded_rules 2

# Check Bug SW #1262606
delete_vxlan_port_then_bridge
check_empty_flower_rules

cleanup
check_syndrome
test_done
