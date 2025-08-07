#!/bin/bash
# test-auth.sh - Independent authentication test for SCDF OAuth2 flow
# This script tests authentication separately from the main rag-stream pipeline

set -eu

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Logging functions
log_info() { echo -e "${BLUE}[INFO]${NC} $1" >&2; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1" >&2; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1" >&2; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

# Configuration (from your config.yaml)
SCDF_CF_URL="https://dataflow-c856b29a-1c7e-4fd5-ab3b-0633b90869cc.apps.tas-ndc.kuhn-labs.com"
SCDF_TOKEN_URL="https://login.sys.tas-ndc.kuhn-labs.com/oauth/token"

echo "SCDF OAuth2 Authentication Test"
echo "================================"
echo "SCDF URL: $SCDF_CF_URL"
echo "Token URL: $SCDF_TOKEN_URL"
echo ""

# Test 1: Basic connectivity to SCDF endpoint (without auth)
log_info "Test 1: Testing basic connectivity to SCDF server..."
if curl -s --max-time 10 --connect-timeout 5 "$SCDF_CF_URL/about" -o /dev/null -w "%{http_code}" | grep -q "401\|403"; then
    log_success "SCDF server is reachable (received auth challenge as expected)"
else
    http_code=$(curl -s --max-time 10 --connect-timeout 5 "$SCDF_CF_URL/about" -o /dev/null -w "%{http_code}" || echo "000")
    if [ "$http_code" = "200" ]; then
        log_warn "SCDF server responded with 200 (no auth required?)"
    else
        log_error "SCDF server connectivity issue (HTTP $http_code)"
        exit 1
    fi
fi

# Test 2: Basic connectivity to OAuth token endpoint
log_info "Test 2: Testing connectivity to OAuth token endpoint..."
if curl -s --max-time 10 --connect-timeout 5 "$SCDF_TOKEN_URL" -o /dev/null -w "%{http_code}" | grep -qE "400|405|401"; then
    log_success "OAuth token endpoint is reachable"
else
    http_code=$(curl -s --max-time 10 --connect-timeout 5 "$SCDF_TOKEN_URL" -o /dev/null -w "%{http_code}" || echo "000")
    log_warn "OAuth token endpoint returned HTTP $http_code (may still be functional)"
fi

# Test 3: Interactive credential collection and token request
echo ""
log_info "Test 3: Testing OAuth2 token acquisition..."

# Collect credentials
while [ -z "${SCDF_CLIENT_ID:-}" ]; do
    read -p "Enter SCDF Client ID: " SCDF_CLIENT_ID
    if [ -z "$SCDF_CLIENT_ID" ]; then
        log_error "Client ID cannot be empty"
    fi
done

while [ -z "${SCDF_CLIENT_SECRET:-}" ]; do
    read -rsp "Enter SCDF Client Secret: " SCDF_CLIENT_SECRET
    echo
    if [ -z "$SCDF_CLIENT_SECRET" ]; then
        log_error "Client Secret cannot be empty"
    fi
done

# Test token request
log_info "Requesting OAuth2 token..."
TOKEN_RESPONSE=$(curl -s --max-time 30 --connect-timeout 10 \
    -X POST \
    -H "Content-Type: application/x-www-form-urlencoded" \
    -d "grant_type=client_credentials" \
    -d "client_id=$SCDF_CLIENT_ID" \
    -d "client_secret=$SCDF_CLIENT_SECRET" \
    "$SCDF_TOKEN_URL" 2>/dev/null || echo '{"error": "request_failed"}')

echo "Raw token response:"
echo "$TOKEN_RESPONSE" | jq . 2>/dev/null || echo "$TOKEN_RESPONSE"
echo ""

# Check if we got a valid token
if ACCESS_TOKEN=$(echo "$TOKEN_RESPONSE" | jq -r '.access_token' 2>/dev/null) && [ "$ACCESS_TOKEN" != "null" ] && [ -n "$ACCESS_TOKEN" ]; then
    log_success "Successfully obtained access token"
    log_info "Token starts with: ${ACCESS_TOKEN:0:20}..."
    
    # Test 4: Use token to access SCDF API
    log_info "Test 4: Testing authenticated API access..."
    
    API_RESPONSE=$(curl -s --max-time 30 --connect-timeout 10 \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Accept: application/json" \
        "$SCDF_CF_URL/about" 2>/dev/null || echo '{"error": "api_request_failed"}')
    
    HTTP_CODE=$(curl -s --max-time 30 --connect-timeout 10 \
        -H "Authorization: Bearer $ACCESS_TOKEN" \
        -H "Accept: application/json" \
        -w "%{http_code}" \
        -o /dev/null \
        "$SCDF_CF_URL/about" 2>/dev/null || echo "000")
    
    echo "API Response (HTTP $HTTP_CODE):"
    echo "$API_RESPONSE" | jq . 2>/dev/null || echo "$API_RESPONSE"
    echo ""
    
    if [ "$HTTP_CODE" = "200" ]; then
        log_success "Authentication successful! Token is valid and API is accessible."
        
        # Test 5: Additional API endpoints
        log_info "Test 5: Testing additional API endpoints..."
        
        # Test apps endpoint
        APPS_HTTP_CODE=$(curl -s --max-time 30 --connect-timeout 10 \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "Accept: application/json" \
            -w "%{http_code}" \
            -o /dev/null \
            "$SCDF_CF_URL/apps" 2>/dev/null || echo "000")
        
        if [ "$APPS_HTTP_CODE" = "200" ]; then
            log_success "Apps endpoint accessible (HTTP $APPS_HTTP_CODE)"
        else
            log_warn "Apps endpoint returned HTTP $APPS_HTTP_CODE"
        fi
        
        # Test streams endpoint
        STREAMS_HTTP_CODE=$(curl -s --max-time 30 --connect-timeout 10 \
            -H "Authorization: Bearer $ACCESS_TOKEN" \
            -H "Accept: application/json" \
            -w "%{http_code}" \
            -o /dev/null \
            "$SCDF_CF_URL/streams/definitions" 2>/dev/null || echo "000")
        
        if [ "$STREAMS_HTTP_CODE" = "200" ]; then
            log_success "Streams endpoint accessible (HTTP $STREAMS_HTTP_CODE)"
        else
            log_warn "Streams endpoint returned HTTP $STREAMS_HTTP_CODE"
        fi
        
    else
        log_error "API access failed (HTTP $HTTP_CODE). Token may be invalid or expired."
        exit 1
    fi
    
else
    log_error "Failed to obtain access token"
    
    # Parse error details if available
    if ERROR_DESC=$(echo "$TOKEN_RESPONSE" | jq -r '.error_description' 2>/dev/null) && [ "$ERROR_DESC" != "null" ]; then
        log_error "Error description: $ERROR_DESC"
    fi
    
    if ERROR_CODE=$(echo "$TOKEN_RESPONSE" | jq -r '.error' 2>/dev/null) && [ "$ERROR_CODE" != "null" ]; then
        log_error "Error code: $ERROR_CODE"
    fi
    
    exit 1
fi

echo ""
log_success "All authentication tests completed successfully!"
log_info "Your credentials are working correctly with the SCDF server."