#!/bin/bash

#
# Created by Liam Powell (gfelipe099)
# archlinux-aip.sh file
# For Arch Linux amd64
#

#
# text formatting codes
# source https://github.com/nbros652/LUKS-guided-manual-partitioning/blob/master/LGMP.sh
#
normalText='\e[0m'
boldText='\e[1m'
yellow='\e[93m'
green='\e[92m'
red='\e[91m'

#
# check if running as root
#
if [ "$(whoami)" != "root" ]; then
    echo -e "${boldText}${red}This script must be executed as root."${normalText}
    exit 0
fi

#
# install this package to check which OS is running
#
pacman -Sy &>/dev/null && pacman -S lsb-release --noconfirm --needed &>/dev/null

# Verify Arch Linux is running
if [ ! -f /usr/bin/pacman ]; then
    echo "Pacman Package Manager was not found in this system, execution aborted."
    exit
    else
	pacman -S lsb-release --noconfirm --needed &>/dev/null
        os=$(lsb_release -ds | sed 's/"//g')
fi

if [ "${os}" != "Arch Linux" ]; then
    echo "You must be using Arch Linux to execute this script."
    exit 1
fi

function welcome() {
    clear
    sudo pacman -S figlet --noconfirm --needed &>/dev/null
    figlet -c "Arch Linux"
    figlet -c "AIP"
    sudo pacman -Rncsd figlet --noconfirm &>/dev/null
    kernelVer="$(lsb_release -ds uname -r | sed -e 's/"/g')"
    echo -e "Welcome to Arch Linux AIP!\n\n\nYour Arch Linux kernel version is: ${kernelVer}"
}

function root {
    # based of
    # source: https://github.com/ChrisTitusTech/ArchMatic
    # author: ChrisTitusTech
    if ! source conf/main.conf &>/dev/null; then
        echo -e "${red}${boldText}:: ERROR. Configuration file 'archlinux-aip.conf' not found. Creating a new one...\n\n"
        echo -e "\n${yellow}${boldText}:: Pacman Mirrorlist Settings${normalText}\n"
        read -p "Where do you live? (First letter in uppercase): " country
        echo -e "\n\n\n${yellow}${boldText}:: System Settings${normalText}\n"
        read -p "Which is your region? (First letter in uppercase): " region
        read -p "Which is your city? (First letter in uppercase): " city
        read -p "Which language do you natively speak? (For example: en_US.UTF-8): " lang
        read -p "Which is your keyboard from? (For example: en): " keymap
        read -p "How shall your computer be known on the network and/or locally?: " hostname
        read -p "Now type in any username you like. Without spaces and lowercase: " username
        while true; do
        read -sp "Please, enter a password: " password
        read -sp "Please, repeat the password: " password2

        # Check if both passwords match
        if [ "$password" != "$password2" ]; then
            echo "\n\n\n${red}${boldText}:: ERROR: Passwords did not match. Try again.${normalText}\n"
        fi
        done
	    printf "[Pacman Mirrorlist Settings]
country="${country}"

[System Settings]
region="${region}"
city="${city}"
lang="${lang}"
keymap="${keymap}"
hostname="${hostname}"

[User Settings]
username="${username}"
password="${password}"" > archlinux-aip.conf
        else
            source archlinux-aip.conf
            echo -e "${green}${boldText}:: Your configuration file was found and loaded successfully!${normalText}\n"
    fi
}

function diskPartitioning() {
    echo -e "\n\n\n${yellow}${boldText}:: Disk Partitioning${normalText}\n"
    # determine which disk we're installing to
    disks=$(lsblk | grep -P "disk *$" | awk '{print "/dev/"$1}')
    while :
    do
        [ $(wc -l <<< "$disks") -eq 1 ] && opt=1 && break
        echo "The following disks have been detected. To which disk would you like to install?"
        i=1
        for opt in $disks
        do
            grep -q '/dev/[sh]da' <<< "$opt" && default=$i
            printf "   [%$((1+$(wc -l <<< "$disks")/10))d] %s\n" $[i++] $opt
        done
        default=${default:-1}
        read -p "Enter the number of your selection [$default]: " opt
        opt=${opt:-$default}
        clear
        [ $opt -gt 0 ] && [ $opt -lt $i ] && break
    done
    disk=$(sed -n "${opt}p" <<< "$disks")

    # warn user of the distructive nature of this script
    clear
    echo -e "WARNING: Continuing will destroy any data that may currently be on $disk.\nPlease ensure there are no other operating systems or files that you may want to keep on this disk!"
    read -p "To continue, type ERASE in all caps: " opt
    [ "$opt" != "ERASE" ] && echo -e "No changes made!" && read -p "Press [Enter] to exit." && exit
    clear

    # function to convert things like 2G or 1M into bytes
    bytes() {
        num=${1:-0}
        numfmt --from=iec $num 2> /dev/null || return 1
    }

    # get upper and lower bounds given the start and size
    bounds() {
        start=$(bytes $1)
        size=$2
        stop=$(($start + $(bytes $size) - 1))
        echo $start $stop
    }

    isEFI() {
        mount | grep -qi efi && return 0 || return 1
    }

    # wipe the disk partition info and create new gpt partition table
    dd if=/dev/zero of=$disk bs=1M count=10 2> /dev/null
    if isEFI; then
        tableType='gpt'
    else
        tableType='msdos'
    fi
    parted $disk mktable $tableType > /dev/null 2>&1

    # get information about desired sizes
    totalRAM=$(cat /proc/meminfo | head -n1 | grep -oP "\d+.*" | tr -d ' B' | tr 'a-z' 'A-Z' | numfmt --from iec --to iec --format "%.f")
    read -p "Size for /boot [500M]: " boot
    isEFI && read -p "Size for /boot/efi [100M]: " efi
    read -p "Size for / (root) [50G]: " root
    clear
    
    # fill in the blanks with default values
    parts="efi=100M boot=500M root=50G"
    for part in $parts
    do
        name=$(cut -f1 -d= <<< $part)
        [ "$name" == "efi" ] && ! isEFI && continue
        [ ${!name} ] || eval "${part}"
    done

    # create physical partitions
    clear
    offset="1M"	#offset for first partition
    physicalParts="boot:ext2 efi:fat16 root:ext4"
    index=$(bytes $offset)
    for part in ${physicalParts}
    do
        name=$(cut -f1 -d: <<< $part)
        type=$(awk -F ':' '{print $2}' <<< $part)
        [ "$name" == "efi" ] && ! isEFI && continue
        if [ "${!name}" == "-1MB" ]; then
            echo -n "Creating $name partition that uses remaining disk space... "
        else
            echo -n "Creating ${!name} $name partition ... "
        fi
        if [ "${!name:0:1}" == "-" ]; then
            parted $disk -- unit b mkpart primary $type $index ${!name} > /dev/null 2>&1 && echo -e "${green}done${normalText}" || echo -e "${red}failed${normalText}"
        else
            parted $disk unit b mkpart primary $type $(bounds $index ${!name}) > /dev/null 2>&1 && echo -e "${green}done${normalText}" || echo -e "${red}failed${normalText}"
            # move index one byte past newly created sector
            let $[index+=$(bytes ${!name})]
        fi
    done
}

