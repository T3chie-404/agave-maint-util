# Validator Setup Script

This script creates the necessary service files and startup scripts for running a Solana/Agave validator or RPC node on Mainnet-Beta.

## Purpose

The `validator_setup.sh` script automates the creation of:
- `~/keys/` directory with proper permissions (700)
- `validator-start.sh` - The startup script with all required arguments
- `validator.service` - The systemd service file

## Prerequisites

1. **System tuning completed** - Run `system_tuning/system_tuner.sh` first
2. **User account created** - The user that will run the validator should exist
3. **Data directories mounted** - `/mnt/ledger`, `/mnt/accounts`, `/mnt/data` should be ready
4. **Keypairs generated** - You'll need your validator keypairs

## Usage

```bash
./validator_setup.sh
```

The script will interactively ask for:
1. **Username** - The user that will run the validator
2. **Node Type** - Validator or RPC

## Node Types

### Validator
- Uses voting with `--authorized-voter`
- Creates identity.json as a symlink for failover support
- Required keypairs:
  - `staked-identity.json` - Main validator identity
  - `unstaked-identity.json` - Passive/failover identity
  - `vote-account-keypair.json` - Vote account
- Service includes ExecStartPre to set passive boot (symlink to unstaked)

### RPC Node
- Uses `--no-voting`, `--full-rpc-api`, `--account-index`
- identity.json is a regular file (no failover)
- Required keypairs:
  - `identity.json` - RPC node identity

## Default Paths

| Path | Description |
|------|-------------|
| `/mnt/ledger` | Validator ledger data |
| `/mnt/accounts` | Account database |
| `/mnt/data/logs/solana-validator.log` | Validator log file |
| `/mnt/data/snapshots_incremental` | Incremental snapshots |
| `/mnt/data/compiled/active_release` | Compiled binaries |
| `~/keys/` | Keypair storage |

## Generated Files

### validator-start.sh

Located at `~/validator-start.sh`, this script:
- Exports SOLANA_METRICS_CONFIG
- Runs agave-validator with all required arguments
- Configured for Mainnet-Beta

### validator.service

Located at `/etc/systemd/system/validator.service`, this service:
- Runs as the specified user
- Sets LimitNOFILE=2000000 and LimitMEMLOCK=2000000000
- Disables log rate limiting
- Auto-restarts on failure
- For validators: Forces passive boot via ExecStartPre

## Post-Setup Commands

```bash
# Create data directories (if not already created)
sudo mkdir -p /mnt/ledger /mnt/accounts /mnt/data/snapshots_incremental
sudo chown <user>:<user> /mnt/ledger /mnt/accounts /mnt/data/snapshots_incremental

# Start the validator
sudo systemctl start validator.service

# Check status
sudo systemctl status validator.service

# View logs
tail -f /mnt/data/logs/solana-validator.log

# Stop the validator
sudo systemctl stop validator.service
```

## Keypair Generation

If you need to generate new keypairs:

```bash
# Generate validator identity
agave-keygen new -o ~/keys/staked-identity.json

# Generate unstaked identity (for failover)
agave-keygen new -o ~/keys/unstaked-identity.json

# Generate vote account (requires funded wallet)
agave-keygen new -o ~/keys/vote-account-keypair.json

# For RPC nodes, just generate identity
agave-keygen new -o ~/keys/identity.json
```

## Network Configuration

Currently configured for **Mainnet-Beta** only with:
- 5 entrypoints
- 9 known validators
- Expected genesis hash: `5eykt4UsFv8P8NJdTREpY1vzqKqZKvdpKuc147dw2N9d`

