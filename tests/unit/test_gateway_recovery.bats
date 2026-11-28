#!/usr/bin/env bats

load ../helpers

setup() {
    export PRIMARY_IFACE=eth0
    export BACKUP_IFACE=wlan0
    export PRIMARY_GATEWAY=""
    export BACKUP_GATEWAY=""
    export DSL_GATEWAY=""
    export LTE_GATEWAY=""
    export PRIMARY_METRIC_NORMAL=50
    export BACKUP_METRIC=200

    export MOCK_PRIMARY_GW="192.168.178.1"
    export MOCK_BACKUP_GW="172.20.10.1"
    export MOCK_PRIMARY_UP=1
    export MOCK_BACKUP_UP=1

    eval "$(sed -n \
        '/^emergency_restore_any_route() {/,/^}/p' \
        "$TEST_REPO_ROOT/src/lib/routing.sh")"
}

log() {
    :
}

send_notification() {
    :
}

_interface_link_up() {
    case "$1" in
        eth0) [[ "$MOCK_PRIMARY_UP" == 1 ]] ;;
        wlan0) [[ "$MOCK_BACKUP_UP" == 1 ]] ;;
        *) return 1 ;;
    esac
}

get_gateway_for_interface() {
    case "$1" in
        eth0)
            [[ -n "$MOCK_PRIMARY_GW" ]] || return 1
            printf '%s\n' "$MOCK_PRIMARY_GW"
            ;;
        wlan0)
            [[ -n "$MOCK_BACKUP_GW" ]] || return 1
            printf '%s\n' "$MOCK_BACKUP_GW"
            ;;
        *)
            return 1
            ;;
    esac
}

ip() {
    printf '%s\n' "$*"
    return 0
}

@test "recovery: discovers primary gateway dynamically" {
    run emergency_restore_any_route

    [ "$status" -eq 0 ]
    [[ "$output" == *"via 192.168.178.1 dev eth0 metric 50"* ]]
}

@test "recovery: discovers iPhone backup gateway" {
    MOCK_PRIMARY_UP=0

    run emergency_restore_any_route

    [ "$status" -eq 0 ]
    [[ "$output" == *"via 172.20.10.1 dev wlan0 metric 200"* ]]
}

@test "recovery: falls back when primary gateway is missing" {
    MOCK_PRIMARY_GW=""

    run emergency_restore_any_route

    [ "$status" -eq 0 ]
    [[ "$output" == *"via 172.20.10.1 dev wlan0"* ]]
}

@test "recovery: respects explicitly configured gateway" {
    PRIMARY_GATEWAY="10.0.0.1"

    run emergency_restore_any_route

    [ "$status" -eq 0 ]
    [[ "$output" == *"via 10.0.0.1 dev eth0"* ]]
}

@test "recovery: respects configured backup metric" {
    MOCK_PRIMARY_UP=0
    BACKUP_METRIC=350

    run emergency_restore_any_route

    [ "$status" -eq 0 ]
    [[ "$output" == *"dev wlan0 metric 350"* ]]
}

@test "recovery: does not add routes without a known gateway" {
    MOCK_PRIMARY_GW=""
    MOCK_BACKUP_GW=""

    run emergency_restore_any_route

    [ "$status" -ne 0 ]
    [ -z "$output" ]
}
