#!/bin/bash

# ================= ARGUMENT PARSING =================
# Defaults
OUTPUT_FILE="output.csv"
ORG_ID=""

# Function to print usage
print_usage() {
    echo "----------------------------------------------------------------"
    echo "🚀 GCP Creator Audit Script"
    echo "----------------------------------------------------------------"
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Required:"
    echo "  -o, --org <ID>       The Google Cloud Organization ID (e.g., 123456789)"
    echo ""
    echo "Optional:"
    echo "  -f, --out <FILE>     Output CSV filename (Default: output.csv)"
    echo "  -h, --help           Show this help message"
    echo ""
    echo "Example:"
    echo "  $0 --org 1093290206792 --out my_audit.csv"
    echo "----------------------------------------------------------------"
}

# Parse named arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -o|--org)
            ORG_ID="$2"
            shift 2
            ;;
        -f|--out|--file)
            OUTPUT_FILE="$2"
            shift 2
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            echo "❌ Error: Unknown parameter passed: $1"
            print_usage
            exit 1
            ;;
    esac
done

# Validate Required Arguments
if [ -z "$ORG_ID" ]; then
    echo "❌ Error: Organization ID (--org) is required."
    print_usage
    exit 1
fi

# ================= CONFIGURATION & INIT =================

# Auto-detect Current User Email
echo "Detecting user identity..." >&2
USER_EMAIL=$(gcloud config get-value account 2>/dev/null)

if [ -z "$USER_EMAIL" ]; then
    echo "❌ Error: Could not determine active user. Please run 'gcloud auth login'." >&2
    exit 1
fi

echo "Authenticated as: $USER_EMAIL" >&2
echo "Target Org ID:    $ORG_ID" >&2
echo "Output File:      $OUTPUT_FILE" >&2

# Global Variables
FIX_TRIGGERED_TIME=0
FIX_SUCCESS=false
RETRY_IDS=()
RETRY_DATES=()

# Statistics
TOTAL_PROJECTS=0
COMPLETED_COUNT=0
START_TIME=$(date +%s)

# Helper: Format Seconds to MM:SS
format_time() {
    local T=$1
    local M=$((T / 60))
    local S=$((T % 60))
    printf "%02d:%02d" $M $S
}

# Helper: Draw Progress Bar
update_progress() {
    local NOW=$(date +%s)
    local ELAPSED=$((NOW - START_TIME))
    [ "$ELAPSED" -lt 1 ] && ELAPSED=1

    # Calculate ETR using awk
    if [ "$COMPLETED_COUNT" -gt 0 ]; then
        local REMAINING=$((TOTAL_PROJECTS - COMPLETED_COUNT))
        local EST_SECONDS=$(awk -v elapsed="$ELAPSED" -v done="$COMPLETED_COUNT" -v left="$REMAINING" 'BEGIN { printf "%.0f", (elapsed / done) * left }')
        local ETR_STR=$(format_time $EST_SECONDS)
    else
        local ETR_STR="--:--"
    fi

    local PERCENT=$(( 100 * COMPLETED_COUNT / TOTAL_PROJECTS ))
    local BAR_LEN=$(( PERCENT / 2 )) # Max 50 chars
    local BAR=$(printf "%0.s#" $(seq 1 $BAR_LEN))
    local SPACES=$(printf "%0.s " $(seq 1 $((50 - BAR_LEN))))

    echo -ne "\rProgress: [$BAR$SPACES] $PERCENT% ($COMPLETED_COUNT/$TOTAL_PROJECTS) | ETR: $ETR_STR " >&2
}

