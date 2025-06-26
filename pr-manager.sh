#!/bin/bash

set -e

# Colors for output (only if terminal supports it)
if [[ -t 1 ]] && command -v tput &> /dev/null && tput colors &> /dev/null && [[ $(tput colors) -ge 8 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    PURPLE='\033[0;35m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    PURPLE=''
    NC=''
fi

# Helper functions - all output to stderr so they don't interfere with return values
print_info() {
    echo -e "${BLUE}[INFO]${NC} $1" >&2
}

print_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1" >&2
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1" >&2
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_header() {
    echo -e "${PURPLE}[PR-MANAGER]${NC} $1" >&2
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
        print_info "Install GitHub CLI: https://cli.github.com/"
        exit 1
    fi
}

# Get the default branch (main or master)
get_default_branch() {
    local default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@')
    if [[ -z "$default_branch" ]]; then
        # Try to determine from available branches
        if git show-ref --verify --quiet refs/remotes/origin/main; then
            default_branch="main"
        elif git show-ref --verify --quiet refs/remotes/origin/master; then
            default_branch="master"
        else
            print_error "Could not determine default branch. Please specify manually." >&2
            exit 1
        fi
    fi
    printf "%s" "$default_branch"
}

# Check git status and repository
check_git_status() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        print_error "Not in a git repository"
        exit 1
    fi
    
    # Fetch latest changes
    print_info "Fetching latest changes from remote..."
    git fetch --all >&2
    
    local current_branch=$(git branch --show-current)
    local default_branch=$(get_default_branch)
    
    print_info "Current branch: $current_branch"
    print_info "Default branch: $default_branch"
    
    if [[ "$current_branch" == "$default_branch" ]]; then
        print_warning "You are on the default branch ($default_branch)."
        print_info "Consider creating a feature branch for your changes."
    fi
    
    # Check for uncommitted changes
    if ! git diff-index --quiet HEAD --; then
        print_warning "You have uncommitted changes."
        git status --short >&2
        echo >&2
        read -p "Do you want to commit and push these changes first? (y/N): " commit_choice
        if [[ "$commit_choice" =~ ^[Yy]$ ]]; then
            read -p "Enter commit message: " commit_msg
            if [[ -n "$commit_msg" ]]; then
                git add . >&2
                git commit -m "$commit_msg" >&2
                print_success "Changes committed."
                
                # Push the changes
                print_info "Pushing committed changes..."
                git push >&2
                print_success "Changes pushed to remote."
            else
                print_error "Commit message required."
                exit 1
            fi
        else
            print_warning "Uncommitted changes will be included when creating PR."
            echo >&2
            read -p "Continue anyway? (y/N): " continue_choice
            if [[ ! "$continue_choice" =~ ^[Yy]$ ]]; then
                print_info "Operation cancelled."
                exit 0
            fi
        fi
    fi
    
    # Return branch info without color codes
    printf "%s:%s" "$current_branch" "$default_branch"
}

# Create a pull request
create_pull_request() {
    local current_branch="$1"
    local default_branch="$2"
    
    if [[ "$current_branch" == "$default_branch" ]]; then
        print_error "Cannot create PR from default branch to itself."
        exit 1
    fi
    
    # Check if branch exists on remote and push accordingly
    if ! git ls-remote --exit-code --heads origin "$current_branch" > /dev/null 2>&1; then
        print_info "Pushing current branch to remote for the first time..."
        git push -u origin "$current_branch" >&2
    else
        # Check if local branch is ahead of remote
        local local_commit=$(git rev-parse HEAD)
        local remote_commit=$(git rev-parse "origin/$current_branch" 2>/dev/null || echo "")
        
        if [[ "$local_commit" != "$remote_commit" ]]; then
            print_info "Pushing latest changes to remote..."
            git push >&2
        else
            print_info "Branch is already up to date with remote."
        fi
    fi
    
    # Get PR details
    echo >&2
    read -p "Enter PR title [Merge $current_branch to $default_branch]: " pr_title
    if [[ -z "$pr_title" ]]; then
        pr_title="Merge $current_branch to $default_branch"
    fi
    
    echo >&2
    echo "Enter PR description (press Enter twice to finish):" >&2
    pr_description=""
    while IFS= read -r line; do
        if [[ -z "$line" && -n "$pr_description" ]]; then
            break
        fi
        if [[ -n "$pr_description" ]]; then
            pr_description+="\n"
        fi
        pr_description+="$line"
    done
    
    if [[ -z "$pr_description" ]]; then
        pr_description="Merging changes from $current_branch to $default_branch"
    fi
    
    # Create PR
    print_info "Creating pull request..."
    local pr_url
    if pr_url=$(gh pr create --title "$pr_title" --body "$pr_description" --base "$default_branch" --head "$current_branch" 2>&1); then
        print_success "Pull request created successfully!"
        print_info "PR URL: $pr_url"
        return 0
    else
        print_error "Failed to create pull request."
        return 1
    fi
}

# List existing pull requests
list_pull_requests() {
    print_info "Existing pull requests:"
    gh pr list --state open
}

# Merge a pull request
merge_pull_request() {
    local default_branch="$1"
    
    # List open PRs
    echo >&2
    list_pull_requests
    echo >&2
    
    read -p "Enter PR number to merge: " pr_number
    if [[ ! "$pr_number" =~ ^[0-9]+$ ]]; then
        print_error "Invalid PR number."
        exit 1
    fi
    
    # Show PR details
    print_info "PR Details:"
    gh pr view "$pr_number"
    
    echo >&2
    read -p "Confirm merge of PR #$pr_number? (y/N): " confirm_merge
    if [[ ! "$confirm_merge" =~ ^[Yy]$ ]]; then
        print_info "Merge cancelled."
        exit 0
    fi
    
    # Choose merge strategy
    echo >&2
    echo "Merge strategies:" >&2
    echo "1) Merge commit (default)" >&2
    echo "2) Squash and merge" >&2
    echo "3) Rebase and merge" >&2
    read -p "Choose merge strategy [1-3, default: 1]: " merge_strategy
    
    local merge_flag=""
    case "$merge_strategy" in
        "2")
            merge_flag="--squash"
            ;;
        "3")
            merge_flag="--rebase"
            ;;
        *)
            merge_flag="--merge"
            ;;
    esac
    
    # Merge PR
    print_info "Merging pull request..."
    if gh pr merge "$pr_number" $merge_flag --delete-branch >&2; then
        print_success "Pull request merged successfully!"
        
        # Update local default branch
        print_info "Updating local $default_branch branch..."
        git checkout "$default_branch" >&2
        git pull origin "$default_branch" >&2
        
        print_success "Local $default_branch branch updated."
    else
        print_error "Failed to merge pull request."
        exit 1
    fi
}

