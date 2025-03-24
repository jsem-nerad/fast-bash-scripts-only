#!/bin/bash

# Universal Wireless Access Point Setup Script

# Colors for better readability
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to display messages
print_msg() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_error() {
  echo -e "${RED}[ERROR]${NC} $1"
  exit 1
}

print_warning() {
  echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Detect system type
detect_system() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    OS=$NAME
    if [[ "$OS" == *"Debian"* ]] || [[ "$OS" == *"Ubuntu"* ]] || [[ "$OS" == *"Raspbian"* ]]; then
      SYSTEM_TYPE="debian"
    elif [[ "$OS" == *"Fedora"* ]] || [[ "$OS" == *"CentOS"* ]] || [[ "$OS" == *"Red Hat"* ]]; then
      SYSTEM_TYPE="redhat"
    elif [[ "$OS" == *"Arch"* ]] || [[ "$OS" == *"Manjaro"* ]]; then
      SYSTEM_TYPE="arch"
    else
      print_warning "Unrecognized distribution: $OS. Will try Debian-based commands."
      SYSTEM_TYPE="debian"
    fi
  else
    print_warning "Could not detect OS. Will try Debian-based commands."
    SYSTEM_TYPE="debian"
  fi
  print_msg "Detected system type: $SYSTEM_TYPE based on $OS"
}

# Check for root privileges
check_root() {
  if [ "$(id -u)" -ne 0 ]; then
    print_error "This script must be run as root. Try 'sudo $0'"
  fi
}

# Install required packages based on system type
install_dependencies() {
  print_msg "Installing required packages..."
  
  case $SYSTEM_TYPE in
    debian)
      apt-get update
      apt-get install -y hostapd dnsmasq wireless-tools iw
      ;;
    redhat)
      dnf install -y hostapd dnsmasq wireless-tools iw
      ;;
    arch)
      pacman -Sy --noconfirm hostapd dnsmasq wireless-tools iw
      ;;
  esac
  
  if [ $? -ne 0 ]; then
    print_error "Failed to install required packages"
  else
    print_success "Required packages installed successfully"
  fi
}

# Check if wireless interface exists
check_wireless() {
  WIRELESS_INTERFACE=$(iw dev | grep Interface | awk '{print $2}' | head -1)
  
  if [ -z "$WIRELESS_INTERFACE" ]; then
    print_error "No wireless interface found"
  fi
  
  print_msg "Using wireless interface: $WIRELESS_INTERFACE"
}