function baseSetup() {
    # Base system installation
    pacstrap /mnt base base-devel linux linux-headers linux-firmware gdm
    genfstab -U /mnt > /mnt/etc/fstab

    arch-chroot /mnt

    pacman -Sy && pacman -S reflector && reflector --country ${country} --sort rate --save /etc/pacman.d/mirrorlist

    sed -i 's/#[multilib]/[multilib]/g' /etc/pacman.conf
    sed -i '#Include = /etc/pacman.d/mirrorlist/Include = /etc/pacman.d/mirrorlist/g' /etc/pacman.conf
    sed -i 's/#RemoteFileSigLevel = Required/RemoteFileSigLevel = Required/g' /etc/pacman.conf
    
    pacman -Syyy && pacman -Syu

    ln -sf /usr/share/zoneinfo/${region}/${city} /etc/localtime && hwclock --systohc && sed -i 's/#${lang}/${lang}/g' /etc/locale.gen && locale-gen

    printf "LANG="${lang}"" > /etc/locale.conf
    printf "KEYMAP="${keymap)"" > /etc/vconsole.conf
    printf "export EDITOR="${editor}"\nQT_QPA_PLATFORM="${qtplatform}"\nQT_QPA_PLATFORMTHEME="${qtplatformtheme}"" >> /etc/enviroment
    printf "alias ron='xhost si:localuser:root'\nalias roff='xhost -si:localuser:root'\nalias ll='ls -ali --color=auto'" > ~/.bash_aliases
    printf "# Load aliases and profile variables\nif [[ -f /etc/profile ]]; then\n    source /etc/profile\nfi\nif [[ -f ~/.bash_aliases ]]; then\n    source ~/.bash_aliases\nfi\n# PS1='[\u@\h \W] \$ '\nPS1='\u@\h \W \$ '" > ~/.bashrc

    cpuCores=$(grep -c ^processor /proc/cpuinfo)
    sed -i 's/#MAKEFLAGS="-j2"/MAKEFLAGS="-j${cpuCores}g' /etc/makepkg.conf
    sed -i 's/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -T ${cpuCores} -z -)/g' /etc/makepkg.conf
    
    printf "abi.vsyscall32 = 1
debug.exception-trace = 1
debug.kprobes-optimization = 1
dev.hpet.max-user-freq = 64
dev.i915.oa_max_sample_rate = 100000
dev.i915.perf_stream_paranoid = 1
dev.mac_hid.mouse_button2_keycode = 97
dev.mac_hid.mouse_button3_keycode = 100
dev.mac_hid.mouse_button_emulation = 0
dev.scsi.logging_level = 0
dev.tty.ldisc_autoload = 1
fs.aio-max-nr = 1048576
fs.aio-nr = 0
fs.binfmt_misc.DOSWin = enabled
fs.binfmt_misc.DOSWin = interpreter /usr/bin/wine
fs.binfmt_misc.DOSWin = flags: 
fs.binfmt_misc.DOSWin = offset 0
fs.binfmt_misc.DOSWin = magic 4d5a
fs.binfmt_misc.status = enabled
fs.dentry-state = 28960	7115	45	0	1463	0
fs.dir-notify-enable = 1
fs.epoll.max_user_watches = 6703759
fs.file-max = 9223372036854775807
fs.file-nr = 12096	0	9223372036854775807
fs.inode-nr = 29501	2666
fs.inode-state = 29501	2666	0	0	0	0	0
fs.inotify.max_queued_events = 16384
fs.inotify.max_user_instances = 1024
fs.inotify.max_user_watches = 524288
fs.lease-break-time = 45
fs.leases-enable = 1
fs.mount-max = 100000
fs.mqueue.msg_default = 10
fs.mqueue.msg_max = 10
fs.mqueue.msgsize_default = 8192
fs.mqueue.msgsize_max = 8192
fs.mqueue.queues_max = 256
fs.nr_open = 1073741816
fs.overflowgid = 65534
fs.overflowuid = 65534
fs.pipe-max-size = 1048576
fs.pipe-user-pages-hard = 0
fs.pipe-user-pages-soft = 16384
fs.protected_fifos = 1
fs.protected_hardlinks = 1
fs.protected_regular = 1
fs.protected_symlinks = 1
fs.quota.allocated_dquots = 0
fs.quota.cache_hits = 0
fs.quota.drops = 0
fs.quota.free_dquots = 0
fs.quota.lookups = 0
fs.quota.reads = 0
fs.quota.syncs = 8
fs.quota.writes = 0
fs.suid_dumpable = 2
fs.verity.require_signatures = 0
kernel.acct = 4	2	30
kernel.acpi_video_flags = 0
kernel.auto_msgmni = 0
kernel.bootloader_type = 114
kernel.bootloader_version = 2
kernel.bpf_stats_enabled = 0
kernel.cad_pid = 1
kernel.cap_last_cap = 39
kernel.core_pattern = |/usr/lib/systemd/systemd-coredump %P %u %g %s %t %c %h
kernel.core_pipe_limit = 0
kernel.core_uses_pid = 1
kernel.ctrl-alt-del = 0
kernel.dmesg_restrict = 1
kernel.domainname = (none)
kernel.ftrace_dump_on_oops = 0
kernel.ftrace_enabled = 1
kernel.hardlockup_all_cpu_backtrace = 0
kernel.hardlockup_panic = 0
kernel.hostname = archlinux
kernel.hung_task_all_cpu_backtrace = 0
kernel.hung_task_check_count = 4194304
kernel.hung_task_check_interval_secs = 0
kernel.hung_task_panic = 0
kernel.hung_task_timeout_secs = 120
kernel.hung_task_warnings = 10
kernel.io_delay_type = 0
kernel.kexec_load_disabled = 0
kernel.keys.gc_delay = 300
kernel.keys.maxbytes = 20000
kernel.keys.maxkeys = 200
kernel.keys.persistent_keyring_expiry = 259200
kernel.keys.root_maxbytes = 25000000
kernel.keys.root_maxkeys = 1000000
kernel.kptr_restrict = 1
kernel.latencytop = 0
kernel.max_lock_depth = 1024
kernel.modprobe = /sbin/modprobe
kernel.modules_disabled = 1
kernel.msg_next_id = -1
kernel.msgmax = 8192
kernel.msgmnb = 16384
kernel.msgmni = 32000
kernel.ngroups_max = 65536
kernel.nmi_watchdog = 1
kernel.ns_last_pid = 24508
kernel.numa_balancing = 0
kernel.numa_balancing_scan_delay_ms = 1000
kernel.numa_balancing_scan_period_max_ms = 60000
kernel.numa_balancing_scan_period_min_ms = 1000
kernel.numa_balancing_scan_size_mb = 256
kernel.oops_all_cpu_backtrace = 0
kernel.osrelease = 5.8.5-arch1-1
kernel.ostype = Linux
kernel.overflowgid = 65534
kernel.overflowuid = 65534
kernel.panic = 0
kernel.panic_on_io_nmi = 0
kernel.panic_on_oops = 0
kernel.panic_on_rcu_stall = 0
kernel.panic_on_unrecovered_nmi = 0
kernel.panic_on_warn = 0
kernel.panic_print = 0
kernel.perf_cpu_time_max_percent = 25
kernel.perf_event_max_contexts_per_stack = 8
kernel.perf_event_max_sample_rate = 50400
kernel.perf_event_max_stack = 127
kernel.perf_event_mlock_kb = 516
kernel.perf_event_paranoid = 2
kernel.pid_max = 4194304
kernel.poweroff_cmd = /sbin/poweroff
kernel.print-fatal-signals = 0
kernel.printk = 1	4	1	4
kernel.printk_delay = 0
kernel.printk_devkmsg = on
kernel.printk_ratelimit = 5
kernel.printk_ratelimit_burst = 10
kernel.pty.max = 4096
kernel.pty.nr = 1
kernel.pty.reserve = 1024
kernel.random.boot_id = 959852f5-da08-4c06-aa5b-cdb3131579e5
kernel.random.entropy_avail = 3939
kernel.random.poolsize = 4096
kernel.random.urandom_min_reseed_secs = 60
kernel.random.uuid = 5bbf2d5b-c42c-483a-866a-4e7b83af3b97
kernel.random.write_wakeup_threshold = 896
kernel.randomize_va_space = 2
kernel.real-root-dev = 0
kernel.sched_autogroup_enabled = 1
kernel.sched_cfs_bandwidth_slice_us = 5000
kernel.sched_child_runs_first = 0
kernel.sched_domain.cpu0.domain0.busy_factor = 32
kernel.sched_domain.cpu0.domain0.cache_nice_tries = 1
kernel.sched_domain.cpu0.domain0.flags = 2327
kernel.sched_domain.cpu0.domain0.imbalance_pct = 117
kernel.sched_domain.cpu0.domain0.max_interval = 12
kernel.sched_domain.cpu0.domain0.max_newidle_lb_cost = 21487
kernel.sched_domain.cpu0.domain0.min_interval = 6
kernel.sched_domain.cpu0.domain0.name = MC
kernel.sched_domain.cpu1.domain0.busy_factor = 32
kernel.sched_domain.cpu1.domain0.cache_nice_tries = 1
kernel.sched_domain.cpu1.domain0.flags = 2327
kernel.sched_domain.cpu1.domain0.imbalance_pct = 117
kernel.sched_domain.cpu1.domain0.max_interval = 12
kernel.sched_domain.cpu1.domain0.max_newidle_lb_cost = 22973
kernel.sched_domain.cpu1.domain0.min_interval = 6
kernel.sched_domain.cpu1.domain0.name = MC
kernel.sched_energy_aware = 1
kernel.sched_latency_ns = 18000000
kernel.sched_migration_cost_ns = 500000
kernel.sched_min_granularity_ns = 2250000
kernel.sched_nr_migrate = 32
kernel.sched_rr_timeslice_ms = 90
kernel.sched_rt_period_us = 1000000
kernel.sched_rt_runtime_us = 950000
kernel.sched_schedstats = 0
kernel.sched_tunable_scaling = 1
kernel.sched_util_clamp_max = 1024
kernel.sched_util_clamp_min = 1024
kernel.sched_wakeup_granularity_ns = 3000000
kernel.seccomp.actions_avail = kill_process kill_thread trap errno user_notif trace log allow
kernel.seccomp.actions_logged = kill_process kill_thread trap errno user_notif trace log
kernel.sem = 32000	1024000000	500	32000
kernel.sem_next_id = -1
kernel.shm_next_id = -1
kernel.shm_rmid_forced = 0
kernel.shmall = 18446744073692774399
kernel.shmmax = 18446744073692774399
kernel.shmmni = 4096
kernel.soft_watchdog = 1
kernel.softlockup_all_cpu_backtrace = 0
kernel.softlockup_panic = 0
kernel.stack_tracer_enabled = 0
kernel.sysctl_writes_strict = 1
kernel.sysrq = 16
kernel.tainted = 0
kernel.threads-max = 124656
kernel.timer_migration = 1
kernel.traceoff_on_warning = 0
kernel.tracepoint_printk = 0
kernel.unknown_nmi_panic = 0
kernel.unprivileged_bpf_disabled = 0
kernel.unprivileged_userns_clone = 1
kernel.usermodehelper.bset = 4294967295	255
kernel.usermodehelper.inheritable = 4294967295	255
kernel.version = #1 SMP PREEMPT Thu, 27 Aug 2020 18:53:02 +0000
kernel.watchdog = 1
kernel.watchdog_cpumask = 0-5
kernel.watchdog_thresh = 10
kernel.yama.ptrace_scope = 1
net.core.bpf_jit_enable = 1
net.core.bpf_jit_harden = 1
net.core.bpf_jit_kallsyms = 1
net.core.bpf_jit_limit = 264241152
net.core.busy_poll = 0
net.core.busy_read = 0
net.core.default_qdisc = fq_codel
net.core.dev_weight = 64
net.core.dev_weight_rx_bias = 1
net.core.dev_weight_tx_bias = 1
net.core.devconf_inherit_init_net = 0
net.core.fb_tunnels_only_for_init_net = 0
net.core.flow_limit_cpu_bitmap = 00
net.core.flow_limit_table_len = 4096
net.core.gro_normal_batch = 8
net.core.high_order_alloc_disable = 0
net.core.max_skb_frags = 17
net.core.message_burst = 10
net.core.message_cost = 5
net.core.netdev_budget = 300
net.core.netdev_budget_usecs = 6666
net.core.netdev_max_backlog = 1000
net.core.netdev_rss_key = 00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00:00
net.core.netdev_tstamp_prequeue = 1
net.core.optmem_max = 20480
net.core.rmem_default = 212992
net.core.rmem_max = 212992
net.core.rps_sock_flow_entries = 0
net.core.somaxconn = 4096
net.core.tstamp_allow_data = 1
net.core.warnings = 0
net.core.wmem_default = 212992
net.core.wmem_max = 212992
net.core.xfrm_acq_expires = 30
net.core.xfrm_aevent_etime = 10
net.core.xfrm_aevent_rseqth = 2
net.core.xfrm_larval_drop = 1
net.ipv4.cipso_cache_bucket_size = 10
net.ipv4.cipso_cache_enable = 1
net.ipv4.cipso_rbm_optfmt = 0
net.ipv4.cipso_rbm_strictvalid = 1
net.ipv4.conf.all.accept_local = 0
net.ipv4.conf.all.accept_redirects = 1
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.arp_accept = 0
net.ipv4.conf.all.arp_announce = 0
net.ipv4.conf.all.arp_filter = 0
net.ipv4.conf.all.arp_ignore = 0
net.ipv4.conf.all.arp_notify = 0
net.ipv4.conf.all.bc_forwarding = 0
net.ipv4.conf.all.bootp_relay = 0
net.ipv4.conf.all.disable_policy = 0
net.ipv4.conf.all.disable_xfrm = 0
net.ipv4.conf.all.drop_gratuitous_arp = 0
net.ipv4.conf.all.drop_unicast_in_l2_multicast = 0
net.ipv4.conf.all.force_igmp_version = 0
net.ipv4.conf.all.forwarding = 0
net.ipv4.conf.all.igmpv2_unsolicited_report_interval = 10000
net.ipv4.conf.all.igmpv3_unsolicited_report_interval = 1000
net.ipv4.conf.all.ignore_routes_with_linkdown = 0
net.ipv4.conf.all.log_martians = 0
net.ipv4.conf.all.mc_forwarding = 0
net.ipv4.conf.all.medium_id = 0
net.ipv4.conf.all.promote_secondaries = 0
net.ipv4.conf.all.proxy_arp = 0
net.ipv4.conf.all.proxy_arp_pvlan = 0
net.ipv4.conf.all.route_localnet = 0
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.all.secure_redirects = 1
net.ipv4.conf.all.send_redirects = 1
net.ipv4.conf.all.shared_media = 1
net.ipv4.conf.all.src_valid_mark = 0
net.ipv4.conf.all.tag = 0
net.ipv4.conf.default.accept_local = 0
net.ipv4.conf.default.accept_redirects = 1
net.ipv4.conf.default.accept_source_route = 0
net.ipv4.conf.default.arp_accept = 0
net.ipv4.conf.default.arp_announce = 0
net.ipv4.conf.default.arp_filter = 0
net.ipv4.conf.default.arp_ignore = 0
net.ipv4.conf.default.arp_notify = 0
net.ipv4.conf.default.bc_forwarding = 0
net.ipv4.conf.default.bootp_relay = 0
net.ipv4.conf.default.disable_policy = 0
net.ipv4.conf.default.disable_xfrm = 0
net.ipv4.conf.default.drop_gratuitous_arp = 0
net.ipv4.conf.default.drop_unicast_in_l2_multicast = 0
net.ipv4.conf.default.force_igmp_version = 0
net.ipv4.conf.default.forwarding = 0
net.ipv4.conf.default.igmpv2_unsolicited_report_interval = 10000
net.ipv4.conf.default.igmpv3_unsolicited_report_interval = 1000
net.ipv4.conf.default.ignore_routes_with_linkdown = 0
net.ipv4.conf.default.log_martians = 0
net.ipv4.conf.default.mc_forwarding = 0
net.ipv4.conf.default.medium_id = 0
net.ipv4.conf.default.promote_secondaries = 1
net.ipv4.conf.default.proxy_arp = 0
net.ipv4.conf.default.proxy_arp_pvlan = 0
net.ipv4.conf.default.route_localnet = 0
net.ipv4.conf.default.rp_filter = 2
net.ipv4.conf.default.secure_redirects = 1
net.ipv4.conf.default.send_redirects = 1
net.ipv4.conf.default.shared_media = 1
net.ipv4.conf.default.src_valid_mark = 0
net.ipv4.conf.default.tag = 0
net.ipv4.conf.enp3s0.accept_local = 0
net.ipv4.conf.enp3s0.accept_redirects = 1
net.ipv4.conf.enp3s0.accept_source_route = 0
net.ipv4.conf.enp3s0.arp_accept = 0
net.ipv4.conf.enp3s0.arp_announce = 0
net.ipv4.conf.enp3s0.arp_filter = 0
net.ipv4.conf.enp3s0.arp_ignore = 0
net.ipv4.conf.enp3s0.arp_notify = 0
net.ipv4.conf.enp3s0.bc_forwarding = 0
net.ipv4.conf.enp3s0.bootp_relay = 0
net.ipv4.conf.enp3s0.disable_policy = 0
net.ipv4.conf.enp3s0.disable_xfrm = 0
net.ipv4.conf.enp3s0.drop_gratuitous_arp = 0
net.ipv4.conf.enp3s0.drop_unicast_in_l2_multicast = 0
net.ipv4.conf.enp3s0.force_igmp_version = 0
net.ipv4.conf.enp3s0.forwarding = 0
net.ipv4.conf.enp3s0.igmpv2_unsolicited_report_interval = 10000
net.ipv4.conf.enp3s0.igmpv3_unsolicited_report_interval = 1000
net.ipv4.conf.enp3s0.ignore_routes_with_linkdown = 0
net.ipv4.conf.enp3s0.log_martians = 0
net.ipv4.conf.enp3s0.mc_forwarding = 0
net.ipv4.conf.enp3s0.medium_id = 0
net.ipv4.conf.enp3s0.promote_secondaries = 1
net.ipv4.conf.enp3s0.proxy_arp = 0
net.ipv4.conf.enp3s0.proxy_arp_pvlan = 0
net.ipv4.conf.enp3s0.route_localnet = 0
net.ipv4.conf.enp3s0.rp_filter = 2
net.ipv4.conf.enp3s0.secure_redirects = 1
net.ipv4.conf.enp3s0.send_redirects = 1
net.ipv4.conf.enp3s0.shared_media = 1
net.ipv4.conf.enp3s0.src_valid_mark = 0
net.ipv4.conf.enp3s0.tag = 0
net.ipv4.conf.lo.accept_local = 0
net.ipv4.conf.lo.accept_redirects = 1
net.ipv4.conf.lo.accept_source_route = 0
net.ipv4.conf.lo.arp_accept = 0
net.ipv4.conf.lo.arp_announce = 0
net.ipv4.conf.lo.arp_filter = 0
net.ipv4.conf.lo.arp_ignore = 0
net.ipv4.conf.lo.arp_notify = 0
net.ipv4.conf.lo.bc_forwarding = 0
net.ipv4.conf.lo.bootp_relay = 0
net.ipv4.conf.lo.disable_policy = 1
net.ipv4.conf.lo.disable_xfrm = 1
net.ipv4.conf.lo.drop_gratuitous_arp = 0
net.ipv4.conf.lo.drop_unicast_in_l2_multicast = 0
net.ipv4.conf.lo.force_igmp_version = 0
net.ipv4.conf.lo.forwarding = 0
net.ipv4.conf.lo.igmpv2_unsolicited_report_interval = 10000
net.ipv4.conf.lo.igmpv3_unsolicited_report_interval = 1000
net.ipv4.conf.lo.ignore_routes_with_linkdown = 0
net.ipv4.conf.lo.log_martians = 0
net.ipv4.conf.lo.mc_forwarding = 0
net.ipv4.conf.lo.medium_id = 0
net.ipv4.conf.lo.promote_secondaries = 1
net.ipv4.conf.lo.proxy_arp = 0
net.ipv4.conf.lo.proxy_arp_pvlan = 0
net.ipv4.conf.lo.route_localnet = 0
net.ipv4.conf.lo.rp_filter = 2
net.ipv4.conf.lo.secure_redirects = 1
net.ipv4.conf.lo.send_redirects = 1
net.ipv4.conf.lo.shared_media = 1
net.ipv4.conf.lo.src_valid_mark = 0
net.ipv4.conf.lo.tag = 0
net.ipv4.conf.virbr0.accept_local = 0
net.ipv4.conf.virbr0.accept_redirects = 1
net.ipv4.conf.virbr0.accept_source_route = 0
net.ipv4.conf.virbr0.arp_accept = 0
net.ipv4.conf.virbr0.arp_announce = 0
net.ipv4.conf.virbr0.arp_filter = 0
net.ipv4.conf.virbr0.arp_ignore = 0
net.ipv4.conf.virbr0.arp_notify = 0
net.ipv4.conf.virbr0.bc_forwarding = 0
net.ipv4.conf.virbr0.bootp_relay = 0
net.ipv4.conf.virbr0.disable_policy = 0
net.ipv4.conf.virbr0.disable_xfrm = 0
net.ipv4.conf.virbr0.drop_gratuitous_arp = 0
net.ipv4.conf.virbr0.drop_unicast_in_l2_multicast = 0
net.ipv4.conf.virbr0.force_igmp_version = 0
net.ipv4.conf.virbr0.forwarding = 0
net.ipv4.conf.virbr0.igmpv2_unsolicited_report_interval = 10000
net.ipv4.conf.virbr0.igmpv3_unsolicited_report_interval = 1000
net.ipv4.conf.virbr0.ignore_routes_with_linkdown = 0
net.ipv4.conf.virbr0.log_martians = 0
net.ipv4.conf.virbr0.mc_forwarding = 0
net.ipv4.conf.virbr0.medium_id = 0
net.ipv4.conf.virbr0.promote_secondaries = 1
net.ipv4.conf.virbr0.proxy_arp = 0
net.ipv4.conf.virbr0.proxy_arp_pvlan = 0
net.ipv4.conf.virbr0.route_localnet = 0
net.ipv4.conf.virbr0.rp_filter = 2
net.ipv4.conf.virbr0.secure_redirects = 1
net.ipv4.conf.virbr0.send_redirects = 1
net.ipv4.conf.virbr0.shared_media = 1
net.ipv4.conf.virbr0.src_valid_mark = 0
net.ipv4.conf.virbr0.tag = 0
net.ipv4.conf.virbr0-nic.accept_local = 0
net.ipv4.conf.virbr0-nic.accept_redirects = 1
net.ipv4.conf.virbr0-nic.accept_source_route = 0
net.ipv4.conf.virbr0-nic.arp_accept = 0
net.ipv4.conf.virbr0-nic.arp_announce = 0
net.ipv4.conf.virbr0-nic.arp_filter = 0
net.ipv4.conf.virbr0-nic.arp_ignore = 0
net.ipv4.conf.virbr0-nic.arp_notify = 0
net.ipv4.conf.virbr0-nic.bc_forwarding = 0
net.ipv4.conf.virbr0-nic.bootp_relay = 0
net.ipv4.conf.virbr0-nic.disable_policy = 0
net.ipv4.conf.virbr0-nic.disable_xfrm = 0
net.ipv4.conf.virbr0-nic.drop_gratuitous_arp = 0
net.ipv4.conf.virbr0-nic.drop_unicast_in_l2_multicast = 0
net.ipv4.conf.virbr0-nic.force_igmp_version = 0
net.ipv4.conf.virbr0-nic.forwarding = 0
net.ipv4.conf.virbr0-nic.igmpv2_unsolicited_report_interval = 10000
net.ipv4.conf.virbr0-nic.igmpv3_unsolicited_report_interval = 1000
net.ipv4.conf.virbr0-nic.ignore_routes_with_linkdown = 0
net.ipv4.conf.virbr0-nic.log_martians = 0
net.ipv4.conf.virbr0-nic.mc_forwarding = 0
net.ipv4.conf.virbr0-nic.medium_id = 0
net.ipv4.conf.virbr0-nic.promote_secondaries = 1
net.ipv4.conf.virbr0-nic.proxy_arp = 0
net.ipv4.conf.virbr0-nic.proxy_arp_pvlan = 0
net.ipv4.conf.virbr0-nic.route_localnet = 0
net.ipv4.conf.virbr0-nic.rp_filter = 2
net.ipv4.conf.virbr0-nic.secure_redirects = 1
net.ipv4.conf.virbr0-nic.send_redirects = 1
net.ipv4.conf.virbr0-nic.shared_media = 1
net.ipv4.conf.virbr0-nic.src_valid_mark = 0
net.ipv4.conf.virbr0-nic.tag = 0
net.ipv4.fib_multipath_hash_policy = 0
net.ipv4.fib_multipath_use_neigh = 0
net.ipv4.fib_sync_mem = 524288
net.ipv4.fwmark_reflect = 0
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.icmp_echo_ignore_broadcasts = 1
net.ipv4.icmp_errors_use_inbound_ifaddr = 0
net.ipv4.icmp_ignore_bogus_error_responses = 1
net.ipv4.icmp_msgs_burst = 50
net.ipv4.icmp_msgs_per_sec = 1000
net.ipv4.icmp_ratelimit = 1000
net.ipv4.icmp_ratemask = 6168
net.ipv4.igmp_link_local_mcast_reports = 1
net.ipv4.igmp_max_memberships = 20
net.ipv4.igmp_max_msf = 10
net.ipv4.igmp_qrv = 2
net.ipv4.inet_peer_maxttl = 600
net.ipv4.inet_peer_minttl = 120
net.ipv4.inet_peer_threshold = 65664
net.ipv4.ip_autobind_reuse = 0
net.ipv4.ip_default_ttl = 64
net.ipv4.ip_dynaddr = 0
net.ipv4.ip_early_demux = 1
net.ipv4.ip_forward = 0
net.ipv4.ip_forward_update_priority = 1
net.ipv4.ip_forward_use_pmtu = 0
net.ipv4.ip_local_port_range = 32768	60999
net.ipv4.ip_local_reserved_ports = 
net.ipv4.ip_no_pmtu_disc = 0
net.ipv4.ip_nonlocal_bind = 0
net.ipv4.ip_unprivileged_port_start = 1024
net.ipv4.ipfrag_high_thresh = 4194304
net.ipv4.ipfrag_low_thresh = 3145728
net.ipv4.ipfrag_max_dist = 64
net.ipv4.ipfrag_secret_interval = 0
net.ipv4.ipfrag_time = 30
net.ipv4.neigh.default.anycast_delay = 99
net.ipv4.neigh.default.app_solicit = 0
net.ipv4.neigh.default.base_reachable_time_ms = 30000
net.ipv4.neigh.default.delay_first_probe_time = 5
net.ipv4.neigh.default.gc_interval = 30
net.ipv4.neigh.default.gc_stale_time = 60
net.ipv4.neigh.default.gc_thresh1 = 128
net.ipv4.neigh.default.gc_thresh2 = 512
net.ipv4.neigh.default.gc_thresh3 = 1024
net.ipv4.neigh.default.locktime = 99
net.ipv4.neigh.default.mcast_resolicit = 0
net.ipv4.neigh.default.mcast_solicit = 3
net.ipv4.neigh.default.proxy_delay = 79
net.ipv4.neigh.default.proxy_qlen = 64
net.ipv4.neigh.default.retrans_time_ms = 1000
net.ipv4.neigh.default.ucast_solicit = 3
net.ipv4.neigh.default.unres_qlen = 101
net.ipv4.neigh.default.unres_qlen_bytes = 212992
net.ipv4.neigh.enp3s0.anycast_delay = 99
net.ipv4.neigh.enp3s0.app_solicit = 0
net.ipv4.neigh.enp3s0.base_reachable_time_ms = 30000
net.ipv4.neigh.enp3s0.delay_first_probe_time = 5
net.ipv4.neigh.enp3s0.gc_stale_time = 60
net.ipv4.neigh.enp3s0.locktime = 99
net.ipv4.neigh.enp3s0.mcast_resolicit = 0
net.ipv4.neigh.enp3s0.mcast_solicit = 3
net.ipv4.neigh.enp3s0.proxy_delay = 79
net.ipv4.neigh.enp3s0.proxy_qlen = 64
net.ipv4.neigh.enp3s0.retrans_time_ms = 1000
net.ipv4.neigh.enp3s0.ucast_solicit = 3
net.ipv4.neigh.enp3s0.unres_qlen = 101
net.ipv4.neigh.enp3s0.unres_qlen_bytes = 212992
net.ipv4.neigh.lo.anycast_delay = 99
net.ipv4.neigh.lo.app_solicit = 0
net.ipv4.neigh.lo.base_reachable_time_ms = 30000
net.ipv4.neigh.lo.delay_first_probe_time = 5
net.ipv4.neigh.lo.gc_stale_time = 60
net.ipv4.neigh.lo.locktime = 99
net.ipv4.neigh.lo.mcast_resolicit = 0
net.ipv4.neigh.lo.mcast_solicit = 3
net.ipv4.neigh.lo.proxy_delay = 79
net.ipv4.neigh.lo.proxy_qlen = 64
net.ipv4.neigh.lo.retrans_time_ms = 1000
net.ipv4.neigh.lo.ucast_solicit = 3
net.ipv4.neigh.lo.unres_qlen = 101
net.ipv4.neigh.lo.unres_qlen_bytes = 212992
net.ipv4.neigh.virbr0.anycast_delay = 99
net.ipv4.neigh.virbr0.app_solicit = 0
net.ipv4.neigh.virbr0.base_reachable_time_ms = 30000
net.ipv4.neigh.virbr0.delay_first_probe_time = 5
net.ipv4.neigh.virbr0.gc_stale_time = 60
net.ipv4.neigh.virbr0.locktime = 99
net.ipv4.neigh.virbr0.mcast_resolicit = 0
net.ipv4.neigh.virbr0.mcast_solicit = 3
net.ipv4.neigh.virbr0.proxy_delay = 79
net.ipv4.neigh.virbr0.proxy_qlen = 64
net.ipv4.neigh.virbr0.retrans_time_ms = 1000
net.ipv4.neigh.virbr0.ucast_solicit = 3
net.ipv4.neigh.virbr0.unres_qlen = 101
net.ipv4.neigh.virbr0.unres_qlen_bytes = 212992
net.ipv4.neigh.virbr0-nic.anycast_delay = 99
net.ipv4.neigh.virbr0-nic.app_solicit = 0
net.ipv4.neigh.virbr0-nic.base_reachable_time_ms = 30000
net.ipv4.neigh.virbr0-nic.delay_first_probe_time = 5
net.ipv4.neigh.virbr0-nic.gc_stale_time = 60
net.ipv4.neigh.virbr0-nic.locktime = 99
net.ipv4.neigh.virbr0-nic.mcast_resolicit = 0
net.ipv4.neigh.virbr0-nic.mcast_solicit = 3
net.ipv4.neigh.virbr0-nic.proxy_delay = 79
net.ipv4.neigh.virbr0-nic.proxy_qlen = 64
net.ipv4.neigh.virbr0-nic.retrans_time_ms = 1000
net.ipv4.neigh.virbr0-nic.ucast_solicit = 3
net.ipv4.neigh.virbr0-nic.unres_qlen = 101
net.ipv4.neigh.virbr0-nic.unres_qlen_bytes = 212992
net.ipv4.nexthop_compat_mode = 1
net.ipv4.ping_group_range = 0	2147483647
net.ipv4.raw_l3mdev_accept = 1
net.ipv4.route.error_burst = 1500
net.ipv4.route.error_cost = 300
net.ipv4.route.gc_elasticity = 8
net.ipv4.route.gc_interval = 60
net.ipv4.route.gc_min_interval = 0
net.ipv4.route.gc_min_interval_ms = 500
net.ipv4.route.gc_thresh = -1
net.ipv4.route.gc_timeout = 300
net.ipv4.route.max_size = 2147483647
net.ipv4.route.min_adv_mss = 256
net.ipv4.route.min_pmtu = 552
net.ipv4.route.mtu_expires = 600
net.ipv4.route.redirect_load = 6
net.ipv4.route.redirect_number = 9
net.ipv4.route.redirect_silence = 6144
net.ipv4.tcp_abort_on_overflow = 0
net.ipv4.tcp_adv_win_scale = 1
net.ipv4.tcp_allowed_congestion_control = reno cubic
net.ipv4.tcp_app_win = 31
net.ipv4.tcp_autocorking = 1
net.ipv4.tcp_available_congestion_control = reno cubic
net.ipv4.tcp_available_ulp = espintcp mptcp
net.ipv4.tcp_base_mss = 1024
net.ipv4.tcp_challenge_ack_limit = 1000
net.ipv4.tcp_comp_sack_delay_ns = 1000000
net.ipv4.tcp_comp_sack_nr = 44
net.ipv4.tcp_comp_sack_slack_ns = 100000
net.ipv4.tcp_congestion_control = cubic
net.ipv4.tcp_dsack = 1
net.ipv4.tcp_early_demux = 1
net.ipv4.tcp_early_retrans = 3
net.ipv4.tcp_ecn = 2
net.ipv4.tcp_ecn_fallback = 1
net.ipv4.tcp_fack = 0
net.ipv4.tcp_fastopen = 1
net.ipv4.tcp_fastopen_blackhole_timeout_sec = 3600
net.ipv4.tcp_fastopen_key = 79bca512-1c75088a-9b0c3843-4d1f76e0
net.ipv4.tcp_fin_timeout = 60
net.ipv4.tcp_frto = 2
net.ipv4.tcp_fwmark_accept = 0
net.ipv4.tcp_invalid_ratelimit = 500
net.ipv4.tcp_keepalive_intvl = 75
net.ipv4.tcp_keepalive_probes = 9
net.ipv4.tcp_keepalive_time = 7200
net.ipv4.tcp_l3mdev_accept = 0
net.ipv4.tcp_limit_output_bytes = 1048576
net.ipv4.tcp_low_latency = 0
net.ipv4.tcp_max_orphans = 131072
net.ipv4.tcp_max_reordering = 300
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_max_tw_buckets = 131072
net.ipv4.tcp_mem = 382032	509377	764064
net.ipv4.tcp_min_rtt_wlen = 300
net.ipv4.tcp_min_snd_mss = 48
net.ipv4.tcp_min_tso_segs = 2
net.ipv4.tcp_moderate_rcvbuf = 1
net.ipv4.tcp_mtu_probe_floor = 48
net.ipv4.tcp_mtu_probing = 0
net.ipv4.tcp_no_metrics_save = 0
net.ipv4.tcp_no_ssthresh_metrics_save = 1
net.ipv4.tcp_notsent_lowat = 4294967295
net.ipv4.tcp_orphan_retries = 0
net.ipv4.tcp_pacing_ca_ratio = 120
net.ipv4.tcp_pacing_ss_ratio = 200
net.ipv4.tcp_probe_interval = 600
net.ipv4.tcp_probe_threshold = 8
net.ipv4.tcp_recovery = 1
net.ipv4.tcp_reordering = 3
net.ipv4.tcp_retrans_collapse = 1
net.ipv4.tcp_retries1 = 3
net.ipv4.tcp_retries2 = 15
net.ipv4.tcp_rfc1337 = 0
net.ipv4.tcp_rmem = 4096	131072	6291456
net.ipv4.tcp_rx_skb_cache = 0
net.ipv4.tcp_sack = 1
net.ipv4.tcp_slow_start_after_idle = 1
net.ipv4.tcp_stdurg = 0
net.ipv4.tcp_syn_retries = 6
net.ipv4.tcp_synack_retries = 5
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_thin_linear_timeouts = 0
net.ipv4.tcp_timestamps = 1
net.ipv4.tcp_tso_win_divisor = 3
net.ipv4.tcp_tw_reuse = 2
net.ipv4.tcp_tx_skb_cache = 0
net.ipv4.tcp_window_scaling = 1
net.ipv4.tcp_wmem = 4096	16384	4194304
net.ipv4.tcp_workaround_signed_windows = 0
net.ipv4.udp_early_demux = 1
net.ipv4.udp_l3mdev_accept = 0
net.ipv4.udp_mem = 764064	1018755	1528128
net.ipv4.udp_rmem_min = 4096
net.ipv4.udp_wmem_min = 4096
net.ipv4.xfrm4_gc_thresh = 32768
net.ipv6.anycast_src_echo_reply = 0
net.ipv6.auto_flowlabels = 1
net.ipv6.bindv6only = 0
net.ipv6.calipso_cache_bucket_size = 10
net.ipv6.calipso_cache_enable = 1
net.ipv6.conf.all.accept_dad = 0
net.ipv6.conf.all.accept_ra = 1
net.ipv6.conf.all.accept_ra_defrtr = 1
net.ipv6.conf.all.accept_ra_from_local = 0
net.ipv6.conf.all.accept_ra_min_hop_limit = 1
net.ipv6.conf.all.accept_ra_mtu = 1
net.ipv6.conf.all.accept_ra_pinfo = 1
net.ipv6.conf.all.accept_ra_rt_info_max_plen = 0
net.ipv6.conf.all.accept_ra_rt_info_min_plen = 0
net.ipv6.conf.all.accept_ra_rtr_pref = 1
net.ipv6.conf.all.accept_redirects = 1
net.ipv6.conf.all.accept_source_route = 0
net.ipv6.conf.all.addr_gen_mode = 0
net.ipv6.conf.all.autoconf = 1
net.ipv6.conf.all.dad_transmits = 1
net.ipv6.conf.all.disable_ipv6 = 0
net.ipv6.conf.all.disable_policy = 0
net.ipv6.conf.all.drop_unicast_in_l2_multicast = 0
net.ipv6.conf.all.drop_unsolicited_na = 0
net.ipv6.conf.all.enhanced_dad = 1
net.ipv6.conf.all.force_mld_version = 0
net.ipv6.conf.all.force_tllao = 0
net.ipv6.conf.all.forwarding = 0
net.ipv6.conf.all.hop_limit = 64
net.ipv6.conf.all.ignore_routes_with_linkdown = 0
net.ipv6.conf.all.keep_addr_on_down = 0
net.ipv6.conf.all.max_addresses = 16
net.ipv6.conf.all.max_desync_factor = 600
net.ipv6.conf.all.mc_forwarding = 0
net.ipv6.conf.all.mldv1_unsolicited_report_interval = 10000
net.ipv6.conf.all.mldv2_unsolicited_report_interval = 1000
net.ipv6.conf.all.mtu = 1280
net.ipv6.conf.all.ndisc_notify = 0
net.ipv6.conf.all.ndisc_tclass = 0
net.ipv6.conf.all.optimistic_dad = 0
net.ipv6.conf.all.proxy_ndp = 0
net.ipv6.conf.all.regen_max_retry = 3
net.ipv6.conf.all.router_probe_interval = 60
net.ipv6.conf.all.router_solicitation_delay = 1
net.ipv6.conf.all.router_solicitation_interval = 4
net.ipv6.conf.all.router_solicitation_max_interval = 3600
net.ipv6.conf.all.router_solicitations = -1
net.ipv6.conf.all.rpl_seg_enabled = 0
net.ipv6.conf.all.seg6_enabled = 0
net.ipv6.conf.all.seg6_require_hmac = 0
net.ipv6.conf.all.suppress_frag_ndisc = 1
net.ipv6.conf.all.temp_prefered_lft = 86400
net.ipv6.conf.all.temp_valid_lft = 604800
net.ipv6.conf.all.use_oif_addrs_only = 0
net.ipv6.conf.all.use_optimistic = 0
net.ipv6.conf.all.use_tempaddr = 0
net.ipv6.conf.default.accept_dad = 1
net.ipv6.conf.default.accept_ra = 1
net.ipv6.conf.default.accept_ra_defrtr = 1
net.ipv6.conf.default.accept_ra_from_local = 0
net.ipv6.conf.default.accept_ra_min_hop_limit = 1
net.ipv6.conf.default.accept_ra_mtu = 1
net.ipv6.conf.default.accept_ra_pinfo = 1
net.ipv6.conf.default.accept_ra_rt_info_max_plen = 0
net.ipv6.conf.default.accept_ra_rt_info_min_plen = 0
net.ipv6.conf.default.accept_ra_rtr_pref = 1
net.ipv6.conf.default.accept_redirects = 1
net.ipv6.conf.default.accept_source_route = 0
net.ipv6.conf.default.addr_gen_mode = 0
net.ipv6.conf.default.autoconf = 1
net.ipv6.conf.default.dad_transmits = 1
net.ipv6.conf.default.disable_ipv6 = 0
net.ipv6.conf.default.disable_policy = 0
net.ipv6.conf.default.drop_unicast_in_l2_multicast = 0
net.ipv6.conf.default.drop_unsolicited_na = 0
net.ipv6.conf.default.enhanced_dad = 1
net.ipv6.conf.default.force_mld_version = 0
net.ipv6.conf.default.force_tllao = 0
net.ipv6.conf.default.forwarding = 0
net.ipv6.conf.default.hop_limit = 64
net.ipv6.conf.default.ignore_routes_with_linkdown = 0
net.ipv6.conf.default.keep_addr_on_down = 0
net.ipv6.conf.default.max_addresses = 16
net.ipv6.conf.default.max_desync_factor = 600
net.ipv6.conf.default.mc_forwarding = 0
net.ipv6.conf.default.mldv1_unsolicited_report_interval = 10000
net.ipv6.conf.default.mldv2_unsolicited_report_interval = 1000
net.ipv6.conf.default.mtu = 1280
net.ipv6.conf.default.ndisc_notify = 0
net.ipv6.conf.default.ndisc_tclass = 0
net.ipv6.conf.default.optimistic_dad = 0
net.ipv6.conf.default.proxy_ndp = 0
net.ipv6.conf.default.regen_max_retry = 3
net.ipv6.conf.default.router_probe_interval = 60
net.ipv6.conf.default.router_solicitation_delay = 1
net.ipv6.conf.default.router_solicitation_interval = 4
net.ipv6.conf.default.router_solicitation_max_interval = 3600
net.ipv6.conf.default.router_solicitations = -1
net.ipv6.conf.default.rpl_seg_enabled = 0
net.ipv6.conf.default.seg6_enabled = 0
net.ipv6.conf.default.seg6_require_hmac = 0
net.ipv6.conf.default.suppress_frag_ndisc = 1
net.ipv6.conf.default.temp_prefered_lft = 86400
net.ipv6.conf.default.temp_valid_lft = 604800
net.ipv6.conf.default.use_oif_addrs_only = 0
net.ipv6.conf.default.use_optimistic = 0
net.ipv6.conf.default.use_tempaddr = 0
net.ipv6.conf.enp3s0.accept_dad = 1
net.ipv6.conf.enp3s0.accept_ra = 0
net.ipv6.conf.enp3s0.accept_ra_defrtr = 1
net.ipv6.conf.enp3s0.accept_ra_from_local = 0
net.ipv6.conf.enp3s0.accept_ra_min_hop_limit = 1
net.ipv6.conf.enp3s0.accept_ra_mtu = 1
net.ipv6.conf.enp3s0.accept_ra_pinfo = 1
net.ipv6.conf.enp3s0.accept_ra_rt_info_max_plen = 0
net.ipv6.conf.enp3s0.accept_ra_rt_info_min_plen = 0
net.ipv6.conf.enp3s0.accept_ra_rtr_pref = 1
net.ipv6.conf.enp3s0.accept_redirects = 1
net.ipv6.conf.enp3s0.accept_source_route = 0
net.ipv6.conf.enp3s0.addr_gen_mode = 1
net.ipv6.conf.enp3s0.autoconf = 1
net.ipv6.conf.enp3s0.dad_transmits = 1
net.ipv6.conf.enp3s0.disable_ipv6 = 0
net.ipv6.conf.enp3s0.disable_policy = 0
net.ipv6.conf.enp3s0.drop_unicast_in_l2_multicast = 0
net.ipv6.conf.enp3s0.drop_unsolicited_na = 0
net.ipv6.conf.enp3s0.enhanced_dad = 1
net.ipv6.conf.enp3s0.force_mld_version = 0
net.ipv6.conf.enp3s0.force_tllao = 0
net.ipv6.conf.enp3s0.forwarding = 0
net.ipv6.conf.enp3s0.hop_limit = 64
net.ipv6.conf.enp3s0.ignore_routes_with_linkdown = 0
net.ipv6.conf.enp3s0.keep_addr_on_down = 0
net.ipv6.conf.enp3s0.max_addresses = 16
net.ipv6.conf.enp3s0.max_desync_factor = 600
net.ipv6.conf.enp3s0.mc_forwarding = 0
net.ipv6.conf.enp3s0.mldv1_unsolicited_report_interval = 10000
net.ipv6.conf.enp3s0.mldv2_unsolicited_report_interval = 1000
net.ipv6.conf.enp3s0.mtu = 1500
net.ipv6.conf.enp3s0.ndisc_notify = 0
net.ipv6.conf.enp3s0.ndisc_tclass = 0
net.ipv6.conf.enp3s0.optimistic_dad = 0
net.ipv6.conf.enp3s0.proxy_ndp = 0
net.ipv6.conf.enp3s0.regen_max_retry = 3
net.ipv6.conf.enp3s0.router_probe_interval = 60
net.ipv6.conf.enp3s0.router_solicitation_delay = 1
net.ipv6.conf.enp3s0.router_solicitation_interval = 4
net.ipv6.conf.enp3s0.router_solicitation_max_interval = 3600
net.ipv6.conf.enp3s0.router_solicitations = -1
net.ipv6.conf.enp3s0.rpl_seg_enabled = 0
net.ipv6.conf.enp3s0.seg6_enabled = 0
net.ipv6.conf.enp3s0.seg6_require_hmac = 0
net.ipv6.conf.enp3s0.suppress_frag_ndisc = 1
net.ipv6.conf.enp3s0.temp_prefered_lft = 86400
net.ipv6.conf.enp3s0.temp_valid_lft = 604800
net.ipv6.conf.enp3s0.use_oif_addrs_only = 0
net.ipv6.conf.enp3s0.use_optimistic = 0
net.ipv6.conf.enp3s0.use_tempaddr = 0
net.ipv6.conf.lo.accept_dad = -1
net.ipv6.conf.lo.accept_ra = 1
net.ipv6.conf.lo.accept_ra_defrtr = 1
net.ipv6.conf.lo.accept_ra_from_local = 0
net.ipv6.conf.lo.accept_ra_min_hop_limit = 1
net.ipv6.conf.lo.accept_ra_mtu = 1
net.ipv6.conf.lo.accept_ra_pinfo = 1
net.ipv6.conf.lo.accept_ra_rt_info_max_plen = 0
net.ipv6.conf.lo.accept_ra_rt_info_min_plen = 0
net.ipv6.conf.lo.accept_ra_rtr_pref = 1
net.ipv6.conf.lo.accept_redirects = 1
net.ipv6.conf.lo.accept_source_route = 0
net.ipv6.conf.lo.addr_gen_mode = 0
net.ipv6.conf.lo.autoconf = 1
net.ipv6.conf.lo.dad_transmits = 1
net.ipv6.conf.lo.disable_ipv6 = 0
net.ipv6.conf.lo.disable_policy = 0
net.ipv6.conf.lo.drop_unicast_in_l2_multicast = 0
net.ipv6.conf.lo.drop_unsolicited_na = 0
net.ipv6.conf.lo.enhanced_dad = 1
net.ipv6.conf.lo.force_mld_version = 0
net.ipv6.conf.lo.force_tllao = 0
net.ipv6.conf.lo.forwarding = 0
net.ipv6.conf.lo.hop_limit = 64
net.ipv6.conf.lo.ignore_routes_with_linkdown = 0
net.ipv6.conf.lo.keep_addr_on_down = 0
net.ipv6.conf.lo.max_addresses = 16
net.ipv6.conf.lo.max_desync_factor = 600
net.ipv6.conf.lo.mc_forwarding = 0
net.ipv6.conf.lo.mldv1_unsolicited_report_interval = 10000
net.ipv6.conf.lo.mldv2_unsolicited_report_interval = 1000
net.ipv6.conf.lo.mtu = 65536
net.ipv6.conf.lo.ndisc_notify = 0
net.ipv6.conf.lo.ndisc_tclass = 0
net.ipv6.conf.lo.optimistic_dad = 0
net.ipv6.conf.lo.proxy_ndp = 0
net.ipv6.conf.lo.regen_max_retry = 3
net.ipv6.conf.lo.router_probe_interval = 60
net.ipv6.conf.lo.router_solicitation_delay = 1
net.ipv6.conf.lo.router_solicitation_interval = 4
net.ipv6.conf.lo.router_solicitation_max_interval = 3600
net.ipv6.conf.lo.router_solicitations = -1
net.ipv6.conf.lo.rpl_seg_enabled = 0
net.ipv6.conf.lo.seg6_enabled = 0
net.ipv6.conf.lo.seg6_require_hmac = 0
net.ipv6.conf.lo.suppress_frag_ndisc = 1
net.ipv6.conf.lo.temp_prefered_lft = 86400
net.ipv6.conf.lo.temp_valid_lft = 604800
net.ipv6.conf.lo.use_oif_addrs_only = 0
net.ipv6.conf.lo.use_optimistic = 0
net.ipv6.conf.lo.use_tempaddr = -1
net.ipv6.conf.virbr0.accept_dad = 1
net.ipv6.conf.virbr0.accept_ra = 0
net.ipv6.conf.virbr0.accept_ra_defrtr = 1
net.ipv6.conf.virbr0.accept_ra_from_local = 0
net.ipv6.conf.virbr0.accept_ra_min_hop_limit = 1
net.ipv6.conf.virbr0.accept_ra_mtu = 1
net.ipv6.conf.virbr0.accept_ra_pinfo = 1
net.ipv6.conf.virbr0.accept_ra_rt_info_max_plen = 0
net.ipv6.conf.virbr0.accept_ra_rt_info_min_plen = 0
net.ipv6.conf.virbr0.accept_ra_rtr_pref = 1
net.ipv6.conf.virbr0.accept_redirects = 1
net.ipv6.conf.virbr0.accept_source_route = 0
net.ipv6.conf.virbr0.addr_gen_mode = 0
net.ipv6.conf.virbr0.autoconf = 0
net.ipv6.conf.virbr0.dad_transmits = 1
net.ipv6.conf.virbr0.disable_ipv6 = 1
net.ipv6.conf.virbr0.disable_policy = 0
net.ipv6.conf.virbr0.drop_unicast_in_l2_multicast = 0
net.ipv6.conf.virbr0.drop_unsolicited_na = 0
net.ipv6.conf.virbr0.enhanced_dad = 1
net.ipv6.conf.virbr0.force_mld_version = 0
net.ipv6.conf.virbr0.force_tllao = 0
net.ipv6.conf.virbr0.forwarding = 0
net.ipv6.conf.virbr0.hop_limit = 64
net.ipv6.conf.virbr0.ignore_routes_with_linkdown = 0
net.ipv6.conf.virbr0.keep_addr_on_down = 0
net.ipv6.conf.virbr0.max_addresses = 16
net.ipv6.conf.virbr0.max_desync_factor = 600
net.ipv6.conf.virbr0.mc_forwarding = 0
net.ipv6.conf.virbr0.mldv1_unsolicited_report_interval = 10000
net.ipv6.conf.virbr0.mldv2_unsolicited_report_interval = 1000
net.ipv6.conf.virbr0.mtu = 1500
net.ipv6.conf.virbr0.ndisc_notify = 0
net.ipv6.conf.virbr0.ndisc_tclass = 0
net.ipv6.conf.virbr0.optimistic_dad = 0
net.ipv6.conf.virbr0.proxy_ndp = 0
net.ipv6.conf.virbr0.regen_max_retry = 3
net.ipv6.conf.virbr0.router_probe_interval = 60
net.ipv6.conf.virbr0.router_solicitation_delay = 1
net.ipv6.conf.virbr0.router_solicitation_interval = 4
net.ipv6.conf.virbr0.router_solicitation_max_interval = 3600
net.ipv6.conf.virbr0.router_solicitations = -1
net.ipv6.conf.virbr0.rpl_seg_enabled = 0
net.ipv6.conf.virbr0.seg6_enabled = 0
net.ipv6.conf.virbr0.seg6_require_hmac = 0
net.ipv6.conf.virbr0.suppress_frag_ndisc = 1
net.ipv6.conf.virbr0.temp_prefered_lft = 86400
net.ipv6.conf.virbr0.temp_valid_lft = 604800
net.ipv6.conf.virbr0.use_oif_addrs_only = 0
net.ipv6.conf.virbr0.use_optimistic = 0
net.ipv6.conf.virbr0.use_tempaddr = 0
net.ipv6.conf.virbr0-nic.accept_dad = 1
net.ipv6.conf.virbr0-nic.accept_ra = 1
net.ipv6.conf.virbr0-nic.accept_ra_defrtr = 1
net.ipv6.conf.virbr0-nic.accept_ra_from_local = 0
net.ipv6.conf.virbr0-nic.accept_ra_min_hop_limit = 1
net.ipv6.conf.virbr0-nic.accept_ra_mtu = 1
net.ipv6.conf.virbr0-nic.accept_ra_pinfo = 1
net.ipv6.conf.virbr0-nic.accept_ra_rt_info_max_plen = 0
net.ipv6.conf.virbr0-nic.accept_ra_rt_info_min_plen = 0
net.ipv6.conf.virbr0-nic.accept_ra_rtr_pref = 1
net.ipv6.conf.virbr0-nic.accept_redirects = 1
net.ipv6.conf.virbr0-nic.accept_source_route = 0
net.ipv6.conf.virbr0-nic.addr_gen_mode = 0
net.ipv6.conf.virbr0-nic.autoconf = 1
net.ipv6.conf.virbr0-nic.dad_transmits = 1
net.ipv6.conf.virbr0-nic.disable_ipv6 = 0
net.ipv6.conf.virbr0-nic.disable_policy = 0
net.ipv6.conf.virbr0-nic.drop_unicast_in_l2_multicast = 0
net.ipv6.conf.virbr0-nic.drop_unsolicited_na = 0
net.ipv6.conf.virbr0-nic.enhanced_dad = 1
net.ipv6.conf.virbr0-nic.force_mld_version = 0
net.ipv6.conf.virbr0-nic.force_tllao = 0
net.ipv6.conf.virbr0-nic.forwarding = 0
net.ipv6.conf.virbr0-nic.hop_limit = 64
net.ipv6.conf.virbr0-nic.ignore_routes_with_linkdown = 0
net.ipv6.conf.virbr0-nic.keep_addr_on_down = 0
net.ipv6.conf.virbr0-nic.max_addresses = 16
net.ipv6.conf.virbr0-nic.max_desync_factor = 600
net.ipv6.conf.virbr0-nic.mc_forwarding = 0
net.ipv6.conf.virbr0-nic.mldv1_unsolicited_report_interval = 10000
net.ipv6.conf.virbr0-nic.mldv2_unsolicited_report_interval = 1000
net.ipv6.conf.virbr0-nic.mtu = 1500
net.ipv6.conf.virbr0-nic.ndisc_notify = 0
net.ipv6.conf.virbr0-nic.ndisc_tclass = 0
net.ipv6.conf.virbr0-nic.optimistic_dad = 0
net.ipv6.conf.virbr0-nic.proxy_ndp = 0
net.ipv6.conf.virbr0-nic.regen_max_retry = 3
net.ipv6.conf.virbr0-nic.router_probe_interval = 60
net.ipv6.conf.virbr0-nic.router_solicitation_delay = 1
net.ipv6.conf.virbr0-nic.router_solicitation_interval = 4
net.ipv6.conf.virbr0-nic.router_solicitation_max_interval = 3600
net.ipv6.conf.virbr0-nic.router_solicitations = -1
net.ipv6.conf.virbr0-nic.rpl_seg_enabled = 0
net.ipv6.conf.virbr0-nic.seg6_enabled = 0
net.ipv6.conf.virbr0-nic.seg6_require_hmac = 0
net.ipv6.conf.virbr0-nic.suppress_frag_ndisc = 1
net.ipv6.conf.virbr0-nic.temp_prefered_lft = 86400
net.ipv6.conf.virbr0-nic.temp_valid_lft = 604800
net.ipv6.conf.virbr0-nic.use_oif_addrs_only = 0
net.ipv6.conf.virbr0-nic.use_optimistic = 0
net.ipv6.conf.virbr0-nic.use_tempaddr = 0
net.ipv6.fib_multipath_hash_policy = 0
net.ipv6.flowlabel_consistency = 1
net.ipv6.flowlabel_reflect = 0
net.ipv6.flowlabel_state_ranges = 0
net.ipv6.fwmark_reflect = 0
net.ipv6.icmp.echo_ignore_all = 0
net.ipv6.icmp.echo_ignore_anycast = 0
net.ipv6.icmp.echo_ignore_multicast = 0
net.ipv6.icmp.ratelimit = 1000
net.ipv6.icmp.ratemask = 0-1,3-127
net.ipv6.idgen_delay = 1
net.ipv6.idgen_retries = 3
net.ipv6.ip6frag_high_thresh = 4194304
net.ipv6.ip6frag_low_thresh = 3145728
net.ipv6.ip6frag_secret_interval = 0
net.ipv6.ip6frag_time = 60
net.ipv6.ip_nonlocal_bind = 0
net.ipv6.max_dst_opts_length = 2147483647
net.ipv6.max_dst_opts_number = 8
net.ipv6.max_hbh_length = 2147483647
net.ipv6.max_hbh_opts_number = 8
net.ipv6.mld_max_msf = 64
net.ipv6.mld_qrv = 2
net.ipv6.neigh.default.anycast_delay = 99
net.ipv6.neigh.default.app_solicit = 0
net.ipv6.neigh.default.base_reachable_time_ms = 30000
net.ipv6.neigh.default.delay_first_probe_time = 5
net.ipv6.neigh.default.gc_interval = 30
net.ipv6.neigh.default.gc_stale_time = 60
net.ipv6.neigh.default.gc_thresh1 = 128
net.ipv6.neigh.default.gc_thresh2 = 512
net.ipv6.neigh.default.gc_thresh3 = 1024
net.ipv6.neigh.default.locktime = 0
net.ipv6.neigh.default.mcast_resolicit = 0
net.ipv6.neigh.default.mcast_solicit = 3
net.ipv6.neigh.default.proxy_delay = 79
net.ipv6.neigh.default.proxy_qlen = 64
net.ipv6.neigh.default.retrans_time_ms = 1000
net.ipv6.neigh.default.ucast_solicit = 3
net.ipv6.neigh.default.unres_qlen = 101
net.ipv6.neigh.default.unres_qlen_bytes = 212992
net.ipv6.neigh.enp3s0.anycast_delay = 99
net.ipv6.neigh.enp3s0.app_solicit = 0
net.ipv6.neigh.enp3s0.base_reachable_time_ms = 30000
net.ipv6.neigh.enp3s0.delay_first_probe_time = 5
net.ipv6.neigh.enp3s0.gc_stale_time = 60
net.ipv6.neigh.enp3s0.locktime = 0
net.ipv6.neigh.enp3s0.mcast_resolicit = 0
net.ipv6.neigh.enp3s0.mcast_solicit = 3
net.ipv6.neigh.enp3s0.proxy_delay = 79
net.ipv6.neigh.enp3s0.proxy_qlen = 64
net.ipv6.neigh.enp3s0.retrans_time_ms = 1000
net.ipv6.neigh.enp3s0.ucast_solicit = 3
net.ipv6.neigh.enp3s0.unres_qlen = 101
net.ipv6.neigh.enp3s0.unres_qlen_bytes = 212992
net.ipv6.neigh.lo.anycast_delay = 99
net.ipv6.neigh.lo.app_solicit = 0
net.ipv6.neigh.lo.base_reachable_time_ms = 30000
net.ipv6.neigh.lo.delay_first_probe_time = 5
net.ipv6.neigh.lo.gc_stale_time = 60
net.ipv6.neigh.lo.locktime = 0
net.ipv6.neigh.lo.mcast_resolicit = 0
net.ipv6.neigh.lo.mcast_solicit = 3
net.ipv6.neigh.lo.proxy_delay = 79
net.ipv6.neigh.lo.proxy_qlen = 64
net.ipv6.neigh.lo.retrans_time_ms = 1000
net.ipv6.neigh.lo.ucast_solicit = 3
net.ipv6.neigh.lo.unres_qlen = 101
net.ipv6.neigh.lo.unres_qlen_bytes = 212992
net.ipv6.neigh.virbr0.anycast_delay = 99
net.ipv6.neigh.virbr0.app_solicit = 0
net.ipv6.neigh.virbr0.base_reachable_time_ms = 30000
net.ipv6.neigh.virbr0.delay_first_probe_time = 5
net.ipv6.neigh.virbr0.gc_stale_time = 60
net.ipv6.neigh.virbr0.locktime = 0
net.ipv6.neigh.virbr0.mcast_resolicit = 0
net.ipv6.neigh.virbr0.mcast_solicit = 3
net.ipv6.neigh.virbr0.proxy_delay = 79
net.ipv6.neigh.virbr0.proxy_qlen = 64
net.ipv6.neigh.virbr0.retrans_time_ms = 1000
net.ipv6.neigh.virbr0.ucast_solicit = 3
net.ipv6.neigh.virbr0.unres_qlen = 101
net.ipv6.neigh.virbr0.unres_qlen_bytes = 212992
net.ipv6.neigh.virbr0-nic.anycast_delay = 99
net.ipv6.neigh.virbr0-nic.app_solicit = 0
net.ipv6.neigh.virbr0-nic.base_reachable_time_ms = 30000
net.ipv6.neigh.virbr0-nic.delay_first_probe_time = 5
net.ipv6.neigh.virbr0-nic.gc_stale_time = 60
net.ipv6.neigh.virbr0-nic.locktime = 0
net.ipv6.neigh.virbr0-nic.mcast_resolicit = 0
net.ipv6.neigh.virbr0-nic.mcast_solicit = 3
net.ipv6.neigh.virbr0-nic.proxy_delay = 79
net.ipv6.neigh.virbr0-nic.proxy_qlen = 64
net.ipv6.neigh.virbr0-nic.retrans_time_ms = 1000
net.ipv6.neigh.virbr0-nic.ucast_solicit = 3
net.ipv6.neigh.virbr0-nic.unres_qlen = 101
net.ipv6.neigh.virbr0-nic.unres_qlen_bytes = 212992
net.ipv6.route.gc_elasticity = 9
net.ipv6.route.gc_interval = 30
net.ipv6.route.gc_min_interval = 0
net.ipv6.route.gc_min_interval_ms = 500
net.ipv6.route.gc_thresh = 1024
net.ipv6.route.gc_timeout = 60
net.ipv6.route.max_size = 4096
net.ipv6.route.min_adv_mss = 1220
net.ipv6.route.mtu_expires = 600
net.ipv6.route.skip_notify_on_dev_down = 0
net.ipv6.seg6_flowlabel = 0
net.ipv6.xfrm6_gc_thresh = 32768
net.mptcp.enabled = 1
net.netfilter.nf_conntrack_acct = 0
net.netfilter.nf_conntrack_buckets = 65536
net.netfilter.nf_conntrack_checksum = 1
net.netfilter.nf_conntrack_count = 182
net.netfilter.nf_conntrack_dccp_loose = 1
net.netfilter.nf_conntrack_dccp_timeout_closereq = 64
net.netfilter.nf_conntrack_dccp_timeout_closing = 64
net.netfilter.nf_conntrack_dccp_timeout_open = 43200
net.netfilter.nf_conntrack_dccp_timeout_partopen = 480
net.netfilter.nf_conntrack_dccp_timeout_request = 240
net.netfilter.nf_conntrack_dccp_timeout_respond = 480
net.netfilter.nf_conntrack_dccp_timeout_timewait = 240
net.netfilter.nf_conntrack_events = 1
net.netfilter.nf_conntrack_expect_max = 1024
net.netfilter.nf_conntrack_frag6_high_thresh = 4194304
net.netfilter.nf_conntrack_frag6_low_thresh = 3145728
net.netfilter.nf_conntrack_frag6_timeout = 60
net.netfilter.nf_conntrack_generic_timeout = 600
net.netfilter.nf_conntrack_gre_timeout = 30
net.netfilter.nf_conntrack_gre_timeout_stream = 180
net.netfilter.nf_conntrack_helper = 0
net.netfilter.nf_conntrack_icmp_timeout = 30
net.netfilter.nf_conntrack_icmpv6_timeout = 30
net.netfilter.nf_conntrack_log_invalid = 0
net.netfilter.nf_conntrack_max = 262144
net.netfilter.nf_conntrack_sctp_timeout_closed = 10
net.netfilter.nf_conntrack_sctp_timeout_cookie_echoed = 3
net.netfilter.nf_conntrack_sctp_timeout_cookie_wait = 3
net.netfilter.nf_conntrack_sctp_timeout_established = 432000
net.netfilter.nf_conntrack_sctp_timeout_heartbeat_acked = 210
net.netfilter.nf_conntrack_sctp_timeout_heartbeat_sent = 30
net.netfilter.nf_conntrack_sctp_timeout_shutdown_ack_sent = 3
net.netfilter.nf_conntrack_sctp_timeout_shutdown_recd = 0
net.netfilter.nf_conntrack_sctp_timeout_shutdown_sent = 0
net.netfilter.nf_conntrack_tcp_be_liberal = 0
net.netfilter.nf_conntrack_tcp_loose = 1
net.netfilter.nf_conntrack_tcp_max_retrans = 3
net.netfilter.nf_conntrack_tcp_timeout_close = 10
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 60
net.netfilter.nf_conntrack_tcp_timeout_established = 432000
net.netfilter.nf_conntrack_tcp_timeout_fin_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_last_ack = 30
net.netfilter.nf_conntrack_tcp_timeout_max_retrans = 300
net.netfilter.nf_conntrack_tcp_timeout_syn_recv = 60
net.netfilter.nf_conntrack_tcp_timeout_syn_sent = 120
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 120
net.netfilter.nf_conntrack_tcp_timeout_unacknowledged = 300
net.netfilter.nf_conntrack_timestamp = 0
net.netfilter.nf_conntrack_udp_timeout = 30
net.netfilter.nf_conntrack_udp_timeout_stream = 120
net.netfilter.nf_log.0 = NONE
net.netfilter.nf_log.1 = NONE
net.netfilter.nf_log.10 = NONE
net.netfilter.nf_log.11 = NONE
net.netfilter.nf_log.12 = NONE
net.netfilter.nf_log.2 = NONE
net.netfilter.nf_log.3 = NONE
net.netfilter.nf_log.4 = NONE
net.netfilter.nf_log.5 = NONE
net.netfilter.nf_log.6 = NONE
net.netfilter.nf_log.7 = NONE
net.netfilter.nf_log.8 = NONE
net.netfilter.nf_log.9 = NONE
net.netfilter.nf_log_all_netns = 0
net.nf_conntrack_max = 262144
net.unix.max_dgram_qlen = 512
user.max_cgroup_namespaces = 62328
user.max_inotify_instances = 1024
user.max_inotify_watches = 524288
user.max_ipc_namespaces = 62328
user.max_mnt_namespaces = 62328
user.max_net_namespaces = 62328
user.max_pid_namespaces = 62328
user.max_time_namespaces = 62328
user.max_user_namespaces = 62328
user.max_uts_namespaces = 62328
vm.admin_reserve_kbytes = 8192
vm.block_dump = 0
vm.compact_unevictable_allowed = 1
vm.dirty_background_bytes = 0
vm.dirty_background_ratio = 10
vm.dirty_bytes = 0
vm.dirty_expire_centisecs = 3000
vm.dirty_ratio = 20
vm.dirty_writeback_centisecs = 500
vm.dirtytime_expire_seconds = 43200
vm.extfrag_threshold = 500
vm.hugetlb_shm_group = 0
vm.laptop_mode = 0
vm.legacy_va_layout = 0
vm.lowmem_reserve_ratio = 256	256	32	0	0
vm.max_map_count = 65530
vm.memory_failure_early_kill = 0
vm.memory_failure_recovery = 1
vm.min_free_kbytes = 67584
vm.min_slab_ratio = 5
vm.min_unmapped_ratio = 1
vm.mmap_min_addr = 65536
vm.mmap_rnd_bits = 28
vm.mmap_rnd_compat_bits = 8
vm.nr_hugepages = 16
vm.nr_hugepages_mempolicy = 16
vm.nr_overcommit_hugepages = 0
vm.numa_stat = 1
vm.numa_zonelist_order = Node
vm.oom_dump_tasks = 1
vm.oom_kill_allocating_task = 0
vm.overcommit_kbytes = 0
vm.overcommit_memory = 0
vm.overcommit_ratio = 50
vm.page-cluster = 3
vm.panic_on_oom = 0
vm.percpu_pagelist_fraction = 0
vm.stat_interval = 1
vm.swappiness = 10
vm.unprivileged_userfaultfd = 1
vm.user_reserve_kbytes = 131072
vm.vfs_cache_pressure = 100
vm.watermark_boost_factor = 15000
vm.watermark_scale_factor = 10
vm.zone_reclaim_mode = 0" > /etc/sysctl.conf && sysctl -p -q &>/dev/null

    printf "${hostname}" > /etc/hostname
    printf "127.0.0.1   localhost\n::1  localhost" > /etc/hosts
    pacman -S networkmanager --noconfirm --needed

    printf "function update-grub {\n    sudo grub-mkconfig -o /boot/grub/grub.cfg\n}" /etc/profile.d/update-grub.sh
    printf "function update-initramfs {\n    sudo mkinitcpio -P\n}" /etc/profile.d/update-initramfs.sh
    source /etc/profile.d/update-grub.sh && source /etc/profile.d/update-initramfs.sh
    printf '#!/bin/bash

function mirror-alcatel {
    deviceIp="172.16.255.244"
    internalDeviceName="5024D_EEA"
    deviceName="Alcatel 1S (2019)"

    clear
    echo -e ":: Before you can mirror your smartphone screen you need to enable developer tools, USB debugging and then, after connecting the device, allow access for ADB. Afterwards, select MTP."
    read -n1 -p "Press any key to continue... "

    echo -n ":: Starting ADB server... "
    adb start-server &>/dev/null && echo -e "done" || echo -e "failed"

    echo -n ":: Enabling device over TCP/IP... "
    adb tcpip 5555 &>/dev/null && echo -e "done" || echo -e "failed"

    echo -e ":: Unplug the device now"
    read -n1 -p "PRESS ANY KEY TO CONTINUE..."

    echo -n ":: Connecting to device ${deviceName}... "
    adb connect ${deviceIp}:5555 &>/dev/null && echo -e "done" || echo -e "failed"

    echo -e ":: Connected to device: ${deviceName} "
    scrcpy --always-on-top -Sw --window-title "5024D_EEA" &>/dev/null

    echo -n ":: Closing ADB server... "
    adb kill-server &>/dev/null && echo -e "done" || echo -e "failed"
}' > /etc/profile.d/mirror-alcatel.sh

    sudo pacman -S grub --noconfirm --needed
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=archlinux
    update-grub
    update-initramfs

    echo -e "\n:: Please type in a password for the root user"
    passwd root
    
    echo -e "\n"

    while true; do
        read -p ":: Do you want to create your own user? [Y/n] " $input
        case $input in
            [Yy]* ) useradd -m ${username}; passwd ${password}; exit;;
            [Nn]* ) break;;
            * ) echo "Invalid parameter, please type Yy or Nn instead.";;
        esac
    done

    echo -e "\n:: Base system is now ready for use\n"
    read -n1 -p ":: Press any key to continue..."
}

