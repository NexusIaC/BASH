# Check if the system is Linux or FreeBSD
if [ "$(uname)" == "Linux" ]; then
    # Change ownership and permissions for Linux
    chown -R www-data:www-data /var/www/
    find /var/www/ -type d -exec chmod 750 {} \;
    find /var/www/ -type f -exec chmod 640 {} \;
elif [ "$(uname)" == "FreeBSD" ]; then
    # Change ownership and permissions for FreeBSD
    chown -R www:www /usr/local/www
    find /usr/local/www -type d -exec chmod 750 {} \;
    find /usr/local/www -type f -exec chmod 640 {} \;
fi
