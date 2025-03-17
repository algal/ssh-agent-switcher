#!/bin/bash
# Comparison test script that tests both Go and Python implementations

set -e  # Exit on error

echo "Building Go implementation..."
go build -o ssh-agent-switcher-go main.go
chmod +x ssh-agent-switcher-go

echo "Starting comparison tests for both implementations..."

# Function to run a test with both implementations and compare results
run_comparison_test() {
  local test_name="$1"
  local test_func="$2"
  
  echo "====== Test: $test_name ======"
  
  # Run with Go implementation first
  echo "Running with Go implementation..."
  local go_output_file="go_output.log"
  local go_log_file="go_switcher.log"
  $test_func "go" "./ssh-agent-switcher-go" "$go_output_file" "$go_log_file"
  
  # Run with Python implementation
  echo "Running with Python implementation..."
  local py_output_file="py_output.log"
  local py_log_file="py_switcher.log"
  $test_func "py" "./ssh_agent_switcher.py" "$py_output_file" "$py_log_file"
  
  # Compare essential parts of the logs
  echo "Comparing results..."
  
  # Filter logs to compare only essential parts (removing timestamps, PIDs, etc)
  grep -v "^time=" "$go_log_file" | sort > "go_filtered.log"
  grep -v "^20" "$py_log_file" | sort > "py_filtered.log"
  
  if diff -q "go_filtered.log" "py_filtered.log" >/dev/null; then
    echo "✅ Logs match (with expected formatting differences)"
  else
    echo "⚠️ Logs differ in content (may be acceptable formatting differences)"
    echo "Differences:"
    diff -u "go_filtered.log" "py_filtered.log" | head -20
  fi
  
  # Compare actual output
  if diff -q "$go_output_file" "$py_output_file" >/dev/null; then
    echo "✅ Command outputs match exactly"
  else
    echo "❌ Command outputs differ"
    echo "Differences:"
    diff -u "$go_output_file" "$py_output_file"
    return 1
  fi
  
  echo "Test passed!"
  return 0
}

# Test 1: Default socket path test
test_default_socket_path() {
  local impl_name="$1"
  local binary="$2"
  local output_file="$3"
  local log_file="$4"
  
  local sockets_dir="$(mktemp -d -p /tmp)"
  local socket_path="/tmp/ssh-agent.fake-user"
  
  # Remove socket if it exists from previous run
  rm -f "$socket_path"
  
  # Run the implementation
  USER=fake-user $binary 2>"$log_file" &
  local pid=$!
  
  # Wait for socket to appear
  local i=0
  while [ ! -e "$socket_path" ] && [ $i -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  
  # Check if socket was created
  if [ -e "$socket_path" ]; then
    echo "Socket created: Yes" > "$output_file"
  else
    echo "Socket created: No" > "$output_file"
  fi
  
  # Clean up
  kill $pid
  rm -f "$socket_path"
  rm -rf "$sockets_dir"
}

# Test 2: SIGHUP handling test
test_sighup_handling() {
  local impl_name="$1"
  local binary="$2"
  local output_file="$3"
  local log_file="$4"
  
  local sockets_dir="$(mktemp -d -p /tmp)"
  local socket_path="${sockets_dir}/socket"
  
  # Run the implementation
  $binary --socketPath "$socket_path" 2>"$log_file" &
  local pid=$!
  
  # Wait for socket to appear
  local i=0
  while [ ! -e "$socket_path" ] && [ $i -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  
  # Send SIGHUP
  kill -HUP $pid
  
  # Wait to see if process survived
  sleep 1
  
  # Check if socket still exists and process is running
  if kill -0 $pid 2>/dev/null && [ -e "$socket_path" ]; then
    echo "Process survived SIGHUP: Yes" > "$output_file"
  else
    echo "Process survived SIGHUP: No" > "$output_file"
  fi
  
  # Clean up
  kill $pid 2>/dev/null || true
  rm -rf "$sockets_dir"
}

# Test 3: Agent discovery test
test_agent_discovery() {
  local impl_name="$1"
  local binary="$2"
  local output_file="$3"
  local log_file="$4"
  
  local sockets_dir="$(mktemp -d -p /tmp)"
  
  # Create agent directory structure
  local agent_dir="${sockets_dir}/ssh-test"
  mkdir -p "$agent_dir"
  local agent_sock="${agent_dir}/agent.test"
  
  # Start a real SSH agent
  ssh-agent -a "$agent_sock" > agent.env
  
  # Create some distractors (as in the original test)
  touch "${sockets_dir}/file-unknown"
  mkdir "${sockets_dir}/dir-unknown"
  touch "${sockets_dir}/ssh-not-a-dir"
  mkdir "${sockets_dir}/ssh-empty"
  
  # Start our switcher pointing to the sockets root
  local switcher_sock="${sockets_dir}/switcher_sock"
  $binary --socketPath "$switcher_sock" --agentsDir "$sockets_dir" 2>"$log_file" &
  local pid=$!
  
  # Wait for socket to appear
  local i=0
  while [ ! -e "$switcher_sock" ] && [ $i -lt 50 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  
  # Try to use the agent
  export SSH_AUTH_SOCK="$switcher_sock"
  ssh-add -l > "$output_file" 2>&1 || true
  
  # Clean up
  kill $pid
  . agent.env
  kill $SSH_AGENT_PID
  rm -f agent.env
  rm -rf "$sockets_dir"
}

# Run all comparison tests
run_comparison_test "Default Socket Path" test_default_socket_path
run_comparison_test "SIGHUP Handling" test_sighup_handling
run_comparison_test "Agent Discovery and SSH-Add" test_agent_discovery

# Clean up all temporary files
rm -f go_output.log py_output.log go_switcher.log py_switcher.log go_filtered.log py_filtered.log

echo "All comparison tests completed!"