function aurSetup() {
    pacman -S git --nocm --needed &>/dev/null
    if [[ ! -d /opt/yay-git ]]; then
        cd /opt/
        git clone -q https://aur.archlinux.org/yay-git.git
        chown -R $username:$username yay-git/
        cd yay-git/
        makepkg -si --noconfirm &>/dev/null
        else
            cd /opt/yay-git/
            chown -R $username:$username .
            makepkg -si --noconfirm
    fi
}

function extrasSetup() {
    packagesArch="pacman-contrib qemu bridge-utils ovmf bleachbit gedit bleachbit chrome-gnome-shell clamtk code fail2ban gimp adobe-source-han-{sans-cn-fonts,sans-tw-fonts,serif-cn-fonts,serif-tw-fonts} gnome-{backgrounds,screenshot,tweaks,terminal,control-center,keyring} libgnome-keyring gstreamer-vaapi intel-ucode libappindicator-{gtk2,gtk3} libreoffice libvdpau-va-gl lutris wine-staging giflib lib32-giflib libpng lib32-libpng libldap lib32-libldap gnutls lib32-gnutls mpg123 lib32-mpg123 openal lib32-openal v4l-utils lib32-v4l-utils libpulse lib32-libpulse libgpg-error lib32-libgpg-error alsa-plugins lib32-alsa-plugins alsa-lib lib32-alsa-lib libjpeg-turbo lib32-libjpeg-turbo sqlite lib32-sqlite libxcomposite lib32-libxcomposite libxinerama lib32-libgcrypt libgcrypt lib32-libxinerama ncurses lib32-ncurses opencl-icd-loader lib32-opencl-icd-loader libxslt lib32-libxslt libva lib32-libva gtk3 lib32-gtk3 gst-plugins-base-libs lib32-gst-plugins-base-libs vulkan-icd-loader lib32-vulkan-icd-loader mokutil nautilus neofetch papirus-icon-theme pcsx2 pulseaudio pulseaudio-{jack,bluetooth} steam telegram-desktop unrar unzip xdg-user-dirs apparmor gvfs-mtp gvfs-google cups hplip"
    packagesAur="brave-nightly-bin minecraft-launcher plata-theme-gnome psensor-git scrcpy"
    packagesAurEol="spotify"
    if [[ ! -f /usr/bin/yay ]]; then
        echo -ne "\n\n\n${red}${boldText}:: ERROR: Yay AUR Helper was not found on this system and it is being installed now. Please wait...${normalText} "
	aurSetup &>/dev/null && echo -e "${green}done${normalText}" || echo -e "${red}failed"
    fi
    yay -Syyy && yay -Syu --noconfirm && yay -S ${packagesArch} ${packagesAur} ${packagesAurEol} --noconfirm --needed
    freshclam && systemctl enable --now clamav-freshclam
    systemctl enable --now fail2ban
    printf "#!/bin/bash
PATH=/usr/bin
alert="Signature detected: $CLAM_VIRUSEVENT_VIRUSNAME in $CLAM_VIRUSEVENT_FILENAME"

# Send the alert to systemd logger if exist, othewise to /var/log
if [[ -z $(command -v systemd-cat) ]]; then
        echo "$(date) - $alert" >> /var/log/clamav/detections.log
else
        # This could cause your DE to show a visual alert. Happens in Plasma, but the next visual alert is much nicer.
        echo "$alert" | /usr/bin/systemd-cat -t clamav -p emerg
fi

# Send an alert to all graphical users.
XUSERS=($(who|awk '{print $1$NF}'|sort -u))

for XUSER in $XUSERS; do
    NAME=(${XUSER/(/ })
    DISPLAY=${NAME[1]/)/}
    DBUS_ADDRESS=unix:path=/run/user/$(id -u ${NAME[0]})/bus
    echo "run $NAME - $DISPLAY - $DBUS_ADDRESS -" >> /tmp/testlog 
    /usr/bin/sudo -u ${NAME[0]} DISPLAY=${DISPLAY} \
                       DBUS_SESSION_BUS_ADDRESS=${DBUS_ADDRESS} \
                       PATH=${PATH} \
                       /usr/bin/notify-send -i dialog-warning "clamAV" "$alert"
done" > /etc/clamav/detected.sh && aa-complain clamd &>/dev/null && sed -i 's/#User clamav/User root/g' /etc/clamav/clamd.conf && sed -i 's/#LocalSocket /run/clamav/clamd.ctl/LocalSocket /run/clamav/clamd.ctl/g' /etc/clamav/clamd.conf && sudo systemctl restart clamav-daemon
    xdg-user-dirs-update
    sed -i 's/SHUTDOWN_TIMEOUT=suspend/SHUTDOWN_TIMEOUT=shutdown/g' /usr/lib/libvirt/libvirt-guests.sh && systemctl enable --now libvirt-guests
}

# Initialize script functions in this order
welcome
root
diskPartitioning
baseSetup
extrasSetup
