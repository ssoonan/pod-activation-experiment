#!/bin/bash

# Experiment orchestration script for K3s timing experiments
# This script manages experiments by:
# 1. Deploying pods that log their start time
# 2. Collecting the timing logs
# 3. Restarting K3s (k3s-killall.sh + systemctl start k3s)
# 4. Repeating for 21 iterations (exp0 is warmup, exp1-exp20 are logged)
#
# Usage:
#   ./run_experiment.sh         # Run experiments without building images
#   ./run_experiment.sh --build # Build and import images before experiments

set -e

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
MAX_EXPERIMENTS=21  # exp0 is warmup, exp1-exp20 are logged (20 experiments total)
RESULTS_DIR="./experiment-results"
POD_READY_WAIT=30  # seconds to wait for pods to be ready
LOG_COLLECTION_WAIT=10  # seconds to wait for logs to be written
K3S_STATUS_CHECK_INTERVAL=0.1  # seconds between K3s status checks

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

# Build Docker images
build_images() {
    print_header "Building Docker Images"

    print_msg "$YELLOW" "Building Ubuntu 22.04 image..."
    docker build -t timing-experiment:ubuntu -f Dockerfile.ubuntu .

    print_msg "$YELLOW" "Building ROS2 Humble image..."
    docker build -t timing-experiment:ros2 -f Dockerfile.ros2 .

    print_msg "$GREEN" "✓ Docker images built successfully"
}

# Import images to K3s
import_images_to_k3s() {
    print_header "Importing Images to K3s"

    print_msg "$YELLOW" "Saving Ubuntu image..."
    docker save timing-experiment:ubuntu -o /tmp/timing-ubuntu.tar

    print_msg "$YELLOW" "Importing Ubuntu image to K3s..."
    sudo k3s ctr images import /tmp/timing-ubuntu.tar

    print_msg "$YELLOW" "Saving ROS2 image..."
    docker save timing-experiment:ros2 -o /tmp/timing-ros2.tar

    print_msg "$YELLOW" "Importing ROS2 image to K3s..."
    sudo k3s ctr images import /tmp/timing-ros2.tar

    rm /tmp/timing-ubuntu.tar /tmp/timing-ros2.tar

    print_msg "$GREEN" "✓ Images imported to K3s successfully"
}

# Wait for pods to be ready
wait_for_pods_ready() {
    local namespace=$1
    local expected_count=$2
    local max_wait=$3

    print_msg "$YELLOW" "Waiting for $expected_count pods to be ready (max ${max_wait}s)..."

    local elapsed=0
    local interval=5

    while [ $elapsed -lt $max_wait ]; do
        local ready_count=$(kubectl get pods -n "$namespace" --no-headers 2>/dev/null | grep -c "Running" || echo "0")

        if [ "$ready_count" -eq "$expected_count" ]; then
            print_msg "$GREEN" "✓ All $expected_count pods are ready"
            return 0
        fi

        print_msg "$YELLOW" "  Ready: $ready_count/$expected_count (${elapsed}s elapsed)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    print_msg "$RED" "Warning: Not all pods became ready within ${max_wait}s"
    return 1
}

