#!/bin/bash

set -euo pipefail

# General arguments
ROOT=$PWD

export PUB_MULTI_ADDRS
export PEER_MULTI_ADDRS
export HOST_MULTI_ADDRS
export IDENTITY_PATH
export CONNECT_TO_TESTNET
export ORG_ID
export HF_HUB_DOWNLOAD_TIMEOUT=120  # 2 minutes

# Retry related variables
RETRY_COUNT=0
RETRY_DELAY=240  # Retry delay in seconds

# Mac-specific memory optimization settings
if [[ "$OSTYPE" == "darwin"* ]]; then
    # Mac environment variables
    export PYTORCH_ENABLE_MPS_FALLBACK=1
    export PYTORCH_MPS_HIGH_WATERMARK_RATIO=0.0
    export OMP_NUM_THREADS=2
    export MKL_NUM_THREADS=2
    export VECLIB_MAXIMUM_THREADS=2
    export NUMEXPR_NUM_THREADS=2
    export NUMEXPR_MAX_THREADS=2
    
    # Memory limiting for Mac
    export PYTORCH_MPS_ALLOCATOR_POLICY=delayed
    export PYTORCH_MPS_ALLOCATOR_POLICY_MAX_ALLOCATION=4096  # Limit max memory allocation to 4GB
fi

# Check if public multi-address is given else set to default
DEFAULT_PUB_MULTI_ADDRS=""
PUB_MULTI_ADDRS=${PUB_MULTI_ADDRS:-$DEFAULT_PUB_MULTI_ADDRS}

# Check if peer multi-address is given else set to default
DEFAULT_PEER_MULTI_ADDRS="/ip4/38.101.215.13/tcp/30002/p2p/QmQ2gEXoPJg6iMBSUFWGzAabS2VhnzuS782Y637hGjfsRJ" # gensyn coordinator node
PEER_MULTI_ADDRS=${PEER_MULTI_ADDRS:-$DEFAULT_PEER_MULTI_ADDRS}

# Check if host multi-address is given else set to default
DEFAULT_HOST_MULTI_ADDRS="/ip4/0.0.0.0/tcp/38331"
HOST_MULTI_ADDRS=${HOST_MULTI_ADDRS:-$DEFAULT_HOST_MULTI_ADDRS}

# Path to an RSA private key. If this path does not exist, a new key pair will be created.
# Remove this file if you want a new PeerID.
DEFAULT_IDENTITY_PATH="$ROOT"/swarm.pem
IDENTITY_PATH=${IDENTITY_PATH:-$DEFAULT_IDENTITY_PATH}

SMALL_SWARM_CONTRACT="0x69C6e1D608ec64885E7b185d39b04B491a71768C"
BIG_SWARM_CONTRACT="0x6947c6E196a48B77eFa9331EC1E3e45f3Ee5Fd58"

# Will ignore any visible GPUs if set.
CPU_ONLY=${CPU_ONLY:-"1"}

# Set if successfully parsed from modal-login/temp-data/userData.json.
ORG_ID=${ORG_ID:-""}

GREEN_TEXT="\033[32m"
BLUE_TEXT="\033[34m"
RESET_TEXT="\033[0m"

echo_green() {
    echo -e "$GREEN_TEXT$1$RESET_TEXT"
}

echo_blue() {
    echo -e "$BLUE_TEXT$1$RESET_TEXT"
}

ROOT_DIR="$(cd $(dirname ${BASH_SOURCE[0]}) && pwd)"

