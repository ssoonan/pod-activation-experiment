#include <iostream>
#include <fstream>
#include <time.h>
#include <unistd.h>
#include <sys/stat.h>
#include <sstream>
#include <cstdlib>

// Get shared directory from environment or use default
std::string getSharedDir() {
    const char* env_dir = std::getenv("SHARED_DIR");
    if (env_dir != nullptr) {
        return std::string(env_dir);
    }
    return "/shared";
}

// Get process name from environment (HOSTNAME) or hostname
std::string getProcessName() {
    const char* env_hostname = std::getenv("HOSTNAME");
    if (env_hostname != nullptr) {
        return std::string(env_hostname);
    }

    char hostname[256];
    gethostname(hostname, sizeof(hostname));
    return std::string(hostname);
}

// Get realtime clock time (Unix epoch)
void getCurrentTime(struct timespec* ts) {
    clock_gettime(CLOCK_REALTIME, ts);
}

// Format timespec to string
std::string formatTime(const struct timespec& ts) {
    std::ostringstream oss;
    oss << ts.tv_sec << "." << ts.tv_nsec;
    return oss.str();
}

int main() {
    std::cout << "=== Baseline Timing Experiment ===" << std::endl;

    // Get process information
    std::string processName = getProcessName();
    std::cout << "Process name: " << processName << std::endl;

    // Get shared directory
    std::string sharedDir = getSharedDir();
    std::cout << "Shared directory: " << sharedDir << std::endl;

    // Get current time
    struct timespec startTime;
    getCurrentTime(&startTime);

    std::cout << "Start time (CLOCK_REALTIME): "
              << formatTime(startTime) << std::endl;

    // Write timing data to shared folder
    std::string fileName = sharedDir + "/" + processName + ".txt";
    std::ofstream file(fileName);
    if (file.is_open()) {
        file << "process=" << processName << std::endl;
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
    std::cout << "Process exiting normally (baseline mode)..." << std::endl;

    // For baseline, exit immediately after logging
    // (not keeping container running like in K8s version)
    return 0;
}
