#!/usr/bin/env bash

testdir=$(readlink -f $(dirname $0))
rootdir=$(readlink -f $testdir/../../..)
source $rootdir/test/common/autotest_common.sh
source $rootdir/test/iscsi_tgt/common.sh

# $1 = "iso" - triggers isolation mode (setting up required environment).
# $2 = test type posix or vpp. defaults to posix.
iscsitestinit $1 $2

function check_qos_works_well() {
	local enable_limit=$1
	local qos_limit=$2
	local check_qos=$4
	local retval=0
	local iostats

	iostats=$($rpc_py get_bdevs_iostat -b $3)
	start_io_count=$(jq -r '.bdevs[0].num_read_ops' <<< "$iostats")
	start_bytes_read=$(jq -r '.bdevs[0].bytes_read' <<< "$iostats")

	$fio_py iscsi 1024 128 randread 5 1

	iostats=$($rpc_py get_bdevs_iostat -b $3)
	end_io_count=$(jq -r '.bdevs[0].num_read_ops' <<< "$iostats")
	end_bytes_read=$(jq -r '.bdevs[0].bytes_read' <<< "$iostats")

	if [ $LIMIT_TYPE = IOPS ]; then
		read_result=$(((end_io_count-start_io_count)/5))
	else
		read_result=$(((end_bytes_read-start_bytes_read)/5))
	fi

	if [ $enable_limit = true ]; then
		#qos realization is related with bytes transfered.It currently have like 5% variation.
		retval=$(echo "$qos_limit*0.85 < $read_result && $read_result < $qos_limit*1.05" | bc)
		if [ $retval -eq 0 ]; then
			echo "Failed to limit the io read rate of malloc bdev by qos"
			exit 1
		fi
	else
		retval=$(echo "$read_result > $qos_limit" | bc)
		if [ $retval -eq 0 ]; then
			if [ $check_qos = true ]; then
				echo "$read_result less than $qos_limit - exit QoS testing"
				ENABLE_QOS=false
				exit 0
			else
				echo "$read_result less than $qos_limit - expected greater than"
				exit 1
			fi
		fi
	fi
}

if [ -z "$TARGET_IP" ]; then
	echo "TARGET_IP not defined in environment"
	exit 1
fi

if [ -z "$INITIATOR_IP" ]; then
	echo "INITIATOR_IP not defined in environment"
	exit 1
fi

timing_enter qos

MALLOC_BDEV_SIZE=64
MALLOC_BLOCK_SIZE=512
ENABLE_QOS=true
IOPS_LIMIT=20000
BANDWIDTH_LIMIT_MB=20
BANDWIDTH_LIMIT=$(($BANDWIDTH_LIMIT_MB*1024*1024))
READ_BANDWIDTH_LIMIT_MB=10
READ_BANDWIDTH_LIMIT=$(($READ_BANDWIDTH_LIMIT_MB*1024*1024))
LIMIT_TYPE=IOPS
rpc_py="$rootdir/scripts/rpc.py"
fio_py="$rootdir/scripts/fio.py"

timing_enter start_iscsi_tgt

$ISCSI_APP &
pid=$!
echo "Process pid: $pid"
trap "killprocess $pid; iscsitestfini $1 $2; exit 1" SIGINT SIGTERM EXIT
waitforlisten $pid
echo "iscsi_tgt is listening. Running tests..."

timing_exit start_iscsi_tgt

$rpc_py add_portal_group $PORTAL_TAG $TARGET_IP:$ISCSI_PORT
$rpc_py add_initiator_group $INITIATOR_TAG $INITIATOR_NAME $NETMASK
$rpc_py construct_malloc_bdev $MALLOC_BDEV_SIZE $MALLOC_BLOCK_SIZE
# "Malloc0:0" ==> use Malloc0 blockdev for LUN0
# "1:2" ==> map PortalGroup1 to InitiatorGroup2
# "64" ==> iSCSI queue depth 64
# "-d" ==> disable CHAP authentication
$rpc_py construct_target_node Target1 Target1_alias 'Malloc0:0' $PORTAL_TAG:$INITIATOR_TAG 64 -d
sleep 1

iscsiadm -m discovery -t sendtargets -p $TARGET_IP:$ISCSI_PORT
iscsiadm -m node --login -p $TARGET_IP:$ISCSI_PORT

trap "iscsicleanup; killprocess $pid; iscsitestfini $1 $2; exit 1" SIGINT SIGTERM EXIT

# Check whether to enable the QoS testing.
check_qos_works_well false $IOPS_LIMIT Malloc0 true

if [ $ENABLE_QOS = true ]; then
	# Limit the I/O rate by RPC, then confirm the observed rate matches.
	$rpc_py set_bdev_qos_limit Malloc0 --rw_ios_per_sec $IOPS_LIMIT
	check_qos_works_well true $IOPS_LIMIT Malloc0 false

	# Now disable the rate limiting, and confirm the observed rate is not limited anymore.
	$rpc_py set_bdev_qos_limit Malloc0 --rw_ios_per_sec 0
	check_qos_works_well false $IOPS_LIMIT Malloc0 false

	# Limit the I/O rate again.
	$rpc_py set_bdev_qos_limit Malloc0 --rw_ios_per_sec $IOPS_LIMIT
	check_qos_works_well true $IOPS_LIMIT Malloc0 false
	echo "I/O rate limiting tests successful"

	# Limit the I/O bandwidth rate by RPC, then confirm the observed rate matches.
	LIMIT_TYPE=BANDWIDTH
	$rpc_py set_bdev_qos_limit Malloc0 --rw_ios_per_sec 0 --rw_mbytes_per_sec $BANDWIDTH_LIMIT_MB
	check_qos_works_well true $BANDWIDTH_LIMIT Malloc0 false

	# Now disable the bandwidth rate limiting, and confirm the observed rate is not limited anymore.
	$rpc_py set_bdev_qos_limit Malloc0 --rw_mbytes_per_sec 0
	check_qos_works_well false $BANDWIDTH_LIMIT Malloc0 false

	# Limit the I/O bandwidth rate again with both read/write and read/only.
	$rpc_py set_bdev_qos_limit Malloc0 --rw_mbytes_per_sec $BANDWIDTH_LIMIT_MB --r_mbytes_per_sec $READ_BANDWIDTH_LIMIT_MB
	check_qos_works_well true $READ_BANDWIDTH_LIMIT Malloc0 false
	echo "I/O bandwidth limiting tests successful"
fi

iscsicleanup
$rpc_py delete_target_node 'iqn.2016-06.io.spdk:Target1'

rm -f ./local-job0-0-verify.state
trap - SIGINT SIGTERM EXIT
killprocess $pid

iscsitestfini $1 $2
timing_exit qos
