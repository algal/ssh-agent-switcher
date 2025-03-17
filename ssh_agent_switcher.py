#!/usr/bin/env python3
"""
ssh-agent-switcher serves a Unix domain socket that proxies connections to any valid SSH agent
socket provided by sshd.
"""

import argparse
import errno
import logging
import os
import signal
import socket
import stat
import sys
import threading
from typing import Optional, List, Tuple


def default_socket_path() -> str:
    """Computes the name of the default value for the socketPath argument."""
    user = os.environ.get("USER", "")
    if not user:
        return ""
    return f"/tmp/ssh-agent.{user}"


def find_agent_socket_subdir(dir_path: str) -> Optional[socket.socket]:
    """
    Scans the contents of "dir", which should point to a session directory created by sshd,
    looks for a valid "agent.*" socket, opens it, and returns the connection to the agent.

    This tries all possible files in search for a socket and only returns an error if no valid
    and alive candidate can be found.
    """
    try:
        entries = os.listdir(dir_path)
    except OSError as err:
        return None

    for entry in entries:
        path = os.path.join(dir_path, entry)

        if not entry.startswith("agent."):
            logging.info(f"Ignoring {path}: does not start with 'agent.'")
            continue

        try:
            file_info = os.stat(path)
        except OSError as err:
            logging.info(f"Ignoring {path}: stat failed: {err}")
            continue

        # Check if it's a socket
        if not stat.S_ISSOCK(file_info.st_mode):
            logging.info(f"Ignoring {path}: not a socket")
            continue

        try:
            conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            conn.connect(path)
            logging.info(f"Successfully opened SSH agent at {path}")
            return conn
        except socket.error as err:
            logging.info(f"Ignoring {path}: open failed: {err}")
            continue

    return None


def find_agent_socket(dir_path: str) -> Optional[socket.socket]:
    """
    Scans the contents of "dir", which should point to the directory where
    sshd places the session directories for forwarded agents, looks for a valid connection to
    an agent, opens the agent's socket, and returns the connection to the agent.

    This tries all possible directories in search for a socket and only returns an error if
    no valid and alive candidate can be found.
    """
    try:
        entries = os.listdir(dir_path)
    except OSError as err:
        return None

    # The sorting is unnecessary but it helps with testing certain conditions.
    entries.sort()

    our_uid = os.getuid()
    for entry in entries:
        path = os.path.join(dir_path, entry)

        if not os.path.isdir(path):
            logging.info(f"Ignoring {path}: not a directory")
            continue

        if not entry.startswith("ssh-"):
            logging.info(f"Ignoring {path}: does not start with 'ssh-'")
            continue

        try:
            file_info = os.stat(path)
        except OSError as err:
            logging.info(f"Ignoring {path}: stat failed: {err}")
            continue

        # This check is not strictly necessary: if we found sshd sockets owned by other users, we
        # would simply fail to open them later anyway.
        if file_info.st_uid != our_uid:
            logging.info(f"Ignoring {path}: owner {file_info.st_uid} is not current user {our_uid}")
            continue

        agent = find_agent_socket_subdir(path)
        if agent is not None:
            return agent
        logging.info(f"Ignoring {path}: no socket in directory")

    return None


def proxy_connection(client: socket.socket, agent: socket.socket) -> Optional[Exception]:
    """
    Forwards all request from the client to the agent, and all responses from
    the agent to the client.
    """
    # The buffer needs to be large enough to handle any one read or write by the client or
    # the agent. Otherwise bad things will happen.
    buf_size = 4096

    try:
        while True:
            try:
                # Read from client
                data = client.recv(buf_size)
                if not data:  # EOF
                    break

                # Write to agent
                try:
                    agent.sendall(data)
                except socket.error as err:
                    return Exception(f"write to agent failed: {err}")

                # Read from agent
                try:
                    response = agent.recv(buf_size)
                    if not response:
                        break
                except socket.error as err:
                    return Exception(f"read from agent failed: {err}")

                # Write to client
                try:
                    client.sendall(response)
                except socket.error as err:
                    return Exception(f"write to client failed: {err}")
                
            except socket.error as err:
                if err.errno == errno.ECONNRESET:
                    # Connection reset by peer - not an error
                    break
                return Exception(f"read from client failed: {err}")
    except Exception as err:
        return err

    return None


def handle_connection(client: socket.socket, agents_dir: str) -> None:
    """
    Receives a connection from the client, looks for an sshd serving an agent,
    and proxies the connection to it.
    """
    logging.info("Accepted client connection")
    
    try:
        agent = find_agent_socket(agents_dir)
        if agent is None:
            logging.info("Dropping connection: agent not found")
            client.close()
            return

        try:
            err = proxy_connection(client, agent)
            if err:
                logging.info(f"Dropping connection: {err}")
        finally:
            agent.close()
            
    finally:
        client.close()
        logging.info("Closing client connection")


def setup_signals(socket_path: str) -> None:
    """
    Installs signal handlers to clean up files and ignores signals that we don't want
    to cause us to exit.
    """
    # Prevent terminal disconnects from killing this process if started in the background.
    signal.signal(signal.SIGHUP, signal.SIG_IGN)

    # Clean up the socket we create on exit.
    def cleanup_handler(signum, frame):
        logging.info(f"Shutting down due to signal and deleting {socket_path}")
        try:
            os.unlink(socket_path)
        except OSError:
            pass
        sys.exit(1)

    signal.signal(signal.SIGINT, cleanup_handler)
    signal.signal(signal.SIGTERM, cleanup_handler)


def connection_handler_thread(client: socket.socket, agents_dir: str) -> None:
    """Thread function to handle a client connection."""
    handle_connection(client, agents_dir)


def run_server(args) -> None:
    if not args.socketPath:
        logging.error("socketPath is empty")
        sys.exit(1)
    
    # Configure logging
    logging.basicConfig(
        level=logging.INFO,
        format='%(levelname)s: %(message)s'  # Match Go's log format
    )

    # Install signal handlers before we create the socket so that we don't leave it
    # behind in any case.
    setup_signals(args.socketPath)

    # Ensure the socket is not group nor world readable so that we don't expose the
    # real socket indirectly to other users.
    old_umask = os.umask(0o177)
    
    try:
        # Remove the socket file if it already exists
        try:
            os.unlink(args.socketPath)
        except OSError:
            if os.path.exists(args.socketPath):
                raise

        server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        server.bind(args.socketPath)
        server.listen(5)
        logging.info(f"Listening on {args.socketPath}")
        
        while True:
            client, _ = server.accept()
            # Use a thread for each connection to match Go's goroutines
            thread = threading.Thread(
                target=connection_handler_thread,
                args=(client, args.agentsDir),
                daemon=True
            )
            thread.start()
            
    except KeyboardInterrupt:
        logging.info(f"Shutting down and deleting {args.socketPath}")
        try:
            os.unlink(args.socketPath)
        except OSError:
            pass
    finally:
        # Restore the original umask
        os.umask(old_umask)
    

def main() -> None:
    """Main entry point for the program."""
    parser = argparse.ArgumentParser(
        description="SSH agent switcher that proxies connections to any valid SSH agent socket")
    parser.add_argument(
        "--socketPath", 
        default=default_socket_path(),
        help="path to the socket to listen on"
    )
    parser.add_argument(
        "--agentsDir", 
        default="/tmp",
        help="directory where to look for running agents"
    )
    
    args = parser.parse_args()
    
    # No positional arguments allowed
    if len(sys.argv) > 1 and sys.argv[1][0] != '-':
        logging.error("No arguments allowed")
        sys.exit(1)

    run_server(args)

if __name__ == "__main__":
    main()
