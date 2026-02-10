#!/bin/bash

# libfiber One-Click Start Script
# This script handles dependencies, builds the project, and launches the monitoring dashboard.

set -e

# --- Colors for better UI ---
RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}==============================================${NC}"
echo -e "${BLUE}   libfiber: One-Click Linux Setup & Demo    ${NC}"
echo -e "${BLUE}==============================================${NC}"

# 1. Install System Dependencies
echo -e "\n${GREEN}[1/5] Checking System Dependencies...${NC}"
echo "You might be asked for your sudo password to install build-essential, libev, and python3-psutil."
sudo apt-get update -qq
sudo apt-get install -y -qq build-essential libev-dev python3-psutil docker.io docker-compose zip

# 2. Check if Docker is running
if ! systemctl is-active --quiet docker; then
    echo -e "${RED}Docker is not running. Attempting to start...${NC}"
    sudo systemctl start docker
fi

# 3. Build the Library
echo -e "\n${GREEN}[2/5] Building libfiber and echo_server...${NC}"
make clean > /dev/null
make

# 4. Create and Setup Demo Package
echo -e "\n${GREEN}[3/5] Setting up Monitoring Stack (Grafana/Prometheus)...${NC}"
chmod +x create_demo_zip.sh
./create_demo_zip.sh

cd libfiber_demo_package
chmod +x setup_demo.sh
# Run setup_demo.sh with sudo for Docker permissions
sudo ./setup_demo.sh

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
