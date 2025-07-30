#!/bin/bash

set -x

# Non-interactive apt operations
export DEBIAN_FRONTEND=noninteractive

cd /

# 备份 partclone.xfs
echo "Making backup of Ubuntu repository partclone.xfs binary before installing newer partclone. See #367"
if [ -f /usr/sbin/partclone.xfs ]; then
    cp -f /usr/sbin/partclone.xfs /partclone.xfs.backup
fi

# 清理可能存在的冲突包
echo "Removing existing conflicting packages..."
apt-get remove --purge -y partclone || true
apt-get autoremove --purge -y || true

# 安装 rescuezilla 主包
if [ -f /rescuezilla*deb ]; then
    if ! gdebi --non-interactive /rescuezilla*deb; then
        echo "Trying force install with dpkg..."
        dpkg -i --force-overwrite --force-depends /rescuezilla*deb
        apt-get install -f -y
    fi
fi
rm -f /rescuezilla.*deb

# 安装其他依赖包
for f in /*.deb; do
    if [ -f "$f" ]; then
        echo "Installing $f..."
        if ! gdebi --non-interactive "$f"; then
            echo "Trying force install with dpkg..."
            dpkg -i --force-overwrite --force-depends "$f"
            apt-get install -f -y
        fi
        dpkg -c "$f"
    fi
done

# Extra validation for the Image Explorer (beta)'s underlying app, in case
# something went wrong in its relatively complex build environment.
if [[ ! -f "/usr/local/bin/partclone-nbd" ]]; then
    echo "Error: failed to find partclone-nbd binary in expected location"
fi

# Delete the now-installed deb files from the chroot filesystem
rm /*.deb

# 恢复 partclone.xfs 备份
echo "Deploying Ubuntu repository partclone.xfs binary after installing newer partclone. See #367"
if [ -f /partclone.xfs.backup ]; then
    mv /partclone.xfs.backup /usr/sbin/partclone.xfs
    chmod 755 /usr/sbin/partclone.xfs
fi

# 配置系统设置
mkdir -p /root/.local/share/applications/
rsync -aP /home/ubuntu/.local/share/applications/mimeapps.list /root/.local/share/applications/

# Set the default xdg-open MIME association for root user on folder paths
# to use PCManFM file manager, rather that baobab (GNOME disks)
# Required for Image Explorer, as it uses 'xdg-open' on a folder path
xdg-mime default pcmanfm.desktop inode/directory

update-alternatives --set x-terminal-emulator /usr/bin/xfce4-terminal
update-alternatives --install /usr/share/plymouth/themes/default.plymouth default.plymouth /usr/share/plymouth/themes/rescuezilla-logo/rescuezilla-logo.plymouth 100
update-alternatives --set default.plymouth /usr/share/plymouth/themes/rescuezilla-logo/rescuezilla-logo.plymouth

update-initramfs -u

# 系统清理
apt-get --yes autoremove

rm -f /var/lib/dbus/machine-id
rm -f /sbin/initctl
dpkg-divert --rename --remove /sbin/initctl

# 保存和移动 apt 缓存
mv /var/cache/apt/archives /var.cache.apt.archives
mv /var/lib/apt/lists /var.lib.apt.lists
apt-get clean

# 禁用 systemd-timesyncd 服务
rm -f /etc/systemd/system/systemd-timesyncd.service
ln -s /dev/null /etc/systemd/system/systemd-timesyncd.service

# 配置 DNS
cat > /etc/resolv.conf << EOF
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# 清理临时文件并卸载文件系统
rm -rf /tmp/*
rm -rf /var/lib/apt/lists/????????*
umount -lf /proc || true
umount -lf /sys || true
umount -lf /dev/pts || true

exit 0
