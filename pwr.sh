#!/bin/bash

set -e

# --- Dynamic Path and Environment Setup ---
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
PWR_DIR="$SCRIPT_DIR" # The script is inside the pwr directory.

# Define paths for critical files dynamically.
ENV_FILE="${PWR_DIR}/.env"
WALLET_FILE="${PWR_DIR}/wallet"
PASSWORD_FILE="${PWR_DIR}/password"
LOG_FILE="${PWR_DIR}/log.out"
VALIDATOR_JAR_PATH="${PWR_DIR}/validator.jar"
CONFIG_FILE_PATH="${PWR_DIR}/config.json"
BLOCKS_DIR="${PWR_DIR}/blocks"
MERKLE_TREE_DIR="${PWR_DIR}/merkleTree"

# --- Automatic IP Address Detection ---
# Fetches the public IP of the server to ensure the validator uses the correct one.
echo "[INFO] Detecting public IP address..."
PUBLIC_IP=$(curl -s https://api.ipify.org/)
if [ -z "$PUBLIC_IP" ]; then
    echo "[ERROR] Failed to retrieve public IP address. Please check your internet connection." >&2
    exit 1
fi
echo "[INFO] Server public IP detected: $PUBLIC_IP"


# --- .env File and Configuration Loading ---
# Check if the .env file exists. If not, create it and instruct the user.
if [ ! -f "$ENV_FILE" ]; then
  echo "[WARN] .env file not found at ${ENV_FILE}."
  echo "[INFO] Creating a new .env file. Please edit it with your details."
  cat > "$ENV_FILE" <<EOL
# --- Telegram Bot Configuration ---
# Your Telegram bot token from BotFather.
TELEGRAM_TOKEN=
# Your personal or group chat ID.
CHAT_ID=

# --- PWR Validator Configuration ---
# The address of the validator you are monitoring.
VALIDATOR_ADDRESS=

# --- (Optional) Discord Faucet Configuration ---
# Your Discord authorization token for the faucet.
# If you leave this blank, the faucet claim will be skipped.
DISCORD_TOKEN=
EOL
  echo "[ACTION] .env file created. Please fill in your details in ${ENV_FILE} and run the script again."
  exit 1
fi

# Load the environment variables from the .env file.
set -a
source "$ENV_FILE"
set +a
echo "[INFO] Loaded configuration from ${ENV_FILE}"

# --- Validate Required Configuration ---
# Check if the essential variables from the .env file have been set.
if [ -z "$VALIDATOR_ADDRESS" ]; then
  echo "[ERROR] The required VALIDATOR_ADDRESS variable is missing in ${ENV_FILE}." >&2
  echo "[ERROR] Please ensure VALIDATOR_ADDRESS is set." >&2
  exit 1
fi

# Warn if Telegram variables are missing, but don't exit.
if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$CHAT_ID" ]; then
  echo "[WARN] TELEGRAM_TOKEN or CHAT_ID are not set in ${ENV_FILE}. Telegram notifications will be disabled."
fi


# --- Validate Critical Validator Files ---
if [ ! -f "$WALLET_FILE" ]; then
    echo "[ERROR] Validator wallet file not found at ${WALLET_FILE}" >&2
    echo "[ERROR] The script cannot proceed without the wallet file." >&2
    send_telegram "❌ *Fatal Error:* Validator wallet file not found at \`${WALLET_FILE}\`. Script is stopping."
    exit 1
fi
if [ ! -f "$PASSWORD_FILE" ]; then
    echo "[ERROR] Validator password file not found at ${PASSWORD_FILE}" >&2
    echo "[ERROR] The script cannot proceed without the password file." >&2
    send_telegram "❌ *Fatal Error:* Validator password file not found at \`${PASSWORD_FILE}\`. Script is stopping."
    exit 1
fi
echo "[INFO] Validator wallet and password files found."


# --- Configuration and Global Variables ---
TELEGRAM_API="https://api.telegram.org/bot${TELEGRAM_TOKEN}/sendMessage"
API_URL="https://pwrrpc.pwrlabs.io/validator?validatorAddress=${VALIDATOR_ADDRESS}"
BLOCKS_URL="https://explorerbe.pwrlabs.io/blocksCreated/?validatorAddress=${VALIDATOR_ADDRESS}&page=1&count=1"
LATEST_BLOCK_URL="https://explorerbe.pwrlabs.io/latestBlocks/?page=1&count=1"
BLOCK_EXPLORER_URL="https://explorer.pwrlabs.io/blocks"
VALIDATOR_EXPLORER_URL="https://explorer.pwrlabs.io/address/${VALIDATOR_ADDRESS}"
PWR_RELEASES_API_URL="https://api.github.com/repos/pwrlabs/PWR-Validator/releases/latest"
LATEST_VALIDATOR_JAR_URL="https://github.com/pwrlabs/PWR-Validator/releases/latest/download/validator.jar"
LATEST_CONFIG_URL="https://github.com/pwrlabs/PWR-Validator/raw/main/config.json"


# --- Core Functions ---

send_telegram() {
  local message="$1"
  # If Telegram credentials are not set, do nothing.
  if [ -z "$TELEGRAM_TOKEN" ] || [ -z "$CHAT_ID" ]; then
    return 0
  fi

  if ! command -v curl &> /dev/null; then
      echo "[ERROR] 'curl' is not installed, cannot send Telegram message." >&2
      return 1
  fi
  # Send the message with disable_web_page_preview=true to prevent link previews.
  curl -s -X POST "$TELEGRAM_API" \
        -d chat_id="$CHAT_ID" \
        -d parse_mode="Markdown" \
        -d disable_web_page_preview=true \
        --data-urlencode text="$message" > /dev/null
}

restart_validator() {
  echo "[INFO] Attempting to restart the validator..."
  send_telegram "⚠️ *Validator Restart Triggered!*
Attempting to restart validator with IP: \`$PUBLIC_IP\`"

  # Forcefully stop any running Java processes to ensure a clean start.
  sudo pkill java || echo "[INFO] No running Java process to kill."
  sleep 5
  sudo pkill -9 java

  # Clear the log file for the new session.
  echo "[INFO] Cleaning log file..."
  echo "" > "$LOG_FILE"

  # Change to the PWR directory to run the validator.
  cd "$PWR_DIR" || {
    echo "[ERROR] Failed to cd into ${PWR_DIR}";
    send_telegram "❌ *Restart Error:* Failed to change directory to \`${PWR_DIR}\`";
    exit 1;
  }

  # Start the validator in the background using the detected public IP.
  nohup sudo java --enable-native-access=ALL-UNNAMED -Xms1g -Xmx6g -jar "$VALIDATOR_JAR_PATH" --ip "$PUBLIC_IP" --password "$PASSWORD_FILE" >> "$LOG_FILE" 2>&1 &

  if [ $? -eq 0 ]; then
    echo "[INFO] Validator restart command issued successfully."
    send_telegram "✅ *Validator Restarted*
Now running with IP: \`$PUBLIC_IP\`
Check logs for detailed status."
  else
    echo "[ERROR] Failed to issue validator restart command."
    send_telegram "❌ *Restart Failed:* Could not start the validator process. Please check manually."
  fi
}

manage_bash_aliases() {
  echo "[INFO] Managing .bash_aliases..."
  local HOME_ALIASES="${HOME}/.bash_aliases"
  local TEMP_ALIASES
  TEMP_ALIASES=$(mktemp) # Create a secure temporary file

  local ALIAS_MARKER="# BEGIN PWR Validator Aliases"
  local END_ALIAS_MARKER="# END PWR Validator Aliases"

  # If the original .bash_aliases exists, filter out the old PWR block.
  if [ -f "$HOME_ALIASES" ]; then
    awk "
      /${ALIAS_MARKER}/ { in_block=1 }
      !in_block { print }
      /${END_ALIAS_MARKER}/ { in_block=0 }
    " "$HOME_ALIASES" > "$TEMP_ALIASES"
  fi

  echo "[INFO] Adding/updating dynamic PWR aliases in ${HOME_ALIASES}."

  # Append the new, updated aliases to the temporary file.
  cat >> "$TEMP_ALIASES" << EOL
${ALIAS_MARKER}
# These aliases are dynamically set by pwr.sh. Do not edit this block manually.
# Current PWR Directory: ${PWR_DIR}
alias pwrlogs='tail -f -n 1000 "${PWR_DIR}/log.out"'
alias pwrstop='sudo pkill java && sleep 5 && sudo pkill -9 java'
alias pwrrestart='(cd "${PWR_DIR}" && ./"$(basename "${BASH_SOURCE[0]}")")'
alias pwrblock='grep "Block created" "${PWR_DIR}/log.out"'
alias pwraddress='(cd "${PWR_DIR}" && sudo java -jar validator.jar get-address password)'
alias pwrseed='(cd "${PWR_DIR}" && sudo java -jar validator.jar get-seed-phrase password)'
${END_ALIAS_MARKER}
EOL

  # Replace the original .bash_aliases with the updated temporary file.
  mv "$TEMP_ALIASES" "$HOME_ALIASES"

  echo "[INFO] PWR aliases have been configured in ${HOME_ALIASES}."
  echo "[ACTION] Please run 'source ~/.bash_aliases' or restart your terminal to use them."

  # Remove the old static alias file if it exists.
  if [ -f "${PWR_DIR}/.bash_aliases" ]; then
      echo "[INFO] Removing old static .bash_aliases file from ${PWR_DIR}."
      rm -f "${PWR_DIR}/.bash_aliases"
  fi
}

check_and_install_dependencies() {
  echo "[INFO] Checking for required dependencies..."
  local dependencies_met=true

  if ! command -v btop &> /dev/null; then
    echo "[WARN] 'btop' is not installed. Attempting to install..."
    sudo apt-get update && sudo apt-get install -y btop || dependencies_met=false
  fi

  if ! command -v vnstat &> /dev/null; then
    echo "[WARN] 'vnstat' is not installed. Attempting to install..."
    sudo apt-get update && sudo apt-get install -y vnstat || dependencies_met=false
  fi

  if ! command -v jq &> /dev/null; then
    echo "[WARN] 'jq' is not installed. Attempting to install..."
    sudo apt-get update && sudo apt-get install -y jq || dependencies_met=false
  fi

  if ! command -v wget &> /dev/null; then
    echo "[WARN] 'wget' is not installed. Attempting to install..."
    sudo apt-get update && sudo apt-get install -y wget || dependencies_met=false
  fi

  if ! command -v curl &> /dev/null; then
    echo "[WARN] 'curl' is not installed. Attempting to install..."
    sudo apt-get update && sudo apt-get install -y curl || dependencies_met=false
  fi

  if ! $dependencies_met; then
    echo "[ERROR] Failed to install required dependencies. Please install them manually." >&2
    send_telegram "❌ *Dependency Error:* Failed to auto-install dependencies. Please install manually."
    exit 1
  fi

  if ! command -v java &> /dev/null; then
    echo "[INFO] Java not found. Attempting to install OpenJDK 21..."
    send_telegram "☕️ *Java Not Found*
Starting automatic installation of OpenJDK 21. This may take a few minutes."
    
    sudo apt-get update
    sudo apt-get install -y openjdk-21-jdk
    
    if command -v java &> /dev/null; then
        echo "[INFO] Java installed successfully."
        send_telegram "✅ *Java Installation Successful*"
        java -version
    else
        echo "[ERROR] Java installation failed." >&2
        send_telegram "❌ *Java Installation Failed*. Please install Java 21 manually."
        exit 1
    fi
  else
    echo "[INFO] Java is already installed."
  fi

  # Conditionally check for Node.js if DISCORD_TOKEN is set for the faucet.
  if [ -n "$DISCORD_TOKEN" ]; then
    echo "[INFO] DISCORD_TOKEN is set. Checking for Node.js for faucet functionality."
    if ! command -v node &> /dev/null; then
        echo "[WARN] Node.js is not installed, but is required for the faucet. Attempting to install..."
        curl -fsSL https://deb.nodesource.com/setup_lts.x | sudo -E bash -
        sudo apt-get install -y nodejs
    fi

    if command -v node &> /dev/null; then
        echo "[INFO] Node.js is installed."
        local FAUCET_DIR="${PWR_DIR}/faucet"
        if [ -f "${FAUCET_DIR}/package.json" ] && [ ! -d "${FAUCET_DIR}/node_modules" ]; then
            echo "[INFO] Faucet dependencies are missing. Running 'npm install'..."
            (cd "$FAUCET_DIR" && npm install) || echo "[WARN] 'npm install' failed. Faucet claim might not work."
        fi
    else
        echo "[ERROR] Failed to install Node.js. Faucet claims will fail."
        send_telegram "❌ *Node.js Installation Failed*
Automatic installation of Node.js failed. Faucet claims will not work."
    fi
  fi
}

get_local_version() {
  if [ ! -f "$VALIDATOR_JAR_PATH" ]; then echo "Error: JAR_NOT_FOUND"; return; fi
  # Try common ways to get version string from validator.jar
  local version
  version=$(sudo java -jar "$VALIDATOR_JAR_PATH" --version 2>/dev/null | grep 'Validator Version:' | awk '{print $3}')
  [ -n "$version" ] && { echo "$version"; return; }
  version=$(sudo java -jar "$VALIDATOR_JAR_PATH" 2>/dev/null | grep 'Version' | awk '{print $7}')
  [ -n "$version" ] && { echo "$version"; return; }
  echo "Error: VERSION_READ_FAILED"
}

get_latest_version() {
  local latest_tag
  latest_tag=$(curl -s "$PWR_RELEASES_API_URL" | jq -r .tag_name)
  if [ -n "$latest_tag" ] && [ "$latest_tag" != "null" ]; then
    echo "$latest_tag"
  else
    echo "Error: GITHUB_FETCH_FAILED"
  fi
}

get_latest_synced_block() {
  if [ ! -d "$BLOCKS_DIR" ] || [ -z "$(ls -A "$BLOCKS_DIR")" ]; then
    echo 0
    return
  fi
  ls -v "$BLOCKS_DIR" | tail -n 1
}

is_node_actively_syncing() {
  echo "[INFO] Checking for active block syncing over 5 seconds..."
  local start_block end_block
  start_block=$(get_latest_synced_block)
  echo "[INFO] Initial synced block: ${start_block}"
  sleep 5
  end_block=$(get_latest_synced_block)
  echo "[INFO] Synced block after 5 seconds: ${end_block}"

  if [ "$end_block" -gt "$start_block" ]; then
    echo "[INFO] Syncing is active."
    return 0 # true
  else
    echo "[INFO] Syncing is not active or is stalled."
    return 1 # false
  fi
}

check_for_corrupt_jar() {
  echo "[INFO] Checking for corrupt JAR file error in logs..."
  if [ -s "$LOG_FILE" ]; then
    if grep -q "Invalid or corrupt jarfile" "$LOG_FILE"; then
      echo "[CRITICAL] Corrupt validator.jar file detected!"
      send_telegram "🚨 *Corrupt JAR File Detected!*
The validator.jar file is corrupted. Attempting to re-download and fix automatically."
      
      local latest_version
      latest_version=$(get_latest_version)
      
      # An update will remove the old jar and download a new one.
      perform_update "${latest_version:-latest}" false
      
      return 0 # true
    fi
  fi
  echo "[INFO] No corrupt JAR file error found."
  return 1 # false
}

perform_update() {
  local new_version="$1"
  local is_reset="${2:-false}" # Default to false if not provided

  send_telegram "🚀 *Updating PWR Validator to ${new_version}...*"
  echo "[INFO] Starting full update process for version ${new_version}..."

  # 1. Stop any running validator
  echo "[INFO] Stopping current validator process..."
  sudo pkill java || echo "[INFO] No running Java process to kill."
  sleep 5
  sudo pkill -9 java

  # If it's a network reset, delete data and optionally claim from faucet.
  if [ "$is_reset" = true ]; then
      echo "[INFO] Deleting old blockchain data due to network reset..."
      sudo rm -rf "$BLOCKS_DIR" "$MERKLE_TREE_DIR"
      echo "[INFO] ./blocks and ./merkleTree directories deleted."
      send_telegram "🗑️ *Old Data Cleared*
Local blocks and merkleTree data have been removed for the reset."
      
      if [ -n "$DISCORD_TOKEN" ]; then
          local FAUCET_DIR="${PWR_DIR}/faucet"
          if [ -f "${FAUCET_DIR}/faucet.js" ] && command -v node &> /dev/null; then
              echo "[INFO] Attempting to claim faucet tokens via faucet.js..."
              (cd "$FAUCET_DIR" && node faucet.js) || echo "[WARN] faucet.js script failed. Please check its logs."
          else
              echo "[WARN] faucet.js not found or Node.js not installed. Skipping faucet claim."
          fi
      else
          echo "[INFO] DISCORD_TOKEN not set in .env. Skipping faucet claim."
      fi
      sleep 5
  fi

  # 2. Remove old files
  echo "[INFO] Removing old validator.jar and config.json..."
  sudo rm -f "${VALIDATOR_JAR_PATH}" "${CONFIG_FILE_PATH}"

  # 3. Download new files
  local jar_download_ok=false
  local config_download_ok=false

  echo "[INFO] Downloading new validator.jar..."
  if sudo wget -q -O "${VALIDATOR_JAR_PATH}" "$LATEST_VALIDATOR_JAR_URL" && [ -s "${VALIDATOR_JAR_PATH}" ]; then
    echo "[INFO] validator.jar downloaded successfully."
    jar_download_ok=true
  else
    echo "[ERROR] Failed to download or downloaded validator.jar is empty."
  fi

  echo "[INFO] Downloading new config.json..."
  if sudo wget -q -O "${CONFIG_FILE_PATH}" "$LATEST_CONFIG_URL" && [ -s "${CONFIG_FILE_PATH}" ]; then
    echo "[INFO] config.json downloaded successfully."
    config_download_ok=true
  else
    echo "[ERROR] Failed to download or downloaded config.json is empty."
  fi

  # 4. Restart if downloads were successful
  if $jar_download_ok && $config_download_ok; then
    echo "[INFO] Both files updated successfully. Restarting validator..."
    send_telegram "✅ *Update Complete!* New version ${new_version} and config.json downloaded. Restarting..."
    restart_validator
    return 0
  else
    echo "[ERROR] Update failed. One or both files could not be downloaded."
    send_telegram "❌ *Update Failed:* Could not download validator.jar or config.json. Please check the server manually."
    return 1
  fi
}

check_and_update_version() {
  local local_version latest_version
  local_version=$(get_local_version)
  latest_version=$(get_latest_version)

  local version_message="├*Version Status:* \n│  ├─💿 Local: \`${local_version}\` \n│  ├─📀 Latest: \`${latest_version}\`"
  if [[ "$local_version" == "Error: JAR_NOT_FOUND" ]]; then
    version_message+="\n⚠️ *Local validator.jar not found.*"
    if [[ "$latest_version" != "Error:"* ]]; then
      version_message+="\n🚀 *Attempting to download ${latest_version} as a fresh installation...*"
      echo -e "$version_message"
      perform_update "$latest_version" && return 10 || return 1
    else
      version_message+="\n❌ *Cannot fetch latest version. Update failed.*"
      echo -e "$version_message"
      return 2
    fi
  fi

  if [[ "$local_version" == "Error:"* ]] || [[ "$latest_version" == "Error:"* ]]; then
      version_message+="\n⚠️ *Could not verify versions. Update check skipped.*"
      echo -e "$version_message"
      return 2
  fi

  # Simple version comparison by removing non-numeric characters
  local san_local_ver=${local_version//[^0-9]/}
  local san_latest_ver=${latest_version//[^0-9]/}

  if [ "$san_latest_ver" -gt "$san_local_ver" ]; then
    version_message+="\n🚀 *New version available! Initiating update...*"
    echo -e "$version_message"
    perform_update "$latest_version" && return 10 || return 1
  else
    version_message+="\n│  └─✅ *Validator is up to date.*"
    echo -e "$version_message"
    return 0
  fi
}

check_validator_status() {
  echo "[INFO] Checking validator status..."
  
  # --- Network Reset Check ---
  local latest_global_block_data
  latest_global_block_data=$(curl -s "$LATEST_BLOCK_URL")
  local latest_global_block_height
  latest_global_block_height=$(echo "$latest_global_block_data" | jq -r '.blocks[0].blockHeight // 0')
  local latest_local_block
  latest_local_block=$(get_latest_synced_block)

  # Trigger a reset if local block is more than 25 blocks ahead of the network.
  if [[ "$latest_global_block_height" -gt 0 && "$latest_local_block" -gt $((latest_global_block_height + 25)) ]]; then
      echo "[CRITICAL] Network reset detected! Local: ${latest_local_block}, Network: ${latest_global_block_height}."
      send_telegram "🚨 *Network Reset Detected!* 🚨
Your node at block \`${latest_local_block}\` is ahead of network block \`${latest_global_block_height}\`.
Initiating a full node reset and update."
      
      local latest_version
      latest_version=$(get_latest_version)
      perform_update "${latest_version:-latest}" true 
      return
  fi

  # --- New/Syncing Node Check ---
  local data
  data=$(curl -s --max-time 10 "$API_URL")
  local not_a_validator_msg
  not_a_validator_msg=$(echo "$data" | jq -r '.message // ""')

  if [[ "$not_a_validator_msg" == "Address provided is not a validator" ]]; then
    echo "[WARN] Address ${VALIDATOR_ADDRESS} is not yet a validator. Checking node status."
    send_telegram "ℹ️ *New/Syncing Node Detected*
Address is not yet a validator. Checking node status..."
    
    local update_code
    check_and_update_version
    update_code=$?

    if [[ "$update_code" -eq 10 ]]; then
        echo "[INFO] Node was just updated. Assuming sync will begin."
        send_telegram "✅ *Node Updated & Restarted*
Syncing should now be in progress."
        return
    fi

    if is_node_actively_syncing; then
        echo "[INFO] Node is actively syncing blocks. No action needed."
        local current_block=$(get_latest_synced_block)
        send_telegram "✅ *Node is Actively Syncing*
Current Block: \`${current_block}\`"
    else
        echo "[WARN] Node is not actively syncing blocks."
        
        # Check for a corrupt JAR file before restarting.
        if check_for_corrupt_jar; then
            echo "[INFO] Corrupt JAR was handled. Exiting status check for this run."
            return
        fi

        if ! pgrep -f "java.*validator.jar" > /dev/null; then
            echo "[INFO] Validator process is not running. Starting it."
            send_telegram "⚠️ *Stalled/Inactive Node*
The validator process was not running. Attempting to start it."
            restart_validator
        else
            echo "[INFO] Validator process is running but stalled. Forcing a restart."
            send_telegram "⚠️ *Stalled Node Detected*
The validator process is running but not syncing. Forcing a restart."
            restart_validator
        fi
    fi
    return
  fi

  # --- Logic for Active/Standby Validators ---
  local blocks
  blocks=$(curl -s --max-time 10 "$BLOCKS_URL")
  local status
  status=$(echo "$data" | jq -r '.validator.status // "Unknown"')
  local addr
  addr=$(echo "$data" | jq -r '.validator.address // "N/A"')
  local short_addr="${addr:0:6}...${addr: -4}"
  local total_blocks
  total_blocks=$(echo "$blocks" | jq -r '.metadata.totalItems // 0')

  local version_status_message
  local update_code
  version_status_message=$(check_and_update_version)
  update_code=$?

  # --- Fetch Detailed Block Info ---
  local latest_validator_block_data
  latest_validator_block_data=$(echo "$blocks" | jq '.blocks[0]')
  local validator_block_height
  validator_block_height=$(echo "$latest_validator_block_data" | jq -r '.blockHeight // "N/A"')
  local validator_timestamp
  validator_timestamp=$(echo "$latest_validator_block_data" | jq -r '.timeStamp // "N/A"')
  local validator_tx_count
  validator_tx_count=$(echo "$latest_validator_block_data" | jq -r '.txnsCount // "N/A"')
  local validator_reward
  validator_reward=$(echo "$latest_validator_block_data" | jq -r '.blockReward // "N/A"')
  local validator_block_link="${BLOCK_EXPLORER_URL}/${validator_block_height}"
  local validator_time_fmt=""
  if [[ "$validator_timestamp" != "N/A" && "$validator_timestamp" =~ ^[0-9]+$ ]]; then
    validator_time_fmt=$(date -d "@$((${validator_timestamp}/1000))" '+%H:%M:%S %m-%d-%y' 2>/dev/null)
  fi

  local global_block
  global_block=$(echo "$latest_global_block_data" | jq '.blocks[0]')
  local global_block_height
  global_block_height=$(echo "$global_block" | jq -r '.blockHeight // "N/A"')
  local global_block_link="${BLOCK_EXPLORER_URL}/${global_block_height}"
  local global_block_timestamp
  global_block_timestamp=$(echo "$global_block" | jq -r '.timeStamp // "N/A"')
  local global_block_tx_count
  global_block_tx_count=$(echo "$global_block" | jq -r '.txnsCount // "N/A"')
  local global_block_reward
  global_block_reward=$(echo "$global_block" | jq -r '.blockReward // "N/A"')
  local global_time_fmt=""
  if [[ "$global_block_timestamp" != "N/A" && "$global_block_timestamp" =~ ^[0-9]+$ ]]; then
    global_time_fmt=$(date -d "@$global_block_timestamp" '+%H:%M:%S %m-%d-%y' 2>/dev/null)
  fi

  # Construct the final detailed message
  local final_message="🛰 *PWR Validator Node* 🛰
┌────────────────
${version_status_message}
│
├*Validator Info:*
│  ├─*🆔 Address*: [${short_addr}](${VALIDATOR_EXPLORER_URL})
│  ├─*🌐 IP*: \`${PUBLIC_IP}\`
│  ├─*📊 Status*: \`${status}\`
│  └─*⚛ Blocks Created*: \`${total_blocks}\`
│
├*Last Created Block:*
│  ├─*📌 Height*: [${validator_block_height}](${validator_block_link})
│  ├─*🕒 At:* \`${validator_time_fmt}\`
│  ├─*🔄 Transactions:* \`${validator_tx_count}\`
│  └─*🎁 Reward:* \`${validator_reward}\`
│
└*Network Latest Block:*
     ├─*📌 Height:* [${global_block_height}](${global_block_link})
     ├─*🕒 At:* \`${global_time_fmt}\`
     ├─*🔄 Transactions:* \`${global_block_tx_count}\`
     └─*🎁 Reward:* \`${global_block_reward}\`"
  echo -e "$final_message"
  send_telegram "$final_message"

  # If status is standby and an update wasn't just performed, restart proactively.
  if [[ "$status" == "standby" ]] && [[ "$update_code" -ne 10 ]]; then
    echo "[WARN] Validator is in STANDBY. Initiating a proactive restart."
    send_telegram "ℹ️ Validator is in STANDBY. Initiating a proactive restart."
    restart_validator
  fi
}


# --- Main Execution ---
main() {
  echo "================================================="
  echo "[INFO] PWR Validator Watcher Script Started at $(date)"
  
  check_and_install_dependencies
  manage_bash_aliases
  check_validator_status
  
  echo "[INFO] Script Finished at $(date)"
  echo "================================================="
}

main

