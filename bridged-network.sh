#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Linux container networking lab
# Simulates two Linux hosts inside one WSL2 instance
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

echo "================================================"
echo "Cleaning up previous lab configuration"
echo "================================================"

# Delete existing lab namespaces, if present
for ns in "$NS1" "$NS2" "$NS3" "$NS4" "$HOST2"; do
    sudo ip netns del "$ns" 2>/dev/null || true
done

# Delete existing lab bridges and host-to-host link
sudo ip link del br0 2>/dev/null || true
sudo ip link del h1-link 2>/dev/null || true

# Remove any old route from previous attempts
sudo ip route del 172.16.1.0/24 2>/dev/null || true


# ============================================================
# HOST1 — Main WSL network namespace
# ============================================================

echo "Creating HOST1 namespaces..."

sudo ip netns add "$NS1"
sudo ip netns add "$NS2"

echo "Creating HOST1 virtual Ethernet pairs..."

sudo ip link add veth10 type veth peer name veth11
sudo ip link add veth20 type veth peer name veth21

echo "Moving interfaces into HOST1 namespaces..."

sudo ip link set veth11 netns "$NS1"
sudo ip link set veth21 netns "$NS2"

echo "Configuring HOST1 namespace interfaces..."

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

sudo ip link set br0 up
sudo ip link set veth10 up
sudo ip link set veth20 up

echo "Configuring HOST1 namespace default routes..."

sudo ip netns exec "$NS1" ip route add default via "$BRIDGE1_IP"
sudo ip netns exec "$NS2" ip route add default via "$BRIDGE1_IP"


# ============================================================
# HOST1 <-> HOST2 — Virtual connection
# ============================================================

echo "Creating HOST2 namespace..."

sudo ip netns add "$HOST2"

echo "Creating virtual connection between hosts..."

sudo ip link add h1-link type veth peer name h2-link

sudo ip link set h2-link netns "$HOST2"

echo "Configuring HOST1 connection..."

sudo ip addr add "$HOST1_IP/24" dev h1-link
sudo ip link set h1-link up

echo "Configuring HOST2 connection..."

sudo ip netns exec "$HOST2" ip link set lo up
sudo ip netns exec "$HOST2" ip addr add "$HOST2_IP/24" dev h2-link
sudo ip netns exec "$HOST2" ip link set h2-link up


# ============================================================
# HOST2 — Second bridge and namespaces
# ============================================================

echo "Creating HOST2 namespaces..."

sudo ip netns add "$NS3"
sudo ip netns add "$NS4"

echo "Creating HOST2 virtual Ethernet pairs..."

sudo ip link add veth30 type veth peer name veth31
sudo ip link add veth40 type veth peer name veth41

echo "Moving interfaces into HOST2 and its namespaces..."

sudo ip link set veth30 netns "$HOST2"
sudo ip link set veth31 netns "$NS3"

sudo ip link set veth40 netns "$HOST2"
sudo ip link set veth41 netns "$NS4"

echo "Configuring HOST2 namespace interfaces..."

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

sudo ip netns exec "$HOST2" ip link set br1 up
sudo ip netns exec "$HOST2" ip link set veth30 up
sudo ip netns exec "$HOST2" ip link set veth40 up

echo "Configuring HOST2 namespace default routes..."

sudo ip netns exec "$NS3" ip route add default via "$BRIDGE2_IP"
sudo ip netns exec "$NS4" ip route add default via "$BRIDGE2_IP"


# ============================================================
# ROUTING BETWEEN HOST1 AND HOST2
# ============================================================

echo "Enabling IPv4 forwarding on HOST1..."

sudo sysctl -w net.ipv4.ip_forward=1

echo "Enabling IPv4 forwarding on HOST2..."

sudo ip netns exec "$HOST2" sysctl -w net.ipv4.ip_forward=1

echo "Adding HOST1 route to HOST2 LAN..."

sudo ip route add 172.16.1.0/24 via "$HOST2_IP" dev h1-link

echo "Adding HOST2 route to HOST1 LAN..."

sudo ip netns exec "$HOST2" \
    ip route add 172.16.0.0/24 via "$HOST1_IP" dev h2-link


# ============================================================
# TESTING CONNECTIVITY
# ============================================================

echo "================================================"
echo "Testing HOST1 <-> HOST2 connection"
echo "================================================"

ping -c 3 "$HOST2_IP"

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
echo "Testing communication between the two LANs"
echo "================================================"

sudo ip netns exec "$NS1" ping -c 3 "$HOST2_IP"
sudo ip netns exec "$NS1" ping -c 3 "$BRIDGE2_IP"
sudo ip netns exec "$NS1" ping -c 3 "$IP3"
sudo ip netns exec "$NS1" ping -c 3 "$IP4"

echo "================================================"
echo "Testing reverse communication"
echo "================================================"

sudo ip netns exec "$NS3" ping -c 3 "$IP1"

echo "================================================"
echo "Lab setup and connectivity tests completed"
echo "================================================"