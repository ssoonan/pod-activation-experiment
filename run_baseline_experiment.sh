#!/bin/bash

# Baseline experiment script for direct cgroup execution
# This script runs timing_app binaries directly in cgroup without K3s
# to compare against K3s pod scheduling overhead
#
# Usage:
#   ./run_baseline_experiment.sh

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
MAX_EXPERIMENTS=21  # exp0 is warmup, exp1-exp20 are logged (20 experiments total)
RESULTS_DIR="./baseline-results"
PROCESS_READY_WAIT=5  # seconds to wait for processes to start and log
CGROUP_NAME="baseline_experiment"
CPU_CORES="8-15"  # CPU cores to use
BINARY_PATH="./timing_app_baseline"
DATA_DIR="/tmp/baseline-experiment-data"

# Print colored message
print_msg() {
    local color=$1
    local msg=$2
    echo -e "${color}${msg}${NC}"
}

# Print section header
print_header() {
    echo ""
    print_msg "$BLUE" "=========================================="
    print_msg "$BLUE" "$1"
    print_msg "$BLUE" "=========================================="
}

# Create cgroup and set CPU affinity
create_cgroup() {
    local cgroup_name=$1
    local cpu_cores=$2

    print_msg "$YELLOW" "Creating cgroup: $cgroup_name with CPUs: $cpu_cores"

    # Remove existing cgroup if it exists
    if [ -d "/sys/fs/cgroup/$cgroup_name" ]; then
        sudo rmdir "/sys/fs/cgroup/$cgroup_name" 2>/dev/null || true
    fi

    # Create new cgroup (cgroup v2)
    sudo mkdir -p "/sys/fs/cgroup/$cgroup_name"

    # Set CPU affinity
    echo "$cpu_cores" | sudo tee "/sys/fs/cgroup/$cgroup_name/cpuset.cpus" > /dev/null

    # Enable controllers
    echo "+cpuset" | sudo tee "/sys/fs/cgroup/cgroup.subtree_control" > /dev/null 2>&1 || true

    print_msg "$GREEN" "✓ Cgroup created successfully"
}

# Delete cgroup
delete_cgroup() {
    local cgroup_name=$1

    if [ -d "/sys/fs/cgroup/$cgroup_name" ]; then
        print_msg "$YELLOW" "Removing cgroup: $cgroup_name"
        sudo rmdir "/sys/fs/cgroup/$cgroup_name" 2>/dev/null || true
        print_msg "$GREEN" "✓ Cgroup removed"
    fi
}

# Run processes in cgroup
run_processes_in_cgroup() {
    local cgroup_name=$1
    local num_processes=$2
    local data_dir=$3
    local base_timestamp=$4

    print_msg "$YELLOW" "Starting $num_processes processes in cgroup..."

    local pids=()

    for i in $(seq 1 $num_processes); do
        # Set shared directory and hostname for each process
        local proc_name="baseline-proc-${i}"

        # Run process in cgroup with custom environment
        (
            # Write PID to cgroup
            echo $$ | sudo tee "/sys/fs/cgroup/$cgroup_name/cgroup.procs" > /dev/null

            # Create temporary wrapper script to set environment and redirect output
            export SHARED_DIR="$data_dir"
            export HOSTNAME="$proc_name"

            # Modify timing_app behavior via environment
            # Since timing_app uses gethostname(), we need to run with custom hostname
            # For baseline, we'll create symlinks and run with modified output

            # Run the binary with output redirection
            "$BINARY_PATH" > "$data_dir/${proc_name}_stdout.log" 2>&1
        ) &

        pids+=($!)
    done

    print_msg "$GREEN" "✓ Started $num_processes processes (PIDs: ${pids[@]})"

    # Store PIDs for later cleanup
    echo "${pids[@]}" > "/tmp/${cgroup_name}_pids.txt"
}

# Kill all processes
kill_processes() {
    local cgroup_name=$1

    if [ -f "/tmp/${cgroup_name}_pids.txt" ]; then
        local pids=$(cat "/tmp/${cgroup_name}_pids.txt")
        print_msg "$YELLOW" "Killing processes: $pids"

        for pid in $pids; do
            sudo kill -9 $pid 2>/dev/null || true
        done

        rm -f "/tmp/${cgroup_name}_pids.txt"
        print_msg "$GREEN" "✓ Processes killed"
    fi
}

