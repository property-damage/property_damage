#!/bin/bash
#
# ToyBank Integration Test Runner
# ================================
#
# This script runs PropertyDamage integration tests against the ToyBank service.
# It handles starting/stopping the service, running tests, and generating reports.
#
# PREREQUISITES:
#   - Docker and Docker Compose installed
#   - ToyBank source code at ../../../toy_bank (or set TOY_BANK_PATH)
#   - Elixir/Mix installed
#
# USAGE:
#   ./scripts/test_toybank.sh [OPTIONS]
#
# OPTIONS:
#   --runs N          Number of test runs (default: 100)
#   --hunt N          Bug hunt mode: find N unique bugs
#   --chaos           Enable chaos testing with ChaosModel
#   --report FORMAT   Generate report: markdown, junit, json
#   --keep-running    Don't stop ToyBank after tests
#   --skip-start      Assume ToyBank is already running
#   --verbose         Show detailed output
#   --help            Show this help message
#
# EXAMPLES:
#   # Basic integration test
#   ./scripts/test_toybank.sh
#
#   # Run 500 tests with JUnit report
#   ./scripts/test_toybank.sh --runs 500 --report junit
#
#   # Bug hunting mode
#   ./scripts/test_toybank.sh --hunt 10
#
#   # Chaos testing
#   ./scripts/test_toybank.sh --chaos --runs 50
#
# ENVIRONMENT VARIABLES:
#   TOY_BANK_PATH     Path to ToyBank source (default: ../../../toy_bank)
#   TOY_BANK_URL      ToyBank URL (default: http://localhost:4555)
#   REPORTS_DIR       Directory for reports (default: ./reports)
#
# EXIT CODES:
#   0  All tests passed
#   1  Tests failed (bugs found)
#   2  Setup/configuration error
#

set -e

# =============================================================================
# Configuration
# =============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

TOY_BANK_PATH="${TOY_BANK_PATH:-$PROJECT_DIR/../../../toy_bank}"
TOY_BANK_URL="${TOY_BANK_URL:-http://localhost:4555}"
REPORTS_DIR="${REPORTS_DIR:-$PROJECT_DIR/reports}"

# Defaults
RUNS=100
COMMANDS=50
MODEL="ToyBankTest.Model"
ADAPTER="ToyBankTest.Adapters.HTTPAdapter"
HUNT_MODE=false
HUNT_COUNT=0
CHAOS_MODE=false
REPORT_FORMAT=""
KEEP_RUNNING=false
SKIP_START=false
VERBOSE=false

# =============================================================================
# Helper Functions
# =============================================================================

print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "         TOYBANK PROPERTYDAMAGE INTEGRATION TEST"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
}

print_usage() {
    head -50 "$0" | grep "^#" | sed 's/^# \?//'
}

log() {
    if [ "$VERBOSE" = true ]; then
        echo "[$(date '+%H:%M:%S')] $1"
    fi
}

error() {
    echo "ERROR: $1" >&2
    exit 2
}

check_prerequisites() {
    log "Checking prerequisites..."

    if ! command -v docker &> /dev/null; then
        error "Docker is not installed"
    fi

    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        error "Docker Compose is not installed"
    fi

    if ! command -v mix &> /dev/null; then
        error "Elixir/Mix is not installed"
    fi

    if [ ! -d "$TOY_BANK_PATH" ]; then
        error "ToyBank not found at $TOY_BANK_PATH (set TOY_BANK_PATH)"
    fi
}

start_toybank() {
    echo "Starting ToyBank service..."
    log "ToyBank path: $TOY_BANK_PATH"

    cd "$TOY_BANK_PATH"

    # Use docker compose (v2) or docker-compose (v1)
    if docker compose version &> /dev/null 2>&1; then
        docker compose up -d
    else
        docker-compose up -d
    fi

    cd "$PROJECT_DIR"

    echo "Waiting for ToyBank to be ready..."
    wait_for_service "$TOY_BANK_URL/api/health" 60
    echo "ToyBank is ready!"
}