# Helper: Process a Single Project (Fetch -> Format -> Write)
process_project() {
    local P_ID=$1
    local C_TIME=$2
    local IS_RETRY=$3

    # 1. Fetch Creator from Logs
    local LOG_OUT
    LOG_OUT=$(gcloud logging read "protoPayload.methodName:CreateProject" \
        --project="$P_ID" \
        --limit=1 \
        --order=asc \
        --format="value(protoPayload.authenticationInfo.principalEmail)" 2>&1 < /dev/null)

    # 2. Check for Permission Denial
    if [[ "$LOG_OUT" == *"PERMISSION_DENIED"* ]]; then
        # IF this is the first pass (not a retry), we Queue it.
        if [ "$IS_RETRY" = false ]; then
            return 1 # Return 1 signals "Add to Queue"
        fi
        CREATOR_DISPLAY="Error: Still No Access (Fix Failed)"
    elif [[ "$LOG_OUT" == *"API has not been used"* ]]; then
        CREATOR_DISPLAY="Error: Logging Disabled"
    elif [[ -z "$LOG_OUT" ]]; then
        CREATOR_DISPLAY="Unknown: Logs Expired"
    else
        CREATOR_DISPLAY="$LOG_OUT"
    fi

    # 3. Fetch Owner (IAM)
    local OWNERS_RAW
    OWNERS_RAW=$(gcloud projects get-iam-policy "$P_ID" \
        --flatten="bindings[].members" \
        --filter="bindings.role:roles/owner" \
        --format="value(bindings.members)" 2>&1 < /dev/null)

    local OWNER_DISPLAY
    if [[ "$OWNERS_RAW" == *"PERMISSION_DENIED"* ]]; then
        OWNER_DISPLAY="Error: No IAM Access"
    elif [ -z "$OWNERS_RAW" ]; then
        OWNER_DISPLAY="No Owners Found"
    else
        OWNER_DISPLAY=$(echo "$OWNERS_RAW" | sed 's/user://g; s/serviceAccount://g' | tr '\n' ',' | sed 's/,$//')
    fi

    # 4. Write to CSV
    echo "\"$P_ID\",\"$C_TIME\",\"$CREATOR_DISPLAY\",\"$OWNER_DISPLAY\"" >> "$OUTPUT_FILE"

    # 5. Increment Global Counter
    ((COMPLETED_COUNT++))
    return 0
}

# ================= MAIN EXECUTION =================

echo "Initializing scan..." >&2
echo "Project ID,Created,Creator (from Logs),Current Owner(s) (from IAM)" > "$OUTPUT_FILE"

# 1. Load Projects
echo "Fetching project list..." >&2
mapfile -t PROJECT_LIST < <(gcloud projects list --format="value(projectId,createTime)" --sort-by=~createTime)
TOTAL_PROJECTS=${#PROJECT_LIST[@]}

if [ "$TOTAL_PROJECTS" -eq 0 ]; then
    echo "No projects found." >&2; exit 0
fi

echo "Found $TOTAL_PROJECTS projects. Starting scan..." >&2

# 2. First Pass (Main Loop)
for LINE in "${PROJECT_LIST[@]}"; do
    PROJECT_ID=$(echo "$LINE" | awk '{print $1}')
    CREATE_TIME=$(echo "$LINE" | awk '{print $2}')

    # Try processing
    process_project "$PROJECT_ID" "$CREATE_TIME" false
    STATUS=$?

    # If process_project returns 1, we hit PERMISSION_DENIED.
    if [ $STATUS -eq 1 ]; then

        # Trigger the FIX if not yet triggered
        if [ "$FIX_TRIGGERED_TIME" -eq 0 ]; then
            echo -ne "\n⚠️  Access Denied ($PROJECT_ID). Triggering global permission fix for $USER_EMAIL...\n" >&2

            # Run Fix asynchronously
            gcloud organizations add-iam-policy-binding $ORG_ID \
                --member="user:$USER_EMAIL" \
                --role="roles/logging.viewer" > /dev/null 2>&1 &

            FIX_TRIGGERED_TIME=$(date +%s)
            FIX_SUCCESS=true
        fi

        # Add to Retry Queue
        RETRY_IDS+=("$PROJECT_ID")
        RETRY_DATES+=("$CREATE_TIME")
    else
        update_progress
    fi
done

# 3. Process Retry Queue (If any)
QUEUE_SIZE=${#RETRY_IDS[@]}

if [ "$QUEUE_SIZE" -gt 0 ]; then
    echo -ne "\n\nMain list done. Processing $QUEUE_SIZE queued projects..." >&2

    # Check if we need to wait for the 60s propagation
    if [ "$FIX_TRIGGERED_TIME" -gt 0 ]; then
        NOW=$(date +%s)
        ELAPSED_SINCE_FIX=$((NOW - FIX_TRIGGERED_TIME))
        WAIT_TIME=$((60 - ELAPSED_SINCE_FIX))

        if [ "$WAIT_TIME" -gt 0 ]; then
            echo -ne "\n⏳ Waiting ${WAIT_TIME}s for permissions to propagate..." >&2
            for ((i=WAIT_TIME; i>0; i--)); do
                echo -ne "\r⏳ Waiting ${i}s for permissions to propagate...   " >&2
                sleep 1
            done
            echo "" >&2
        fi
    fi

    # Loop through Queue
    for ((i=0; i<QUEUE_SIZE; i++)); do
        P_ID="${RETRY_IDS[$i]}"
        C_TIME="${RETRY_DATES[$i]}"

        # Process with IS_RETRY = true
        process_project "$P_ID" "$C_TIME" true
        update_progress
    done
fi

echo -e "\n\n✅ Done! Output saved to: $OUTPUT_FILE" >&2