#!/bin/bash

set -e

# Colors for output (only if terminal supports it)
if [[ -t 1 ]] && command -v tput &> /dev/null && tput colors &> /dev/null && [[ $(tput colors) -ge 8 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    NC=''
fi

# Helper functions
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Function to validate version format (semantic versioning)
validate_version() {
    local version="$1"
    if [[ ! "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        print_error "Invalid version format. Please use semantic versioning (e.g., 1.0.0)"
        return 1
    fi
    return 0
}

# Function to increment version
increment_version() {
    local version="$1"
    local part="$2"
    
    IFS='.' read -r major minor patch <<< "$version"
    
    case "$part" in
        "major")
            major=$((major + 1))
            minor=0
            patch=0
            ;;
        "minor")
            minor=$((minor + 1))
            patch=0
            ;;
        "patch")
            patch=$((patch + 1))
            ;;
        *)
            print_error "Invalid increment type. Use: major, minor, or patch"
            return 1
            ;;
    esac
    
    echo "$major.$minor.$patch"
}

# Check if required tools are available
check_requirements() {
    local missing_tools=()
    
    if ! command -v git &> /dev/null; then
        missing_tools+=("git")
    fi
    
    if ! command -v gh &> /dev/null; then
        missing_tools+=("gh (GitHub CLI)")
    fi
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        print_info "Please install the missing tools and try again."
        exit 1
    fi
}

# Check git status
check_git_status() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        print_error "Not in a git repository"
        exit 1
    fi
    
    # Fetch latest changes
    print_info "Fetching latest changes from remote..."
    git fetch --all
    
    local current_branch=$(git branch --show-current)
    print_info "Current branch: $current_branch"
    
    # Check if there are uncommitted changes
    if ! git diff-index --quiet HEAD --; then
        print_warning "You have uncommitted changes that will be included in the release."
        git status --short
        echo
        read -p "Do you want to continue? (y/N): " continue_choice
        if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
            print_info "Release cancelled."
            exit 0
        fi
    fi
}

print_info "=== SCDF-RAG Release Script ==="
echo

# Check requirements
check_requirements

# Check git status
check_git_status

# Get current version
current_version=""
if [[ -f VERSION ]]; then
    current_version=$(cat VERSION | tr -d '\n' | tr -d ' ')
    print_info "Current version: $current_version"
else
    print_warning "No VERSION file found. Starting with version 1.0.0"
    current_version="1.0.0"
    echo "$current_version" > VERSION
fi

# Ask user for version choice
echo
echo "Version options:"
echo "1) Increment patch version (${current_version} -> $(increment_version "$current_version" "patch"))"
echo "2) Increment minor version (${current_version} -> $(increment_version "$current_version" "minor"))"
echo "3) Increment major version (${current_version} -> $(increment_version "$current_version" "major"))"
echo "4) Specify custom version"
echo

read -p "Choose an option [1-4, default: 1]: " version_choice

case "$version_choice" in
    "2")
        new_version=$(increment_version "$current_version" "minor")
        ;;
    "3")
        new_version=$(increment_version "$current_version" "major")
        ;;
    "4")
        while true; do
            read -p "Enter new version (e.g., 2.1.0): " custom_version
            if validate_version "$custom_version"; then
                new_version="$custom_version"
                break
            fi
        done
        ;;
    *)
        new_version=$(increment_version "$current_version" "patch")
        ;;
esac

print_info "New version will be: $new_version"

# Update VERSION file
echo "$new_version" > VERSION

# Get commit message
echo
read -p "Enter release commit message [Release v$new_version]: " commit_msg
if [[ -z "$commit_msg" ]]; then
    commit_msg="Release v$new_version"
fi

# Get release notes
echo
read -p "Enter release notes (optional): " release_notes
if [[ -z "$release_notes" ]]; then
    release_notes="$commit_msg"
fi

# Show what will be committed
echo
print_info "Files to be committed:"
git add .
git status --short

echo
read -p "Proceed with release? (y/N): " proceed_choice
if [[ ! "$proceed_choice" =~ ^[Yy]$ ]]; then
    print_info "Release cancelled."
    # Restore VERSION file
    echo "$current_version" > VERSION
    exit 0
fi

# Commit and push changes
print_info "Committing changes..."
git commit -m "$commit_msg"

print_info "Pushing changes to remote..."
git push

# Create and push tag
print_info "Creating and pushing tag v$new_version..."
git tag -a "v$new_version" -m "Release v$new_version: $release_notes"
git push origin "v$new_version"

# Create GitHub release
print_info "Creating GitHub release..."
if gh release create "v$new_version" --title "Release v$new_version" --notes "$release_notes"; then
    print_success "GitHub release created successfully!"
else
    print_warning "Failed to create GitHub release. You may need to create it manually."
fi

print_success "Release process completed successfully!"
print_info "Version: v$new_version"
print_info "Branch: $(git branch --show-current)"
print_info "Commit: $(git rev-parse HEAD)"