# Collect timing logs from shared directory
collect_logs() {
    local data_dir=$1
    local result_dir=$2
    local experiment_num=$3

    print_msg "$YELLOW" "Collecting logs from: $data_dir"

    # Create experiment-specific log directory
    local exp_log_dir="${result_dir}/exp${experiment_num}"
    mkdir -p "$exp_log_dir"

    # Copy all .txt files from shared directory
    if [ -d "$data_dir" ]; then
        local file_count=$(find "$data_dir" -maxdepth 1 -name "*.txt" 2>/dev/null | wc -l)

        if [ "$file_count" -gt 0 ]; then
            sudo cp "$data_dir"/*.txt "$exp_log_dir/" 2>/dev/null || true
            sudo chown -R $USER:$USER "$exp_log_dir"
            print_msg "$GREEN" "✓ Collected $file_count log files to $exp_log_dir"
        else
            print_msg "$YELLOW" "Warning: No log files found in $data_dir"
        fi
    else
        print_msg "$YELLOW" "Warning: Data directory $data_dir does not exist"
    fi
}

# Restart K3s and track activation timestamp
restart_k3s() {
    local timestamp_file=$1

    print_header "Restarting K3s"

    print_msg "$YELLOW" "Stopping K3s..."
    sudo /usr/local/bin/k3s-killall.sh || true
    sleep 5

    print_msg "$YELLOW" "Starting K3s..."
    local start_time=$(date +%s.%N)
    sudo systemctl start k3s

    # Poll K3s status until it becomes active
    print_msg "$YELLOW" "Waiting for K3s to become active..."
    local active_timestamp=""
    local max_wait=120  # Maximum 120 seconds
    local elapsed=0

    while [ -z "$active_timestamp" ] && (( $(echo "$elapsed < $max_wait" | bc -l) )); do
        sleep $K3S_STATUS_CHECK_INTERVAL

        if systemctl is-active --quiet k3s; then
            # Capture the exact timestamp when K3s becomes active
            active_timestamp=$(date +%s.%N)
            local elapsed_time=$(echo "$active_timestamp - $start_time" | bc -l)
            print_msg "$GREEN" "✓ K3s became active at: $active_timestamp ($(printf "%.3f" $elapsed_time)s after start command)"

            # Save timestamp to file if provided
            if [ -n "$timestamp_file" ]; then
                echo "$active_timestamp" >> "$timestamp_file"
            fi
            break
        fi

        elapsed=$(echo "$elapsed + $K3S_STATUS_CHECK_INTERVAL" | bc -l)
    done

    if [ -z "$active_timestamp" ]; then
        print_msg "$RED" "Error: K3s failed to become active within ${max_wait}s"
        return 1
    fi

    # Additional wait for K3s API to be fully ready
    print_msg "$YELLOW" "Waiting for K3s API to be fully ready..."
    sleep 30
}

# Run a single experiment configuration
run_experiment() {
    local config_name=$1
    local deployment_file=$2
    local data_dir=$3
    local expected_pod_count=$4

    print_header "Starting Experiment: $config_name"

    # Create result directory
    local result_dir="${RESULTS_DIR}/${config_name}_$(date +%Y%m%d_%H%M%S)"
    mkdir -p "$result_dir"

    # Create K3s activation timestamps file
    local k3s_timestamps_file="$result_dir/k3s_activation_timestamps.txt"
    echo "# K3s activation timestamps (Unix epoch with nanoseconds)" > "$k3s_timestamps_file"
    echo "# Format: Each line is the timestamp when K3s became active for that experiment" >> "$k3s_timestamps_file"
    echo "# exp0 is warmup (not logged), exp1-exp20 timestamps are below" >> "$k3s_timestamps_file"

    # Save configuration info
    echo "Configuration: $config_name" > "$result_dir/config.txt"
    echo "Deployment: $deployment_file" >> "$result_dir/config.txt"
    echo "Pod Count: $expected_pod_count" >> "$result_dir/config.txt"
    echo "Max Experiments (including warmup): $MAX_EXPERIMENTS" >> "$result_dir/config.txt"
    echo "Logged Experiments: $((MAX_EXPERIMENTS - 1))" >> "$result_dir/config.txt"
    echo "Start Time: $(date)" >> "$result_dir/config.txt"

    # Clean up data directory
    print_msg "$YELLOW" "Preparing data directory: $data_dir"
    sudo rm -rf "$data_dir"
    sudo mkdir -p "$data_dir"
    sudo chmod 777 "$data_dir"

    # Initial deployment
    print_msg "$YELLOW" "Deploying $config_name..."
    kubectl apply -f "$deployment_file"

    # Wait for initial pods to be ready
    wait_for_pods_ready "timing-experiment" "$expected_pod_count" 120

    # Run experiment iterations (exp0 to exp20, where exp0 is warmup)
    for exp_num in $(seq 0 $((MAX_EXPERIMENTS - 1))); do
        if [ $exp_num -eq 0 ]; then
            print_header "Experiment $config_name - Warmup (exp0 - not logged)"
        else
            print_header "Experiment $config_name - Iteration $exp_num/$((MAX_EXPERIMENTS - 1))"
        fi

        # Wait for logs to be written
        print_msg "$YELLOW" "Waiting ${LOG_COLLECTION_WAIT}s for logs to be written..."
        sleep $LOG_COLLECTION_WAIT

        # Collect logs only if not warmup (exp0)
        if [ $exp_num -gt 0 ]; then
            collect_logs "$data_dir" "$result_dir" "$exp_num"
        else
            print_msg "$YELLOW" "Skipping log collection for warmup iteration"
        fi

        # Clear the data directory for next iteration
        print_msg "$YELLOW" "Clearing data directory for next iteration..."
        sudo rm -f "$data_dir"/*.txt

        # If not the last experiment, restart K3s
        if [ $exp_num -lt $((MAX_EXPERIMENTS - 1)) ]; then
            restart_k3s "$k3s_timestamps_file"

            # Wait for pods to be ready again (K3s will automatically restart existing deployments)
            wait_for_pods_ready "timing-experiment" "$expected_pod_count" 120
        fi
    done

    # Final cleanup
    print_msg "$YELLOW" "Cleaning up deployment..."
    kubectl delete -f "$deployment_file" --ignore-not-found=true || true

    # Save end time
    echo "End Time: $(date)" >> "$result_dir/config.txt"

    # Generate summary
    print_msg "$YELLOW" "Generating summary..."
    local total_files=$(find "$result_dir" -name "*.txt" -not -name "config.txt" -not -name "k3s_activation_timestamps.txt" | wc -l)
    local k3s_timestamp_count=$(grep -v "^#" "$k3s_timestamps_file" | wc -l)
    echo "Total log files collected: $total_files" >> "$result_dir/config.txt"
    echo "K3s activation timestamps recorded: $k3s_timestamp_count" >> "$result_dir/config.txt"

    print_msg "$GREEN" "✓ Experiment $config_name completed!"
    print_msg "$GREEN" "Results saved to: $result_dir"
    print_msg "$GREEN" "K3s activation timestamps: $k3s_timestamps_file"
}

# Main execution
main() {
    # Parse command line arguments
    local build_images_flag=false

    for arg in "$@"; do
        case $arg in
            --build)
                build_images_flag=true
                shift
                ;;
            *)
                print_msg "$RED" "Unknown option: $arg"
                print_msg "$YELLOW" "Usage: $0 [--build]"
                print_msg "$YELLOW" "  --build    Build and import Docker images before experiments"
                exit 1
                ;;
        esac
    done

    print_header "K3s Pod Timing Experiment Suite"

    # Check if running as root
    if [ "$EUID" -eq 0 ]; then
        print_msg "$RED" "Error: This script should not be run as root."
        print_msg "$RED" "It will use sudo for specific commands that require elevated privileges."
        exit 1
    fi

    # Check K3s is running
    if ! systemctl is-active --quiet k3s; then
        print_msg "$RED" "Error: K3s is not running. Please start K3s first:"
        print_msg "$RED" "  sudo systemctl start k3s"
        exit 1
    fi

    # Check required commands
    for cmd in kubectl docker k3s bc; do
        if ! command -v $cmd &> /dev/null; then
            print_msg "$RED" "Error: Required command '$cmd' not found"
            exit 1
        fi
    done

    # Check k3s-killall.sh exists
    if [ ! -f /usr/local/bin/k3s-killall.sh ]; then
        print_msg "$RED" "Error: /usr/local/bin/k3s-killall.sh not found"
        exit 1
    fi

    # Create results directory
    mkdir -p "$RESULTS_DIR"

    # Conditionally build and import images
    if [ "$build_images_flag" = true ]; then
        build_images
        import_images_to_k3s
    else
        print_msg "$YELLOW" "Skipping image build (use --build flag to build images)"
    fi

    print_header "Experiment Configurations"
    print_msg "$YELLOW" "1. Ubuntu 22.04 - 8 pods"
    print_msg "$YELLOW" "2. Ubuntu 22.04 - 16 pods"
    print_msg "$YELLOW" "3. ROS2 Humble - 8 pods"
    print_msg "$YELLOW" "4. ROS2 Humble - 16 pods"
    print_msg "$YELLOW" "All configurations use core-id annotation: 8-15"
    print_msg "$YELLOW" "Each configuration will run for $((MAX_EXPERIMENTS - 1)) iterations (exp1-exp$((MAX_EXPERIMENTS - 1)))"
    print_msg "$YELLOW" "Note: exp0 is a warmup iteration and will not be logged"
    echo ""

    read -p "Do you want to run all experiments? (y/n) " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_msg "$YELLOW" "Experiment cancelled."
        exit 0
    fi

    # Run all experiment configurations
    run_experiment "ubuntu-8pods" \
                   "k8s/deployment-ubuntu-8pods.yaml" \
                   "/mnt/experiment-data/ubuntu-8pods" \
                   8

    run_experiment "ubuntu-16pods" \
                   "k8s/deployment-ubuntu-16pods.yaml" \
                   "/mnt/experiment-data/ubuntu-16pods" \
                   16

    run_experiment "ros2-8pods" \
                   "k8s/deployment-ros2-8pods.yaml" \
                   "/mnt/experiment-data/ros2-8pods" \
                   8

    run_experiment "ros2-16pods" \
                   "k8s/deployment-ros2-16pods.yaml" \
                   "/mnt/experiment-data/ros2-16pods" \
                   16

    print_header "All Experiments Completed!"
    print_msg "$GREEN" "Results are saved in: $RESULTS_DIR"

    # Generate final summary
    print_msg "$YELLOW" "Generating final summary..."
    local summary_file="$RESULTS_DIR/final_summary.txt"
    echo "Experiment Summary - $(date)" > "$summary_file"
    echo "=====================================" >> "$summary_file"

    for exp_dir in "$RESULTS_DIR"/*; do
        if [ -d "$exp_dir" ] && [ -f "$exp_dir/config.txt" ]; then
            echo "" >> "$summary_file"
            echo "$(basename "$exp_dir"):" >> "$summary_file"
            grep "Total log files" "$exp_dir/config.txt" >> "$summary_file" 2>/dev/null || echo "  No summary available" >> "$summary_file"
        fi
    done

    cat "$summary_file"
    print_msg "$GREEN" "✓ All experiments completed successfully!"
}

# Run main function
main "$@"
