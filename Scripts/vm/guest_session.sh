test_vm_is_virtual_mac() {
    case "$(/usr/sbin/sysctl -n hw.model 2>/dev/null)" in
        VirtualMac*) return 0 ;;
        *) return 1 ;;
    esac
}

test_vm_require_guest_session() {
    if ! test_vm_is_virtual_mac ||
        [ ! -x /usr/local/libexec/big-wallet-vm/guest_runner ]; then
        echo 'error: native tests require the provisioned test VM' >&2
        return 1
    fi
    /usr/local/libexec/big-wallet-vm/guest_runner --verify-session
}
