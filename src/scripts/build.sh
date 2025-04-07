#!/bin/bash

# Echo each command
set -x

# Flag to enable integration test mode [1]. Disabled by default.
#
# Images built with this flag include an SSH server, a simple netcat TCP query server,
# and other changes to support Rescuezilla's automated end-to-end integration test suite [1].
#
# The flag is very useful for development and debugging too.  The SSH server is handy, as is
# the lower compression ratio on the squashfs root filesystem (for faster builds during development).
#
# This flag is obviously never enabled in production builds, and users are able to easily
# audit that no SSH server or netcat TCP query server is ever installed.
#
# [1] See src/integration-test/README.md for more information.
#
IS_INTEGRATION_TEST="${IS_INTEGRATION_TEST=:false}"

# Set the default base operating system, using the Ubuntu release's shortened code name [1].
# [1] https://wiki.ubuntu.com/Releases
CODENAME="${CODENAME:-INVALID}"

# Sets CPU architecture using Ubuntu designation [1]
# [1] https://help.ubuntu.com/lts/installation-guide/armhf/ch02s01.html
ARCH="${ARCH:-INVALID}"

# One-higher than directory containing this build script
BASEDIR="$(git rev-parse --show-toplevel)"

RESCUEZILLA_ISO_FILENAME=rescuezilla.$ARCH.$CODENAME.iso
# The base build directory is "build/", unless overridden by an environment variable
BASE_BUILD_DIRECTORY=${BASE_BUILD_DIRECTORY:-build/${BASE_BUILD_DIRECTORY}}
BUILD_DIRECTORY=${BUILD_DIRECTORY:-${BASE_BUILD_DIRECTORY}/${CODENAME}.${ARCH}}
mkdir -p "$BUILD_DIRECTORY/chroot"
# Ensure the build directory is an absolute path
BUILD_DIRECTORY=$( readlink -f "$BUILD_DIRECTORY" )
PKG_CACHE_DIRECTORY=${PKG_CACHE_DIRECTORY:-pkg.cache}
# Use a recent version of debootstrap from git
DEBOOTSTRAP_SCRIPT_DIRECTORY=${BASEDIR}/src/third-party/debootstrap
DEBOOTSTRAP_CACHE_DIRECTORY=debootstrap.$CODENAME.$ARCH
APT_PKG_CACHE_DIRECTORY=var.cache.apt.archives.$CODENAME.$ARCH
APT_INDEX_CACHE_DIRECTORY=var.lib.apt.lists.$CODENAME.$ARCH

# If the current commit is not tagged, the version number from `git
# describe--tags` is X.Y.Z-abc-gGITSHA-dirty, where X.Y.Z is the previous tag,
# 'abc' is the number of commits since that tag, gGITSHA is the git sha
# prepended by a 'g', and -dirty is present if the working tree has been
# modified.
#
# Note: the --match is a glob, not a regex.
VERSION_STRING=$(git describe --tags --match="[0-9].[0-9]*" --dirty)

# Date of current git commit in colon-less ISO 8601 format (2013-04-01T130102)
GIT_COMMIT_DATE=$(date +"%Y-%m-%dT%H%M%S" --date=@$(git show --no-patch --format=%ct HEAD))

if [[ $EUID -ne 0 ]]; then
   echo "This script must be run as root. Please consult build instructions." 
   exit 1
fi

if [ "$CODENAME" = "INVALID" ] || [ "$ARCH" = "INVALID" ]; then
  echo "The variable CODENAME=${CODENAME} or ARCH=${ARCH} was not set correctly. Are you using the Makefile? Please consult build instructions."
  exit 1
fi

# Disable the debootstrap GPG validation for Ubuntu 18.04 (Bionic) after its public key
# failed to validate on the Docker build environment container for an unclear reason.
# See [1] for full write-up.
#
# [1] https://github.com/rescuezilla/rescuezilla/issues/538
GPG_CHECK_OPTS=""
if [ "$CODENAME" = "bionic" ]; then
    GPG_CHECK_OPTS="--no-check-gpg"
