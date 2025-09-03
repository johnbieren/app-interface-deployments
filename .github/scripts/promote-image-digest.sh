#!/usr/bin/env bash
set -euo pipefail

DRY_RUN="false"
ORG="hacbs-release"
REPO="app-interface-deployments"
TMP_DIR="$(mktemp -d)"
REPO_DIR="$TMP_DIR/repo"
NEW_DIGEST=""
OLD_DIGEST=""
PR_NUMBER=""

show_help() {
	cat <<EOF
A script to promote an image digest from source to target branch.

Usage: $0 --source SOURCE_BRANCH --target TARGET_BRANCH --feature FEATURE_BRANCH --image IMAGE [--dry-run DRY_RUN]

Options:
  -s, --source     Source branch
  -t, --target     Target branch
  -f, --feature    Feature branch name
  -i, --image      Image name (e.g. quay.io/org/image)
  -d, --dry-run    'true' or 'false' (default: false)
  -h, --help       Show this help message

Required environment variables:
  GITHUB_TOKEN
  GIT_AUTHOR_NAME
  GIT_AUTHOR_EMAIL

Example:
  $0 --source main --target staging --feature bump-image --image quay.io/org/image
EOF
}

parse_args() {
	OPTIONS=$(getopt --long "source:,target:,feature:,image:,dry-run:,help" -o "s:,t:,f:,i:,d:,h" -- "$@")
	eval set -- "$OPTIONS"

	while true; do
		case "$1" in
		-s | --source)
			SOURCE_BRANCH="$2"
			shift 2
			;;
		-t | --target)
			TARGET_BRANCH="$2"
			shift 2
			;;
		-f | --feature)
			FEATURE_BRANCH="$2"
			shift 2
			;;
		-i | --image)
			IMG="$2"
			shift 2
			;;
		-d | --dry-run)
			DRY_RUN="$2"
			shift 2
			;;
		-h | --help)
			show_help
			exit 0
			;;
		--)
			shift
			break
			;;
		*)
			echo "Error: Unexpected option: $1"
			show_help
			exit 1
			;;
		esac
	done
}

