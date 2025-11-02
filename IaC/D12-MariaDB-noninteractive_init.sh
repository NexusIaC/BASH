#!/usr/bin/expect -f

# 设置超时为 10 秒
set timeout 10
spawn mariadb-secure-installation

# 自动处理每一个交互提示
expect "Enter current password for root (enter for none):" { send "\r" }
expect "Switch to unix_socket authentication" { send "n\r" }
expect "Change the root password?" { send "Y\r" }
expect "New password:" { send "Adeste\r" }
expect "Re-enter new password:" { send "Adeste\r" }
expect "Remove anonymous users?" { send "Y\r" }
expect "Disallow root login remotely?" { send "Y\r" }
expect "Remove test database and access to it?" { send "Y\r" }
expect "Reload privilege tables now?" { send "Y\r" }

expect eof