fi

# debootstrap part 1/2: If package cache doesn't exist, download the packages
# used in a base Debian system into the package cache directory [1]
#
# [1] https://unix.stackexchange.com/a/397966
if [ ! -d "$PKG_CACHE_DIRECTORY/$DEBOOTSTRAP_CACHE_DIRECTORY" ] ; then
    mkdir -p $PKG_CACHE_DIRECTORY/$DEBOOTSTRAP_CACHE_DIRECTORY
    # Selecting a geographically closer APT mirror may increase network transfer rates.
    #
    # Note: After the support window for a specific release ends, the packages are moved to the 'old-releases' 
    # URL [1], which means substitution becomes mandatory in-order to build older releases from scratch.
    #
    # [1] http://old-releases.ubuntu.com/ubuntu
    TARGET_FOLDER=`readlink -f $PKG_CACHE_DIRECTORY/$DEBOOTSTRAP_CACHE_DIRECTORY`
    pushd ${DEBOOTSTRAP_SCRIPT_DIRECTORY}
    #DEBOOTSTRAP_DIR=${DEBOOTSTRAP_SCRIPT_DIRECTORY} ./debootstrap ${GPG_CHECK_OPTS} --arch=$ARCH --foreign $CODENAME $TARGET_FOLDER http://archive.ubuntu.com/ubuntu/
    DEBOOTSTRAP_DIR=${DEBOOTSTRAP_SCRIPT_DIRECTORY} ./debootstrap ${GPG_CHECK_OPTS} --arch=$ARCH --foreign $CODENAME $TARGET_FOLDER  http://ports.ubuntu.com/ubuntu-ports/
    RET=$?
    popd
    if [[ $RET -ne 0 ]]; then
        echo "debootstrap part 1/2 failed. This may occur if you're using an older version of deboostrap"
        echo "that doesn't have a script for \"$CODENAME\". Please consult the build instructions." 
        exit 1
    fi
fi

echo "Copy debootstrap package cache"
rsync --archive "$PKG_CACHE_DIRECTORY/$DEBOOTSTRAP_CACHE_DIRECTORY/" "$BUILD_DIRECTORY/chroot/"
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "Failed to copy"
    exit 1
fi
 
# debootstrap part 2/2: Bootstrap a Debian root filesystem based on cached packages directory (part 2/2)
chroot $BUILD_DIRECTORY/chroot/ /bin/bash -c "DEBOOTSTRAP_DIR=\"debootstrap\" ./debootstrap/debootstrap --second-stage ${GPG_CHECK_OPTS}"
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "debootstrap part 2/2 failed. This may occur if the package cache ($PKG_CACHE_DIRECTORY/$DEBOOTSTRAP_CACHE_DIRECTORY/)"
    echo "exists but is not fully populated. If so, deleting this directory might help. Please consult the build instructions." 
    exit 1
fi

# Ensures tmp directory has correct mode, including sticky-bit
chmod 1777 "$BUILD_DIRECTORY/chroot/tmp/"

# Copy cached apt packages, if present, to reduce need to download packages from internet
if [ -d "$PKG_CACHE_DIRECTORY/$APT_PKG_CACHE_DIRECTORY/" ] ; then
    mkdir -p "$BUILD_DIRECTORY/chroot/var/cache/apt/archives/"
    echo "Copy apt package cache"
    rsync --archive "$PKG_CACHE_DIRECTORY/$APT_PKG_CACHE_DIRECTORY/" "$BUILD_DIRECTORY/chroot/var/cache/apt/archives"
    RET=$?
    if [[ $RET -ne 0 ]]; then
        echo "Failed to copy"
        exit 1
    fi
fi

