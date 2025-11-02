#!/bin/bash

# 检查存储库是否已经存在
if ! grep -q "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" /etc/apt/sources.list; then
  echo "存储库不存在，将会被添加至 /etc/apt/sources.list"
  # 在文件末尾追加存储库
  echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" >> /etc/apt/sources.list
else
  echo "存储库已存在于 /etc/apt/sources.list"
fi

#!/bin/bash

# 注释 pve-enterprise.list 中未注释的行
sed -i '/^#/!s/^/#/' /etc/apt/sources.list.d/pve-enterprise.list

# 显示文件内容以确认注释
echo "Contents of pve-enterprise.list after commenting:"
cat /etc/apt/sources.list.d/pve-enterprise.list

# 删除 ceph.list 文件
rm /etc/apt/sources.list.d/ceph.list
echo "ceph.list file has been removed."

apt -y update
