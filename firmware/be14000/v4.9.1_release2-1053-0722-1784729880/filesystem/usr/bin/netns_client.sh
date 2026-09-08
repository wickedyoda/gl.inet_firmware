#!/bin/sh

# Function to display help
usage() {
    echo "Usage: $0 (-c|-d) <interface> <id> | $0 clean"
    echo "Options:"
    echo "  -c: Create or enter namespace"
    echo "  -d: Delete the namespace"
    echo "Arguments:"
    echo "  interface: Network interface (e.g., br-lan, eth0)"
    echo "  id: Numeric ID (1-99)"
    echo "Commands:"
    echo "  clean: Remove all client namespaces"
    echo "Example: $0 -c br-lan 1"
    echo "         $0 -d br-lan 1"
    echo "         $0 clean"
    exit 1
}

fix_guest_bridge_off(){
    ip link set br-guest promisc off
}

fix_iot_bridge_off(){
    ip link set br-iot promisc off
}

fix_guest_bridge_on(){
    [ "$INTERFACE" = br-guest ] && ip link set br-guest promisc on
}

fix_iot_bridge_on(){
    [ "$INTERFACE" = br-iot ] && ip link set br-iot promisc on
}

# Function to cleanup namespace
cleanup_namespace() {
    local ns_name=$1
    local id=$2
    # Kill dnsmasq and dhcp processes
    kill $(pgrep -f "dnsmasq.*${ns_name}") >/dev/null 2>&1
    local short_interface=$(echo $ns_name | cut -d'_' -f2 | sed 's/^br-//')
    kill $(pgrep -f "udhcpc.*veth1_${short_interface}_${id}") >/dev/null 2>&1
    # Unmount resolv.conf if it exists
    ip netns exec $ns_name umount /etc/resolv.conf 2>/dev/null
    # Delete namespace and interface
    ip netns delete $ns_name 2>/dev/null
    local short_interface=$(echo $ns_name | cut -d'_' -f2 | sed 's/^br-//')
    ip link delete veth0_${short_interface}_${id} 2>/dev/null
    # Clean up temporary files
    rm -rf /tmp/${ns_name}
    echo "Namespace $ns_name cleaned up"
}

# Default values
MODE=""

# Parse options
while getopts "cd" opt; do
    case $opt in
        c) MODE="create" ;;
        d) MODE="delete" ;;
        ?) usage ;;
    esac
done

# Shift to get the remaining arguments
shift $((OPTIND-1))

# Handle clean command
if [ "$1" = "clean" ]; then
    echo "Cleaning all client namespaces..."
    for ns in $(ip netns list | grep "^client_" | cut -d' ' -f1); do
        # Extract ID from namespace name
        id=$(echo $ns | grep -o '[0-9]\+$')
        echo "Cleaning namespace $ns"
        cleanup_namespace $ns $id
    done
    fix_guest_bridge_off
    fix_iot_bridge_off
    echo "All client namespaces cleaned"
    exit 0
fi

# Check arguments for normal operation
if [ $# -ne 2 ]; then
    usage
fi

# Check if veth module is loaded
if ! lsmod | grep -q "^veth "; then
    echo "Please install and load the veth module:"
    echo "  opkg update"
    echo "  opkg install kmod-veth"
    exit 1
fi

INTERFACE=$1
ID=$2

# Validate ID
if ! echo "$ID" | grep -q '^[1-9][0-9]\?$'; then
    echo "Error: ID must be a number between 1 and 99"
    exit 1
fi

NS_NAME="client_${INTERFACE}_${ID}"

# Handle different modes
case $MODE in
    "delete")
        if ! ip netns list | grep -q "^$NS_NAME"; then
            echo "Error: Namespace $NS_NAME does not exist"
            exit 1
        fi
        cleanup_namespace $NS_NAME $ID
        exit 0
        ;;
    "create")
        # Continue with creation/entry logic
        ;;
    "")
        echo "Error: Must specify either -c or -d option"
        usage
        ;;
esac

# Check if interface exists
if ! ip link show "$INTERFACE" >/dev/null 2>&1; then
    echo "Error: Interface $INTERFACE does not exist"
    exit 1
fi

# Function to enter namespace shell
enter_namespace_shell() {
    local ns_name=$1
    local ns_ps1="[ns:${ns_name}] # "
    echo "Entering namespace $ns_name shell. Type 'exit' to leave."
    # Mount a tmpfs on /etc and create a new resolv.conf file
    ip netns exec $ns_name /bin/ash -c "
        # Make all mounts private to prevent propagation
        # mount --make-rprivate /
        # Create a tmpfs for /etc
        mount -t tmpfs tmpfs /etc
        cp -a /rom/etc/* /etc/ 2>/dev/null
        rm -f /etc/resolv.conf
        cat /tmp/${ns_name}/resolv.conf > /etc/resolv.conf
        # Start shell
        PS1='$ns_ps1' exec /bin/ash
    "
}

# Check if namespace already exists
if ip netns list | grep -q "^$NS_NAME"; then
    echo "Entering existing namespace $NS_NAME"
    enter_namespace_shell $NS_NAME
    exit 0
fi

# Create new namespace
ip netns add $NS_NAME

# Get short interface name for veth naming
SHORT_INTERFACE=$(echo $INTERFACE | sed 's/^br-//')

# Create and configure veth pair
ip link add veth0_${SHORT_INTERFACE}_${ID} type veth peer name veth1_${SHORT_INTERFACE}_${ID}
ip link set veth1_${SHORT_INTERFACE}_${ID} netns $NS_NAME
ip link set veth0_${SHORT_INTERFACE}_${ID} master $INTERFACE
ip link set veth0_${SHORT_INTERFACE}_${ID} up

fix_guest_bridge_on
fix_iot_bridge_on

# Configure namespace
ip netns exec $NS_NAME ip link set veth1_${SHORT_INTERFACE}_${ID} up
ip netns exec $NS_NAME ip link set lo up
ip netns exec $NS_NAME udhcpc -x hostname:"${NS_NAME}" -i veth1_${SHORT_INTERFACE}_${ID} &
NAMESERVER_IP4=$(ip -4 addr show dev $INTERFACE | grep 'inet' | awk '{print $2}' | cut -d/ -f1 | head -n1)
NAMESERVER_IP6=$(uci -q get dhcp.lan.dns)
# Setup private DNS configuration
ipv6_enabled=$(uci -q get glipv6.globals.enabled)
mkdir -p /tmp/${NS_NAME}
{
    echo 'search lan'
    if [ -n "$NAMESERVER_IP6" -a "$ipv6_enabled" = '1' ]; then
        echo "nameserver $NAMESERVER_IP6"
    fi
    if [ -n "$NAMESERVER_IP4" ]; then
        echo "nameserver $NAMESERVER_IP4"
    fi
} > /tmp/${NS_NAME}/resolv.conf

# Start dnsmasq
# ip netns exec $NS_NAME dnsmasq --listen-address=127.0.0.1 --no-resolv --server=$INTERFACE_IP --pid-file=/tmp/dnsmasq_${NS_NAME}.pid --cache-size=0


# Show network status
echo "Network namespace $NS_NAME created and connected to $INTERFACE"
ip netns exec $NS_NAME ip addr show

# Enter namespace shell
enter_namespace_shell $NS_NAME
