# 🤖 PWR Validator Node Monitor

This script is an all-in-one solution for monitoring, maintaining, and managing a PWR Validator node. It automates common tasks such as checking validator status, handling updates, restarting on standby, and sending detailed notifications to your Telegram.

## ✨ Key Features

  - **Automatic Restart:** 🔄 Proactively restarts the validator if it enters `standby` mode or appears stalled.
  - **Version Management:** ⬆️ Automatically checks for new `validator.jar` versions and performs updates.
  - **Network Reset Detection:** 🌐 Identifies potential network resets by comparing local block height with the network's and triggers a full data reset and update.
  - **Telegram Notifications:** 📢 Sends detailed status reports, update notifications, and error alerts directly to your Telegram chat.
  - **Dependency Management:** 📦 Checks for and attempts to install required system packages like Java, JQ, and Curl.
  - **Corrupt JAR Detection:** 🔍 Identifies a corrupted `validator.jar` file from logs and automatically re-downloads it.
  - **Automatic Faucet Claim:** 🚰 If a `DISCORD_TOKEN` is provided, it will automatically claim from the faucet after a network reset.
  - **Dynamic Bash Aliases:** 🪄 Creates and manages a set of helpful command-line aliases for easy node management.

-----

## 1\. 💻 System Requirements
  - **Full Guide:** [PWR-Validator official repository.](https://github.com/pwrlabs/PWR-Validator/blob/main/README.md)
  - **OS:** A Debian-based Linux distribution (like Ubuntu) is recommended, as the script uses `apt-get` for dependency installation.
  - **Shell:** `bash`
  - **Required Packages:**
      - `curl`
      - `wget`
      - `jq`
      - `btop` (optional, for system monitoring)
      - `vnstat` (optional, for network monitoring)
      - `openjdk-21-jdk` (or newer)
      - `nodejs` and `npm` (only required if using the Discord faucet claim feature)

*The script will attempt to automatically install these dependencies if they are not found.*

-----

## 2\. 📁 Project Structure

For the script to function correctly, you must place its files inside your main PWR validator directory. The final structure should look like this:

```

/your/pwr/directory/
├── wallet             # <-- Your validator wallet file
├── password           # <-- Your validator password file
├── validator.jar      # (Will be downloaded by the script)
├── config.json        # (Will be downloaded by the script)
├── blocks/            # (Created automatically)
├── merkleTree/        # (Created automatically)
├── log.out            # (Created automatically)
├── pwr.sh             # The main monitoring script
├── .env               # (You will create this file)
└── faucet/            # <-- Directory for the faucet claimer script
    ├── faucet.js
    ├── package.json
    └── session.json

```

-----

## 3\. ⚙️ How It Works

This script operates through a sequence of checks and actions to ensure your validator node is always online and up-to-date. The entire process is kicked off from the `main` function.

1.  **🚀 Initialization:**

      * The script first determines its own location to dynamically set paths for all necessary files like `wallet`, `password`, `validator.jar`, and `log.out`.
      * It detects the server's public IP address, which is crucial for the validator to announce itself correctly on the network.
      * It loads all necessary configurations (like your `VALIDATOR_ADDRESS` and `TELEGRAM_TOKEN`) from the `.env` file.

2.  **🔧 Dependency & Environment Setup:**

      * **`check_and_install_dependencies`:** The script checks if essential tools like `java`, `curl`, and `jq` are installed. If they are missing, it attempts to install them using `apt-get`. It will also install Node.js if a `DISCORD_TOKEN` is provided for the faucet.
      * **`manage_bash_aliases`:** It automatically creates or updates a set of helpful command-line shortcuts (e.g., `pwrlogs`, `pwrstop`) in your `~/.bash_aliases` file for easier manual management.

3.  **🔎 Main Status Check (`check_validator_status`):** This is the core logic loop of the script.

      * **Network Reset Detection:** It first fetches the latest block height from both your local node and the public network explorer. If your local node is significantly ahead of the network, it assumes a network reset has occurred. It then triggers `perform_update` with a special flag to delete old blockchain data (`/blocks` and `/merkleTree`) before downloading the new version.
      * **New or Syncing Node:** If the PWR RPC reports that your address is "not a validator," the script assumes the node is new or syncing. It checks if the process is actively syncing blocks by comparing the latest block number over a 5-second interval. If it's not making progress, it restarts the validator process to kickstart it.
      * **Active/Standby Validator:** If the node is a recognized validator, the script fetches detailed status information, including its status (`active` or `standby`), total blocks created, and version information.
      * **Version Check:** It compares your local `validator.jar` version against the latest release on GitHub. If a new version is available, it automatically triggers the `perform_update` function.
      * **Proactive Restart:** If the validator's status is `standby`, the script initiates a proactive restart to try and get it back into an `active` state.

4.  **🔔 Notifications:**

      * Throughout this entire process, the `send_telegram` function is called to send detailed, formatted messages to your configured Telegram chat. This ensures you are always aware of the node's status, any actions being taken (like updates or restarts), and any errors that occur.

5.  **🚰 Faucet Claim Process (`faucet.js`):**

      * This process is **only triggered automatically after a network reset is detected** and only if you have provided your `DISCORD_TOKEN` in the `.env` file.
      * The `pwr.sh` script calls the `faucet/faucet.js` Node.js script.
      * First, it checks your validator's balance. If you have a balance greater than 0, the process stops to avoid unnecessary claims.
      * To communicate with Discord's API, it needs a temporary `session_id`. It connects to Discord's real-time Gateway (via WebSocket) and identifies itself using your token to receive this ID. The ID is then cached in `faucet/session.json` for future use.
      * Finally, it sends an HTTP POST request to Discord's API, simulating the `/claim` slash command in the official PWR Discord channel, which requests faucet funds for your validator address.
        > **⚠️ Important:**  
        > I take no responsibility for any actions taken against your account for using these script or how users use my open-source code.  
        > Using this on a user account is prohibited by the [Discord TOS](https://discord.com/terms) and can lead to your account getting banned in very rare cases.

-----

## 4\. 🛠️ How to Use

Follow these steps to set up the monitor.

### Step 1: Place The Script 📍

Move the `pwr.sh` script and the entire `faucet` directory into the same directory where your `validator.jar`, `wallet`, and `password` files are located.

### Step 2: Configure Environment Variables 🔑

The script uses a `.env` file to store your sensitive information. The first time you run `pwr.sh`, it will create this file for you if it doesn't exist.

1.  Run the script once: `./pwr.sh`

2.  It will create a `.env` file. Open it with a text editor: `nano .env`

3.  Fill in the required details:

    ```dotenv
    # --- PWR Validator Configuration ---
    # The address of the validator you are monitoring.
    VALIDATOR_ADDRESS=0xYourValidatorAddressHere

    # --- Telegram Bot Configuration ---
    # Your Telegram bot token from BotFather.
    TELEGRAM_TOKEN=your_telegram_bot_token_here
    # Your personal or group chat ID.
    CHAT_ID=your_telegram_chat_id_here

    # --- (Optional) Discord Faucet Configuration ---
    # Your Discord authorization token for the faucet.
    # This is only needed for automatic faucet claims after a network reset.
    DISCORD_TOKEN=your_discord_auth_token_here
    ```
    
    > [Create your own Telegram Bot](https://t.me/BotFather). \
    > [How to get Discord Token](https://t.me/NoDropsChat/4297).

### Step 3: Set Up Crontab for Automation ⏰

To have the script run automatically at regular intervals (e.g., every 5 minutes), you need to add it to your crontab.

1.  Open the crontab editor:

    ```bash
    crontab -e
    ```

2.  Add the following line to the end of the file. **Make sure to replace `/path/to/your/pwr.sh` with the actual, full path to the script.**

    ```crontab
    */5 * * * * /path/to/your/pwr.sh
    ```

    *This configuration will execute the script every 5 minutes.*

3.  Save and exit the editor.

### Step 4: Use the New Bash Aliases ✨

For a better management experience, this script automatically adds a set of useful aliases to your `~/.bash_aliases` file.

**To start using them, you must either restart your terminal session or run:**

```bash
source ~/.bash_aliases
```

Here are the aliases that will be available:

| Alias       | Description                                                          |
| :---------- | :------------------------------------------------------------------- |
| `pwrlogs`   | View the live validator logs (`tail -f /your/pwr/directory/log.out`).                    |
| `pwrstop`   | Forcefully stops the validator Java process.                         |
| `pwrrestart`| Manually runs the `pwr.sh` script to check status and restart if needed. |
| `pwrblock`  | Shows only the "Block created" lines from the log.                   |
| `pwraddress`| Displays your validator's public address.                            |
| `pwrseed`   | Displays your validator's seed phrase.                               |

-----


## 🤝 Contributing

Contributions are what make the open-source community such an amazing place to learn, inspire, and create. Any contributions you make are **greatly appreciated**.

If you have a suggestion that would make this project better, please fork the repository and create a pull request. You can also simply open an issue with the tag "enhancement".

Don't forget to give the project a star! ⭐ Thanks again!


## ⚠️ **Disclaimer**

This bot is provided **"as is"**, without any warranties.  
You're fully responsible for any actions taken using this tool. Understand the risks before proceeding.



## 📜 **License**

This project is licensed under the [MIT License](https://opensource.org/license/mit).

**Enjoy your automated and smoothly running PWR Validator\! 🎉**
