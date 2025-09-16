#!/bin/bash

# Docker build script for BV-BRC runtime environments
# Usage: ./build-docker.sh [minimal|full|dev|all]

set -e

SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
PARENT_DIR="$(dirname "$SCRIPT_DIR")"
cd "$PARENT_DIR"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

# Function to check if Docker is installed
check_docker() {
    if ! command -v docker &> /dev/null; then
        print_error "Docker is not installed. Please install Docker first."
        exit 1
    fi
    print_info "Docker is installed"
}

# Function to check if docker-compose is installed
check_docker_compose() {
    if ! command -v docker-compose &> /dev/null && ! docker compose version &> /dev/null; then
        print_error "Docker Compose is not installed. Please install Docker Compose first."
        exit 1
    fi
    print_info "Docker Compose is installed"
}

# Function to prepare build context
prepare_build_context() {
    print_info "Preparing build context..."
    
    # Ensure minimal modules file exists in docker directory
    if [ ! -f "docker/modules-minimal.dat" ]; then
        print_info "Creating docker/modules-minimal.dat..."
        cat > docker/modules-minimal.dat <<EOF
# Minimal runtime modules for Perl, Python, and Go
kb_perl_runtime	./build.runtime
kb_python_runtime	./build.python
kb_python_runtime	./install-python-packages.sh
p3_python3	./build.package
EOF
    fi
    
    # Verify ubuntu-22 modules exist
    if [ ! -d "ubuntu-22" ]; then
        print_warning "ubuntu-22 directory not found. Full builds may fail."
    fi
}

# Function to build minimal runtime
build_minimal() {
    print_info "Building minimal runtime environment..."
    docker build -f docker/Dockerfile.minimal -t bvbrc/runtime:minimal .
    if [ $? -eq 0 ]; then
        print_info "Minimal runtime build completed successfully"
    else
        print_error "Minimal runtime build failed"
        exit 1
    fi
}

# Function to build full runtime
build_full() {
    print_info "Building full runtime environment..."
    docker build -f docker/Dockerfile.full -t bvbrc/runtime:full .
    if [ $? -eq 0 ]; then
        print_info "Full runtime build completed successfully"
    else
        print_error "Full runtime build failed"
        exit 1
    fi
}

# Function to build dev runtime
build_dev() {
    print_info "Building development runtime environment..."
    docker build -f docker/Dockerfile.full --target base -t bvbrc/runtime:dev .
    if [ $? -eq 0 ]; then
        print_info "Development runtime build completed successfully"
    else
        print_error "Development runtime build failed"
        exit 1
    fi
}

# Function to build base environment (mirrors base.def)
build_base() {
    print_info "Building base runtime environment (mirrors base.def)..."
    docker build --platform linux/amd64 -f docker/Dockerfile.base -t bvbrc/runtime:base -t c4epi/bvbrc-runtime:base .
    if [ $? -eq 0 ]; then
        print_info "Base runtime build completed successfully"
    else
        print_error "Base runtime build failed"
        exit 1
    fi
}

# Function to build basic environment (mirrors finish-1.def)
build_basic() {
    print_info "Building basic runtime environment (mirrors finish-1.def)..."
    docker build --platform linux/amd64 -f docker/Dockerfile.basic -t bvbrc/runtime:basic -t c4epi/bvbrc-runtime:basic .
    if [ $? -eq 0 ]; then
        print_info "Basic runtime build completed successfully"
    else
        print_error "Basic runtime build failed"
        exit 1
    fi
}

# Function to build BV-BRC dev optimized environment
build_bvbrc_dev_optimized() {
    print_info "Building BV-BRC service app development environment (optimized)..."
    docker build -f docker/Dockerfile.bvbrc-dev.optimized -t bvbrc/dev:optimized .
    if [ $? -eq 0 ]; then
        print_info "BV-BRC dev optimized build completed successfully"
    else
        print_error "BV-BRC dev optimized build failed"
        exit 1
    fi
}

