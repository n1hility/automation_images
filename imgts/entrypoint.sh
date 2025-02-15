#!/usr/bin/env bash

# This script is set as, and intended to run as the `imgts` container's
# entrypoint. It's purpose is to operate on a list of VM Images, adding
# metadata to each.  It must be executed alongside any repository's
# automation, which produces or uses GCP VMs and/or AWS EC2 instances.
#
# N/B: Timestamp updating is not required for AWS EC2 images as they
# have a 'LastLaunchedTime' attribute which is updated automatically.
# However, updating their permanent=true tag (when appropriate) and
# a reference to the build ID and repo name are all useful.

set -e

# shellcheck source=imgts/lib_entrypoint.sh
source /usr/local/bin/lib_entrypoint.sh

req_env_vars GCPJSON GCPNAME GCPPROJECT IMGNAMES BUILDID REPOREF

# Set this to 1 for testing
DRY_RUN="${DRY_RUN:-0}"

# These must be defined by the cirrus-ci job using the container
# shellcheck disable=SC2154
ARGS=(\
    "--update-labels=last-used=$(date +%s)"
    "--update-labels=build-id=$BUILDID"
    "--update-labels=repo-ref=$REPOREF"
    "--update-labels=project=$GCPPROJECT"
)

# Must be defined by the cirrus-ci job using the container
# shellcheck disable=SC2154
[[ -n "$IMGNAMES" ]] || \
    die 1 "No \$IMGNAMES were specified."

# Under some runtime conditions, not all images may be available
REQUIRE_ALL=${REQUIRE_ALL:-1}

# Don't allow one bad apple to ruin the whole batch
ERRIMGS=''

# It's possible for multiple simultaneous label updates to clash
CLASHMSG='Labels fingerprint either invalid or resource labels have changed'

# This function accepts a single argument: A Cirrus-CI build ID. The
# function looks up the build from Cirrus-CI to determine if it occured
# on a non-main branch.  If so the function returns zero.  Otherwise, it
# returns 1 for executions on behalf of the `main` branch, all PRs and
# all tags.  It will fully exit non-zero in case of any error.
is_release_branch_image(){
    local buildId api query result prefix branch tag
    buildId=$1
    api="https://api.cirrus-ci.com/graphql"
    query="{
        \"query\": \"query {
            build(id: $buildId) {
                branch
                tag
                pullRequest
            }
          }\"
        }"

    # This is mandatory, must never be unset, empty, or shorter than an actual ID.
    # Normally about 16-characters long.
    if ((${#buildId}<14)); then
        die 1 "Empty/invalid  BuildId '$buildId' passed to is_release_branch_image()"
    fi

    prefix=".data.build"
    result=$(curl --silent --location \
             --request POST --data @- --url "$api" <<<"$query") \
             || \
             die 2 "Error communicating with GraphQL API $api: $result"

    # Any problems with the GraphQL reply or mismatch of the JSON
    # structure (specified in query) is an error that operators should
    # be made aware of.
    if ! jq -e "$prefix" <<<"$result" &> /dev/null; then
        die 3 "Response from Cirrus API query '$query' has unexpected/invalid JSON structure:
$result"
    fi

    # Cirrus-CI always sets some branch value for all execution contexts
    if ! branch=$(jq -e --raw-output "${prefix}.branch" <<<"$result"); then
        die 4 "Empty/null branch value returned for build '$buildId':
$result"
    fi

    # This value will be empty/null for PRs and branch builds
    tag=$(jq --raw-output "${prefix}.tag" <<<"$result" | sed 's/null//g')

    # Cirrus-CI sets `branch=pull/#` for pull-requests, dependabot creates
    if [[ -z "$tag" && "$branch" =~ ^(v|release-)v?[0-9]+.* ]]; then
        msg "Found build $buildId for release branch '$branch'."
        return 0
    fi

    msg "Found build '$buildId' for non-release branch '$branch' and/or tag '$tag' (may be empty)."
    return 1
}

unset SET_PERM
if is_release_branch_image $BUILDID; then
    ARGS+=("--update-labels=permanent=true")
    SET_PERM=1
fi

if ((DRY_RUN)); then
    GCLOUD="echo $GCLOUD"
    AWS="echo $AWS"
    DRPREFIX="DRY-RUN: "
else
    # This outputs a status message to stderr
    gcloud_init
fi

# Must be defined by the cirrus-ci job using the container
# shellcheck disable=SC2154
for image in $IMGNAMES
do
    if ! OUTPUT=$($GCLOUD compute images update "$image" "${ARGS[@]}" 2>&1); then
        msg "$OUTPUT"
        if grep -iq "$CLASHMSG" <<<"$OUTPUT"; then
            # Updating the 'last-used' label is most important.
            # Assume clashing update did this for us.
            msg "Warning: Detected simultaneous label update, ignoring clash."
            continue
        fi
        msg "Detected update error for '$image'" > /dev/stderr
        ERRIMGS+=" $image"
    else
        # Display the URI to the updated image for reference
        if ((SET_PERM)); then
            msg "${DRPREFIX}IMAGE $image MARKED FOR PERMANENT RETENTION"
        else
            msg "${DRPREFIX}Updated image $image last-used timestamp"
        fi
    fi
done

# Not all repos use EC2 instances, only touch AWS if both
# EC2IMGNAMES and AWSINI are set.
if [[ -n "$EC2IMGNAMES" ]]; then
    msg "---"
    req_env_vars AWSINI BUILDID REPOREF

    if ! ((DRY_RUN)); then
        aws_init
        # aws_init() has no output because that would break in other contexts.
        msg "Activated AWS CLI for service acount."
    fi

    for image in $EC2IMGNAMES; do
        if ((DRY_RUN)); then
            # AWS=echo; no lookup will actually happen
            amiid="dry-run-$image"
        elif ! amiid=$(get_ec2_ami "$image"); then
            ERRIMGS+=" $image"
            continue
        fi

        # AWS deliberately left unquoted for intentional word-splitting.
        # N/B: For $DRY_RUN==1: AWS=echo
        # shellcheck disable=SC2206
        awscmd=(\
            $AWS ec2 create-tags
            --resources "$amiid" --tags
            "Key=build-id,Value=$BUILDID"
            "Key=repo-ref,Value=$REPOREF"
        )
        if ((SET_PERM)); then
            awscmd+=("Key=permanent,Value=true")
        fi

        if ! OUTPUT=$("${awscmd[@]}"); then
            ERRIMGS+=" $image"
        elif ((SET_PERM)); then
            msg "${DRPREFIX}IMAGE $image ($amiid) MARKED FOR PERMANENT RETENTION"
        else
            msg "${DRPREFIX}Updated image $image ($amiid) metadata."
        fi
    done
fi

if [[ -n "$ERRIMGS" ]]; then
    die_or_warn=die
    ((REQUIRE_ALL)) || die_or_warn=warn
    $die_or_warn 2 "Failed to update one or more image timestamps: $ERRIMGS"
fi
