#!/bin/bash
# Supervises the LTE data session on the Telit LN940.
#
# Why this exists: MBIM mode (cdc_mbim) is unusable on the Pi Zero -- cdc_ncm
# aggregation trips the dwc_otg TX watchdog and every packet errors out. QMI
# raw-IP works, but needs a manual driver bind and ModemManager can't
# auto-detect it, so the session is driven directly with qmicli here.
#
# Runs as a loop: establishes the session, then re-establishes if it drops.

set -u

WDM="/dev/cdc-wdm0"
IFACE="wwan0"
APN="povo.jp"
USER_="user@povo.jp"
PASS="povo"
METRIC="${LTE_METRIC:-50}"
CHECK_HOST="8.8.8.8"

log() { echo "[xhome-lte] $*"; }

bind_driver() {
  modprobe qmi_wwan 2>/dev/null
  if [ ! -e "$WDM" ]; then
    log "binding qmi_wwan to 1bc7:1900"
    echo "1bc7 1900" > /sys/bus/usb/drivers/qmi_wwan/new_id 2>/dev/null
    sleep 3
  fi
}

session_up() {
  # Healthy if the interface has a 10.x address and packets actually flow.
  ip -br addr show "$IFACE" 2>/dev/null | grep -q "10\." || return 1
  ping -I "$IFACE" -c 2 -W 4 "$CHECK_HOST" >/dev/null 2>&1
}

establish() {
  log "establishing session"

  bind_driver
  [ -e "$WDM" ] || { log "no $WDM, cannot continue"; return 1; }

  ip link set "$IFACE" down 2>/dev/null
  if [ -f "/sys/class/net/$IFACE/qmi/raw_ip" ]; then
    echo Y > "/sys/class/net/$IFACE/qmi/raw_ip"
  fi
  ip link set "$IFACE" up

  qmicli -d "$WDM" -p \
    --wds-start-network="apn=${APN},username=${USER_},password=${PASS},auth=chap,ip-type=4" \
    --client-no-release-cid >/dev/null 2>&1

  local settings ip4 gw4 mask mtu
  settings=$(qmicli -d "$WDM" -p --wds-get-current-settings 2>/dev/null)
  ip4=$(echo "$settings"  | grep -i "IPv4 address:"         | awk '{print $NF}')
  gw4=$(echo "$settings"  | grep -i "IPv4 gateway address:" | awk '{print $NF}')
  mask=$(echo "$settings" | grep -i "IPv4 subnet mask:"     | awk '{print $NF}')
  mtu=$(echo "$settings"  | grep -iE "^[[:space:]]*MTU:"    | awk '{print $NF}')

  [ -z "$ip4" ] && { log "no IP from network"; return 1; }
  log "got ip=$ip4 gw=$gw4 mtu=${mtu:-1440}"

  ip addr flush dev "$IFACE"
  ip addr add "${ip4}/${mask:-255.255.255.252}" dev "$IFACE" 2>/dev/null \
    || ip addr add "${ip4}/30" dev "$IFACE"
  ip link set "$IFACE" mtu "${mtu:-1440}"
  ip route replace default via "$gw4" dev "$IFACE" metric "$METRIC"

  # With WiFi off nothing else maintains resolv.conf, so publish the
  # carrier's resolvers here (8.8.8.8 kept as a fallback).
  local dns1 dns2
  dns1=$(echo "$settings" | grep -i "IPv4 primary DNS:"   | awk '{print $NF}')
  dns2=$(echo "$settings" | grep -i "IPv4 secondary DNS:" | awk '{print $NF}')
  {
    echo "# LTE DNS - written by xhome-lte"
    [ -n "$dns1" ] && echo "nameserver $dns1"
    [ -n "$dns2" ] && echo "nameserver $dns2"
    echo "nameserver 8.8.8.8"
  } > /etc/resolv.conf
  log "dns: ${dns1:-none} ${dns2:-none}"

  return 0
}

# ModemManager fights qmicli for the control channel.
systemctl is-active --quiet ModemManager && systemctl stop ModemManager

log "starting supervisor (metric=$METRIC)"
fails=0
while true; do
  if session_up; then
    fails=0
  else
    fails=$((fails + 1))
    log "session down (failure #$fails), re-establishing"
    establish || log "establish failed"
    # Back off a little if it keeps failing, so we don't hammer the modem.
    [ "$fails" -ge 3 ] && sleep 30
  fi
  sleep 20
done