# Function to clean up the server process upon exit
cleanup() {
    echo_green ">> Shutting down trainer..."

    # Remove modal credentials if they exist
    rm -r $ROOT_DIR/modal-login/temp-data/*.json 2> /dev/null || true

    # Kill all processes belonging to this script's process group
    kill -- -$$ || true

    exit 0
}

# Function to check and cleanup existing processes
check_and_cleanup_processes() {
    echo_green ">> Checking and cleaning up existing processes..."
    if [ -f "$ROOT/swarm.pem" ]; then
        echo_green ">> Found swarm.pem file: $ROOT/swarm.pem"
        for pid in $(lsof -t "$ROOT/swarm.pem" 2>/dev/null); do
            echo_green ">> Found process using swarm.pem: $pid"
            if kill -9 $pid 2>/dev/null; then
                echo_green ">> Successfully terminated process: $pid"
            fi
        done
        sleep 2
    fi

    for pid in $(pgrep -f "hivemind"); do
        echo_green ">> Found hivemind related process: $pid"
        if kill -9 $pid 2>/dev/null; then
            echo_green ">> Successfully terminated process: $pid"
        fi
    done
    sleep 2

    echo_green ">> Cleaning up semaphores..."
    for sem in $(ipcs -s | awk '{print $2}' | tail -n +3); do
        ipcrm -s $sem 2>/dev/null || true
    done
}

trap cleanup EXIT

echo -e "\033[38;5;224m"
cat << "EOF"
    ██████  ██            ███████ ██     ██  █████  ██████  ███    ███
    ██   ██ ██            ██      ██     ██ ██   ██ ██   ██ ████  ████
    ██████  ██      █████ ███████ ██  █  ██ ███████ ██████  ██ ████ ██
    ██   ██ ██                 ██ ██ ███ ██ ██   ██ ██   ██ ██  ██  ██
    ██   ██ ███████       ███████  ███ ███  ██   ██ ██   ██ ██      ██

    From Gensyn

EOF

# Automatically set connection to testnet
CONNECT_TO_TESTNET=True
echo_green ">> Connecting to Testnet"

if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS version
    SWARM_CONTRACT="$SMALL_SWARM_CONTRACT"
    pc=0.5
else
    # Linux version - default to small swarm and 0.5B parameters
    SWARM_CONTRACT="$SMALL_SWARM_CONTRACT"
    pc=0.5
fi

# Run modal_login server.
echo "Please login to create an Ethereum Server Wallet"
cd modal-login

# Node.js + NVM setup
if ! command -v node > /dev/null 2>&1; then
    echo "Node.js not found. Installing NVM and latest Node.js..."
    export NVM_DIR="$HOME/.nvm"
    if [ ! -d "$NVM_DIR" ]; then
        curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.7/install.sh | bash
    fi
    [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
    [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
    nvm install node
else
    echo "Node.js is already installed: $(node -v)"
fi

if ! command -v yarn > /dev/null 2>&1; then
    # Detect Ubuntu (including WSL Ubuntu) and install Yarn accordingly
    if grep -qi "ubuntu" /etc/os-release 2> /dev/null || uname -r | grep -qi "microsoft"; then
        echo "Detected Ubuntu or WSL Ubuntu. Installing Yarn via apt..."
        curl -sS https://dl.yarnpkg.com/debian/pubkey.gpg | sudo apt-key add -
        echo "deb https://dl.yarnpkg.com/debian/ stable main" | sudo tee /etc/apt/sources.list.d/yarn.list
        sudo apt update && sudo apt install -y yarn
    else
        echo "Yarn not found. Installing Yarn globally with npm..."
        npm install -g --silent yarn
    fi
fi

echo "Starting modal-login service..."
mkdir -p modal-login/logs
yarn install
yarn dev > modal-login/logs/server.log 2>&1 &

SERVER_PID=$!
echo "Started server process: $SERVER_PID"
sleep 3
if ! ps -p $SERVER_PID > /dev/null; then
    echo "Warning: modal-login service failed to start, check logs for details"
    cat modal-login/logs/server.log
    echo "Attempting to restart service..."
    yarn dev > modal-login/logs/server.log 2>&1 &
    SERVER_PID=$!
    sleep 3
    
    if ! ps -p $SERVER_PID > /dev/null; then
        echo "Error: Unable to start modal-login service, please check dependencies and configuration"
        exit 1
    fi
fi

echo "modal-login service started successfully, PID: $SERVER_PID"

# Try to open the URL in the default browser
if open http://localhost:3000 2> /dev/null; then
    echo_green ">> Successfully opened http://localhost:3000 in your default browser."
else
    echo ">> Failed to open http://localhost:3000. Please open it manually."
fi

cd ..

echo_green ">> Waiting for modal userData.json to be created..."
while [ ! -f "modal-login/temp-data/userData.json" ]; do
    sleep 5
done
echo "Found userData.json. Proceeding..."

ORG_ID=$(awk 'BEGIN { FS = "\"" } !/^[ \t]*[{}]/ { print $(NF - 1); exit }' modal-login/temp-data/userData.json)
echo "Your ORG_ID is set to: $ORG_ID"

# Wait until the API key is activated by the client
echo "Waiting for API key to become activated..."
while true; do
    STATUS=$(curl -s "http://localhost:3000/api/get-api-key-status?orgId=$ORG_ID")
    if [[ "$STATUS" == "activated" ]]; then
        echo "API key is activated! Proceeding..."
        break
    else
        echo "Waiting for API key to be activated..."
        sleep 5
    fi
done

ENV_FILE="$ROOT"/modal-login/.env
if [[ "$OSTYPE" == "darwin"* ]]; then
    # macOS version
    sed -i '' "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
else
    # Linux version
    sed -i "3s/.*/SMART_CONTRACT_ADDRESS=$SWARM_CONTRACT/" "$ENV_FILE"
fi

pip_install() {
    pip install --disable-pip-version-check -q -r "$1" --timeout 60 --retries 10 || {
        echo_green ">> First pip install attempt failed, trying with Aliyun mirror..."
        pip install --disable-pip-version-check -q -r "$1" --timeout 60 --retries 10 --index-url https://mirrors.aliyun.com/pypi/simple/ || {
            echo_green ">> Second pip install attempt failed, trying with Tsinghua mirror..."
            pip install --disable-pip-version-check -q -r "$1" --timeout 60 --retries 10 --index-url https://pypi.tuna.tsinghua.edu.cn/simple/
        }
    }
}

