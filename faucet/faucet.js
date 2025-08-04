const axios = require('axios');
const fs = require('fs');
const path = require('path');
const FormData = require('form-data');
const WebSocket = require('ws');

require('dotenv').config();

const SESSION_FILE = path.resolve(__dirname, './session.json');
let sessions = {};

const FAUCET_CONFIG = {
    application_id: "1169175472140210196",
    guild_id: "1141787507189624992",
    channel_id: "1142055910001352835",
    command_version: "1199682721748897918",
    command_id: "1199682721748897912",
    command_name: "claim",
};

function saveSessions() {
    try {
        fs.writeFileSync(SESSION_FILE, JSON.stringify(sessions, null, 2));
    } catch (err) {
        console.error(`\x1b[31m[ERROR] Failed to save session file: ${err.message}\x1b[0m`);
    }
}

try {
    if (fs.existsSync(SESSION_FILE)) {
        sessions = JSON.parse(fs.readFileSync(SESSION_FILE, 'utf8'));
    }
} catch (err) {
    console.error(`\x1b[31m[ERROR] Error loading session file: ${err.message}\x1b[0m`);
    sessions = {};
}

async function getValidatorBalance(walletAddress) {
    const url = `https://explorerbe.pwrlabs.io/balanceOf/?userAddress=${walletAddress}`;
    console.log(`\x1b[36m[INFO] Checking balance for address: ${walletAddress}\x1b[0m`);
    try {
        const response = await axios.get(url, {
            headers: { 'accept': 'application/json' }
        });
        const balance = response.data?.balance || 0;
        console.log(`\x1b[32m[INFO] Current balance is: ${balance}\x1b[0m`);
        return Number(balance);
    } catch (error) {
        console.error(`\x1b[31m[ERROR] Could not fetch balance: ${error.message}\x1b[0m`);
        return -1;
    }
}


function getSessionId(token) {
    if (sessions[token] && sessions[token].sessionId) {
        console.log(`\x1b[32m[INFO] Using cached Discord session ID.\x1b[0m`);
        return Promise.resolve(sessions[token].sessionId);
    }

    console.log(`\x1b[33m[INFO] No cached session ID found. Connecting to Discord Gateway...\x1b[0m`);
    const ws = new WebSocket('wss://gateway.discord.gg/?v=9&encoding=json');

    return new Promise((resolve, reject) => {
        ws.on('open', () => {
            console.log(`\x1b[36m[INFO] WebSocket connection opened. Sending IDENTIFY payload.\x1b[0m`);
            ws.send(JSON.stringify({
                op: 2,
                d: {
                    token,
                    properties: { os: 'linux', browser: 'chrome', device: '' }
                }
            }));
        });

        ws.on('message', (data) => {
            const parsed = JSON.parse(data);
            console.log(`\x1b[36m[DEBUG] RECV: op code ${parsed.op}, type ${parsed.t}\x1b[0m`);

            if (parsed.t === 'READY' && parsed.d?.session_id) {
                console.log(`\x1b[32m[SUCCESS] Obtained new Discord session ID: ${parsed.d.session_id}\x1b[0m`);
                if (!sessions[token]) sessions[token] = {};
                sessions[token].sessionId = parsed.d.session_id;
                saveSessions();
                ws.close();
                resolve(parsed.d.session_id);
            }
        });

        ws.on('error', (err) => {
            console.error(`\x1b[31m[ERROR] WebSocket error: ${err.message}\x1b[0m`);
            reject(err);
        });

        ws.on('close', (code) => {
             console.log(`\x1b[33m[INFO] WebSocket connection closed with code: ${code}\x1b[0m`);
        });

        setTimeout(() => {
            if (ws.readyState !== WebSocket.CLOSED && ws.readyState !== WebSocket.CLOSING) {
                ws.terminate();
                reject(new Error('WebSocket connection timed out after 15 seconds. Did not receive READY event.'));
            }
        }, 15000);
    });
}

function generateNonce() {
    return (BigInt(Date.now()) - 1420070400000n << 22n).toString();
}

async function claimFaucet(walletAddress, discordToken) {
    console.log(`\x1b[36m--- Starting Faucet Process for ${walletAddress} ---\x1b[0m`);

    const balance = await getValidatorBalance(walletAddress);
    if (balance > 0) {
        console.log("\x1b[32m[SKIP] Validator already has a balance. No need to claim faucet.\x1b[0m");
        return;
    }
    if (balance === -1) {
        console.error("\x1b[31m[FAIL] Halting process due to error fetching balance.\x1b[0m");
        return;
    }

    try {
        const sessionId = await getSessionId(discordToken);
        const formData = new FormData();

        const addressNoPrefix = walletAddress.startsWith('0x') ? walletAddress.substring(2) : walletAddress;

        const payload = {
            type: 2,
            application_id: FAUCET_CONFIG.application_id,
            guild_id: FAUCET_CONFIG.guild_id,
            channel_id: FAUCET_CONFIG.channel_id,
            session_id: sessionId,
            data: {
                version: FAUCET_CONFIG.command_version,
                id: FAUCET_CONFIG.command_id,
                name: FAUCET_CONFIG.command_name,
                type: 1,
                options: [{ type: 3, name: 'address', value: addressNoPrefix }],
                application_command: { id: FAUCET_CONFIG.command_id, name: FAUCET_CONFIG.command_name },
                attachments: []
            },
            nonce: generateNonce(),
        };

        formData.append('payload_json', JSON.stringify(payload));

        console.log(`\x1b[36m[INFO] Sending faucet claim request to Discord...\x1b[0m`);
        const response = await axios.post('https://discord.com/api/v9/interactions', formData, {
            headers: {
                'Authorization': discordToken,
                ...formData.getHeaders()
            }
        });

        console.log(`\x1b[32m[SUCCESS] Faucet claim request sent successfully! Discord API responded with status: ${response.status}\x1b[0m`);

    } catch (error) {
        let errMsg = error.message;
        if (error.response) {
            errMsg = `HTTP ${error.response.status}: ${JSON.stringify(error.response.data)}`;
            if (errMsg.toLowerCase().includes('session')) {
                console.warn(`\x1b[33m[WARN] Invalid session ID detected. Clearing cache...\x1b[0m`);
                if (sessions[discordToken]) {
                    delete sessions[discordToken].sessionId;
                    saveSessions();
                }
            }
        }
        console.error(`\x1b[31m[ERROR] Faucet claim failed: ${errMsg}\x1b[0m`);
        console.error(`\x1b[31m[ERROR] If the error persists, your Discord token may be invalid or expired.\x1b[0m`);
    }
}

const { DISCORD_TOKEN, VALIDATOR_ADDRESS } = process.env;

if (!DISCORD_TOKEN || !VALIDATOR_ADDRESS) {
    console.error("\x1b[31m[ERROR] Missing environment variables.\x1b[0m");
    console.error("Please ensure DISCORD_TOKEN and VALIDATOR_ADDRESS are set in your .env file.");
    process.exit(1);
}

claimFaucet(VALIDATOR_ADDRESS, DISCORD_TOKEN);
