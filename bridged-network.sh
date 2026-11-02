#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Linux container networking lab
# Two simulated Linux hosts inside one WSL2 instance
# GRE tunnel between HOST1 and HOST2
# ============================================================

# -------------------- Configuration -------------------------

NS1="NS1"
NS2="NS2"
HOST2="HOST2"
NS3="NS3"
NS4="NS4"

HOST1_IP="192.168.0.10"
HOST2_IP="192.168.0.11"

BRIDGE1_IP="172.16.0.1"
IP1="172.16.0.2"
IP2="172.16.0.3"

BRIDGE2_IP="172.16.1.1"
IP3="172.16.1.2"
IP4="172.16.1.3"

GRE1_IP="10.10.10.1"
GRE2_IP="10.10.10.2"

# -------------------- Cleanup -------------------------------

echo "Cleaning up previous lab..."

for ns in "$NS1" "$NS2" "$NS3" "$NS4" "$HOST2"; do
    sudo ip netns del "$ns" 2>/dev/null || true
done

for iface in gre1 br0 h1-link veth10 veth20; do
    sudo ip link del "$iface" 2>/dev/null || true
done

# -------------------- HOST1 ----------------------------------

echo "Creating HOST1 namespaces..."

sudo ip netns add "$NS1"
sudo ip netns add "$NS2"

echo "Creating HOST1 virtual Ethernet pairs..."

sudo ip link add veth10 type veth peer name veth11
sudo ip link add veth20 type veth peer name veth21

sudo ip link set veth11 netns "$NS1"
sudo ip link set veth21 netns "$NS2"

echo "Configuring HOST1 namespaces..."

sudo ip netns exec "$NS1" ip addr add "$IP1/24" dev veth11
sudo ip netns exec "$NS2" ip addr add "$IP2/24" dev veth21

sudo ip netns exec "$NS1" ip link set lo up
sudo ip netns exec "$NS2" ip link set lo up

sudo ip netns exec "$NS1" ip link set veth11 up
sudo ip netns exec "$NS2" ip link set veth21 up

echo "Creating HOST1 bridge..."

sudo ip link add br0 type bridge
sudo ip addr add "$BRIDGE1_IP/24" dev br0

sudo ip link set veth10 master br0
sudo ip link set veth20 master br0

sudo ip link set veth10 up
sudo ip link set veth20 up
sudo ip link set br0 up

sudo ip netns exec "$NS1" ip route add default via "$BRIDGE1_IP"
sudo ip netns exec "$NS2" ip route add default via "$BRIDGE1_IP"

# -------------------- HOST1 <-> HOST2 ------------------------

echo "Creating HOST2 namespace..."

sudo ip netns add "$HOST2"

echo "Creating transport connection..."

sudo ip link add h1-link type veth peer name h2-link
sudo ip link set h2-link netns "$HOST2"

sudo ip addr add "$HOST1_IP/24" dev h1-link
sudo ip link set h1-link up

sudo ip netns exec "$HOST2" ip link set lo up
sudo ip netns exec "$HOST2" ip addr add "$HOST2_IP/24" dev h2-link
sudo ip netns exec "$HOST2" ip link set h2-link up

# -------------------- HOST2 LAN ------------------------------

echo "Creating HOST2 namespaces..."

sudo ip netns add "$NS3"
sudo ip netns add "$NS4"

echo "Creating HOST2 virtual Ethernet pairs..."

sudo ip link add veth30 type veth peer name veth31
sudo ip link add veth40 type veth peer name veth41

sudo ip link set veth30 netns "$HOST2"
sudo ip link set veth31 netns "$NS3"

sudo ip link set veth40 netns "$HOST2"
sudo ip link set veth41 netns "$NS4"

echo "Configuring HOST2 namespaces..."

sudo ip netns exec "$NS3" ip link set lo up
sudo ip netns exec "$NS4" ip link set lo up

sudo ip netns exec "$NS3" ip addr add "$IP3/24" dev veth31
sudo ip netns exec "$NS4" ip addr add "$IP4/24" dev veth41

sudo ip netns exec "$NS3" ip link set veth31 up
sudo ip netns exec "$NS4" ip link set veth41 up

echo "Creating HOST2 bridge..."

sudo ip netns exec "$HOST2" ip link add br1 type bridge

sudo ip netns exec "$HOST2" ip addr add "$BRIDGE2_IP/24" dev br1

sudo ip netns exec "$HOST2" ip link set veth30 master br1
sudo ip netns exec "$HOST2" ip link set veth40 master br1

sudo ip netns exec "$HOST2" ip link set veth30 up
sudo ip netns exec "$HOST2" ip link set veth40 up
sudo ip netns exec "$HOST2" ip link set br1 up

sudo ip netns exec "$NS3" ip route add default via "$BRIDGE2_IP"
sudo ip netns exec "$NS4" ip route add default via "$BRIDGE2_IP"

# -------------------- IPv4 FORWARDING ------------------------

echo "Enabling IPv4 forwarding..."

sudo sysctl -w net.ipv4.ip_forward=1
sudo ip netns exec "$HOST2" sysctl -w net.ipv4.ip_forward=1

# -------------------- GRE TUNNEL -----------------------------

echo "Creating GRE tunnel on HOST1..."

sudo ip tunnel add gre1 mode gre \
    local "$HOST1_IP" \
    remote "$HOST2_IP" \
    ttl 64

sudo ip addr add "$GRE1_IP/30" dev gre1
sudo ip link set gre1 up

echo "Creating GRE tunnel on HOST2..."

sudo ip netns exec "$HOST2" ip tunnel add gre1 mode gre \
    local "$HOST2_IP" \
    remote "$HOST1_IP" \
    ttl 64

sudo ip netns exec "$HOST2" ip addr add "$GRE2_IP/30" dev gre1
sudo ip netns exec "$HOST2" ip link set gre1 up

# -------------------- ROUTING THROUGH GRE -------------------

echo "Adding LAN routes through GRE..."

sudo ip route add 172.16.1.0/24 via "$GRE2_IP" dev gre1

sudo ip netns exec "$HOST2" \
    ip route add 172.16.0.0/24 via "$GRE1_IP" dev gre1

# -------------------- CONNECTIVITY TESTS ---------------------

echo "================================================"
echo "Testing HOST1 <-> HOST2 transport"
echo "================================================"

ping -c 3 "$HOST2_IP"

echo "================================================"
echo "Testing GRE tunnel"
echo "================================================"

ping -c 3 "$GRE2_IP"

sudo ip netns exec "$HOST2" ping -c 3 "$GRE1_IP"

echo "================================================"
echo "Testing HOST1 LAN"
echo "================================================"

sudo ip netns exec "$NS1" ping -c 3 "$IP2"
sudo ip netns exec "$NS1" ping -c 3 "$BRIDGE1_IP"

echo "================================================"
echo "Testing HOST2 LAN"
echo "================================================"

sudo ip netns exec "$NS3" ping -c 3 "$IP4"
sudo ip netns exec "$NS3" ping -c 3 "$BRIDGE2_IP"

echo "================================================"
echo "Testing LAN-to-LAN communication through GRE"
echo "================================================"

sudo ip netns exec "$NS1" ping -c 3 "$IP3"
sudo ip netns exec "$NS1" ping -c 3 "$IP4"

echo "================================================"
echo "Testing reverse LAN communication"
echo "================================================"

sudo ip netns exec "$NS3" ping -c 3 "$IP1"
sudo ip netns exec "$NS3" ping -c 3 "$IP2"

echo "================================================"
echo "Lab setup completed successfully"
echo "================================================"
