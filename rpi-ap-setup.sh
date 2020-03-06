#!/bin/sh

if [ `id -u` != "0" ]; then
    echo "Please run this script as root."
    exit
fi

# Update distribution packages.
apt-get update
apt-get upgrade -y

# Install required packages:
# - hostapd: access point
# - udhcpd: lightweight DHCP server
apt-get install -y hostapd dnsmasq

# Stop services
systemctl stop hostapd
systemctl stop dnsmasq

# Modify our dhcpd configuration so that we can take control of the wlan0 interface.
cat <<EOF > /etc/dhcpcd.conf
interface wlan0
    static ip_address=192.168.88.1/24
    nohook wpa_supplicant
EOF

# Restart our dhcpd service so it will load in all our configuration changes. To do this run the following command to reload the dhcpd service.
systemctl restart dhcpcd


# Setup Hostapd
cat <<EOF > /etc/hostapd/hostapd.conf
interface=wlan0
driver=nl80211

hw_mode=g
channel=6
ieee80211n=1
wmm_enabled=0
macaddr_acl=0
ignore_broadcast_ssid=0

auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP

# This is the name of the network
ssid=lisimetro-config-ap
# The network passphrase
wpa_passphrase=lisimetro
EOF

# Enable Hostapd.
cat <<EOF > /etc/default/hostapd
DAEMON_CONF="/etc/hostapd/hostapd.conf"
EOF

# Enable Hostapd.
cat <<EOF > /etc/init.d/hostapd
#!/bin/sh

PATH=/sbin:/bin:/usr/sbin:/usr/bin
DAEMON_SBIN=/usr/sbin/hostapd
DAEMON_DEFS=/etc/default/hostapd
DAEMON_CONF=/etc/hostapd/hostapd.conf
NAME=hostapd
DESC="advanced IEEE 802.11 management"
PIDFILE=/run/hostapd.pid

[ -x "$DAEMON_SBIN" ] || exit 0
[ -s "$DAEMON_DEFS" ] && . /etc/default/hostapd
[ -n "$DAEMON_CONF" ] || exit 0

DAEMON_OPTS="-B -P $PIDFILE $DAEMON_OPTS $DAEMON_CONF"

. /lib/lsb/init-functions

for conf in $DAEMON_CONF
do
    if [ ! -r "$conf" ]
    then
        log_action_msg "hostapd config $conf not found, not starting hostapd."
        exit 0
    fi
done

case "$1" in
  start)
        if [ "$DAEMON_CONF" != /etc/hostapd/hostapd.conf ]
        then
                log_warning_msg "hostapd config not in /etc/hostapd/hostapd.conf -- please read /usr/share/doc/hostapd/NEWS.Debian.gz"
        fi
        log_daemon_msg "Starting $DESC" "$NAME"
        start-stop-daemon --start --oknodo --quiet --exec "$DAEMON_SBIN" \
                --pidfile "$PIDFILE" -- $DAEMON_OPTS >/dev/null
EOF

# Move onto setting up dnsmasq. Before we begin editing its configuration file we will rename the current one as we don?t need any of its current configurations.
mv /etc/dnsmasq.conf /etc/dnsmasq.conf.orig

# Set a static address for wlan0.
cat <<EOF > /etc/dnsmasq.conf
interface=wlan0       # Use interface wlan0  
server=1.1.1.1       # Use Cloudflare DNS  
dhcp-range=192.168.88.100,192.168.88.200,12h # IP range and lease time 
EOF

# Activate IPv4 packet forwarding in kernel configuration.
cat <<EOF >> /etc/sysctl.conf
net.ipv4.conf.all.rp_filter=1
net.ipv4.ip_forward=1
EOF

#Enable on next boot we can run the following command to activate it immediately.
sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"

# Setup packet forwarding.
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Save our new set of rules run the following command.
sh -c "iptables-save > /etc/iptables.ipv4.nat"

# Make this file "iptables.ipv4.nat" be loaded back in on every reboot
cat <<EOF >> /etc/rc.local
#!/bin/sh -e
# Print the IP address
_IP=$(hostname -I) || true
if [ "$_IP" ]; then
  printf "My IP address is %s\n" "$_IP"
fi
iptables-restore < /etc/iptables.ipv4.nat
exit 0
EOF

#Start the two services and enable them in systemctl. Run the following two commands.
systemctl unmask hostapd
systemctl enable hostapd
systemctl start hostapd
service dnsmasq start

# Enable packet forwarding when wlan0 is up.
cat <<EOF > /etc/network/if-up.d/wlan0
#!/bin/sh
# Enable network forwarding when Wi-Fi access point is up.

set -e

if [ "\$MODE" != start ]; then
    exit 0
fi

if [ "\$IFACE" = wlan0 ]; then
    iptables-restore < /etc/iptables.ipv4.nat
fi
exit 0
EOF

chmod +x /etc/network/if-up.d/wlan0

#Usage
cd /home/pi/lysimeter-wifi-conf
/usr/bin/node server.js < /dev/null &

echo "Done. Wi-Fi access point enabled."

