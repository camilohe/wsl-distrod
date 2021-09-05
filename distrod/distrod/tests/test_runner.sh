#!/bin/sh

set -e

###
# Because Distrod doesn't implement nested distrod instance running, 
# this script runs the integration test in a new mount namespace to 
# avoid the problem caused by nesting
###

main () {
    if [ "$1" != run ] && [ "$1" != enter ]; then
        echo "Usage: $0 COMMAND" >&2
        echo "" >&2
        echo "COMMAND" >&2
        echo "  - run: run the integration test." >&2
        echo "  - enter: enter the namespace for testing." >&2
        exit 1
    fi
    COMMAND="$1"

    if [ "$2" != "--unshared" ]; then
        sudo unshare -mfp sudo -u "$(whoami)" "$0" "$COMMAND" --unshared "$(which cargo)"
        exit $?
    else
        sudo mount -t proc none /proc  # Make it see the new PIDs
    fi

    if [ -z "$3" ]; then
        echo "Error: Internal usage: $0 $COMMAND --unshared path_to_cargo" >&2
        exit 1
    fi
    CARGO="$3"

    prepare_for_nested_distrod
    set_pseudo_wsl_envs
    NS="itestns"
    remove_pseudo_wsl_netns "$NS"  # delete netns and interfaces if there is existing ones
    create_pseudo_wsl_netns "$NS"
    make_rootfs_dir
    DISTROD_INSTALL_DIR="$RET"

    # run the tests
    export DISTROD_INSTALL_DIR
    set +e
    case "$COMMAND" in
    run)
        sudo -E -- ip netns exec "$NS" sudo -E -u "$(whoami)" -- "$CARGO" test --verbose -p distrod
        EXIT_CODE=$?
        ;;
    enter)
        sudo -E -- ip netns exec "$NS" sudo -E -u "$(whoami)" -- bash
        EXIT_CODE=0
        ;;
    esac
    set -e

    kill_distrod || true
    remove_rootfs_dir "$DISTROD_INSTALL_DIR" || true
    remove_pseudo_wsl_netns "$NS" || true

    exit $EXIT_CODE
}

prepare_for_nested_distrod() {
    # Enter a new mount namespace for testing.
    # To make distrod think it's not inside another distrod,
    # 1. Delete /var/run/distrod.json without affecting the running distrod by 
    #    mounting overlay
    # 2. Unmount directories under /mnt/distrod_root, which is a condition 
    #    distrod checks
    sudo rm -rf /tmp/distrod_test
    mkdir -p /tmp/distrod_test/var/run/upper /tmp/distrod_test/var/run/work
    sudo mount --bind /var/run /var/run
    sudo mount -t overlay overlay -o lowerdir=/var/run,upperdir=/tmp/distrod_test/var/run/upper,workdir=/tmp/distrod_test/var/run/work /var/run
    sudo rm -f /var/run/distrod.json
    sudo umount /mnt/distrod_root/proc || true  # may not exist
}

set_pseudo_wsl_envs() {
    # Simulate WSL environment variables on non-WSL Linux such as on
    # the GitHub action runner.
    export WSL_DISTRO_NAME=DUMMY_DISTRO
    export WSL_INTEROP=/run/WSL/1_interop
}

create_pseudo_wsl_netns() {
    NS_NAME="$1"

    # set variables such as $INTERFACE_BRIDGE
    set_link_name_variables "$NS_NAME"

    # create a ns
    sudo ip netns del "$NS_NAME" > /dev/null 2>&1 || true
    sudo ip netns add "$NS_NAME"

    # create a veth for the guest as "eth0", which is the name of the inferface on WSL
    sudo ip link add name "$INTERFACE_GUEST" type veth peer name "$INTERFACE_GUEST_PEER"
    sudo ip link set "$INTERFACE_GUEST" netns "$NS_NAME"
    sudo ip netns exec "$NS_NAME" ip link set "$INTERFACE_GUEST" name eth0
    INTERFACE_GUEST="eth0"

    # create a bridge
    sudo ip link add name "$INTERFACE_BRIDGE" type bridge
    sudo ip link set dev "$INTERFACE_GUEST_PEER" master "$INTERFACE_BRIDGE"

    # Set IP addresses
    HOST_IP="${SUBNET}.1"
    sudo ip addr add "${HOST_IP}/24" dev "$INTERFACE_BRIDGE"
    sudo ip netns exec "$NS_NAME" ip addr add "${SUBNET}.2/24" dev "$INTERFACE_GUEST"

    # Link up the guest interfaces
    sudo ip netns exec "$NS_NAME" ip link set lo up
    sudo ip netns exec "$NS_NAME" ip link set "$INTERFACE_GUEST" up
    sudo ip link set "$INTERFACE_GUEST_PEER" up
    # Set the default gateway
    sudo ip netns exec "$NS_NAME" ip route add default via "$HOST_IP"

    # Link up the bridge
    sudo ip link set "$INTERFACE_BRIDGE" up

    # Enable IP forwarding
    echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null

    # Forward packets from/to the bridge
    sudo iptables -A FORWARD -i "${INTERFACE_BRIDGE}" -j ACCEPT
    sudo iptables -A FORWARD -o "${INTERFACE_BRIDGE}" -j ACCEPT

    # Set up a NAT
    sudo iptables -t nat -A POSTROUTING -s "${SUBNET}.0/24" -j MASQUERADE
}

remove_pseudo_wsl_netns() {
    NS_NAME="$1"

    # set variables such as $INTERFACE_BRIDGE
    set_link_name_variables "$NS_NAME"

    sudo ip netns delete "$NS_NAME" > /dev/null 2>&1 || true
    sudo ip link delete "$INTERFACE_BRIDGE" > /dev/null 2>&1 || true
    sudo ip link delete "$INTERFACE_GUEST" > /dev/null 2>&1 || true
    sudo ip link delete "$INTERFACE_GUEST_PEER" > /dev/null 2>&1 || true

    sudo iptables -D FORWARD -i "${INTERFACE_BRIDGE}" -j ACCEPT > /dev/null 2>&1 || true
    sudo iptables -D FORWARD -o "${INTERFACE_BRIDGE}" -j ACCEPT > /dev/null 2>&1 || true

    # Set up a NAT
    sudo iptables -t nat -D POSTROUTING -s "${SUBNET}.0/24" -j MASQUERADE > /dev/null 2>&1 || true
}

set_link_name_variables() {
    NS_NAME="$1"

    SUBNET="192.168.99"
    INTERFACE_GUEST="veth-${NS_NAME}"
    INTERFACE_GUEST_PEER="br-g${NS_NAME}"
    INTERFACE_BRIDGE="${NS_NAME}"

    if [ "${#INTERFACE_GUEST}" -ge 16 ]; then
        echo "NS_NAME must be shorter so that INTERFACE_GUEST becomes shorter than 16 characters." >&2
        return 1
    fi
}

is_inside_wsl() {
    uname -a | grep microsoft > /dev/null
    return $?
}

make_rootfs_dir() {
    RET="$(mktemp -d)"
    chmod 755 "$RET"
    sudo chown root:root "$RET"
}

kill_distrod() {
    sudo "$(dirname "$0")"/../../target/debug/distrod stop -9
}

remove_rootfs_dir() {
    sudo rm -rf "$1"
}

main "$@"