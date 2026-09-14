#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR=$(cd "$(dirname "$0")/.." && pwd)
SOURCE_DIR="$ROOT_DIR/DesignAssets/AppIcon"
ASSET_DIR="$ROOT_DIR/LotteryWallet/Resources/AppIcon.icon/Assets"

mkdir -p "$ASSET_DIR"
cp "$SOURCE_DIR/back-ticket.svg" "$ASSET_DIR/BackTicket.svg"
cp "$SOURCE_DIR/middle-ticket.svg" "$ASSET_DIR/MiddleTicket.svg"
cp "$SOURCE_DIR/front-ticket.svg" "$ASSET_DIR/FrontTicket.svg"

echo "Synced App Icon source layers into AppIcon.icon."
