# #!/usr/bin/env bash
# set -euo pipefail

# #====================================================================
# # Required config (from library group)
# #====================================================================
# : "${GHE_API_URL:?Missing GHE_API_URL (e.g. https://api.github.com)}"
# : "${GHE_PAT:?Missing GHE_PAT}"

# GHE_ORG="${GHE_ORG:-}"
# STALE_THRESHOLD="${STALE_THRESHOLD:-90}"
# DRY_RUN="${DRY_RUN:-true}"
# REPO_FILE="repos.txt"

# CUTOFF_EPOCH=$(date -d "$STALE_THRESHOLD days ago" +%s)
# PROTECTED_BRANCH_REGEX='^(main|master|develop|reelase/)'
# AUTH_HEADER="Authorization: token $GHE_PAT"

# #====================================================================
# # Header
# #====================================================================
# echo "================================================"
# echo "Github Stale Branch Cleanup"
# echo "API Base  : $GHE_API_URL"
# echo "Default Org : ${GHE_ORG:-<not used>}"
# echo "Stale days : $STALE_THRESHOLD"
# echo "Dry-Run : $DRY_RUN"
# echo "Repo file" : $REPO_FILE"
# echo "================================================"
# echo ""


# #====================================================================
# # Validate repos list
# #====================================================================

#!/usr/bin/env bash
set -euo pipefail

#====================================================================
# Required config (from library group)
#====================================================================
: "${GHE_API_URL:?Missing GHE_API_URL (e.g. https://ghe.example.com/api/v3)}"
: "${GHE_PAT:?Missing GHE_PAT}"

GHE_ORG="${GHE_ORG:-}"
STALE_THRESHOLD="${STALE_THRESHOLD:-90}"   # days
DRY_RUN="${DRY_RUN:-true}"
REPO_FILE="repos.txt"

CUTOFF_EPOCH=$(date -d "$STALE_THRESHOLD days ago" +%s)
PROTECTED_BRANCH_REGEX='^(main|master|develop|release/)'
AUTH_HEADER="Authorization: token $GHE_PAT"

#====================================================================
# Header
#====================================================================
echo "================================================"
echo "GitHub Stale Branch Cleanup"
echo "API Base       : $GHE_API_URL"
echo "Default Org    : ${GHE_ORG:-<not used>}"
echo "Stale days     : $STALE_THRESHOLD"
echo "Dry-Run        : $DRY_RUN"
echo "Repo file      : $REPO_FILE"
echo "================================================"
echo ""

#====================================================================
# 1. Validate repos list
#====================================================================
if [[ ! -f "$REPO_FILE" ]]; then
  echo "ERROR: $REPO_FILE not found in project root."
  exit 1
fi

mapfile -t REPOS < "$REPO_FILE"

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "ERROR: $REPO_FILE is empty — no repositories to process."
  exit 1
fi

echo "Repositories to process:"
printf ' - %s\n' "${REPOS[@]}"
echo ""

#====================================================================
# Helper: Fetch branches for a repo
#====================================================================
fetch_branches() {
  local repo="$1"

  gh api \
    -H "$AUTH_HEADER" \
    "$GHE_API_URL/repos/$repo/branches?per_page=200" \
    --jq '.[] | {name: .name, sha: .commit.sha}'
}

#====================================================================
# Helper: Get last commit timestamp
#====================================================================
branch_last_commit_epoch() {
  local repo="$1"
  local sha="$2"

  local date
  date=$(gh api \
    -H "$AUTH_HEADER" \
    "$GHE_API_URL/repos/$repo/commits/$sha" \
    --jq '.commit.committer.date')

  date -d "$date" +%s
}

#====================================================================
# Helper: Delete branch
#====================================================================
delete_branch() {
  local repo="$1"
  local branch="$2"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY RUN] Would delete: $repo → $branch"
    return
  fi

  echo "Deleting: $repo → $branch"

  gh api \
    -X DELETE \
    -H "$AUTH_HEADER" \
    "$GHE_API_URL/repos/$repo/git/refs/heads/$branch" \
    >/dev/null 2>&1 || echo "Failed to delete $branch"
}

#====================================================================
# 2. Process repositories
#====================================================================
for repo in "${REPOS[@]}"; do
  echo "------------------------------------------------"
  echo "Processing repository: $repo"
  echo "------------------------------------------------"

  branches_json=$(fetch_branches "$repo")

  if [[ -z "$branches_json" ]]; then
    echo "No branches found or repo not accessible."
    continue
  fi

  stale_branches=()

  #================================================================
  # 3. Collect stale branches for this repo
  #================================================================
  while read -r name sha; do
    branch="$name"

    # Skip protected branches
    if [[ "$branch" =~ $PROTECTED_BRANCH_REGEX ]]; then
      echo "Skipping protected branch: $branch"
      continue
    fi

    # Get last commit timestamp
    last_commit_epoch=$(branch_last_commit_epoch "$repo" "$sha")

    if (( last_commit_epoch < CUTOFF_EPOCH )); then
      echo "STALE: $branch (last commit: $(date -d "@$last_commit_epoch"))"
      stale_branches+=("$branch")
    else
      echo "ACTIVE: $branch"
    fi

  done < <(echo "$branches_json" | jq -r '.name + " " + .sha')

  #================================================================
  # 4. Print per-repo summary and act
  #================================================================
  echo ""
  echo "Summary for $repo:"
  if [[ ${#stale_branches[@]} -eq 0 ]]; then
    echo "No stale branches found."
    echo ""
    continue
  fi

  printf ' - %s\n' "${stale_branches[@]}"
  echo ""

  for br in "${stale_branches[@]}"; do
    delete_branch "$repo" "$br"
  done

  echo ""
done

echo "================================================"
echo "Stale branch cleanup completed."
echo "================================================"