echo_green ">> Installing requirements..."

pip install --upgrade pip
if [ -n "$CPU_ONLY" ] || ! command -v nvidia-smi &> /dev/null; then
    # CPU-only mode or no NVIDIA GPU found
    echo_green ">> Using CPU mode"
    pip_install "$ROOT"/requirements-cpu.txt
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
    GAME="gsm8k"
    export CUDA_VISIBLE_DEVICES=""
    CPU_ONLY="1"
else
    # NVIDIA GPU found - still default to CPU mode
    echo_green ">> NVIDIA GPU detected but defaulting to CPU mode"
    pip_install "$ROOT"/requirements-cpu.txt
    CONFIG_PATH="$ROOT/hivemind_exp/configs/mac/grpo-qwen-2.5-0.5b-deepseek-r1.yaml"
    GAME="gsm8k"
    export CUDA_VISIBLE_DEVICES=""
    CPU_ONLY="1"
fi

echo_green ">> Installation complete!"

HUGGINGFACE_ACCESS_TOKEN="None"

echo_green ">> Good luck in the swarm!"
echo_blue ">> Post about rl-swarm on X/twitter! --> https://tinyurl.com/swarmtweet"
echo_blue ">> And remember to star the repo on GitHub! --> https://github.com/gensyn-ai/rl-swarm"

# Function to run training
run_training() {
    if [ -n "$ORG_ID" ]; then
        python -m hivemind_exp.gsm8k.train_single_gpu \
            --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
            --identity_path "$IDENTITY_PATH" \
            --modal_org_id "$ORG_ID" \
            --contract_address "$SWARM_CONTRACT" \
            --config "$CONFIG_PATH" \
            --game "$GAME"
    else
        python -m hivemind_exp.gsm8k.train_single_gpu \
            --hf_token "$HUGGINGFACE_ACCESS_TOKEN" \
            --identity_path "$IDENTITY_PATH" \
            --public_maddr "$PUB_MULTI_ADDRS" \
            --initial_peers "$PEER_MULTI_ADDRS" \
            --host_maddr "$HOST_MULTI_ADDRS" \
            --config "$CONFIG_PATH" \
            --game "$GAME"
    fi
}

# Main training loop with retry logic
while true; do
    # Clean up processes before starting training
    check_and_cleanup_processes
    echo_green ">> Starting training attempt $((RETRY_COUNT + 1))"

    # Run training
    if run_training; then
        echo_green ">> Training completed successfully"
    else
        echo_green ">> Training failed, will retry after $RETRY_DELAY seconds"
        sleep $RETRY_DELAY
    fi

    # Increment retry count
    RETRY_COUNT=$((RETRY_COUNT + 1))
done

wait  # Keep script running until Ctrl+C
