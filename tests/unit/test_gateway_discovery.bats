#!/usr/bin/env bats

load ../helpers

setup() {
    export MOCK_GATEWAY=""
    export MOCK_DHCP=""
    export MOCK_NM_FAILURE=0

    # Load only the function under test. No network mutations.
    eval "$(sed -n '/^get_gateway_from_nm() {/,/^}/p' \
        "$TEST_REPO_ROOT/src/lib/routing.sh")"
}

nmcli() {
    if [[ "$MOCK_NM_FAILURE" == "1" ]]; then
        return 1
    fi

    case "$2" in
        IP4.GATEWAY)
            printf '%s\n' "$MOCK_GATEWAY"
            ;;
        DHCP4.OPTION)
            printf '%s\n' "$MOCK_DHCP"
            ;;
        *)
            return 1
            ;;
    esac
}

@test "gateway: prefers NetworkManager IPv4 gateway" {
    MOCK_GATEWAY="192.168.178.1"
    MOCK_DHCP="routers = 172.20.10.1"

    run get_gateway_from_nm eth0

    [ "$status" -eq 0 ]
    [ "$output" = "192.168.178.1" ]
}

@test "gateway: detects iPhone router in pipe-separated DHCP options" {
    MOCK_DHCP="ip_address = 172.20.10.3 | requested_routers = 1 | routers = 172.20.10.1 | subnet_mask = 255.255.255.240"

    run get_gateway_from_nm wlan0

    [ "$status" -eq 0 ]
    [ "$output" = "172.20.10.1" ]
}

@test "gateway: supports multiline DHCP options" {
    MOCK_GATEWAY="--"
    MOCK_DHCP=$'ip_address = 172.20.10.3\nrouters = 172.20.10.1'

    run get_gateway_from_nm wlan0

    [ "$status" -eq 0 ]
    [ "$output" = "172.20.10.1" ]
}

@test "gateway: rejects missing router option" {
    MOCK_DHCP="requested_routers = 1"

    run get_gateway_from_nm wlan0

    [ "$status" -ne 0 ]
    [ -z "$output" ]
}

@test "gateway: rejects invalid IPv4 address" {
    MOCK_DHCP="routers = 999.20.10.1"

    run get_gateway_from_nm wlan0

    [ "$status" -ne 0 ]
}

@test "gateway: handles unavailable NetworkManager data" {
    MOCK_NM_FAILURE=1

    run get_gateway_from_nm wlan0

    [ "$status" -ne 0 ]
}