# Get user configuration
get_user_config() {
  echo ""
  print_msg "Wireless Access Point Configuration"
  echo "----------------------------------------"
  
  # SSID
  read -p "Enter SSID name: " SSID
  while [ -z "$SSID" ]; do
    print_warning "SSID cannot be empty"
    read -p "Enter SSID name: " SSID
  done
  
  # Password
  read -p "Enter password (minimum 8 characters): " PASSWORD
  while [ ${#PASSWORD} -lt 8 ]; do
    print_warning "Password must be at least 8 characters long"
    read -p "Enter password (minimum 8 characters): " PASSWORD
  done
  
  # Channel
  read -p "Enter WiFi channel (1-11) [default: 7]: " CHANNEL
  CHANNEL=${CHANNEL:-7}
  
  # Internet forwarding
  read -p "Enable internet forwarding? (y/n) [default: n]: " ENABLE_FORWARDING
  ENABLE_FORWARDING=${ENABLE_FORWARDING:-n}
  
  if [[ "$ENABLE_FORWARDING" =~ ^[Yy]$ ]]; then
    read -p "Enter internet-connected interface (e.g., eth0): " INTERNET_IFACE
    while [ -z "$INTERNET_IFACE" ]; do
      print_warning "Interface cannot be empty"
      read -p "Enter internet-connected interface (e.g., eth0): " INTERNET_IFACE
    done
  fi
  
  # IP range
  read -p "Enter AP IP address [default: 192.168.4.1]: " AP_IP
  AP_IP=${AP_IP:-192.168.4.1}
  
  # Extract network from IP
  IP_BASE=$(echo $AP_IP | cut -d. -f1-3)
  
  read -p "Enter DHCP range start [default: ${IP_BASE}.2]: " DHCP_START
  DHCP_START=${DHCP_START:-${IP_BASE}.2}
  
  read -p "Enter DHCP range end [default: ${IP_BASE}.20]: " DHCP_END
  DHCP_END=${DHCP_END:-${IP_BASE}.20}
  
  # Confirmation
  echo ""
  echo "Configuration Summary:"
  echo "----------------------"
  echo "SSID: $SSID"
  echo "Password: ${PASSWORD:0:2}${'*' * (${#PASSWORD} - 4)}${PASSWORD: -2}"
  echo "Channel: $CHANNEL"
  echo "AP IP Address: $AP_IP"
  echo "DHCP Range: $DHCP_START - $DHCP_END"
  if [[ "$ENABLE_FORWARDING" =~ ^[Yy]$ ]]; then
    echo "Internet Forwarding: Enabled (via $INTERNET_IFACE)"
  else
    echo "Internet Forwarding: Disabled"
  fi
  
  read -p "Proceed with this configuration? (y/n): " CONFIRM
  if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_msg "Configuration cancelled. Exiting."
    exit 0
  fi
}

# Setup access point
setup_ap() {
  print_msg "Setting up access point..."
  
  # Stop services if they're running
  systemctl stop dnsmasq
  systemctl stop hostapd
  
  # Unmask and enable hostapd
  systemctl unmask hostapd
  systemctl enable hostapd
  
  # Create virtual AP interface
  print_msg "Creating virtual AP interface..."
  iw dev $WIRELESS_INTERFACE interface add wlan_ap type __ap
  if [ $? -ne 0 ]; then
    print_warning "Failed to create virtual interface. Trying direct mode with $WIRELESS_INTERFACE"
    AP_INTERFACE=$WIRELESS_INTERFACE
  else
    AP_INTERFACE="wlan_ap"
  fi
  
  # Configure dnsmasq
  print_msg "Configuring dnsmasq..."
  cat <<EOF > /etc/dnsmasq.conf
interface=$AP_INTERFACE
dhcp-range=$DHCP_START,$DHCP_END,255.255.255.0,24h
EOF

  # Add DNS configuration if internet forwarding is enabled
  if [[ "$ENABLE_FORWARDING" =~ ^[Yy]$ ]]; then
    cat <<EOF >> /etc/dnsmasq.conf
# Use Google DNS
server=8.8.8.8
server=8.8.4.4
# Don't use /etc/hosts
no-hosts
# Use local domain
domain=wlan
# Set local domain
local=/wlan/
# Log queries
log-queries
# Don't forward short names
domain-needed
# Don't forward addresses in non-routed address spaces
bogus-priv
EOF
  fi

  systemctl restart dnsmasq
  
  # Configure hostapd
  print_msg "Configuring hostapd..."
  cat <<EOF > /etc/hostapd/hostapd.conf
interface=$AP_INTERFACE
driver=nl80211
ssid=$SSID
hw_mode=g
channel=$CHANNEL
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=$PASSWORD
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP
EOF

  sed -i 's|#DAEMON_CONF="|DAEMON_CONF="/etc/hostapd/hostapd.conf|' /etc/default/hostapd
  
  # Configure IP and start services
  print_msg "Configuring network..."
  ip addr add $AP_IP/24 dev $AP_INTERFACE
  ip link set $AP_INTERFACE up
  
  # Setup internet forwarding if requested
  if [[ "$ENABLE_FORWARDING" =~ ^[Yy]$ ]]; then
    print_msg "Setting up internet forwarding..."
    echo 1 > /proc/sys/net/ipv4/ip_forward
    
    # Add persistent forwarding
    sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
    
    # Setup NAT
    iptables -t nat -A POSTROUTING -o $INTERNET_IFACE -j MASQUERADE
    iptables -A FORWARD -i $INTERNET_IFACE -o $AP_INTERFACE -m state --state RELATED,ESTABLISHED -j ACCEPT
    iptables -A FORWARD -i $AP_INTERFACE -o $INTERNET_IFACE -j ACCEPT
    
    # Save iptables rules based on system type
    case $SYSTEM_TYPE in
      debian)
        apt-get install -y iptables-persistent
        iptables-save > /etc/iptables/rules.v4
        ;;
      redhat)
        iptables-save > /etc/sysconfig/iptables
        ;;
      arch)
        iptables-save > /etc/iptables/iptables.rules
        ;;
    esac
  fi
  
  # Start hostapd
  print_msg "Starting hostapd..."
  systemctl start hostapd
  
  if [ $? -ne 0 ]; then
    print_error "Failed to start hostapd. Check logs with 'journalctl -xe'"
  fi
}

# Main execution
main() {
  clear
  echo "=========================================="
  echo "   Universal Wireless Access Point Setup  "
  echo "=========================================="
  echo ""
  
  check_root
  detect_system
  install_dependencies
  check_wireless
  get_user_config
  setup_ap
  
  print_success "Access point setup is complete!"
  echo ""
  echo "Connect to SSID '$SSID' with password '$PASSWORD'"
  echo "Access the network at $AP_IP"
  if [[ "$ENABLE_FORWARDING" =~ ^[Yy]$ ]]; then
    echo "Internet forwarding is enabled via $INTERNET_IFACE"
  fi
  echo ""
  echo "To stop the access point, run: sudo systemctl stop hostapd dnsmasq"
  echo "To start it again, run: sudo systemctl start hostapd dnsmasq"

# Run the main function
main
