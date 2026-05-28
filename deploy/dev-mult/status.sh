#!/bin/bash
# ============================================================================
# Check status of all nodes: processes, HTTP health, P2P port, disk space
# Usage: ./status.sh [--verbose]
# ============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/config.sh"

VERBOSE="${1:-}"

print_header "Setu Cluster Status"

printf "  %-14s %-18s %-10s %-10s %-10s %-10s %s\n" \
    "Node" "IP" "Validator" "Solver" "HTTP" "P2P" "Notes"
echo "  ────────────── ────────────────── ────────── ────────── ────────── ────────── ──────"

for i in "${!SERVERS[@]}"; do
    host="${SERVERS[$i]}"
    vid="${VALIDATOR_IDS[$i]}"
    
    # Check Validator process
    proc_status="✗"
    if remote_exec "$host" "pgrep -f setu-validator" &>/dev/null; then
        proc_status="✓ running"
    else
        proc_status="✗ stopped"
    fi

    # Check Solver process
    solver_status="✗"
    if remote_exec "$host" "pgrep -f setu-solver" &>/dev/null; then
        solver_status="✓ running"
    else
        solver_status="✗ stopped"
    fi

    # Check HTTP health
    http_status="✗"
    health_resp=$(curl -sf --connect-timeout 3 "http://${host}:${HTTP_PORT}/api/v1/health" 2>/dev/null || echo "")
    if [ -n "$health_resp" ]; then
        http_status="✓ healthy"
    else
        http_status="✗ no resp"
    fi
    
    # Check P2P port (UDP/QUIC)
    p2p_status="?"
    if remote_exec "$host" "ss -ulnp | grep -q ':${P2P_PORT}'" 2>/dev/null; then
        p2p_status="✓ listen"
    else
        p2p_status="✗ not lstn"
    fi
    
    # note
    note=""
    if [ "$i" -eq 0 ]; then
        note="(build server)"
    fi
    
    printf "  %-14s %-18s %-10s %-10s %-10s %-10s %s\n" \
        "$vid" "$host" "$proc_status" "$solver_status" "$http_status" "$p2p_status" "$note"
done

if [ "$VERBOSE" = "--verbose" ] || [ "$VERBOSE" = "-v" ]; then
    echo ""
    echo "━━━ Details ━━━"
    for i in "${!SERVERS[@]}"; do
        host="${SERVERS[$i]}"
        vid="${VALIDATOR_IDS[$i]}"
        
        echo ""
        echo "  [${vid}] ${host}"
        
        # Process info
        echo "  Processes:"
        remote_exec "$host" "ps aux | grep -E 'setu-(validator|solver)' | grep -v grep || echo '    (no running processes)'" 2>/dev/null

        # Solver logs
        echo "  Solver logs:"
        remote_exec "$host" "tail -3 ${REMOTE_LOGS}/solver.log 2>/dev/null || echo '    (no logs)'" 2>/dev/null

        # Disk space
        echo "  Disk:"
        remote_exec "$host" "df -h ${REMOTE_BASE} 2>/dev/null | tail -1 || echo '    (unknown)'" 2>/dev/null

        # RocksDB size
        echo "  Data:"
        remote_exec "$host" "du -sh ${REMOTE_DATA}/db 2>/dev/null || echo '    (no data)'" 2>/dev/null
        
        # Last lines of logs
        echo "  Recent logs:"
        remote_exec "$host" "tail -3 ${REMOTE_LOGS}/validator.log 2>/dev/null || echo '    (no logs)'" 2>/dev/null
        
        # Health details
        health=$(curl -sf --connect-timeout 3 "http://${host}:${HTTP_PORT}/api/v1/health" 2>/dev/null || echo "")
        if [ -n "$health" ]; then
            echo "  health response: ${health}"
        fi
    done
fi

echo ""
