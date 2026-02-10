#!/bin/bash
# One-Click Simple Demo for libfiber
# No Docker, No Prometheus, No Complexity - Just a beautiful dashboard!

set -e

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}========================================${NC}"
echo -e "${BLUE}  libfiber Simple Performance Demo     ${NC}"
echo -e "${BLUE}========================================${NC}"

# 1. Install minimal dependencies
echo -e "\n${GREEN}[1/3] Installing dependencies...${NC}"
sudo apt-get update -qq || true
sudo apt-get install -y -qq build-essential python3-flask python3-psutil 2>/dev/null || {
    echo "Attempting to fix package manager..."
    sudo dpkg --configure -a || true
    sudo apt --fix-broken install -y || true
    sudo apt-get install -y build-essential python3-flask python3-psutil
}

# 2. Build servers
echo -e "\n${GREEN}[2/3] Building servers...${NC}"
make -j$(nproc) || make

# Compile thread server
if [ ! -f "bin/thread_server" ]; then
    gcc -O2 -pthread -o bin/thread_server tools/thread_echo_server.c
fi

# 3. Start dashboard
echo -e "\n${GREEN}[3/3] Starting dashboard...${NC}"
cd simple_demo

echo -e "\n${BLUE}========================================${NC}"
echo -e "${GREEN}✓ Ready! Opening browser...${NC}"
echo -e "${BLUE}========================================${NC}"
echo -e "URL: ${BLUE}http://localhost:5000${NC}"
echo -e "\nPress Ctrl+C to stop\n"

python3 server.py