# Copy cached apt indexes, if present, to a temporary directory, to reduce need to download packages from internet.
if [ -d "$PKG_CACHE_DIRECTORY/$APT_INDEX_CACHE_DIRECTORY/" ] ; then
    mkdir -p "$BUILD_DIRECTORY/chroot/var/lib/apt/"
    echo "Copy apt index cache"
    rsync --archive "$PKG_CACHE_DIRECTORY/$APT_INDEX_CACHE_DIRECTORY/" "$BUILD_DIRECTORY/chroot/var/lib/apt/lists.cache"
    RET=$?
    if [[ $RET -ne 0 ]]; then
        echo "Failed to copy"
        exit 1
    fi
fi

cd "$BUILD_DIRECTORY"
# Enter chroot, and launch next stage of script
mount --bind /dev chroot/dev

# Copy files related to network connectivity
cp /etc/hosts chroot/etc/hosts
cp /etc/resolv.conf chroot/etc/resolv.conf

# Copy the CHANGELOG
rsync --archive "$BASEDIR/CHANGELOG" "$BUILD_DIRECTORY/chroot/usr/share/rescuezilla/"
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "Failed to copy"
    exit 1
fi

# Synchronize apt package manager configuration files
rsync --archive "$BASEDIR/src/livecd/chroot/etc/apt/" "$BUILD_DIRECTORY/chroot/etc/apt"
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "Failed to copy"
    exit 1
fi

if  [ "$IS_INTEGRATION_TEST" == "true" ]; then
    LINUX_QUERY_SERVER_INSTALLER="$BASEDIR/src/integration-test/scripts/install-linux-query-tcp-server.sh"
    rsync --archive "$LINUX_QUERY_SERVER_INSTALLER" "$BUILD_DIRECTORY/chroot/"
    RET=$?
    if [[ $RET -ne 0 ]]; then
        echo "Failed to copy"
        exit 1
    fi
fi

# Renames the apt-preferences file to ensure backports and proposed
# repositories for the desired code name are never automatically selected.
pushd "chroot/etc/apt/preferences.d/"
mv "89_CODENAME_SUBSTITUTE-backports_default" "89_$CODENAME-backports_default"
mv "90_CODENAME_SUBSTITUTE-proposed_default" "90_$CODENAME-proposed_default"
popd

mv "chroot/etc/apt/sources.list.d/mozillateam-ubuntu-ppa-CODENAME_SUBSTITUTE.list" "chroot/etc/apt/sources.list.d/mozillateam-ubuntu-ppa-$CODENAME.list"

pushd "chroot/etc/apt/sources.list.d/"
# Since Ubuntu 22.04 (Jammy) firefox packaged as snap, which is not easily installed in a chroot
# [1] https://bugs.launchpad.net/snappy/+bug/1609903
mv "mozillateam-ubuntu-ppa-CODENAME_SUBSTITUTE.list" "mozillateam-ubuntu-ppa-CODENAME_SUBSTITUTE.list"
popd
APT_CONFIG_FILES=(
    "chroot/etc/apt/preferences.d/89_$CODENAME-backports_default"
    "chroot/etc/apt/preferences.d/90_$CODENAME-proposed_default"
    "chroot/etc/apt/sources.list.d/mozillateam-ubuntu-ppa-$CODENAME.list"
    "chroot/etc/apt/sources.list"
)
# Substitute Ubuntu code name into relevant apt configuration files
for apt_config_file in "${APT_CONFIG_FILES[@]}"; do
  sed --in-place s/CODENAME_SUBSTITUTE/$CODENAME/g $apt_config_file
done

cp "$BASEDIR/src/scripts/chroot-steps-part-1.sh" "$BASEDIR/src/scripts/chroot-steps-part-2.sh" chroot
# Launch first stage chroot. In other words, run commands within the root filesystem
# that is being constructed using binaries from within that root filesystem.
chroot chroot/ /bin/bash -c "IS_INTEGRATION_TEST=$IS_INTEGRATION_TEST ARCH=$ARCH CODENAME=$CODENAME /chroot-steps-part-1.sh"
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to execute chroot steps part 1."
    exit 1
