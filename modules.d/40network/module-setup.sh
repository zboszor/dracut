#!/bin/bash
# -*- mode: shell-script; indent-tabs-mode: nil; sh-basic-offset: 4; -*-
# ex: ts=8 sw=4 sts=4 et filetype=sh

check() {
    local _program

    require_binaries ip arping dhclient || return 1

    return 255
}

depends() {
    return 0
}

installkernel() {
    # Include wired net drivers, excluding wireless

    net_module_filter() {
        local _net_drivers='eth_type_trans|register_virtio_device|usbnet_open'
        local _unwanted_drivers='/(wireless|isdn|uwb|net/ethernet|net/phy|net/team)/'
        local _ret
        # subfunctions inherit following FDs
        local _merge=8 _side2=9
        function nmf1() {
            local _fname _fcont
            while read _fname; do
                [[ $_fname =~ $_unwanted_drivers ]] && continue
                case "$_fname" in
                    *.ko)    _fcont="$(<        $_fname)" ;;
                    *.ko.gz) _fcont="$(gzip -dc $_fname)" ;;
                    *.ko.xz) _fcont="$(xz -dc   $_fname)" ;;
                esac
                [[   $_fcont =~ $_net_drivers
                && ! $_fcont =~ iw_handler_get_spy ]] \
                && echo "$_fname"
            done
            return 0
        }
        function rotor() {
            local _f1 _f2
            while read _f1; do
                echo "$_f1"
                if read _f2; then
                    echo "$_f2" 1>&${_side2}
                fi
            done | nmf1 1>&${_merge}
            return 0
        }
        # Use two parallel streams to filter alternating modules.
        set +x
        eval "( ( rotor ) ${_side2}>&1 | nmf1 ) ${_merge}>&1"
        [[ $debug ]] && set -x
        return 0
    }

    { find_kernel_modules_by_path drivers/net; if [ "$_arch" = "s390" -o "$_arch" = "s390x" ]; then find_kernel_modules_by_path drivers/s390/net; fi; } \
        | net_module_filter | instmods

    #instmods() will take care of hostonly
    instmods \
        =drivers/net/phy \
        =drivers/net/team \
        =drivers/net/ethernet \
        ecb arc4 bridge stp llc ipv6 bonding 8021q af_packet virtio_net
    hostonly="" instmods iscsi_ibft crc32c iscsi_boot_sysfs
}

install() {
    local _arch _i _dir
    inst_multiple ip arping dhclient sed
    inst_multiple -o ping ping6
    inst_multiple -o brctl
    inst_multiple -o teamd teamdctl teamnl
    inst_simple /etc/libnl/classid
    inst_script "$moddir/ifup.sh" "/sbin/ifup"
    inst_script "$moddir/netroot.sh" "/sbin/netroot"
    inst_script "$moddir/dhclient-script.sh" "/sbin/dhclient-script"
    inst_simple "$moddir/net-lib.sh" "/lib/net-lib.sh"
    inst_simple "$moddir/dhclient.conf" "/etc/dhclient.conf"
    inst_hook pre-udev 50 "$moddir/ifname-genrules.sh"
    inst_hook pre-udev 60 "$moddir/net-genrules.sh"
    inst_hook cmdline 91 "$moddir/dhcp-root.sh"
    inst_hook cmdline 92 "$moddir/parse-ibft.sh"
    inst_hook cmdline 95 "$moddir/parse-vlan.sh"
    inst_hook cmdline 96 "$moddir/parse-bond.sh"
    inst_hook cmdline 96 "$moddir/parse-team.sh"
    inst_hook cmdline 97 "$moddir/parse-bridge.sh"
    inst_hook cmdline 98 "$moddir/parse-ip-opts.sh"
    inst_hook cmdline 99 "$moddir/parse-ifname.sh"
    inst_hook cleanup 10 "$moddir/kill-dhclient.sh"

    # install all config files for teaming
    unset TEAM_MASTER
    unset TEAM_CONFIG
    unset TEAM_PORT_CONFIG
    unset HWADDR
    unset SUBCHANNELS
    for i in /etc/sysconfig/network-scripts/ifcfg-*; do
        [ -e "$i" ] || continue
        case "$i" in
            *~ | *.bak | *.orig | *.rpmnew | *.rpmorig | *.rpmsave)
                continue
                ;;
        esac
        (
            . "$i"
            if ! [ "${ONBOOT}" = "no" -o "${ONBOOT}" = "NO" ] \
                    && [ -n "${TEAM_MASTER}${TEAM_CONFIG}${TEAM_PORT_CONFIG}" ]; then
                if [ -n "$TEAM_CONFIG" ] && [ -n "$DEVICE" ]; then
                    mkdir -p $initdir/etc/teamd
                    printf -- "%s" "$TEAM_CONFIG" > "$initdir/etc/teamd/${DEVICE}.conf"
                elif [ -n "$TEAM_PORT_CONFIG" ]; then
                    inst_simple "$i"

                    HWADDR="$(echo $HWADDR | sed 'y/ABCDEF/abcdef/')"
                    if [ -n "$HWADDR" ]; then
                        ln_r "$i" "/etc/sysconfig/network-scripts/mac-${HWADDR}.conf"
                    fi

                    SUBCHANNELS="$(echo $SUBCHANNELS | sed 'y/ABCDEF/abcdef/')"
                    if [ -n "$SUBCHANNELS" ]; then
                        ln_r "$i" "/etc/sysconfig/network-scripts/ccw-${SUBCHANNELS}.conf"
                    fi
                fi
            fi
        )
    done

    _arch=$(uname -m)

    inst_libdir_file {"tls/$_arch/",tls/,"$_arch/",}"libnss_dns.so.*" \
        {"tls/$_arch/",tls/,"$_arch/",}"libnss_mdns4_minimal.so.*"

    dracut_need_initqueue
}