# Complete workflow: create PR and merge
complete_workflow() {
    local current_branch="$1"
    local default_branch="$2"
    
    print_header "Complete PR Workflow: Create → Review → Merge"
    
    # Create PR
    if ! create_pull_request "$current_branch" "$default_branch"; then
        print_error "Failed to create PR. Aborting workflow."
        exit 1
    fi
    
    echo >&2
    read -p "Open PR in browser for review? (Y/n): " open_browser
    if [[ ! "$open_browser" =~ ^[Nn]$ ]]; then
        gh pr view --web
    fi
    
    echo >&2
    print_info "PR created. You can now:"
    print_info "1. Review the PR in your browser"
    print_info "2. Wait for CI/CD checks to pass"
    print_info "3. Get approval from reviewers"
    print_info "4. Come back to merge when ready"
    
    echo >&2
    read -p "Do you want to merge now? (y/N): " merge_now
    if [[ "$merge_now" =~ ^[Yy]$ ]]; then
        # Get the PR number from the most recent PR
        local pr_number=$(gh pr list --author "@me" --state open --limit 1 --json number --jq '.[0].number')
        if [[ -n "$pr_number" ]]; then
            print_info "Merging PR #$pr_number..."
            merge_pull_request "$default_branch"
        else
            print_error "Could not find PR to merge."
        fi
    fi
}

# Show help
show_help() {
    echo "Usage: $0 [COMMAND]" >&2
    echo >&2
    echo "Pull Request Manager for SCDF-RAG" >&2
    echo >&2
    echo "Commands:" >&2
    echo "  create     Create a new pull request" >&2
    echo "  list       List existing pull requests" >&2
    echo "  merge      Merge an existing pull request" >&2
    echo "  workflow   Complete workflow (create + optional merge)" >&2
    echo "  help       Show this help message" >&2
    echo >&2
    echo "If no command is provided, the interactive menu will be shown." >&2
}

# Interactive menu
show_menu() {
    local current_branch="$1"
    local default_branch="$2"
    
    while true; do
        echo >&2
        print_header "SCDF-RAG Pull Request Manager"
        echo >&2
        echo "Current branch: $current_branch" >&2
        echo "Default branch: $default_branch" >&2
        echo >&2
        echo "Options:" >&2
        echo "1) Create pull request" >&2
        echo "2) List existing pull requests" >&2
        echo "3) Merge pull request" >&2
        echo "4) Complete workflow (create + optional merge)" >&2
        echo "5) Switch to default branch and pull latest" >&2
        echo "q) Quit" >&2
        echo >&2
        read -p "Choose an option [1-5, q]: " choice
        
        case "$choice" in
            "1")
                create_pull_request "$current_branch" "$default_branch"
                ;;
            "2")
                list_pull_requests
                ;;
            "3")
                merge_pull_request "$default_branch"
                ;;
            "4")
                complete_workflow "$current_branch" "$default_branch"
                ;;
            "5")
                print_info "Switching to $default_branch and pulling latest..."
                git checkout "$default_branch" >&2
                git pull origin "$default_branch" >&2
                print_success "Updated to latest $default_branch"
                current_branch="$default_branch"
                ;;
            "q"|"Q")
                print_info "Goodbye!"
                exit 0
                ;;
            *)
                print_error "Invalid option. Please try again."
                ;;
        esac
    done
}

# Main script
main() {
    print_header "=== SCDF-RAG Pull Request Manager ==="
    
    # Check requirements
    check_requirements
    
    # Check git status and get branch info
    local branch_info=$(check_git_status)
    local current_branch=$(echo "$branch_info" | cut -d':' -f1)
    local default_branch=$(echo "$branch_info" | cut -d':' -f2)
    
    # Handle command line arguments
    case "${1:-}" in
        "create")
            create_pull_request "$current_branch" "$default_branch"
            ;;
        "list")
            list_pull_requests
            ;;
        "merge")
            merge_pull_request "$default_branch"
            ;;
        "workflow")
            complete_workflow "$current_branch" "$default_branch"
            ;;
        "help"|"--help"|"-h")
            show_help
            ;;
        "")
            show_menu "$current_branch" "$default_branch"
            ;;
        *)
            print_error "Unknown command: $1"
            show_help
            exit 1
            ;;
    esac
}

# Run main function
main "$@" 