fi

rm "$BUILD_DIRECTORY/chroot/install-linux-query-tcp-server.sh"

cd "$BASEDIR"
# Copy the source FHS filesystem tree onto the build's chroot FHS tree, overwriting the base files where conflicts occur.
# The only exception the apt package manager configuration files which have already been copied above.
rsync --archive --exclude "chroot/etc/apt" src/livecd/ "$BUILD_DIRECTORY"
RET=$?
if [[ $RET -ne 0 ]]; then
    echo "Failed to copy"
    exit 1
fi

cp --archive $BUILD_DIRECTORY/../*.deb "$BUILD_DIRECTORY/chroot/"
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to copy Rescuezilla deb packages."
    exit 1
fi

# Create desktop icon shortcuts
ln -s /usr/share/applications/rescuezilla.desktop "$BUILD_DIRECTORY/chroot/home/ubuntu/Desktop/rescuezilla.desktop"
ln -s /usr/share/applications/org.xfce.mousepad.desktop "$BUILD_DIRECTORY/chroot/home/ubuntu/Desktop/mousepad.desktop"
ln -s /usr/share/applications/gparted.desktop "$BUILD_DIRECTORY/chroot/home/ubuntu/Desktop/gparted.desktop"

if  [ "$CODENAME" == "oracular" ]; then
  # HACK: Remove the Firefox desktop shortcut that this build system copied in earlier
  # as Oracular doesn't have a mozillateam PPA based Firefox unlike earlier releases
  rm "$BUILD_DIRECTORY/chroot/home/ubuntu/Desktop/firefox.desktop"
fi

# Process GRUB locale files
pushd "$BUILD_DIRECTORY/image/boot/grub/locale/"
for grub_po_file in *.po; do
        if [[ ! -f "$grub_po_file" ]]; then
                echo "Warning: $grub_po_file translation does not exist. Skipping."
        else
                # Remove .po extension from filename
                lang=$(echo "$grub_po_file" | cut -f 1 -d '.')
                echo "Converting language translation file: $BUILD_DIRECTORY/image/boot/grub/locale/$grub_po_file to $lang.mo" 
                msgfmt --output-file="$lang.mo" "$grub_po_file"
                if [[ $? -ne 0 ]]; then
                        echo "Error: Unable to convert GRUB bootloader configuration $lang translation from text-based po format to binary mo format."
                        exit 1
                fi
                # Remove unused *.po file
                rm "$grub_po_file"
        fi
done
popd

# Most end-users will not understand the terms i386 and AMD64.
MEMORY_BUS_WIDTH=""
if  [ "$ARCH" == "i386" ]; then
  MEMORY_BUS_WIDTH="32bit"
elif  [ "$ARCH" == "amd64" ]; then
  MEMORY_BUS_WIDTH="64bit"
elif  [ "$ARCH" == "arm64" ]; then
  MEMORY_BUS_WIDTH="64bit"
else
    echo "Warning: unknown register width $ARCH"
fi

SUBSTITUTIONS=(
    # GRUB boot menu 
    "$BUILD_DIRECTORY/image/boot/grub/theme/theme.txt"
    # Firefox browser homepage query-string, to be able to provide a "You are using an old version. Please update."
    # message when users open the web browser with a (inevitably) decades old version.
    "$BUILD_DIRECTORY/chroot/usr/lib/firefox/distribution/policies.json"
)
for file in "${SUBSTITUTIONS[@]}"; do
    # Substitute version into file
    sed --in-place s/VERSION-SUBSTITUTED-BY-BUILD-SCRIPT/${VERSION_STRING}/g $file
    # Substitute CPU architecture description into file
    sed --in-place s/ARCH-SUBSTITUTED-BY-BUILD-SCRIPT/${ARCH}/g $file
    # Substitute CPU human-readable CPU architecture into file
    sed --in-place s/MEMORY-BUS-WIDTH-SUBSTITUTED-BY-BUILD-SCRIPT/${MEMORY_BUS_WIDTH}/g $file
    # Substitute date
    sed --in-place s/GIT-COMMIT-DATE-SUBSTITUTED-BY-BUILD-SCRIPT/${GIT_COMMIT_DATE}/g $file
done

# Enter chroot again
cd "$BUILD_DIRECTORY"
chroot chroot/ /bin/bash /chroot-steps-part-2.sh
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to execute chroot steps part 2."
    exit 1
fi

rsync --archive chroot/var.cache.apt.archives/ "$BASEDIR/$PKG_CACHE_DIRECTORY/$APT_PKG_CACHE_DIRECTORY"
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to copy."
    exit 1
fi

rm -rf chroot/var.cache.apt.archives
rsync --archive chroot/var.lib.apt.lists/ "$BASEDIR/$PKG_CACHE_DIRECTORY/$APT_INDEX_CACHE_DIRECTORY"
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to copy."
    exit 1
fi
rm -rf chroot/var.lib.apt.lists

umount -lf chroot/dev/
rm chroot/root/.bash_history
rm chroot/chroot-steps-part-1.sh chroot/chroot-steps-part-2.sh

mkdir -p image/casper image/memtest
cp chroot/boot/vmlinuz-*-generic image/casper/vmlinuz
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to copy vmlinuz image."
    exit 1
fi
# Ensures compressed Linux kernel image is readable during the MD5 checksum at boot
chmod 644 image/casper/vmlinuz

cp chroot/boot/initrd.img-*-generic image/casper/initrd.lz
if [[ $? -ne 0 ]]; then
    echo "Error: Failed to copy initrd image."
    exit 1
fi

# Create manifest
chroot chroot dpkg-query -W --showformat='${Package} ${Version}\n' > image/casper/filesystem.manifest
cp -v image/casper/filesystem.manifest image/casper/filesystem.manifest-desktop
REMOVE=("ubiquity"
        "ubiquity-frontend-gtk"
        "ubiquity-frontend-kde"
        "casper"
        "live-initramfs"
        "user-setup"
        "discover"
        "xresprobe"
        "os-prober"
        "libdebian-installer4"
)
for remove in "${REMOVE[@]}"
do
     sed -i "/${remove}/d" image/casper/filesystem.manifest-desktop
done

cat << EOF > image/README.diskdefines
#define DISKNAME Rescuezilla
#define TYPE binary
#define TYPEbinary 1
#define ARCH $ARCH
#define ARCH$ARCH 1
#define DISKNUM 1
#define DISKNUM1 1
#define TOTALNUM 0
#define TOTALNUM0 1
EOF

touch image/ubuntu
mkdir image/.disk
cd image/.disk
touch base_installable
echo "full_cd/single" > cd_type
echo "Ubuntu Remix" > info
echo "https://rescuezilla.com" > release_notes_url
cd ../..

rm -rf image/casper/filesystem.squashfs "$RESCUEZILLA_ISO_FILENAME"

echo "Compressing squashfs using zstandard (rather than default gzip)."
if  [ "$IS_INTEGRATION_TEST" == "true" ]; then
    echo "Using lowest possible compression level of 1 to speed up compression for debug builds." 
    COMPRESSION_LEVEL=1
else
    echo "Using max compression level of 19. The compression time is greatly increased, but the decompression time "
    echo "is the same as gzip (though uses more memory). The benefit is the compression ratio is improved over gzip."
    COMPRESSION_LEVEL=19
fi

mksquashfs chroot image/casper/filesystem.squashfs -comp zstd -b 1M -Xcompression-level "${COMPRESSION_LEVEL}" -e boot -e /sys
printf $(sudo du -sx --block-size=1 chroot | cut -f1) > image/casper/filesystem.size
cd image

# Create EFI directory structure for ARM64
# Modified for ARM64 - Using ARM64-specific files
if [ "$ARCH" == "arm64" ]; then
    mkdir --parents "$BUILD_DIRECTORY/image/EFI/BOOT/"
    
    # Check if required ARM64 UEFI bootloader files are available
    if [ -f "/usr/lib/grub/arm64-efi/grub.efi" ]; then
        cp /usr/lib/grub/arm64-efi/grub.efi "$BUILD_DIRECTORY/image/EFI/BOOT/BOOTAA64.EFI"
    else
        echo "Warning: ARM64 UEFI bootloader not found. Installing grub-efi-arm64 package to get required files."
        apt-get update && apt-get install -y grub-efi-arm64
        if [ -f "/usr/lib/grub/arm64-efi/grub.efi" ]; then
            cp /usr/lib/grub/arm64-efi/grub.efi "$BUILD_DIRECTORY/image/EFI/BOOT/BOOTAA64.EFI"
        else
            echo "Error: Could not find ARM64 UEFI bootloader."
            exit 1
        fi
    fi
    
    # Copy ARM64 GRUB modules if available
    if [ -d "/usr/lib/grub/arm64-efi" ]; then
        cp -r /usr/lib/grub/arm64-efi "$BUILD_DIRECTORY/image/boot/grub/"
    fi
    
    # Create GRUB font directory
    mkdir -p "$BUILD_DIRECTORY/image/boot/grub/fonts"
    
    # Deploy unicode font
    cp /usr/share/grub/unicode.pf2 "$BUILD_DIRECTORY/image/boot/grub/fonts"
    
    # Create ESP image for ARM64
    ESP_FAT_IMAGE="$BUILD_DIRECTORY/image/boot/esp.img"
    rm -f "$ESP_FAT_IMAGE"
    dd if=/dev/zero of="$ESP_FAT_IMAGE" count=6 bs=1M
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to create blank file for EFI System Partition."
        exit 1
    fi
    
    mkfs.msdos "$ESP_FAT_IMAGE"
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to create MSDOS filesystem for EFI System Partition (ESP)."
        exit 1
    fi
    
    # Pack EFI directory into ESP image
    mcopy -s -i "$ESP_FAT_IMAGE" "$BUILD_DIRECTORY/image/EFI" ::
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to pack EFI System Partition directory structure into FAT filesystem."
        exit 1
    fi
else
    # Original x86 code (will not be executed for ARM64)
    mkdir --parents "$BUILD_DIRECTORY/image/EFI/BOOT/"
    cp /usr/lib/shim/shimx64.efi.signed "$BUILD_DIRECTORY/image/EFI/BOOT/BOOTx64.EFI"
    cp /usr/lib/grub/x86_64-efi-signed/grubx64.efi.signed "$BUILD_DIRECTORY/image/EFI/BOOT/grubx64.efi"
    cp -r /usr/lib/grub/x86_64-efi "$BUILD_DIRECTORY/image/boot/grub/"
    mkdir "$BUILD_DIRECTORY/image/boot/grub/fonts"
    cp /usr/share/grub/unicode.pf2 "$BUILD_DIRECTORY/image/boot/grub/fonts"
    cp /usr/lib/grub/i386-efi/monolithic/grubia32.efi "$BUILD_DIRECTORY/image/EFI/BOOT/BOOTIA32.EFI"
    cp -r /usr/lib/grub/i386-efi "$BUILD_DIRECTORY/image/boot/grub/"
    cp -r /usr/lib/grub/i386-pc "$BUILD_DIRECTORY/image/boot/grub/"
    
    ESP_FAT_IMAGE="$BUILD_DIRECTORY/image/boot/esp.img"
    rm "$ESP_FAT_IMAGE"
    dd if=/dev/zero of="$ESP_FAT_IMAGE" count=6 bs=1M
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to create blank file for EFI System Partition."
        exit 1
    fi
    
    mkfs.msdos "$ESP_FAT_IMAGE"
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to create MSDOS filesystem for EFI System Partition (ESP)."
        exit 1
    fi
    
    mcopy -s -i "$ESP_FAT_IMAGE" "$BUILD_DIRECTORY/image/EFI" ::
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to pack EFI System Partition directory structure into FAT filesystem."
        exit 1
    fi
    
    grub-mkimage --format i386-pc-eltorito --output "$BUILD_DIRECTORY/image/boot/grub/grub.eltorito.bootstrap.img" --compression auto --prefix /boot/grub boot linux search normal configfile part_gpt fat iso9660 biosdisk test keystatus gfxmenu regexp probe efiemu all_video gfxterm font echo read ls cat png jpeg halt reboot part_msdos biosdisk
    if [[ $? -ne 0 ]]; then
        echo "Error: Failed to create the GRUB bootstrap image required for El Torito CD-ROM boot."
        exit 1
    fi
fi

# Generate md5sum for files in the image
find . -type f -print0 | xargs -0 md5sum | grep -v "./md5sum.txt" > md5sum.txt

# Create ISO image for ARM64 (simplified method without El Torito boot)
if [ "$ARCH" == "arm64" ]; then
    xorrisofs_args=(
        # Output image path
        --output "$BUILD_DIRECTORY/$RESCUEZILLA_ISO_FILENAME"
        # Set filesystem volume ID
        --volid "Rescuezilla"
        # Enable Rock Ridge and set permissions
        -rational-rock
        # Enable Joliet
        -joliet
        # Allow up to 31 characters in ISO file names
        -full-iso9660-filenames
        # For ARM64, use simpler EFI boot method
        --efi-boot "boot/esp.img"
        # Expose ESP image in GPT
        -efi-boot-part --efi-boot-image
        # Use contents of the specified directory as the ISO filesystem root
        "$BUILD_DIRECTORY/image/"
    )
    
    # Create ISO image for ARM64
    xorrisofs "${xorrisofs_args[@]}"
else
    # Original x86 ISO creation code
    xorrisofs_args=(
        --output "$BUILD_DIRECTORY/$RESCUEZILLA_ISO_FILENAME"
        --volid "Rescuezilla"
        -rational-rock
        -joliet
        -full-iso9660-filenames
        --grub2-mbr /usr/lib/grub/i386-pc/boot_hybrid.img
        -eltorito-boot boot/grub/grub.eltorito.bootstrap.img
        --grub2-boot-info
        -no-emul-boot
        -eltorito-catalog boot/boot.cat
        -boot-load-size 4
        -boot-info-table
        --efi-boot "boot/esp.img"
        -efi-boot-part --efi-boot-image
        "$BUILD_DIRECTORY/image/"
    )
    
    # Create ISO image (part 1/4)
    xorrisofs "${xorrisofs_args[@]}"
    
    # Extract from the ISO image the El Torito boot image (part 2/4)
    TEMP_MOUNT_DIR=$(mktemp --directory --suffix $RESCUEZILLA_ISO_FILENAME.temp.mount.dir)
    mount "$BUILD_DIRECTORY/$RESCUEZILLA_ISO_FILENAME" "$TEMP_MOUNT_DIR"
    cp "$TEMP_MOUNT_DIR/boot/grub/grub.eltorito.bootstrap.img" "$BUILD_DIRECTORY/image/boot/grub/grub.eltorito.bootstrap.img"
    umount $TEMP_MOUNT_DIR
    rmdir $TEMP_MOUNT_DIR
    
    # Generate an md5sum of all files (part 3/4)
    find . -type f -print0 | xargs -0 md5sum | grep -v "./md5sum.txt" > md5sum.txt
    
    # Create ISO image (part 4/4)
    xorrisofs "${xorrisofs_args[@]}"
fi

cd "$BUILD_DIRECTORY"
mv "$BUILD_DIRECTORY/$RESCUEZILLA_ISO_FILENAME" ../

# TODO: Evaluate the "Errata" sections of the Redo Backup and Recovery
# TODO: Sourceforge Wiki, and determine if the build scripts need modification.
