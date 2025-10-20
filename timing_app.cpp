#include <iostream>
#include <fstream>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sstream>

// Paths
const char* SHARED_DIR = "/shared";

// Get pod name from hostname
std::string getPodName() {
    char hostname[256];
    gethostname(hostname, sizeof(hostname));
    return std::string(hostname);
}

// Get monotonic clock time
void getCurrentTime(struct timespec* ts) {
    clock_gettime(CLOCK_MONOTONIC, ts);
}

// Format timespec to string
std::string formatTime(const struct timespec& ts) {
    std::ostringstream oss;
    oss << ts.tv_sec << "." << ts.tv_nsec;
    return oss.str();
}

int main() {
    std::cout << "=== Pod Timing Experiment ===" << std::endl;

    // Get pod information
    std::string podName = getPodName();
    std::cout << "Pod name: " << podName << std::endl;

    // Get current time
    struct timespec startTime;
    getCurrentTime(&startTime);

    std::cout << "Start time (CLOCK_MONOTONIC): "
              << formatTime(startTime) << std::endl;

    // Write timing data to shared folder
    std::string fileName = std::string(SHARED_DIR) + "/" + podName + ".txt";
    std::ofstream file(fileName);
    if (file.is_open()) {
        file << "pod=" << podName << std::endl;
        file << "start_time_sec=" << startTime.tv_sec << std::endl;
        file << "start_time_nsec=" << startTime.tv_nsec << std::endl;
        file << "start_time_formatted=" << formatTime(startTime) << std::endl;
        file.close();
        std::cout << "Wrote timing data to: " << fileName << std::endl;
    } else {
        std::cerr << "Error: Could not write to " << fileName << std::endl;
        return 1;
    }

    std::cout << "=== Timing logged successfully ===" << std::endl;
    std::cout << "Keeping container running..." << std::endl;

    // Keep the container running indefinitely
    while(true) {
        sleep(3600);
    }

    return 0;
}
