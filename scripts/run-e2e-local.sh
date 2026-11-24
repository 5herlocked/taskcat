#!/bin/bash
# scripts/run-e2e-local.sh
#
# Run the full e2e test suite locally using your AWS credentials.
# This script supersedes the Docker-based approach in do_e2e_tests.sh,
# providing a simpler direct-execution model that does not require Docker
# or Docker-in-Docker.
#
# Usage:
#   ./scripts/run-e2e-local.sh [--profile PROFILE]
#
# Options:
#   --profile PROFILE   AWS CLI profile to use (default: Admin)
#
# Prerequisites:
#   - AWS CLI v2 installed and configured
#   - Python 3.10 or later with pip
#   - Valid AWS credentials (verified via sts get-caller-identity)
#
set -euo pipefail

###############################################################################
# Configuration
###############################################################################
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
AWS_PROFILE="${AWS_PROFILE:-Admin}"
ROLE_NAME="taskcat-e2e-test"
ROLE_SESSION_NAME="local-e2e-test"
REGION="us-east-1"
COVERAGE_SOURCE="../../taskcat/"
COVERAGE_OMIT="../../taskcat/_stacker.py"

###############################################################################
# Argument parsing
###############################################################################
while [[ $# -gt 0 ]]; do
    case "$1" in
        --profile)
            AWS_PROFILE="$2"
            shift 2
            ;;
        --profile=*)
            AWS_PROFILE="${1#*=}"
            shift
            ;;
        -h|--help)
            echo "Usage: $0 [--profile PROFILE]"
            echo ""
            echo "Run taskcat e2e tests locally without Docker."
            echo ""
            echo "Options:"
            echo "  --profile PROFILE   AWS CLI profile (default: Admin)"
            echo "  -h, --help          Show this help message"
            echo ""
            echo "NOTE: This script supersedes do_e2e_tests.sh (Docker-based approach)."
            exit 0
            ;;
        *)
            echo "ERROR: Unknown argument: $1" >&2
            echo "Run '$0 --help' for usage." >&2
            exit 1
            ;;
    esac
done

