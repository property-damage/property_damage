#!/bin/bash
#
# TravelBooking Integration Test Runner
# =====================================
#
# This script runs PropertyDamage integration tests against the TravelBooking service.
# It handles starting/stopping the service, running tests, and generating reports.
#
# TravelBooking is an in-memory travel booking service with:
#   - HTTP API on port 4445
#   - gRPC API on port 50051
#   - Booking, Flight, and Hotel management
#   - No external database (in-memory storage)
#
# PREREQUISITES:
#   - Docker and Docker Compose installed
#   - TravelBooking source at ../../example_tests/travel_booking (or set TRAVEL_BOOKING_PATH)
#   - Elixir/Mix installed
#
# USAGE:
#   ./scripts/test_travelbooking.sh [OPTIONS]
#
# OPTIONS:
#   --runs N          Number of test runs (default: 100)
#   --commands N      Max commands per run (default: 50)
#   --hunt N          Bug hunt mode: find N unique bugs
#   --chaos           Enable chaos testing with ChaosModel
#   --lifecycle       Use BookingLifecycleModel (focuses on state transitions)
#   --report FORMAT   Generate report: markdown, junit, json
#   --keep-running    Don't stop TravelBooking after tests
#   --skip-start      Assume TravelBooking is already running
#   --local           Run TravelBooking locally with mix (no Docker)
#   --verbose         Show detailed output
#   --help            Show this help message
#
# EXAMPLES:
#   # Basic integration test
#   ./scripts/test_travelbooking.sh
#
#   # Run 500 tests with JUnit report
#   ./scripts/test_travelbooking.sh --runs 500 --report junit
#
#   # Bug hunting mode
#   ./scripts/test_travelbooking.sh --hunt 10
#
#   # Chaos testing with fault injection
#   ./scripts/test_travelbooking.sh --chaos --runs 50
#
#   # Run locally without Docker
#   ./scripts/test_travelbooking.sh --local --runs 20
#
#   # Focus on booking lifecycle testing
#   ./scripts/test_travelbooking.sh --lifecycle --runs 100
#
# ENVIRONMENT VARIABLES:
#   TRAVEL_BOOKING_PATH   Path to TravelBooking source (default: ../../example_tests/travel_booking)
#   TRAVEL_BOOKING_URL    TravelBooking URL (default: http://localhost:4445)
#   REPORTS_DIR           Directory for reports (default: ./reports)
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

TRAVEL_BOOKING_PATH="${TRAVEL_BOOKING_PATH:-$PROJECT_DIR/../example_tests/travel_booking}"
TRAVEL_BOOKING_URL="${TRAVEL_BOOKING_URL:-http://localhost:4445}"
REPORTS_DIR="${REPORTS_DIR:-$PROJECT_DIR/reports}"

# Defaults
RUNS=100
COMMANDS=50
MODEL="TravelBookingTest.Model"
ADAPTER="TravelBookingTest.Adapters.HTTPAdapter"
HUNT_MODE=false
HUNT_COUNT=0
CHAOS_MODE=false
LIFECYCLE_MODE=false
REPORT_FORMAT=""
KEEP_RUNNING=false
SKIP_START=false
LOCAL_MODE=false
VERBOSE=false

# Process tracking
SUT_PID=""

# =============================================================================
# Helper Functions
# =============================================================================

print_header() {
    echo ""
    echo "═══════════════════════════════════════════════════════════════"
    echo "       TRAVELBOOKING PROPERTYDAMAGE INTEGRATION TEST"
    echo "═══════════════════════════════════════════════════════════════"
    echo ""
}

print_usage() {
    head -60 "$0" | grep "^#" | sed 's/^# \?//'
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

    if [ "$LOCAL_MODE" = false ]; then
        if ! command -v docker &> /dev/null; then
            error "Docker is not installed (use --local to run without Docker)"
        fi

        if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
            error "Docker Compose is not installed (use --local to run without Docker)"
        fi
    fi

    if ! command -v mix &> /dev/null; then
        error "Elixir/Mix is not installed"
    fi

    if [ ! -d "$TRAVEL_BOOKING_PATH" ]; then
        error "TravelBooking not found at $TRAVEL_BOOKING_PATH (set TRAVEL_BOOKING_PATH)"
    fi
}

