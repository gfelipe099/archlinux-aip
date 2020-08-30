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

    pacman -Sy && pacman -S reflector
    reflector --country ${country} --sort rate --save /etc/pacman.d/mirrorlist

    sed -i 's/#[multilib]
#Include = /etc/pacman.d/mirrorlist/[multilib]
Include = /etc/pacman.d/mirrorlist/g' /etc/pacman.conf
sed -i 's/#RemoteFileSigLevel = Required/RemoteFileSigLevel = Required/g' /etc/ pacman.conf

    ln -sf /usr/share/zoneinfo/${region}/${city} /etc/localtime
    hwclock --systohc

    sed -i 's/#${lang}/${lang}/g' /etc/locale.gen
    locale-gen

    printf 'LANG=${lang}' > /etc/locale.conf
    printf 'KEYMAP=${keymap)' > /etc/vconsole.conf
    printf 'export EDITOR=${editor}\nQT_QPA_PLATFORM=${qtplatform}\nQT_QPA_PLATFORMTHEME=${qtplatformtheme}' >> /etc/enviroment
    printf 'alias ron='xhost si:localuser:root'\nalias roff='xhost -si:localuser:root'\nalias ll='ls -ali --color=auto'' > ~/.bash_aliases
    printf '# Load aliases and profile variables\nif [[ -f /etc/profile ]]; then\n    source /etc/profile\nfi\nif [[ -f ~/.bash_aliases ]]; then\n    source ~/.bash_aliases\nfi\n# PS1='[\u@\h \W] \$ '\nPS1='\u@\h \W \$ '' > ~/.bashrc

    cpuCores=$(grep -c ^processor /proc/cpuinfo)
    sed -i 's/#MAKEFLAGS="-j2"/MAKEFLAGS="-j${cpuCores}g' /etc/makepkg.conf
    sed -i 's/COMPRESSXZ=(xz -c -z -)/COMPRESSXZ=(xz -c -T ${cpuCores} -z -)/g' /etc/makepkg.conf

    printf '${hostname}' > /etc/hostname
    printf '127.0.0.1   localhost\n::1  localhost' > /etc/hosts
    pacman -S networkmanager --noconfirm --needed

    printf 'function update-grub {\n    sudo grub-mkconfig -o /boot/grub/grub.cfg\n}' /etc/profile.d/update-grub.sh
    printf 'function update-initramfs {\n    sudo mkinitcpio -P\n}' /etc/profile.d/update-initramfs.sh
    source /etc/profile.d/update-grub.sh && source /etc/profile.d/update-initramfs.sh
    sudo pacman -S grub --noconfirm --needed
    grub-install --target=x86_64-efi --efi-directory=/boot/efi --bootloader-id=archlinux
    update-grub
    update-initramfs

    echo -e "\n:: Please type in a password for the root user"
    passwd root

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
    pacman -S git --noconfirm --needed &>/dev/null
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
    packagesArch="pacman-contrib qemu bridge-utils ovmf bleachbit gedit bleachbit chrome-gnome-shell clamtk code fail2ban firefox gimp adobe-source-han-{sans-cn-fonts,sans-tw-fonts,serif-cn-fonts,serif-tw-fonts} gnome-{backgrounds,screenshot,tweaks,terminal,control-center} gstreamer-vaapi intel-ucode libappindicator-{gtk2,gtk3} libreoffice libvdpau-va-gl lutris mokutil nautilus neofetch papirus-icon-theme pcsx2 pulseaudio pulseaudio-{jack,bluetooth} steam telegram-desktop unrar xdg-user-dirs"
    packagesAur="google-chrome minecraft-launcher plata-theme-gnome psensor-git"
    packagesAurEol="spotify"
    if [[ ! -f /usr/bin/yay ]]; then
        echo -e "\n\n\n${red}${boldText}:: ERROR: Yay AUR Helper was not found on this system and it is being installed now. Please wait...${normalText}\n"
        aurSetup
    fi
    yay -Syu --noconfirm && yay -S ${packagesArch} ${packagesAur} ${packagesAurEol} --noconfirm --needed
    xdg-user-dirs-update
}

# Initialize script functions in this order
welcome
root
diskPartitioning
baseSetup
extrasSetup