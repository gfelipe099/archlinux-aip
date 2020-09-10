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
    kernelVer="$(uname -r)"
    echo -e "Welcome to Arch Linux AIP!\n\n\nKernel version: ${kernelVer}"
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
        read -p "Which is your favorite editor? (nano, vi or vim): " editor
        read -p "Which platform do you prefer to use with QT applications? (wayland or xcb): " qtplatform
        read -p "Which thteme do you prefer to use with QT applications? (gtk2 or gtk3): " qtplatformtheme
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
editor=${editor}
qtplatform=${qtplatform}
qtplatformtheme=${qtplatformtheme}

[User Settings]
username="${username}"
password="${password}"" > conf/main.conf
        else
            source conf/main.conf
            echo -e "${green}${boldText}:: Your configuration file was found and loaded successfully!${normalText}\n"
    fi
}

function diskPartitioning() {
    #
    # author(s): nbros652, neuffer
    # source: https://raw.githubusercontent.com/nbros652/LUKS-guided-manual-partitioning/master/LGMP.sh
    # modifications by Liam Powell (gfelipe099): removed swap partition, renamed LVM from vl0 to archlinux
    #
    
    #---------------------------------------------------begin stage one---------------------------------------------------#

    clear
    if [ "$(whoami)" != "root" ]; then
        echo "Restarting with sudo"
        sudo bash $0
        exit
    fi

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
    echo -e "WARNING: Continuing will destroy any data that may currently be on $disk. \nPlease ensure there are no other operating systems or files that you may want \nto keep on this disk!"
    read -p "To continue, type ERASE in all caps: " opt
    [ "$opt" != "ERASE" ] && echo -e "No changes made!" && read -p "Press [Enter] to exit." && exit
    clear

    # disable any active LVM partitions
    lvs=$(lvs --noheadings --rows | head -n1)
    if [ ! -z "$lvs" ]; then
        echo -n "Deactivating LVM volumes ... "
        for lv in $lvs
        do
            lvchange -an $lv > /dev/null 2>&1
        done
        echo -e "${green}done${normalText}"
    fi

    # close any open LUKS disks
    find /dev/mapper -type l | while read path
    do
        dev=$(basename "$path")
        cryptsetup status $dev > /dev/null 2>&1 || exit
        echo -n "Closing LUKS device: $dev ... "
        cryptsetup close $dev && echo -e "${green}done${normalText}" || echo -e "${red}failed${normalText}"
    done
        
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

    hasKeyfile() {
        [ "${keyfileSize,,}" == "none" ] && return 1 || return 0
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
    read -p "Size for LVM [remaining disk space]: " lvm
    read -p "Size for / (root) in LVM [30G]: " root
    read -p "Percent of remaining LVM space to use for /home [100%]: " home
    echo
    while :
    do
        echo "Nothing will be displayed as you type passphrases!"
        read -sp "Encryption passphrase: " luksPass && echo
        [ "$luksPass" == "" ] && echo "Oops, looks like you forgot to provide a passphrase. Try again." && continue
        read -sp "Confirm encryption passphrase: " confirm
        clear
        [ "$luksPass" == "$confirm" ] && break
    echo "passphrases didn't match or passphrase was blank! Try again"
    done
    echo  -e 'In addition to the passphrase you provided, a keyfile can be generated that can \nalso be used for decryption. It is STRONGLY RECOMMENDED that you create this \nfile and store it in a secure location to be used in the event that you ever \nforget your passphrase!\n'
    read -p "Key file size in bytes, or 'none' to prevent key file creation [512]: " keyfileSize
    keyfileSize=${keyfileSize:-512}
    keyfile=/tmp/LUKS.key
    hasKeyfile && dd if=/dev/urandom of="${keyfile}" bs=${keyfileSize} count=1 2> /dev/null

    clear
    # fill in the blanks with default values
    parts="efi=100M boot=500M lvm=-1MB root=30G home=100%"
    for part in $parts
    do
        name=$(cut -f1 -d= <<< $part)
        [ "$name" == "efi" ] && ! isEFI && continue
        [ ${!name} ] || eval "${part}"
    done
    grep -q "%" <<< ${home} || home="${home}%"

    # create physical partitions
    clear
    offset="1M" #offset for first partition
    physicalParts="boot:ext2 efi:fat32 lvm"
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

    # generate partition paths; expects a single argument, the partition number
    getDiskPartitionByNumber() {
        partNum=$1
        if grep -iq "nvme" <<< "$disk"; then
            # partitions for this disk follow an NVMe naming standard
            part="${disk}p${partNum}"
        else
            # partitions for this disk follow a SATA, IDE, SCSI naming standard
            part="${disk}${partNum}"
        fi
        
        # wait until partition is visible to the system; fixes NVMe race condition following partition creation
        while [ ! -e "${part}" ]
        do
            sleep .5
        done
        
        echo "$part"
    }

    bootPart=$(getDiskPartitionByNumber 1)
    isEFI && efiPart=$(getDiskPartitionByNumber 2)

    # setup LUKS encryption
    echo "Setting up encryption:"
    isEFI && luksPart=$(getDiskPartitionByNumber 3) || luksPart=$(getDiskPartitionByNumber 2)
    cryptMapper="${luksPart/\/dev\/}_crypt"
    echo -en "  Encrypting ${luksPart} with your passphrase ... "
    echo -n "${luksPass}" | cryptsetup luksFormat -c aes-xts-plain64 -h sha512 -s 512 --iter-time 5000 --use-random -S 1 -d - ${luksPart}
    echo -e "${green}done${normalText}"
    if hasKeyfile; then
        echo -e "  ${boldText}We're going to need some random data for this next step. If it takes long, try  moving the mouse around or typing on the keyboard in a different window.${normalText}"
        echo -n "  Adding key file as a decryption option for ${luksPart} ... "
        cryptsetup luksAddKey ${luksPart} "${keyfile}" <<< "${luksPass}"
        echo -e "${green}done${normalText}"
    fi

    # unlock LUKS partition
    echo -n "  Decrypting newly created LUKS partition ... "
    echo -n "$luksPass" | cryptsetup luksOpen ${luksPart} ${cryptMapper} && echo -e "${green}done${normalText}" || echo -e "${red}failed${normalText}"

    # setup LVM and create logical partitions
    echo "Setting up LVM:"
    pvcreate /dev/mapper/${cryptMapper} > /dev/null 2>&1
    vgcreate archlinux /dev/mapper/${cryptMapper} > /dev/null 2>&1
    echo -n "  Creating ${root} root logical volume ... "
    lvcreate -n root -L ${root} archlinux > /dev/null 2>&1 && echo -e "${green}done${normalText}" || echo -e "${red}failed${normalText}"
    homeSpace=$(bc <<< "$(vgdisplay --units b | grep Free | awk '{print $7}') * $(tr -d '%' <<< $home) / 100" | numfmt --to=iec)
    echo -n "  Creating ${homeSpace} home logical volume ... "
    lvcreate -n home -l +${home}free archlinux > /dev/null 2>&1 && echo -e "${green}done${normalText}" || echo -e "${red}failed${normalText}"

    # stage one complete; pause and wait for user to perform installation
    echo -e "${yellow}${boldText}\n\nAt this point, you should KEEP THIS WINDOW OPEN and start the installation \nprocess. When you reach the \"Installation type\" page, select \"Something else\" \nand continue to manual partition setup.\n  ${bootPart} should be used as ext2 for /boot\n$(isEFI && echo "  ${efiPart} should be used as EFI System Partition\n")  /dev/mapper/archlinux-home should be used as ext4 for /home\n  /dev/mapper/archlinux-root should be used as ext4 for /\n   $disk should be selected as the \"Device for boot loader installation\"${normalText}"
    echo
    echo -e "${boldText}After installation, once you've chosen the option to continue testing, press     [Enter] in this window.${normalText}"
    read -s && echo


    #---------------------------------------------------begin stage two---------------------------------------------------#

    echo

    # query for trim usage
    echo -e "If you are installing to an SSD, you can enable trim. Beware, some SSD\nmanufacturers advise against the use of trim with their drives! The use of trim\nwith encryption also presents some security concerns in that, while it may not\nexpose encrypted data, it may expose information about encrypted data. If you\nare unsure, don't enable, and be sure to check your manufacturer\nrecommendations. Also, if you plan to use LVM snapshots, do not enable trim."
    read -p "Enable trim [y/N]: " trim
    doTrim() { [ "${trim,,}" == 'y' ] || return -1; }

    # mount stuff for chroot
    echo -n "Mounting the installed system ... "
    mount /dev/archlinux/root /mnt
    mount /dev/archlinux/home /mnt/home
    mount ${bootPart} /mnt/boot
    isEFI && mount ${efiPart} /mnt/boot/efi
    mount --bind /dev /mnt/dev
    mount --bind /run/lvm /mnt/run/lvm
    echo -e "${green}done${normalText}"

    # create crypttab entry
    echo -n "Creating /etc/crypttab entry ... "
    luksUUID="$(blkid | grep $luksPart | tr -d '"' | grep -oP "\bUUID=[0-9a-f\-]+")"
    echo -e "${cryptMapper}\t${luksUUID}\tnone\tluks" > /mnt/etc/crypttab
    chmod 600 /mnt/etc/crypttab
    echo -e "${green}done${normalText}"

    # enable trim if requested
    # trim implemented using instructions found at http://blog.neutrino.es/2013/howto-properly-activate-trim-for-your-ssd-on-linux-fstrim-lvm-and-dmcrypt/
    if doTrim; then
        echo -n "Enabling trim ... "
        # enable trim for LUKS
        sed -i 's/luks$/luks,discard/' /etc/crypttab

        # enable trim in LVM
        lineStr="$(grep -nP "issue_discards ?=" /etc/lvm/lvm.conf )"
        lineNum=$(cut -f1 -d: <<< "$lineStr")
        replaceText="$(cut -f2 -d: <<< "$lineStr" | tr -d '#' | sed 's/issue_discards.*/issue_discards = 1/')"
        sed -i "${lineNum}s/.*/$replaceText/" /etc/lvm/lvm.conf
        
        # enable weekly fstrim
        allParts="/ /boot /home $(isEFI && echo "/boot/efi")"
        cat << EOF > /etc/cron.weekly/dofstrim
    #! /bin/sh
    for mount in $allParts
    do
        fstrim \$mount
    done
    EOF
        chmod 755 /etc/cron.weekly/dofstrim
        echo -e "${green}done${normalText}"
    fi

    # chroot and update the boot files
    echo "Updating your boot files:"
    echo '#!/bin/bash
    mount -t proc proc /proc
    mount -t sysfs sys /sys
    mount -t devpts devpts /dev/pts
    update-initramfs -k all -c
    update-grub > /dev/null 2>&1' > /mnt/boot-update.sh
    chmod +x /mnt/boot-update.sh
    chroot /mnt "./boot-update.sh"
    rm /mnt/boot-update.sh

    # save some files to the installed users desktop
    user=$(cat /mnt/etc/passwd | grep "1000:1000" | cut -f1 -d:)
    dest=/mnt/home/$user/Desktop
    mkdir -p "$dest"

    # save a backup of the LUKS header
    cryptsetup luksHeaderBackup $luksPart --header-backup-file "$dest/LUKS.header"

    # save a copy of the README.html
    echo -e "<!DOCTYPE html>
    <html>
        <head>
            <title>LUKS Encryption</title>
            <style>
                html, body {
                    padding: 0;
                    margin: 0;
                    background-color: aliceblue;
                    background-image: url('data:image/png;base64,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');
                    font-family: sans-serif;
                }
                
                .container {
                    width: 60%;
                    min-width: 700px;
                    background: white;
                    border: 2px solid darkblue;
                    margin: auto;
                }
                
                .header {
                    font-size: 2em;
                    font-weight: bold;
                    background: darkblue;
                    color: white;
                    padding: 1em .75em;
                }
                
                .content {
                    padding: 1em;
                }
                
                .title {
                    margin-top: 1.5em;
                    font-size: .9em;
                    font-weight: bold;
                }
                
                .content p,ul {
                    font-size: .85em;
                    margin-left: .5em;
                    margin-right: .5em;
                }
                
                hr {
                    border-style: solid;
                    color: lightgray;
                }
                
                em {
                    color: brown;
                }
                
            </style>
        </head>
        <body>
            <div class='container'>
                <div class='header'>LUKS Encryption Information</div>
                <div class='content'>
                    <div>
                        Contents
                        <ul>
                            <li><a href='#about-luks'>About LUKS</a></li>
                            <li><a href='#action'>Before you do anything else</a></li>
                            <li><a href='#this-setup'>About this installation</a></li>
                            <li><a href='#passphrase-reset'>Changing a known or forgotten LUKS passphrase</a></li>
                            <li><a href='#reinstall'>Reinstall, preserving the home partition</a></li>
                        </ul>
                    </div>
                    <hr/>
                    <div class='section'><a name='about-luks' />
                        <div class='title'>About LUKS</div>
                        <p>LUKS stands for Linux Unified Key Setup. It is the standard for disk encryption in Linux. It can be used to encrypt an entire disk, a partition, or a file container. In the case of full disk encryption (FDE) on Ubuntu, the disk is typically partitioned into two (non-EFI installation) or three (EFI installation) separate partitions. The partitions needed for booting are not encrypted as they contain the binaries necessary for performing decryption. The last partition is encrypted, and then LVM logical volumes are created within that partition for root. To learn more about LUKS visit the <a href='https://gitlab.com/cryptsetup/cryptsetup'>LUKS homepage</a>.</p>
                    </div>
                    <div class='section'><a name='action' />
                        <div class='title'>Before you do anything else</div>
                        <p>If you're reading this file, then you have already noticed some additional files on your desktop that wouldn't typically be there after a fresh install. These files were created by the LUKS-guided-manual-partitioning script that you used to set up your encryption. You need to move some of these files to a secure location immediately and then delete them from your system.</p>
                        <ul>
                            <li>LUKS.key <em>(exists only if you created a key file)</em></li>
                            <li>LUKS.header</li>
                            <li>Change-LUKS-passphrase.sh</li>
                            <li>Reinstallation.sh</li>
                            <li>LUKS-README.html</li>
                        </ul>
                        <p>The LUKS.key file only exists if you opted to create a key file during setup. This file can be used to decrypt your system without a passphrase. There are tutorials online that document how this can be done, so I won't get into that here. At any rate, <em>anyone</em> who has a copy of this file will be able to decrypt your entire system! Guard it well!</p>
                        <p>The LUKS.header file is not as sensitive as some of the others since this is just the header information for your LUKS partition and can be easily generated without any special credentials. In the event that the LUKS header becomes corrupted, you can use this file to restore the headers. <em>Note that if you modify the key slots on your LUKS partition by changing or removing passphrases or key files, these headers may become invalid and a new copy of the LUKS partition header should be generated.</em></p>
                        <p>The Change-LUKS-passphrase.sh script exists to simplify changing your current decryption passphrase, or if you created a key file, to help you recover and create a new passphrase in the event that you forget your current passphrase. If you chose to create a key file, then it is embedded in this file which means that <em>anyone</em> who has a copy of this file will be able to decrypt your entire system! Guard it well! If you did not create a key file, this file is not sensitive.</p>
                        <p>The Reinstallation.sh exists to facilitate operating system reinstallation using the existing ecryption and partitions. If you chose to create a key file, then it is embedded in this file which means that <em>anyone</em> who has a copy of this file will be able to decrypt your entire system! Guard it well! If you did not create a key file, this file is not sensitive. This script enables you to perform a clean Ubuntu installation while keeping your /home partition intact and maintaining the existing encryption.</p>
                        <p>The LUKS-README.html file (this file you're reading) is not at all sensitive and can be left on this system, but you may want to keep a copy elsewhere in the event that you need to refer to it and are unable to boot into your system to open it.</p>
                        <p></p>
                    </div>
                    <div class='section'><a name='this-setup' />
                        <div class='title'>About this installation</div>
                        <p>The script you used to set up this encrypted installation configured everything mostly the same manner that the automated feature in the Ubuntu installer would have. The physical partitions are created as they would have been with the automated installer except that you were given the option of specifying custom sizes during setup. The encrypted partition itself uses a key size of 512 bytes rather than 256, and the hashing algorithm used is sha512 rather than sha256. The LUKS partition, once unlocked, contains an LVM physical volume that houses the root and home partitions. This is the same as what you would find with the automated installer except that the automated installer does not create a home partition, and of course, you were given the option of setting custom sizes for each of these partitions.</p>
                        <p>LUKS encryption allows for multiple decryption keys. Any saved passphrase or key file can be used to decrypt a LUKS encrypted device or file. If you created a key file, your system has exactly two keys.</p>
                        <ul>
                            <li>Key slot 0: contains the key file created <em>(empty if no key file was created)</em></li>
                            <li>Key slot 1: contains the LUKS passphrase you provided during setup</li>
                        </ul>
                        <p>Regardless of whether you created a key file or not, your LUKS passphrase is in key slot 1 (the second key slot). If you opted not to create a key file, <em>do not forget your LUKS passphrase!</em> Should you forget it, <em>everything</em> on your system will be forever lost.</p>
                        <p></p>
                    </div>
                    <div class='section'><a name='passphrase-reset' />
                        <div class='title'>Changing a known or forgotten LUKS passphrase</div>
                        <p>The Change-LUKS-passphrase.sh script is very handy. It can be used to change your LUKS passphrase, or assuming you created a key file, it can also be used to recover from a forgotten LUKS passphrase.</p>
                        <p>If you just want to change your LUKS passphrase, copy the Change-LUKS-passphrase.sh script back over to your computer and run it. If you did not create a key file during setup you'll be prompted to change your LUKS passphrase using your current passphrase. If you created a key file during setup, you will simply need to provide a new passphrase, and the key file will be used to bypass the need to enter the current passphrase.</p>
                        <p>In the event that you have forgotten your LUKS passphrase <em>and</em> you created a key file, fear not! Get a Live Ubuntu USB/DVD and boot from it, selecting the option to try Ubuntu without installing. Once you're at the desktop, simply copy the Change-LUKS-passphrase.sh script over and run it. In either case, you'll be prompted for a new LUKS passphrase. Upon entering a new passphrase, the embedded key file will be used to remove your old passphrase and add the new one. Then reboot and decrypt your system with the new passphrase you created.</p>
                    </div>
                    <div class='section'><a name='reinstall' />
                        <div class='title'>Reinstall, preserving the home partition</div>
                        <p>If you're looking to reinstall your system or just to perform a fresh install, preserving your home partition, it's possible!  Basically, the LUKS partition must be unlocked. Then the system must be installed (without formatting /home). Finally, /etc/crypttab needs to be created and the initramfs updated.</p>
                        <p>The Reinstallation.sh script that was generated and saved to your desktop does just this. Simply boot from your installation medium, copy over and execute the Reinstallation.sh script, and follow the prompts. When you finish, you should be able to boot into your newly installed system with all of your home partition files still intact.</p>
                    </div>
                </div>
            </div>
        </body>
    </html>" > "$dest/LUKS-README.html"

    # save a copy of the reinstallation script to the installed system
    cat << EOF > "$dest/Reinstallation.sh"
    #!/bin/bash
    # desc: unlock LUKS partition for reinstallation and fix boot files post reinstallation

    clear
    if [ "\$(whoami)" != "root" ]; then
        echo "Restarting with sudo"
        sudo bash \$0
        exit
    fi

    isEFI() {
        mount | grep -qi efi && return 0 || return 1
    }

    extractPayload() {
        header="#----------PAYLOAD----------#"
        startLine=\$(grep -P "^\$header" -n \$0 | cut -f1 -d:)
        startByte=\$(head -n \$startLine "\$0" | wc -c)
        dd if="\$0" bs=\$startByte skip=1 2>/dev/null | base64 -d > "\$keyfile" 2> /dev/null
        [ \$(du "\$keyfile" | cut -f1) -eq 0 ] && return 1 || return 0
    }

    hasKeyfile() {
        cryptsetup luksDump $luksPart | grep -q "Key Slot 0: ENABLED"
    }

    keyfile=/tmp/LUKS.key

    # decrypt LUKS partition
    echo -n "Decrypting LUKS partition ... "
    if hasKeyfile && extractPayload; then
        cryptsetup open $luksPart ${cryptMapper} -d "\$keyfile"
        echo -e "${green}done${normalText}"
    else
        echo "waiting for passphrase"
        read -sp "LUKS encryption passphrase: " luksPass && echo
        echo -n "\$luksPass" | cryptsetup open $luksPart ${cryptMapper} || exit
        echo "LUKS partition successfully decrypted"
    fi

    # backup existing crypttab
    echo -n "Backing up existing crypttab ... "
    while :
    do
        [ -e /dev/archlinux/root ] && break
        sleep .1
    done
    mount /dev/archlinux/root /mnt
    cp /mnt/etc/crypttab /tmp
    umount /mnt
    echo -e "${green}done${normalText}"

    # stage one complete; pause and wait for user to perform installation
    echo -e "\n\nAt this point, you should KEEP THIS WINDOW OPEN and start the installation \nprocess. When you reach the \"Installation type\" page, select \"Something else\" \nand continue to manual partition setup, selecting the option to format \npartitions when available (except /home).\n  ${bootPart} should be used as ext2 for /boot\n\$(isEFI && echo "  ${efiPart} should be used as EFI System Partition\n")  /dev/mapper/archlinux-home should be used as ext4 for /home (DO NOT FORMAT)\n  /dev/mapper/archlinux-root should be used as ext4 for /\n  $disk should be selected as the \"Device for boot loader installation\""
    echo
    read -sp "After installation, once you've chosen the option to continue testing, press    [Enter] in this window." && echo

    # mount stuff for chroot
    echo -n "Mounting the installed system ... "
    mount /dev/archlinux/root /mnt
    mount /dev/archlinux/home /mnt/home
    mount ${bootPart} /mnt/boot
    isEFI && mount ${efiPart} /mnt/boot/efi
    mount --bind /dev /mnt/dev
    mount --bind /run/lvm /mnt/run/lvm
    echo -e "${green}done${normalText}"

    # create crypttab entry
    echo -n "Restoring crypttab ... "
    mv /tmp/crypttab /mnt/etc/crypttab
    chmod 600 /mnt/etc/crypttab
    echo -e "${green}done${normalText}"

    # chroot and update the boot files
    echo "Updating your boot files:"
    echo '#!/bin/bash
    mount -t proc proc /proc
    mount -t sysfs sys /sys
    mount -t devpts devpts /dev/pts
    update-initramfs -k all -c
    update-grub > /dev/null 2>&1' > /mnt/boot-update.sh
    chmod +x /mnt/boot-update.sh
    chroot /mnt "./boot-update.sh"
    rm /mnt/boot-update.sh

    shred -uzn3 "\$keyfile" 2> /dev/null
    echo
    echo "All finished!"
    read -sp "Press [Enter] to reboot" && echo
    reboot

    exit
    #----------PAYLOAD----------#
    $(base64 "$keyfile" 2> /dev/null)
    EOF

    # save a copy of the passphrase change script to the desktop
    cat << EOF > "$dest/Change-LUKS-passphrase.sh"
    #!/bin/bash
    # desc: the function of this script is to change the LUKS passphrase, or in the event
    #   that a key file was created, to recover from a forgotten passphrase

    if [ "\$(whoami)" != "root" ]; then
        echo "Restarting with sudo"
        sudo bash \$0
        exit
    fi

    clear
    extractPayload() {
        header="#----------PAYLOAD----------#"
        startLine=\$(grep -P "^\$header" -n \$0 | cut -f1 -d:)
        startByte=\$(head -n \$startLine "\$0" | wc -c)
        dd if="\$0" bs=\$startByte skip=1 2>/dev/null | base64 -d > "\$keyfile" 2> /dev/null
        [ \$(du "\$keyfile" | cut -f1) -eq 0 ] && return 1 || return 0
    }

    hasKeyfile() {
        cryptsetup luksDump $luksPart | grep -q "Key Slot 0: ENABLED"
    }

    useExistingPassphrase() {
        echo -e "\nChanging LUKS passphrase using current passphrase..."
        cryptsetup luksChangeKey $luksPart -S 1
        exit
    }

    keyfile=/tmp/LUKS.key

    echo -n "Extracting decryption key from this script ... "
    if hasKeyfile && extractPayload; then
        echo -e "${green}done${normalText}"
    else
        echo -e "${red}failed${normalText}"
        useExistingPassphrase
    fi

    # get new passphrase from user
    while :
    do
        read -sp "New LUKS passphrase: " pwd && echo
        read -sp "Confirm passphrase: " confirmation && echo
        [ "\$pwd" == "\$confirmation" ] && break
        clear
        echo "passphrases did not match. Try again."
    done

    echo -n "Removing old LUKS passphrase ... "
    cryptsetup luksKillSlot $luksPart 1 -d "\$keyfile" && echo -e "${green}done${normalText}" || useExistingPassphrase
    echo -n "Adding new LUKS passphrase ... "
    echo -e "\$pwd\n\$pwd" | sudo cryptsetup luksAddKey $luksPart -d "\$keyfile"
    echo -e "${green}done${normalText}"
    shred -uzn3 "\$keyfile" 2> /dev/null

    read -sp "Finished! Press [Enter] to quit." && echo
    exit
    #----------PAYLOAD----------#
    $(base64 "$keyfile" 2> /dev/null)
    EOF

    # if one was created, save the LUKS keyfile to desktop of system user
    if hasKeyfile; then
        echo
        name=$(basename "$keyfile")
        mv "$keyfile" "$dest"
        echo -e "${yellow}${boldText}Your LUKS key file and a passphrase reset script have been saved in \n${dest/\/mnt/} on the installed system. Guard these files because \neither can be used to decrypt your system! \nFollowing your first boot, move these files to a secure location ASAP! ${normalText}"
    fi

    chmod 400 "$dest/"*
    chmod u+x "$dest/"*.sh
    chown -R 1000:1000 "$dest"

    echo
    echo -e "${green}All finished! ${normalText}"
    echo -e "After rebooting your system, you will be able to decrypt with the passphrase you\nprovided or the key file you saved."
    read -sp "Press [Enter] to continue" && echo
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
    printf "KEYMAP="${keymap}"" > /etc/vconsole.conf
    printf "EDITOR="${editor}"\nQT_QPA_PLATFORM="${qtplatform}"\nQT_QPA_PLATFORMTHEME="${qtplatformtheme}\nQT_PLUGIN_PATH=/usr/lib/qt/plugins"" >> /etc/enviroment
    printf "alias ron='xhost si:localuser:root'\nalias roff='xhost -si:localuser:root'\nalias ll='ls -ali --color=auto'" > ~/.bash_aliases
    printf "# Load aliases and profile variables\nif [[ -f /etc/profile ]]; then\n    source /etc/profile\nfi\nif [[ -f ~/.bash_aliases ]]; then\n    source ~/.bash_aliases\nfi\n# PS1='[\u@\h \W] \$ '\nPS1='\u@\h \W \$ '" > ~/.bashrc

    cpuCores=$(grep -c ^processor /proc/cpuinfo)
    sed -i 's/#MAKEFLAGS="-j2"/MAKEFLAGS="-j${cpuCores}g' /etc/makepkg.conf
    sed -i 's/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -T ${cpuCores} -z -)/g' /etc/makepkg.conf
    
    printf "net.ipv4.conf.default.rp_filter=1
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_redirects = 0
net.ipv4.conf.all.secure_redirects = 1
net.ipv6.conf.all.secure_redirects = 1" > /etc/sysctl.conf && sysctl -p -q &>/dev/null

    printf "${hostname}" > /etc/hostname
    printf "127.0.0.1   localhost\n::1  localhost" > /etc/hosts
    pacman -S networkmanager --noconfirm --needed

    printf "function update-grub {\n    sudo grub-mkconfig -o /boot/grub/grub.cfg\n}" /etc/profile.d/update-grub.sh
    printf "function update-initramfs {\n    sudo mkinitcpio -P\n}" /etc/profile.d/update-initramfs.sh
    source /etc/profile.d/update-grub.sh && source /etc/profile.d/update-initramfs.sh
    printf '#!/bin/bash

function mirror-alcatel {

    clear

    if ! source ~/.config/mirror-alcatel/main.conf &>/dev/null; then

        if [ ${deviceIp}="" ]; then
            read -p "There is no device IP established. Please type your device IP address: " input1
            deviceIp="${input1}"
        fi

        if [ ${internalDeviceName}="" ]; then
            read -p "There is no internal device name established. Please type a name: " input2
            internalDeviceName="${input2}"
        fi

        if [ ${deviceName}="" ]; then
            read -p "There is no device name established. Please type a name: " input3
            deviceName="${input3}"
            
            printf "[Settings]
deviceIp="${input1}"
internalDeviceName="${input2}"
deviceName="${input3}"" > ~/.config/mirror-alcatel/main.conf
        fi        
        else
            source ~/.config/mirror-alcatel/main.conf
    fi

    clear
    read -n1 -p ":: Make sure to enable developer tools, USB debugging and enable MTP, then press any key to continue..."

    echo -n ":: Starting ADB server... "
    adb start-server &>/dev/null && echo -e "done" || echo -e "failed"

    echo -n ":: Enabling device over TCP/IP... "
    adb tcpip 5555 &>/dev/null && echo -e "done" || echo -e "failed"

    read -n1 -p ":: Unplug the device now, then press any key to continue... "

    echo -n ":: Connecting to device ${internalDeviceName}... "
    adb connect ${deviceIp}:5555 &>/dev/null && echo -e "done" || echo -e "failed"

    echo -n ":: Connected to device: ${internalDeviceName}"
    scrcpy --always-on-top --window-title ${deviceName} &>/dev/null

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
            * ) echo ":: Invalid parameter, please type Yy or Nn instead.";;
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
    packagesArch="pacman-contrib qemu bridge-utils ovmf gedit bleachbit chrome-gnome-shell clamtk clamtk-gnome code fail2ban gimp adobe-source-han-{sans-cn-fonts,sans-tw-fonts,serif-cn-fonts,serif-tw-fonts} gnome-{backgrounds,screenshot,tweaks,terminal,control-center,keyring} libgnome-keyring gstreamer-vaapi intel-ucode libappindicator-{gtk2,gtk3} libreoffice libvdpau-va-gl lutris wine-staging giflib lib32-giflib libpng lib32-libpng libldap lib32-libldap gnutls lib32-gnutls mpg123 lib32-mpg123 openal lib32-openal v4l-utils lib32-v4l-utils libpulse lib32-libpulse libgpg-error lib32-libgpg-error alsa-plugins lib32-alsa-plugins alsa-lib lib32-alsa-lib libjpeg-turbo lib32-libjpeg-turbo sqlite lib32-sqlite libxcomposite lib32-libxcomposite libxinerama lib32-libgcrypt libgcrypt lib32-libxinerama ncurses lib32-ncurses opencl-icd-loader lib32-opencl-icd-loader libxslt lib32-libxslt libva lib32-libva gtk3 lib32-gtk3 gst-plugins-base-libs lib32-gst-plugins-base-libs vulkan-icd-loader lib32-vulkan-icd-loader mokutil nautilus neofetch papirus-icon-theme pcsx2 pulseaudio pulseaudio-{jack,bluetooth} steam telegram-desktop unrar unzip xdg-user-dirs apparmor gvfs-{mtp,google} cups hplip"
    packagesAur="brave-nightly-bin minecraft-launcher plata-theme-gnome psensor-git scrcpy whatsapp-for-linux"
    packagesAurEol="spotify"
    if [[ ! -f /usr/bin/yay ]]; then
        echo -ne "\n\n\n${red}${boldText}:: ERROR: Yay AUR Helper was not found on this system and it is being installed now. Please wait...${normalText} "
    aurSetup &>/dev/null && echo -e "${green}done${normalText}" || echo -e "${red}failed"
    fi
    yay -Syyy && yay -Syu --noconfirm --needed && yay -S ${packagesArch} ${packagesAur} ${packagesAurEol} --noconfirm --needed &>/dev/null
    freshclam &>/dev/null && systemctl enable --now clamav-freshclam
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
done" > /etc/clamav/detected.sh && aa-complain clamd &>/dev/null &>/dev/null && sed -i 's/#User clamav/User root/g' /etc/clamav/clamd.conf && sed -i 's/#LocalSocket /run/clamav/clamd.ctl/LocalSocket /run/clamav/clamd.ctl/g' /etc/clamav/clamd.conf && sudo systemctl restart clamav-daemon
    xdg-user-dirs-update
    sed -i 's/ON_BOOT=start/ON_BOOT=ignore/g' /usr/lib/libvirt/libvirt-guests.sh && sed -i 's/ON_SHUTDOWN=suspend/ON_SHUTDOWN=shutdown/g' /usr/lib/libvirt/libvirt-guests.sh && systemctl enable --now libvirt-guests
}

# Initialize script functions in this order
welcome
root
diskPartitioning
baseSetup
extrasSetup

