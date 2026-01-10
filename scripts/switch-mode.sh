#!/bin/bash
# Switch between deployment modes
CONFIG_DIR="/etc/pathsteer"
SRC_DIR="/opt/pathsteer/config"

case "${1:-}" in
    mobile)
        cp "$SRC_DIR/config.edge.json" "$CONFIG_DIR/config.json"
        echo "Switched to MOBILE mode (Starlink + dual cellular)"
        ;;
    terrestrial)
        cp "$SRC_DIR/config.terrestrial.json" "$CONFIG_DIR/config.json"
        echo "Switched to TERRESTRIAL mode (Fiber + cellular backup)"
        ;;
    status)
        mode=$(jq -r '.deployment_mode' "$CONFIG_DIR/config.json" 2>/dev/null)
        echo "Current mode: $mode"
        echo ""
        echo "Enabled uplinks:"
        jq -r '.uplinks | to_entries[] | select(.value.enabled) | "  \(.key): \(.value.interface) (\(.value.type))"' "$CONFIG_DIR/config.json"
        ;;
    *)
        echo "Usage: $0 {mobile|terrestrial|status}"
        echo ""
        echo "  mobile      - Starlink + dual cellular (vehicle)"
        echo "  terrestrial - Fiber + cellular backup (fixed site)"
        echo "  status      - Show current mode"
        exit 1
        ;;
esac

# Restart services after mode change
if [[ "${1:-}" == "mobile" || "${1:-}" == "terrestrial" ]]; then
    echo ""
    echo "Restart services to apply:"
    echo "  systemctl restart pathsteer-netns"
    echo "  systemctl restart pathsteer-web"
fi
