#!/usr/bin/env bash
set -e

SSH_DIR="$HOME/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

add_key() {
    local key="$1"
    grep -qxF "$key" "$AUTH_KEYS" || echo "$key" >> "$AUTH_KEYS"
}

add_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAILYqiHy5xUtzymq4Q6pDF1ZliTW0nPjDMJPGu3UjfZ8B civ@CIV002"
add_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDbFJvtxZLtcuGzrO6Nkq1+95pd+dTlFI26Bi4rw9uVb root@PVE2122-Oracle-23102"
add_key "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAZbKNc5jGF4Hlng2GJuG7bUP9veTfj0IpakPOfvfOFY computron@ICECUBE.local"