start_travelbooking_docker() {
    echo "Starting TravelBooking service (Docker)..."
    log "TravelBooking path: $TRAVEL_BOOKING_PATH"

    cd "$TRAVEL_BOOKING_PATH"

    # Check if docker-compose.test.yml exists
    if [ ! -f "docker-compose.test.yml" ]; then
        echo "  Note: docker-compose.test.yml not found, using default docker-compose.yml"
        COMPOSE_FILE="docker-compose.yml"
    else
        COMPOSE_FILE="docker-compose.test.yml"
    fi

    # Use docker compose (v2) or docker-compose (v1)
    if docker compose version &> /dev/null 2>&1; then
        docker compose -f "$COMPOSE_FILE" up -d
    else
        docker-compose -f "$COMPOSE_FILE" up -d
    fi

    cd "$PROJECT_DIR"

    echo "Waiting for TravelBooking to be ready..."
    wait_for_service "$TRAVEL_BOOKING_URL/health" 60
    echo "TravelBooking is ready!"
}

start_travelbooking_local() {
    echo "Starting TravelBooking service (local)..."
    log "TravelBooking path: $TRAVEL_BOOKING_PATH"

    cd "$TRAVEL_BOOKING_PATH"

    # Ensure dependencies are fetched
    mix deps.get --only prod 2>/dev/null || mix deps.get

    # Start the service in the background
    MIX_ENV=prod mix run --no-halt &
    SUT_PID=$!

    cd "$PROJECT_DIR"

    echo "Waiting for TravelBooking to be ready (PID: $SUT_PID)..."
    wait_for_service "$TRAVEL_BOOKING_URL/health" 30
    echo "TravelBooking is ready!"
}

stop_travelbooking() {
    if [ "$LOCAL_MODE" = true ]; then
        if [ -n "$SUT_PID" ] && kill -0 "$SUT_PID" 2>/dev/null; then
            echo "Stopping TravelBooking service (PID: $SUT_PID)..."
            kill "$SUT_PID" 2>/dev/null || true
            wait "$SUT_PID" 2>/dev/null || true
        fi
    else
        echo "Stopping TravelBooking service..."
        cd "$TRAVEL_BOOKING_PATH"

        if [ -f "docker-compose.test.yml" ]; then
            COMPOSE_FILE="docker-compose.test.yml"
        else
            COMPOSE_FILE="docker-compose.yml"
        fi

        if docker compose version &> /dev/null 2>&1; then
            docker compose -f "$COMPOSE_FILE" down
        else
            docker-compose -f "$COMPOSE_FILE" down
        fi

        cd "$PROJECT_DIR"
    fi
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
    echo "  URL:      $TRAVEL_BOOKING_URL"
    echo "  Runs:     $RUNS"
    echo "  Commands: $COMMANDS"
    echo ""

    cd "$PROJECT_DIR"

    # Build command
    local cmd="mix pd.integration"
    cmd="$cmd --model $MODEL"
    cmd="$cmd --adapter $ADAPTER"
    cmd="$cmd --url $TRAVEL_BOOKING_URL"
    cmd="$cmd --runs $RUNS"
    cmd="$cmd --commands $COMMANDS"
    cmd="$cmd --health $TRAVEL_BOOKING_URL/health"

    if [ "$HUNT_MODE" = true ]; then
        cmd="$cmd --hunt $HUNT_COUNT"
        cmd="$cmd --save-failures $REPORTS_DIR/bugs"
    fi

    if [ -n "$REPORT_FORMAT" ]; then
        mkdir -p "$REPORTS_DIR"
        local timestamp=$(date '+%Y%m%d_%H%M%S')
        local report_path="$REPORTS_DIR/travelbooking_${timestamp}"

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
            MODEL="TravelBookingTest.ChaosModel"
            shift
            ;;
        --lifecycle)
            LIFECYCLE_MODE=true
            MODEL="TravelBookingTest.BookingLifecycleModel"
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
        --local)
            LOCAL_MODE=true
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

# Start TravelBooking if needed
if [ "$SKIP_START" = false ]; then
    if [ "$LOCAL_MODE" = true ]; then
        start_travelbooking_local
    else
        start_travelbooking_docker
    fi
fi

# Set up cleanup
cleanup() {
    if [ "$KEEP_RUNNING" = false ] && [ "$SKIP_START" = false ]; then
        stop_travelbooking
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
