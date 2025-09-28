#!/bin/bash

# Get the script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Explicitly set environment variables for systemd
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
export HOME="/opt/moodle-crawler"

# Define possible Python commands to try in order
PYTHON_COMMANDS=("python3" "python" "/usr/bin/python3" "/usr/bin/python")

# Check for Python installation
PYTHON_CMD=""
for cmd in "${PYTHON_COMMANDS[@]}"; do
    if command -v $cmd &> /dev/null; then
        PYTHON_CMD=$cmd
        echo "Found Python: $($PYTHON_CMD --version 2>&1)"
        break
    fi
done

# If Python is not found, try to install it
if [ -z "$PYTHON_CMD" ]; then
    echo "Python not found. Checking if we can install it..."
    if command -v apt-get &> /dev/null; then
        echo "Attempting to install Python 3 (this may require sudo)..."
        sudo apt-get update && sudo apt-get install -y python3 python3-pip python3-venv || {
            echo "Error: Python is not installed and installation attempt failed."
            echo "Please install Python 3 manually with: sudo apt-get install -y python3 python3-pip python3-venv"
            exit 1
        }
        PYTHON_CMD="python3"
    else
        echo "Error: Python is not installed. Please install Python 3."
        exit 1
    fi
fi

# Check if virtual environment exists, create if it doesn't
PROJECT_ROOT="$(cd "$SCRIPT_DIR" && pwd)"
if [ ! -d "$PROJECT_ROOT/venv" ]; then
    echo "Virtual environment not found. Creating one..."
    $PYTHON_CMD -m venv "$PROJECT_ROOT/venv" || {
        echo "Failed to create virtual environment. Make sure python3-venv or python-venv package is installed."
        echo "Try: apt-get update && apt-get install -y python3-venv"
        exit 1
    }

    echo "Installing requirements..."
    "$PROJECT_ROOT/venv/bin/pip" install -r "$PROJECT_ROOT/requirements.txt" || {
        echo "Failed to install requirements. Check your internet connection and requirements.txt file."
        exit 1
    }
fi

# Activate virtual environment with absolute path
if [ -f "$PROJECT_ROOT/venv/bin/activate" ]; then
    source "$PROJECT_ROOT/venv/bin/activate"
else
    echo "Error: Virtual environment not found at $PROJECT_ROOT/venv/bin/activate"
    exit 1
fi

# Use Python from the virtual environment
VENV_PYTHON="$PROJECT_ROOT/venv/bin/python"
if [ ! -f "$VENV_PYTHON" ]; then
    echo "Error: Python not found in virtual environment at $VENV_PYTHON"
    exit 1
fi

# Run the crawler script with the Python from the virtual environment
# and with all arguments passed to this script
"$VENV_PYTHON" "$PROJECT_ROOT/moodle-crawler.py" "$@"