# Function to build BV-BRC dev full environment
build_bvbrc_dev_full() {
    print_info "Building BV-BRC service app development environment (full)..."
    docker build -f docker/Dockerfile.bvbrc-dev.full -t bvbrc/dev:full .
    if [ $? -eq 0 ]; then
        print_info "BV-BRC dev full build completed successfully"
    else
        print_error "BV-BRC dev full build failed"
        exit 1
    fi
}

# Function to build using docker-compose
build_compose() {
    print_info "Building all environments using docker-compose..."
    cd docker
    if docker compose version &> /dev/null; then
        docker compose build
    else
        docker-compose build
    fi
    local result=$?
    cd ..
    if [ $result -eq 0 ]; then
        print_info "Docker Compose build completed successfully"
    else
        print_error "Docker Compose build failed"
        exit 1
    fi
}

# Function to show usage
show_usage() {
    echo "Usage: $0 [base|basic|minimal|full|dev|bvbrc-dev-optimized|bvbrc-dev-full|compose|all]"
    echo ""
    echo "Options:"
    echo "  base               - Build base runtime (mirrors base.def)"
    echo "  basic              - Build basic runtime with core modules (mirrors finish-1.def)"
    echo "  minimal            - Build minimal runtime with Perl, Python, and Go"
    echo "  full               - Build full runtime with all bioinformatics tools"
    echo "  dev                - Build development environment"
    echo "  bvbrc-dev-optimized - Build BV-BRC service app dev environment (optimized, multi-stage)"
    echo "  bvbrc-dev-full     - Build BV-BRC service app dev environment (full, production-like)"
    echo "  compose            - Build all using docker-compose"
    echo "  all                - Build all environments"
    echo ""
    echo "BV-BRC Development Containers:"
    echo "  optimized - Lightweight container with multi-stage builds for fast development"
    echo "  full      - Production-like container based on bvbrc/runtime:minimal-amd64"
    echo ""
    echo "If no option is provided, all environments will be built."
}

# Main script
check_docker
prepare_build_context

BUILD_TARGET=${1:-all}

case "$BUILD_TARGET" in
    base)
        build_base
        ;;
    basic)
        build_basic
        ;;
    minimal)
        build_minimal
        ;;
    full)
        build_full
        ;;
    dev)
        build_dev
        ;;
    bvbrc-dev-optimized)
        build_bvbrc_dev_optimized
        ;;
    bvbrc-dev-full)
        build_bvbrc_dev_full
        ;;
    compose)
        check_docker_compose
        build_compose
        ;;
    all)
        build_base
        build_basic
        build_minimal
        build_full
        build_dev
        build_bvbrc_dev_optimized
        build_bvbrc_dev_full
        print_info "All builds completed"
        ;;
    -h|--help|help)
        show_usage
        exit 0
        ;;
    *)
        print_error "Invalid option: $BUILD_TARGET"
        show_usage
        exit 1
        ;;
esac

print_info "Build process completed"
print_info "You can run containers using:"
print_info "  docker run -it bvbrc/runtime:minimal /bin/bash"
print_info "  docker run -it bvbrc/runtime:full /bin/bash"
print_info "  docker run -it bvbrc/runtime:dev /bin/bash"
print_info "  docker run -it bvbrc/dev:optimized /bin/bash"
print_info "  docker run -it bvbrc/dev:full /bin/bash"
print_info ""
print_info "BV-BRC Development containers with workspace:"
print_info "  docker run -it -v \$(pwd):/workspace bvbrc/dev:optimized /bin/bash"
print_info "  docker run -it -v \$(pwd):/workspace bvbrc/dev:full /bin/bash"
print_info ""
print_info "Or use docker-compose:"
print_info "  cd docker && docker-compose up -d dev-runtime"
print_info "  cd docker && docker-compose exec dev-runtime /bin/bash"