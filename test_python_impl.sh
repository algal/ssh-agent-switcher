#!/bin/bash
# Simple test script for the Python implementation of ssh-agent-switcher

set -e  # Exit on error

echo "Starting tests for the Python ssh-agent-switcher..."

# Test 1: Default socket path
echo "Test 1: Testing default socket path..."
SOCKETS_ROOT="$(mktemp -d -p /tmp)"
USER=fake-user ./ssh_agent_switcher.py 2>switcher.log &
PID=$!
sleep 1  # Wait for the socket to appear

if [ ! -e /tmp/ssh-agent.fake-user ]; then
  echo "ERROR: Default socket path test failed - socket not created"
  kill $PID
  rm -rf "$SOCKETS_ROOT"
  exit 1
fi

echo "  Socket created successfully at /tmp/ssh-agent.fake-user"
kill $PID
rm -f /tmp/ssh-agent.fake-user
rm -f switcher.log

# Test 2: Custom socket path and SIGHUP handling
echo "Test 2: Testing custom socket path and SIGHUP handling..."
SOCKET="${SOCKETS_ROOT}/custom_socket"
./ssh_agent_switcher.py --socketPath "${SOCKET}" 2>switcher.log &
PID=$!
sleep 1  # Wait for the socket to appear

if [ ! -e "${SOCKET}" ]; then
  echo "ERROR: Custom socket path test failed - socket not created"
  kill $PID
  rm -rf "$SOCKETS_ROOT"
  exit 1
fi

echo "  Socket created successfully at ${SOCKET}"

# Test SIGHUP handling
echo "  Testing SIGHUP handling..."
kill -HUP $PID
sleep 1

if [ ! -e "${SOCKET}" ]; then
  echo "ERROR: SIGHUP test failed - daemon exited and deleted socket"
  rm -rf "$SOCKETS_ROOT"
  exit 1
fi

echo "  SIGHUP ignored successfully"
kill $PID
sleep 1  # Wait for cleanup

# Test 3: Integration with ssh-agent
echo "Test 3: Basic integration test..."

# Start a real SSH agent
AGENT_DIR="${SOCKETS_ROOT}/ssh-test"
mkdir -p "$AGENT_DIR"
AGENT_SOCK="${AGENT_DIR}/agent.test"
ssh-agent -a "$AGENT_SOCK" >agent.env

# Start our switcher pointing to the sockets root
SWITCHER_SOCK="${SOCKETS_ROOT}/switcher_sock"
./ssh_agent_switcher.py --socketPath "$SWITCHER_SOCK" --agentsDir "$SOCKETS_ROOT" 2>switcher.log &
SWITCHER_PID=$!
sleep 1

export SSH_AUTH_SOCK="$SWITCHER_SOCK"

# Try to use the agent
echo "  Testing ssh-add -l..."
SSH_ADD_OUTPUT=$(ssh-add -l 2>&1 || true)
if [[ ! "$SSH_ADD_OUTPUT" == *"no identities"* ]]; then
  echo "ERROR: ssh-add test failed"
  echo "Output: $SSH_ADD_OUTPUT"
  kill $SWITCHER_PID
  . agent.env
  kill $SSH_AGENT_PID
  rm -rf "$SOCKETS_ROOT"
  exit 1
fi

echo "  ssh-add -l test passed"

# Check log for expected messages
if ! grep -q "Successfully opened SSH agent at $AGENT_SOCK" switcher.log; then
  echo "ERROR: Log does not contain expected 'Successfully opened' message"
  cat switcher.log
  kill $SWITCHER_PID
  . agent.env
  kill $SSH_AGENT_PID
  rm -rf "$SOCKETS_ROOT"
  exit 1
fi

echo "  Log contains expected agent connection message"

# Clean up
kill $SWITCHER_PID
. agent.env
kill $SSH_AGENT_PID
rm -rf "$SOCKETS_ROOT"
rm -f agent.env
rm -f switcher.log

echo "All tests passed!"