###############################################################################
# Helpers
###############################################################################
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { echo -e "${CYAN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
pass()  { echo -e "${GREEN}[PASS]${NC} $*"; }
fail()  { echo -e "${RED}[FAIL]${NC} $*"; }

cleanup() {
    info "Cleaning up..."
    # Remove coverage data from e2e/tests if present
    if [[ -f "${PROJECT_ROOT}/e2e/tests/.coverage" ]]; then
        rm -f "${PROJECT_ROOT}/e2e/tests/.coverage"
    fi
    # Unset temporary credentials from this shell (does not affect parent)
    unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN 2>/dev/null || true
    info "Cleanup complete."
}

trap cleanup EXIT

###############################################################################
# Step 1: Verify AWS credentials
###############################################################################
info "Verifying AWS credentials (profile: ${AWS_PROFILE})..."

CALLER_IDENTITY=$(aws sts get-caller-identity \
    --profile "${AWS_PROFILE}" \
    --region "${REGION}" \
    --output json 2>&1) || {
    fail "AWS credentials are invalid or expired for profile '${AWS_PROFILE}'."
    echo "${CALLER_IDENTITY}" >&2
    echo ""
    echo "Please ensure your AWS credentials are configured and valid."
    echo "You can specify a different profile with: $0 --profile <profile-name>"
    exit 1
}

CALLER_ARN=$(echo "${CALLER_IDENTITY}" | python3 -c "import sys,json; print(json.load(sys.stdin)['Arn'])")
info "Authenticated as: ${CALLER_ARN}"

###############################################################################
# Step 2: Create or locate the taskcat-e2e-test IAM role
###############################################################################
info "Checking for IAM role '${ROLE_NAME}'..."

ROLE_ARN=$(aws iam list-roles \
    --profile "${AWS_PROFILE}" \
    --region "${REGION}" \
    --query "Roles[?RoleName == \`${ROLE_NAME}\`].Arn" \
    --output text 2>/dev/null || echo "")

if [[ -z "${ROLE_ARN}" || "${ROLE_ARN}" == "None" ]]; then
    info "Role '${ROLE_NAME}' not found. Creating with AdministratorAccess..."

    POLICY_DOC=$(cat <<EOF
{
    "Version": "2012-10-17",
    "Statement": [
        {
            "Sid": "AllowAssumeRole",
            "Effect": "Allow",
            "Principal": {
                "AWS": "${CALLER_ARN}"
            },
            "Action": "sts:AssumeRole"
        }
    ]
}
EOF
)

    ROLE_ARN=$(aws iam create-role \
        --profile "${AWS_PROFILE}" \
        --region "${REGION}" \
        --role-name "${ROLE_NAME}" \
        --description "taskcat e2e test role" \
        --assume-role-policy-document "${POLICY_DOC}" \
        --query 'Role.Arn' \
        --output text)

    aws iam attach-role-policy \
        --profile "${AWS_PROFILE}" \
        --region "${REGION}" \
        --role-name "${ROLE_NAME}" \
        --policy-arn "arn:aws:iam::aws:policy/AdministratorAccess"

    info "Role created: ${ROLE_ARN}"
    info "Waiting 10 seconds for role propagation..."
    sleep 10
else
    info "Found existing role: ${ROLE_ARN}"
fi

###############################################################################
# Step 3: Assume the role and export temporary credentials
###############################################################################
info "Assuming role '${ROLE_NAME}'..."

CREDS_JSON=$(aws sts assume-role \
    --profile "${AWS_PROFILE}" \
    --region "${REGION}" \
    --role-arn "${ROLE_ARN}" \
    --role-session-name "${ROLE_SESSION_NAME}" \
    --output json)

export AWS_ACCESS_KEY_ID=$(echo "${CREDS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['AccessKeyId'])")
export AWS_SECRET_ACCESS_KEY=$(echo "${CREDS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SecretAccessKey'])")
export AWS_SESSION_TOKEN=$(echo "${CREDS_JSON}" | python3 -c "import sys,json; print(json.load(sys.stdin)['Credentials']['SessionToken'])")

# Unset profile so the exported creds take precedence
unset AWS_PROFILE 2>/dev/null || true

info "Temporary credentials exported. Verifying assumed role..."
ASSUMED_ARN=$(aws sts get-caller-identity --region "${REGION}" --query 'Arn' --output text)
info "Now operating as: ${ASSUMED_ARN}"

###############################################################################
# Step 4: Install the package in development mode if needed
###############################################################################
info "Checking taskcat installation..."
cd "${PROJECT_ROOT}"

# NOTE: checking with `python3 -c "import taskcat"` from the repo root is a
# false positive — cwd is on sys.path, so the source tree shadows the check.
# `pip show` only reports an actual (editable or regular) installation.
if ! pip show taskcat >/dev/null 2>&1; then
    info "Installing taskcat in development mode..."
    pip install -e . --quiet
    pip install -r dev-requirements.txt --quiet
    info "Installation complete."
else
    info "taskcat is already installed."
fi

# Ensure coverage is available
if ! python3 -m coverage --version >/dev/null 2>&1; then
    info "Installing coverage..."
    pip install coverage --quiet
fi

###############################################################################
# Step 5: Run the e2e test scripts
###############################################################################
info "Running e2e tests from ${PROJECT_ROOT}/e2e/tests/..."
echo ""

cd "${PROJECT_ROOT}/e2e/tests/"

# Clean previous coverage data
rm -f .coverage

COV_CMD="coverage run -a --source ${COVERAGE_SOURCE} --omit ${COVERAGE_OMIT}"
BIN="../../bin/taskcat"

FAILED=0
PASSED=0
TOTAL=0
FAILED_TESTS=""

for test_script in *.sh; do
    if [[ ! -x "${test_script}" ]]; then
        chmod +x "${test_script}"
    fi

    TOTAL=$((TOTAL + 1))
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    info "Running: ${test_script}"

    if BIN="${BIN}" COV_CMD="${COV_CMD}" ./"${test_script}"; then
        pass "${test_script}"
        PASSED=$((PASSED + 1))
    else
        fail "${test_script}"
        FAILED=$((FAILED + 1))
        FAILED_TESTS="${FAILED_TESTS}  - ${test_script}\n"
    fi
done

###############################################################################
# Step 6: Report results and coverage
###############################################################################
echo ""
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${CYAN}                    E2E TEST RESULTS${NC}"
echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo ""
echo "  Total:  ${TOTAL}"
echo -e "  Passed: ${GREEN}${PASSED}${NC}"
echo -e "  Failed: ${RED}${FAILED}${NC}"
echo ""

if [[ ${FAILED} -gt 0 ]]; then
    echo -e "${RED}Failed tests:${NC}"
    echo -e "${FAILED_TESTS}"
fi

# Generate coverage report
if [[ -f .coverage ]]; then
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${CYAN}                   COVERAGE REPORT${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    coverage report
    echo ""

    # Also save to project root for reference
    coverage report > "${PROJECT_ROOT}/cov_report" 2>/dev/null || true
    info "Coverage report saved to: ${PROJECT_ROOT}/cov_report"
fi

echo ""
if [[ ${FAILED} -eq 0 ]]; then
    pass "ALL E2E TESTS PASSED"
    exit 0
else
    fail "SOME E2E TESTS FAILED"
    exit 1
fi
