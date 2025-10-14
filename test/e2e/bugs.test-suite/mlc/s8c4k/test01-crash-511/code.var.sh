# MLC URL can be found from here:
# https://www.intel.com/content/www/us/en/download/736633/intel-memory-latency-checker-intel-mlc.html
MLC_URL='TODO: go to Intel Memory Latency Checker (MLC) page, approve license, and copy manual download URL and replace this string with it.'

# Check we are running a kernel that uses expected CPU numbering.
min_kernel_version=6.14
vm-command "uname -r"
if [ "$( ( echo $min_kernel_version; echo $COMMAND_OUTPUT ) | sort --version-sort | tail -n 1 )" == "$min_kernel_version" ]; then
    error "quest OS runs too old kernel, hot-plugged CPU node topology may not work. Required: $min_kernel_version"
fi

# Hot-plug CPUs.
vm-command 'grep 511,1535,4095 /sys/devices/system/cpu/enabled' || {
    vm-cpu-hotplug 0 511 0
    vm-cpu-hotplug 2 511 0
    vm-cpu-hotplug 7 511 0

    # Wait for the kernel to expose all hot-plugged CPUs in sysfs.
    vm-run-until '[ -d /sys/devices/system/cpu/cpu511 ] && [ -d /sys/devices/system/cpu/cpu1535 ] && [ -d /sys/devices/system/cpu/cpu4095 ]'

    # Online all CPUs.
    vm-command 'for cpuX in /sys/devices/system/cpu/cpu[1-9]*; do
            echo onlining $cpuX
            ( echo 1 > $cpuX/online && echo Successful: write 1 to $cpuX/online ) || echo Failed: write 1 to $cpuX/online
        done'
}

vm-command 'grep . /sys/devices/system/cpu/cpu[1-9]*/online'

if ! vm-command "command -v mlc"; then
    echo "No mlc installed in the virtual machine. Get it."
    if [[ "$MLC_URL" != "http"* ]]; then
        echo "$MLC_URL"
        exit 1
    fi
    vm-command "curl -O $MLC_URL && tar xvf mlc_v3.12.tgz && cp Linux/mlc /usr/local/bin/"
fi

vm-command "mlc"
