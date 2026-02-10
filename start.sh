#!/bin/bash

# libfiber One-Click Start Script
# This script handles dependencies, builds the project, and launches the monitoring dashboard.

set -e

# --- Colors for better UI ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${BLUE}==============================================${NC}"
echo -e "${BLUE}   libfiber: One-Click Linux Setup & Demo    ${NC}"
echo -e "${BLUE}==============================================${NC}"

# Function to handle apt errors
fix_apt() {
  echo -e "${YELLOW}Detected apt error. Attempting to fix...${NC}"
  sudo dpkg --configure -a || true
  sudo apt --fix-broken install -y || true
  sudo apt-get update -qq || true
}

# 1. Install System Dependencies
echo -e "\n${GREEN}[1/5] Checking System Dependencies...${NC}"
echo "You might be asked for your sudo password to install build-essential, libev, and python3-psutil."
sudo apt-get update -qq || true

if ! sudo apt-get install -y -qq build-essential libev-dev python3-psutil docker.io docker-compose zip; then
    echo -e "${RED}Dependency installation failed. Trying to self-heal...${NC}"
    fix_apt
    echo -e "${GREEN}Retrying installation...${NC}"
    if ! sudo apt-get install -y -qq build-essential libev-dev python3-psutil docker.io docker-compose zip; then
        echo -e "${RED}FATAL: Could not install dependencies even after repair.${NC}"
        echo -e "Please run 'sudo dpkg --configure -a' and 'sudo apt install -f' manually."
        exit 1
    fi
fi

# 2. Check if Docker is running
if ! systemctl is-active --quiet docker; then
    echo -e "${YELLOW}Docker is not running. Attempting to start...${NC}"
    sudo systemctl start docker
    sleep 2
    if ! systemctl is-active --quiet docker; then
        echo -e "${RED}Failed to start Docker. Please start it manually.${NC}"
        exit 1
    fi
fi

# 3. Build the Library
echo -e "\n${GREEN}[2/5] Building libfiber and echo_server...${NC}"
make clean > /dev/null
if ! make; then
    echo -e "${RED}Build failed.${NC}"
    exit 1
fi

# 4. Create and Setup Demo Package
echo -e "\n${GREEN}[3/5] Setting up Monitoring Stack (Grafana/Prometheus)...${NC}"
chmod +x create_demo_zip.sh
./create_demo_zip.sh

cd libfiber_demo_package
chmod +x setup_demo.sh
# Run setup_demo.sh with sudo for Docker permissions
if ! sudo ./setup_demo.sh; then
    echo -e "${RED}Failed to setup demo stack.${NC}"
    exit 1
fi

echo -e "\n${BLUE}==============================================${NC}"
echo -e "${GREEN}SUCCESS: The Monitoring Stack is now running!${NC}"
echo -e "URL: ${BLUE}http://localhost:3000${NC} (admin / admin)"
echo -e "Wait 10 seconds for Grafana to initialize...${NC}"
echo -e "${BLUE}==============================================${NC}"

# 5. Run Experiment
echo -e "\nWould you like to run the Performance Benchmark now? (y/n)"
read -r response
if [[ "$response" =~ ^([yY][eE][sS]|[yY])$ ]]; then
    echo -e "${GREEN}[4/5] Running benchmarks... This will take about 2 minutes.${NC}"
    ./tools/run_experiment.sh ../bin/echo_server ./bin/thread_server
    echo -e "\n${GREEN}[5/5] Experiment complete! Check your Grafana dashboard.${NC}"
else
    echo -e "Skipping benchmark. You can run it later by going to 'libfiber_demo_package' and running:"
    echo -e "./tools/run_experiment.sh ../bin/echo_server ./bin/thread_server"
fi

echo -e "\n${BLUE}To stop the stack later, run: sudo docker-compose down${NC}"
