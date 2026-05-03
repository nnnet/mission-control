# OpenClaw Telegram Onboarding (dmPolicy=`pairing`)

If your bot token is set but Mission Control/OpenClaw still shows:

`Telegram DMs: locked (channels.telegram.dmPolicy="pairing")`

that is **expected**. `pairing` is the secure default and is informational, not a failure.

## 1) Find your Telegram user ID

1. Open Telegram and send any message to your bot (for example `/start`).
2. Query the bot updates endpoint:

```bash
curl -sS "https://api.telegram.org/bot$TELEGRAM_BOT_TOKEN/getUpdates"
```

3. Read your numeric ID from `message.from.id`.

## 2) Approve your DM pairing identity

List pending pairings:

```bash
docker compose -f docker-compose-openclaw.yml run --rm openclaw-cli pairing list
```

Approve your Telegram user ID:

```bash
docker compose -f docker-compose-openclaw.yml run --rm openclaw-cli pairing approve <TELEGRAM_USER_ID>
```

## 3) Add allowlists in `openclaw.json`

Set explicit owner/channel allowlists (replace with your ID):

```json
{
  "commands": {
    "ownerAllowFrom": ["telegram:<TELEGRAM_USER_ID>"]
  },
  "channels": {
    "telegram": {
      "allowFrom": ["<TELEGRAM_USER_ID>"]
    }
  }
}
```

- `commands.ownerAllowFrom` is recommended for owner-level commands.
- `channels.telegram.allowFrom` is optional but recommended for tighter channel ACLs.

## 4) Restart gateway

```bash
make openclaw-restart
```

Then re-run:

```bash
make openclaw-status
```