validate_env() {
	required_vars=(
		"GITHUB_TOKEN"
		"GIT_AUTHOR_NAME"
		"GIT_AUTHOR_EMAIL"
	)
	missing_vars=()

	for var in "${required_vars[@]}"; do
		if [[ -z $var ]]; then
			missing_vars+=("$var")
		fi
	done

	if [[ ${#missing_vars[@]} -gt 0 ]]; then
		echo "Error: the following environment variables are not set: ${missing_vars[*]}"
		exit 1
	fi
}

find_image_digest_refs() {
	branch="$1"
	refs=()

	git checkout "$branch" || {
		echo "Error: failed to checkout branch: $branch"
		exit 1
	}
	echo "Searching branch: $branch for $IMG@sha256:..."

	while IFS= read -r match; do
		refs+=("$match")
	done < <(git grep -I -h -E -o "$IMG@sha256:[a-f0-9]{64}" -- "*.yml" "*.yaml" 2>/dev/null || true)

	readarray -t refs < <(printf '%s\n' "${refs[@]}" | sort -u)

	if [[ ${#refs[@]} -eq 0 ]]; then
		echo "Error: no digest references found for $IMG on $branch"
		exit 1
	fi

	if [[ ${#refs[@]} -ne 1 ]]; then
		echo "Error: multiple digest references found on $branch:"
		printf '%s\n' "${refs[@]}"
		exit 1
	fi

	if [[ "$branch" == "$SOURCE_BRANCH" ]]; then
		NEW_DIGEST="${refs[0]}"
	else
		OLD_DIGEST="${refs[0]}"
	fi

	echo "Found: ${refs[0]} on branch $branch"
}

checkout_branch() {
	git fetch origin || {
		echo "Error: failed to fetch from origin"
		exit 1
	}

	if git ls-remote --exit-code --heads origin "$FEATURE_BRANCH" 2>/dev/null; then
		echo "Feature branch exists, re-using the existing branch"
		git checkout -B "$FEATURE_BRANCH" "origin/$FEATURE_BRANCH" || {
			echo "Error: failed to checkout existing feature branch"
			exit 1
		}
	else
		echo "Branch $FEATURE_BRANCH does not exist, creating a new branch"
		git checkout -B "$FEATURE_BRANCH" "origin/$TARGET_BRANCH" || {
			echo "Error: failed to create feature branch"
			exit 1
		}
	fi

	# Reset to the feature branch to handle re-runs/updates
	git reset --hard "origin/$TARGET_BRANCH" || {
		echo "Error: failed to reset to target branch"
		exit 1
	}
}

replace_image_references() {
	git checkout "$FEATURE_BRANCH" || {
		echo "Error: failed to checkout feature branch"
		exit 1
	}

	echo "Updating image references in branch: $FEATURE_BRANCH"

	# Update the image digest one at a time to avoid command line length issues
	while IFS= read -r -d '' file; do
		if [[ -f "$file" ]]; then
			sed -i'' -e "s|$IMG@sha256:[a-f0-9]\{64\}|$NEW_DIGEST|g" "$file"
		fi
	done < <(find . -type f \( -name "*.yml" -o -name "*.yaml" \) -print0 2>/dev/null || true)
}

create_commit_and_push() {
	git config user.name "$GIT_AUTHOR_NAME" 
	git config user.email "$GIT_AUTHOR_EMAIL" 

	# Add files one at a time to avoid command line length issues
	while IFS= read -r -d '' file; do
		if [[ -f "$file" ]]; then
			git add "$file"
		fi
	done < <(find . -type f \( -name "*.yml" -o -name "*.yaml" \) -print0 2>/dev/null || true)

	git commit -m "$TITLE" \
		-m "$BODY" || {
		echo "Error: failed to create commit"
		exit 1
	}

	if [[ "$DRY_RUN" == "true" ]]; then
		echo "DRY RUN: skipping creating commit"
		return 0
	fi

	git push --force-with-lease origin "$FEATURE_BRANCH" || {
		echo "Error: failed to push feature branch"
		exit 1
	}
}

open_pr() {
	if [[ "$DRY_RUN" == "true" ]]; then
		echo "DRY RUN: skiping creating/updating PR"
		return 0
	fi

	PR_NUMBER="$(gh api "repos/$ORG/$REPO/pulls" \
		-X GET -f state=open -f head="$ORG:$FEATURE_BRANCH" -f base="$TARGET_BRANCH" \
		--jq '.[0].number' 2>/dev/null)"

	if [[ -n "$PR_NUMBER" ]]; then
		echo "Updating existing PR #$PR_NUMBER"
		gh api -X PATCH "repos/$ORG/$REPO/pulls/$PR_NUMBER" \
			-f title="$TITLE" \
			-f body="$BODY" >/dev/null || {
			echo "Error: failed to update existing PR"
			exit 1
		}
	else
		echo "No existing PR found, creating a new PR"
		PR_NUMBER=$(gh api -X POST "repos/$ORG/$REPO/pulls" \
			-f title="$TITLE" \
			-f body="$BODY" \
			-f base="$TARGET_BRANCH" \
			-f head="$FEATURE_BRANCH" \
			--jq '.number' 2>/dev/null) || {
			echo "Error: failed to create PR"
			exit 1
		}
	fi
}

trap 'rm -rf "$TMP_DIR"' EXIT
parse_args "$@"
validate_env

echo "Cloning https://github.com/$ORG/$REPO ..."
git clone "https://oauth2:$GITHUB_TOKEN@github.com/$ORG/$REPO.git" "$REPO_DIR" || {
	echo "Error: failed to clone repository"
	exit 1
}
cd "$REPO_DIR"
find_image_digest_refs "$SOURCE_BRANCH"
find_image_digest_refs "$TARGET_BRANCH"
if [[ "$OLD_DIGEST" == "$NEW_DIGEST" ]]; then
	echo "No update needed: target already matches source."
	exit 0
fi
checkout_branch
replace_image_references
TITLE="chore(deps): bump $IMG from ${OLD_DIGEST: -7} to ${NEW_DIGEST: -7}"
BODY="Promote $IMG digest on $TARGET_BRANCH
- source ($SOURCE_BRANCH): $NEW_DIGEST
- target ($TARGET_BRANCH): $OLD_DIGEST

Signed-off-by: $GIT_AUTHOR_NAME <$GIT_AUTHOR_EMAIL>"
create_commit_and_push
open_pr
echo "Updating of image digests complete...."
echo "All changes have been pushed to the feature branch: $FEATURE_BRANCH"
if [[ -n "$PR_NUMBER" ]]; then
	echo "PR URL: https://github.com/$ORG/$REPO/pull/$PR_NUMBER"
else
	echo "PR URL not available"
fi