# Collect timing logs from data directory
collect_logs() {
    local data_dir=$1
    local result_dir=$2
    local experiment_num=$3

    print_msg "$YELLOW" "Collecting logs from: $data_dir"

    # Create experiment-specific log directory
    local exp_log_dir="${result_dir}/exp${experiment_num}"
    mkdir -p "$exp_log_dir"

    # Copy all .txt files from data directory
    if [ -d "$data_dir" ]; then
        local file_count=$(find "$data_dir" -maxdepth 1 -name "*.txt" 2>/dev/null | wc -l)

        if [ "$file_count" -gt 0 ]; then
            cp "$data_dir"/*.txt "$exp_log_dir/" 2>/dev/null || true
            print_msg "$GREEN" "✓ Collected $file_count log files to $exp_log_dir"
        else
            print_msg "$YELLOW" "Warning: No log files found in $data_dir"
        fi
    else
        print_msg "$YELLOW" "Warning: Data directory $data_dir does not exist"
    fi
}

# Run a single experiment configuration
run_experiment() {
    local config_name=$1
    local num_processes=$2

    print_header "Starting Baseline Experiment: $config_name"

    # Create result directory
    local result_dir="${RESULTS_DIR}/${config_name}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$result_dir"

    # Create base timestamps file
    local base_timestamps_file="$result_dir/base_timestamps.txt"
    echo "# Experiment start timestamps (Unix epoch with nanoseconds)" > "$base_timestamps_file"
    echo "# Format: Each line is the timestamp when the experiment iteration started" >> "$base_timestamps_file"
    echo "# exp0 is warmup (not logged), exp1-exp20 timestamps are below" >> "$base_timestamps_file"

    # Save configuration info
    echo "Configuration: $config_name" > "$result_dir/config.txt"
    echo "Process Count: $num_processes" >> "$result_dir/config.txt"
    echo "CPU Cores: $CPU_CORES" >> "$result_dir/config.txt"
    echo "Cgroup: $CGROUP_NAME" >> "$result_dir/config.txt"
    echo "Binary: $BINARY_PATH" >> "$result_dir/config.txt"
    echo "Max Experiments (including warmup): $MAX_EXPERIMENTS" >> "$result_dir/config.txt"
    echo "Logged Experiments: $((MAX_EXPERIMENTS - 1))" >> "$result_dir/config.txt"
    echo "Start Time: $(date)" >> "$result_dir/config.txt"

    # Create cgroup
    create_cgroup "$CGROUP_NAME" "$CPU_CORES"

    # Run experiment iterations (exp0 to exp20, where exp0 is warmup)
    for exp_num in $(seq 0 $((MAX_EXPERIMENTS - 1))); do
        if [ $exp_num -eq 0 ]; then
            print_header "Experiment $config_name - Warmup (exp0 - not logged)"
        else
            print_header "Experiment $config_name - Iteration $exp_num/$((MAX_EXPERIMENTS - 1))"
        fi

        # Clean up and prepare data directory
        print_msg "$YELLOW" "Preparing data directory: $DATA_DIR"
        rm -rf "$DATA_DIR"
        mkdir -p "$DATA_DIR"
        chmod 777 "$DATA_DIR"

        # Record base timestamp (experiment start time)
        local base_timestamp=$(date +%s.%N)
        print_msg "$GREEN" "Base timestamp: $base_timestamp"

        # Save timestamp only if not warmup
        if [ $exp_num -gt 0 ]; then
            echo "$base_timestamp" >> "$base_timestamps_file"
        fi

        # Run processes in cgroup
        run_processes_in_cgroup "$CGROUP_NAME" "$num_processes" "$DATA_DIR" "$base_timestamp"

        # Wait for processes to complete and write logs
        print_msg "$YELLOW" "Waiting ${PROCESS_READY_WAIT}s for processes to write logs..."
        sleep $PROCESS_READY_WAIT

        # Kill processes
        kill_processes "$CGROUP_NAME"

        # Collect logs only if not warmup (exp0)
        if [ $exp_num -gt 0 ]; then
            collect_logs "$DATA_DIR" "$result_dir" "$exp_num"
        else
            print_msg "$YELLOW" "Skipping log collection for warmup iteration"
        fi

        # Small delay before next iteration
        if [ $exp_num -lt $((MAX_EXPERIMENTS - 1)) ]; then
            print_msg "$YELLOW" "Waiting 2s before next iteration..."
            sleep 2
        fi
    done

    # Cleanup
    delete_cgroup "$CGROUP_NAME"

    # Save end time
    echo "End Time: $(date)" >> "$result_dir/config.txt"

    # Generate summary
    print_msg "$YELLOW" "Generating summary..."
    local total_files=$(find "$result_dir" -name "*.txt" -not -name "config.txt" -not -name "base_timestamps.txt" | wc -l)
    local base_timestamp_count=$(grep -v "^#" "$base_timestamps_file" | wc -l)
    echo "Total log files collected: $total_files" >> "$result_dir/config.txt"
    echo "Base timestamps recorded: $base_timestamp_count" >> "$result_dir/config.txt"

    print_msg "$GREEN" "✓ Experiment $config_name completed!"
    print_msg "$GREEN" "Results saved to: $result_dir"
    print_msg "$GREEN" "Base timestamps: $base_timestamps_file"
}

# Main execution
main() {
    print_header "Baseline Timing Experiment Suite"

    # Check if running as root
    if [ "$EUID" -eq 0 ]; then
        print_msg "$RED" "Error: This script should not be run as root."
        print_msg "$RED" "It will use sudo for specific commands that require elevated privileges."
        exit 1
    fi

    # Check if binary exists
    if [ ! -f "$BINARY_PATH" ]; then
        print_msg "$RED" "Error: Binary not found at $BINARY_PATH"
        print_msg "$RED" "Please compile timing_app_baseline first:"
        print_msg "$RED" "  g++ -o timing_app_baseline timing_app_baseline.cpp -pthread"
        exit 1
    fi

    # Check if binary is executable
    if [ ! -x "$BINARY_PATH" ]; then
        print_msg "$YELLOW" "Making binary executable..."
        chmod +x "$BINARY_PATH"
    fi

    # Check required commands
    for cmd in date mkdir rm; do
        if ! command -v $cmd &> /dev/null; then
            print_msg "$RED" "Error: Required command '$cmd' not found"
            exit 1
        fi
    done

    # Create results directory
    mkdir -p "$RESULTS_DIR"

    print_header "Experiment Configurations"
    print_msg "$YELLOW" "1. 8 processes on cores $CPU_CORES"
    print_msg "$YELLOW" "2. 16 processes on cores $CPU_CORES"
    print_msg "$YELLOW" "Each configuration will run for $((MAX_EXPERIMENTS - 1)) iterations (exp1-exp$((MAX_EXPERIMENTS - 1)))"
    print_msg "$YELLOW" "Note: exp0 is a warmup iteration and will not be logged"
    echo ""

    read -p "Do you want to run all baseline experiments? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_msg "$YELLOW" "Experiment cancelled."
        exit 0
    fi

    # Run all experiment configurations
    run_experiment "baseline-8procs" 8
    run_experiment "baseline-16procs" 16

    print_header "All Baseline Experiments Completed!"
    print_msg "$GREEN" "Results are saved in: $RESULTS_DIR"

    # Generate final summary
    print_msg "$YELLOW" "Generating final summary..."
    local summary_file="$RESULTS_DIR/final_summary.txt"
    echo "Baseline Experiment Summary - $(date)" > "$summary_file"
    echo "=====================================" >> "$summary_file"

    for exp_dir in "$RESULTS_DIR"/*; do
        if [ -d "$exp_dir" ] && [ -f "$exp_dir/config.txt" ]; then
            echo "" >> "$summary_file"
            echo "$(basename "$exp_dir"):" >> "$summary_file"
            grep "Total log files" "$exp_dir/config.txt" >> "$summary_file" 2>/dev/null || echo "  No summary available" >> "$summary_file"
        fi
    done

    cat "$summary_file"
    print_msg "$GREEN" "✓ All baseline experiments completed successfully!"
}

# Cleanup on exit
cleanup_on_exit() {
    print_msg "$YELLOW" "Cleaning up..."
    kill_processes "$CGROUP_NAME" 2>/dev/null || true
    delete_cgroup "$CGROUP_NAME" 2>/dev/null || true
}

trap cleanup_on_exit EXIT INT TERM

# Run main function
main "$@"