stop_toybank() {
    echo "Stopping ToyBank service..."
    cd "$TOY_BANK_PATH"

    if docker compose version &> /dev/null 2>&1; then
        docker compose down
    else
        docker-compose down
    fi

    cd "$PROJECT_DIR"
}

wait_for_service() {
    local url=$1
    local timeout=$2
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        if curl -s "$url" > /dev/null 2>&1; then
            return 0
        fi
        sleep 1
        elapsed=$((elapsed + 1))

        if [ $((elapsed % 10)) -eq 0 ]; then
            echo "  Still waiting... ($elapsed/$timeout seconds)"
        fi
    done

    error "Service did not become ready within $timeout seconds"
}

run_tests() {
    echo ""
    echo "Running PropertyDamage tests..."
    echo "  Model:    $MODEL"
    echo "  Adapter:  $ADAPTER"
    echo "  URL:      $TOY_BANK_URL"
    echo "  Runs:     $RUNS"
    echo ""

    cd "$PROJECT_DIR"

    # Build command
    local cmd="mix pd.integration"
    cmd="$cmd --model $MODEL"
    cmd="$cmd --adapter $ADAPTER"
    cmd="$cmd --url $TOY_BANK_URL"
    cmd="$cmd --runs $RUNS"
    cmd="$cmd --commands $COMMANDS"
    cmd="$cmd --health $TOY_BANK_URL/api/health"

    if [ "$HUNT_MODE" = true ]; then
        cmd="$cmd --hunt $HUNT_COUNT"
        cmd="$cmd --save-failures $REPORTS_DIR/bugs"
    fi

    if [ -n "$REPORT_FORMAT" ]; then
        mkdir -p "$REPORTS_DIR"
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        local report_path="$REPORTS_DIR/toybank_${timestamp}"

        case $REPORT_FORMAT in
            markdown) report_path="${report_path}.md" ;;
            junit)    report_path="${report_path}.xml" ;;
            json)     report_path="${report_path}.json" ;;
        esac

        cmd="$cmd --report $REPORT_FORMAT --report-path $report_path"
    fi

    if [ "$VERBOSE" = false ]; then
        cmd="$cmd --quiet"
    fi

    log "Running: $cmd"

    # Execute
    eval $cmd
    return $?
}

# =============================================================================
# Argument Parsing
# =============================================================================

while [[ $# -gt 0 ]]; do
    case $1 in
        --runs)
            RUNS="$2"
            shift 2
            ;;
        --commands)
            COMMANDS="$2"
            shift 2
            ;;
        --hunt)
            HUNT_MODE=true
            HUNT_COUNT="$2"
            shift 2
            ;;
        --chaos)
            CHAOS_MODE=true
            MODEL="ToyBankTest.ChaosModel"
            shift
            ;;
        --report)
            REPORT_FORMAT="$2"
            shift 2
            ;;
        --keep-running)
            KEEP_RUNNING=true
            shift
            ;;
        --skip-start)
            SKIP_START=true
            shift
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --help|-h)
            print_usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            print_usage
            exit 2
            ;;
    esac
done

# =============================================================================
# Main Execution
# =============================================================================

print_header
check_prerequisites

# Start ToyBank if needed
if [ "$SKIP_START" = false ]; then
    start_toybank
fi

# Set up cleanup
cleanup() {
    if [ "$KEEP_RUNNING" = false ] && [ "$SKIP_START" = false ]; then
        stop_toybank
    fi
}

trap cleanup EXIT

# Run tests
if run_tests; then
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "                    ✓ ALL TESTS PASSED"
    echo "═══════════════════════════════════════════════════════════════"
    exit 0
else
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "                    ✗ TESTS FAILED"
    echo "═══════════════════════════════════════════════════════════════"
    exit 1
fi
