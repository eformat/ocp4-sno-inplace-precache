#!/bin/bash
#
# Utility for loading prestaged images during node installation
#

PROG=$(basename "$0")

DATADIR="/tmp/prestaging"
FS="/dev/disk/by-partlabel/data"

# Determine the image list from the script name, extract-ai.sh or extract-ocp.sh
IMG_GROUP=$(echo "${PROG}" | sed -r 's/.*extract-(.*)\.sh/\1/')
IMG_LIST_FILE="${DATADIR}/${IMG_GROUP}-images.txt"
MAPPING_FILE="${DATADIR}/mapping.txt"

# Set the parallelization job pool size to 80% of the cores
CPUS=$(nproc --all)
MAX_CPU_MULT=0.8
JOB_POOL_SIZE=$(jq -n "$CPUS*$MAX_CPU_MULT" | cut -d . -f1)

# Get initial starting point for info log at end of execution
START=${SECONDS}

#
# cleanup: Clean up resources on exit
#
function cleanup {
    cd /
    if mountpoint -q "${DATADIR}"; then
        umount "${DATADIR}"
    fi

    rm -rf "${DATADIR}"
}

trap cleanup EXIT

#
# mount_data:
#
function mount_data {
    if ! mkdir -p "${DATADIR}"; then
        echo "${PROG}: [FAIL] Failed to create ${DATADIR}"
        exit 1
    fi

    if [ ! -b "${FS}" ]; then
        echo "${PROG}: [FAIL] Not a block device: ${FS}"
        exit 1
    fi

    if ! mount "${FS}" "${DATADIR}"; then
        echo "${PROG}: [FAIL] Failed to mount ${FS}"
        exit 1
    fi

    for f in "${IMG_LIST_FILE}" "${MAPPING_FILE}"; do
        if [ ! -f "${f}" ]; then
            echo "${PROG}: [FAIL] Could not find ${f}"
            exit 1
        fi
    done

    if ! pushd "${DATADIR}"; then
        echo "${PROG}: [FAIL] Failed to chdir to ${DATADIR}"
        exit 1
    fi
}

#
# copy_image: Function that handles extracting an image tarball and copying it into container storage.
#             Launched in background for parallelization, or inline for retries
#
function copy_image {
    local current_copy=$1
    local total_copies=$2
    local uri=$3
    local tag=$4
    local rc=0
    local name=

    echo "${PROG}: [DEBUG] Extracting image ${uri}"
    name=$(basename "${uri/:/_}")
    if ! tar --use-compress-program=pigz -xf "${name}.tgz"; then
        echo "${PROG}: [ERROR] Could not extract the image ${name}.tgz"
        return 1
    fi

    if [[ "${IMG_GROUP}" = "ai" && -n "${tag}" && "${uri}" =~ "@sha" ]]; then
        # During the AI loading stage, if the image has a tag, load that into container storage as well
        echo "${PROG}: [INFO] Copying ${uri}, with tag ${tag} [${current_copy}/${total_copies}]"
        notag=${uri/@*}
        skopeo copy --retry-times 10 "dir://${PWD}/${name}" "containers-storage:${uri}" -q && \
            skopeo copy --retry-times 10 "dir://${PWD}/${name}" "containers-storage:${notag}:${tag}" -q
        rc=$?
    else
        echo "${PROG}: [INFO] Copying ${uri} [${current_copy}/${total_copies}]"
        skopeo copy --retry-times 10 "dir://${PWD}/${name}" "containers-storage:${uri}" -q
        rc=$?
    fi

    echo "${PROG}: [INFO] Removing folder for ${uri}"
    rm -rf "${name}"

    return ${rc}
}

#
# load_images: Launch jobs to prestage images from the appropriate list file
#
function load_images {
    local -A pids # Hash that include the images pulled along with their pids to be monitored by wait command
    local -a images
    mapfile -t images < <( sort -u "${IMG_LIST_FILE}" )

    local total_copies=${#images[@]}
    local current_copy=0
    local job_count=0

    echo "${PROG}: [INFO] Ready to extract ${total_copies} images using $JOB_POOL_SIZE simultaneous processes"

    for uri in "${images[@]}"; do
        current_copy=$((current_copy+1))

        # Check that we've got free space in the job pool
        while [ "${job_count}" -ge "${JOB_POOL_SIZE}" ]; do
            sleep 0.1
            job_count=$(jobs | wc -l)
        done

        echo "${PROG}: [DEBUG] Processing image ${uri}"
        if podman image exists "${uri}"; then
            echo "${PROG}: [INFO] Skipping existing image ${uri} [${current_copy}/${total_copies}]"
            continue
        fi

        tag=$(grep "^${uri}=" "${MAPPING_FILE}" | sed 's/.*://')
        copy_image "${current_copy}" "${total_copies}" "${uri}" "${tag}" &

        pids[${uri}]=$! # Keeping track of the PID and container image in case the pull fails
    done

    echo "${PROG}: [DEBUG] Waiting for job completion"
    for img in "${!pids[@]}"; do
        # Wait for each background task (PID). If any error, then copy the image in the failed array so it can be retried later
        if ! wait "${pids[$img]}"; then
            echo "${PROG}: [ERROR] Pull failed for container image: ${img} . Retrying later... "
            failed_copies+=("${img}") # Failed, then add the image to be retrieved later
        fi
    done
}

#
# retry_images: Retry loading any failed images into container storage
#
function retry_images {
    local total_copies=${#failed_copies[@]}

    if [ "${total_copies}" -eq 0 ]; then
        return 0
    fi

    local rc=0
    local tag
    local current_copy=0

    echo "${PROG}: [RETRYING]"
    for failed_copy in "${failed_copies[@]}"; do
        current_copy=$((current_copy+1))

        echo "${PROG}: [RETRY] Retrying failed image pull: ${failed_copy}"

        tag=$(grep "^${uri}=" "${MAPPING_FILE}" | sed 's/.*://')
        copy_image "${current_copy}" "${total_copies}" "${uri}" "${tag}"
        rc=$?
    done

    echo "${PROG}: [INFO] Image load done"
    return "${rc}"
}

if [[ "${BASH_SOURCE[0]}" = "${0}" ]]; then
    failed_copies=() # Array that will include all the images that failed to be pulled

    mount_data

    load_images

    if ! retry_images; then
        echo "${PROG}: [FAIL] ${#failed_copies[@]} images were not loaded successfully, after $((SECONDS-START)) seconds" #number of failing images
        exit 1
    else
        echo "${PROG}: [SUCCESS] All images were loaded, in $((SECONDS-START)) seconds"
        exit 0
    fi
fi
