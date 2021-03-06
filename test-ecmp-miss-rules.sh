#!/bin/bash
#
# Toggle num of vfs on one port after peer miss rules were already allocated.
# Check number of allocated peer miss rules is correct.
#

NIC=${1:-ens5f0}

my_dir="$(dirname "$0")"
. $my_dir/common.sh

config_sriov 2
require_multipath_support
require_mlxdump
require_mlxconfig
reset_tc_nic $NIC

function disable_sriov() {
    echo 0 > /sys/class/net/$NIC/device/sriov_numvfs
    echo 0 > /sys/class/net/$NIC2/device/sriov_numvfs
}

function enable_sriov() {
    enable_sriov_port1
    enable_sriov_port2
}

function enable_sriov_port1() {
    echo "- Enable SRIOV port1"
    echo 2 > /sys/class/net/$NIC/device/sriov_numvfs
}

function enable_sriov_port2() {
    echo "- Enable SRIOV port2"
    echo 2 > /sys/class/net/$NIC2/device/sriov_numvfs
}

function disable_sriov_port2() {
    echo 0 > /sys/class/net/$NIC2/device/sriov_numvfs
}

function activate_multipath() {
    echo "- Enable multipath"
    disable_sriov
    enable_sriov
    unbind_vfs $NIC
    unbind_vfs $NIC2
    enable_multipath || err "Failed to enable multipath"
    wa_reset_multipath
}

function test_toggle_miss_rules() {
    activate_multipath

    i=0 && mlxdump -d $PCI fsdump --type FT --gvmi=$i --no_zero > /tmp/port$i || err "mlxdump failed"
    i=1 && mlxdump -d $PCI fsdump --type FT --gvmi=$i --no_zero > /tmp/port$i || err "mlxdump failed"
    count0=`cat /tmp/port0 | grep VPORT -B2 | grep source_port | wc -l`
    count1=`cat /tmp/port1 | grep VPORT -B2 | grep source_port | wc -l`

    echo "Got $count0 miss rules on port0 and $count1 rules on port1"

    echo "- Disable SRIOV port2"
    enable_legacy $NIC2
    disable_sriov_port2
    echo "- Enable SRIOV port2" 
    config_sriov 4 $NIC2

    enable_switchdev $NIC2

    i=0 && mlxdump -d $PCI fsdump --type FT --gvmi=$i --no_zero > /tmp/port$i || err "mlxdump failed"
    i=1 && mlxdump -d $PCI fsdump --type FT --gvmi=$i --no_zero > /tmp/port$i || err "mlxdump failed"
    count0=`cat /tmp/port0 | grep VPORT -B2 | grep source_port | wc -l`
    count1=`cat /tmp/port1 | grep VPORT -B2 | grep source_port | wc -l`

    # Today we allocate max possible peer miss rules instead of enabled vports.
    _expect=`mlxconfig -d $PCI q | grep NUM_OF_VFS | awk {'print $2'}`

    if [ $count0 -ne $_expect ] || [ $count1 -ne $_expect ]; then
        echo "Got $count0 miss rules on port0 and $count1 rules on port1"
        err "Expected $_expect peer miss rules on each port."
    else
        success "Got $count0 miss rules on port0 and $count1 rules on port1"
    fi

    # leave NIC in sriov
    disable_multipath || err "Failed to disable multipath"
    disable_sriov
    config_sriov
}


# Execute all test_* functions
for i in `declare -F | awk {'print $3'} | grep ^test_ | grep -v test_done` ; do
    title $i
    eval $i
done

test_done
