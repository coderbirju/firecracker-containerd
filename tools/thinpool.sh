#! /bin/bash
#
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License"). You may
# not use this file except in compliance with the License. A copy of the
# License is located at
#
# 	http://aws.amazon.com/apache2.0/
#
# or in the "license" file accompanying this file. This file is distributed
# on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
# express or implied. See the License for the specific language governing
# permissions and limitations under the License.

FICD_DM_VOLUME_GROUP="$FICD_DM_VOLUME_GROUP"

# The tmp/devmapper/ directory will be created on this project's
# root directory.
DIR=$(dirname $BASH_SOURCE)/../tmp/devmapper

set -euo pipefail

subcommand="$1"
name="$2"

if [ -z "$name" ]; then
    exit 0
fi

create_loopback_device() {
    local path=$1
    local size=$2

    if [[ ! -f "$path" ]]; then
        touch "$path"
        truncate -s "$size" "$path"
    fi

    local dev=$(sudo losetup --output NAME --noheadings --associated "$path")
    if [[ -z "$dev" ]]; then
        dev=$(sudo losetup --find --show $path)
    fi
    echo $dev
}

if [[ -z "$FICD_DM_VOLUME_GROUP" ]]; then
    pool_create() {
        mkdir -p $DIR

        local datadev=$(create_loopback_device "$DIR/data" '10G')
        local metadev=$(create_loopback_device "$DIR/metadata" '1G')

        local sectorsize=512
        local datasize="$(sudo blockdev --getsize64 -q ${datadev})"
        local length_sectors=$(bc <<< "${datasize}/${sectorsize}")
        local thinp_table="0 ${length_sectors} thin-pool ${metadev} ${datadev} 128 32768 1 skip_block_zeroing"
        sudo dmsetup create "$name" --table "${thinp_table}"
    }

    pool_remove() {
        echo "=== Loopback pool removal for: $name ==="
        
        # Phase 1: Remove snapshots with retry logic and force removal
        echo "Removing snapshots for pool: $name"
        for snapshot in $(sudo dmsetup ls 2>/dev/null | awk "/^$name-snap-/ { print \$1 }" || true); do
            echo "Attempting to remove snapshot: $snapshot"
            local retries=3
            while [ $retries -gt 0 ]; do
                if sudo dmsetup remove "$snapshot" 2>/dev/null; then
                    echo "Successfully removed snapshot: $snapshot"
                    break
                else
                    echo "Snapshot $snapshot busy, waiting... (retries left: $retries)"
                    sleep 1
                    retries=$((retries - 1))
                fi
            done
            
            if [ $retries -eq 0 ]; then
                echo "Warning: Failed to remove snapshot $snapshot, trying force removal"
                { sudo dmsetup remove --force "$snapshot" 2>/dev/null || true; } || true
            fi
        done

        # Phase 2: Try to delete thin devices by ID with error handling
        echo "Cleaning up thin devices by ID..."
        for dev_no in {1..50}; do
            # Don't let dmsetup message failures stop the script - wrap in error handling
            { sudo dmsetup message "$name" 0 "delete $dev_no" 2>/dev/null || true; } || true
        done

        # Phase 3: Remove the main pool device with retries
        echo "Removing main pool device: $name"
        local pool_retries=3
        while [ $pool_retries -gt 0 ]; do
            if sudo dmsetup remove "$name" 2>/dev/null; then
                echo "Successfully removed pool: $name"
                break
            else
                echo "Pool $name busy, waiting... (retries left: $pool_retries)"
                sleep 1
                pool_retries=$((pool_retries - 1))
            fi
        done
        
        if [ $pool_retries -eq 0 ]; then
            echo "Warning: Failed to remove pool after retries, trying force removal"
            { sudo dmsetup remove --force "$name" 2>/dev/null || true; } || true
        fi
        
        echo "Pool removal completed"
    }

    pool_reset() {
        echo "=== Starting loopback pool reset for: $name ==="
        
        if sudo dmsetup info "$name" >/dev/null 2>&1; then
            echo "Pool $name exists, performing cleanup..."
            
            # Phase 1: System sync and cache cleanup
            echo "=== Phase 1: System cache cleanup ==="
            sync
            { sudo bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true; } || true
            sync
            sleep 2
            
            # Phase 2: Suspend/resume to force cleanup
            echo "=== Phase 2: Pool suspend/resume ==="
            { sudo dmsetup suspend "$name" 2>/dev/null || true; } || true
            sleep 2
            { sudo dmsetup resume "$name" 2>/dev/null || true; } || true
            sleep 1
            
            # Phase 3: Pool removal with robust error handling
            echo "=== Phase 3: Pool removal ==="
            pool_remove || {
                echo "Warning: pool_remove failed, but continuing with pool creation..."
            }
        else
            echo "Pool $name does not exist, skipping cleanup"
        fi
        
        # Phase 4: Create new pool
        echo "=== Phase 4: Creating new pool ==="
        pool_create
        echo "=== Pool reset completed successfully ==="
    }
else
    dm_device="/dev/mapper/$(echo ${FICD_DM_VOLUME_GROUP} | sed -e s/-/--/g)-$name"

    pool_create() {
        echo sudo lvcreate --type thin-pool \
             --poolmetadatasize 16MiB \
             --size 1GiB \
             -n "$name" "$FICD_DM_VOLUME_GROUP"
        sudo lvcreate --type thin-pool \
             --poolmetadatasize 16MiB \
             --size 1GiB \
             -n "$name" "$FICD_DM_VOLUME_GROUP"
    }

    pool_remove() {
        # Find and remove individual snapshots with retry logic
        for snapshot in $(sudo dmsetup ls | grep "^$(basename ${dm_device})-snap-" | awk '{print $1}' | sort -r); do
            echo "Attempting to remove snapshot: $snapshot"
            local retries=5
            while [ $retries -gt 0 ]; do
                if sudo dmsetup remove "$snapshot" 2>/dev/null; then
                    echo "Successfully removed snapshot: $snapshot"
                    break
                else
                    echo "Snapshot $snapshot busy, waiting... (retries left: $retries)"
                    sleep 2
                    retries=$((retries - 1))
                fi
            done
            
            if [ $retries -eq 0 ]; then
                echo "Warning: Failed to remove snapshot $snapshot after retries"
                # Force remove by checking what's using it
                sudo dmsetup info "$snapshot" 2>/dev/null || true
                sudo lsof "$snapshot" 2>/dev/null || true
                sudo dmsetup remove --force "$snapshot" || true
            fi
        done

        # Remove the thin pool with retries
        local pool_retries=5
        while [ $pool_retries -gt 0 ]; do
            if sudo dmsetup remove "${dm_device}" 2>/dev/null; then
                echo "Successfully removed thin pool: ${dm_device}"
                break
            else
                echo "Thin pool ${dm_device} busy, waiting... (retries left: $pool_retries)"
                sleep 2
                pool_retries=$((pool_retries - 1))
            fi
        done
        
        if [ $pool_retries -eq 0 ]; then
            echo "Warning: Failed to remove thin pool after retries"
            sudo dmsetup info "${dm_device}" 2>/dev/null || true
            sudo lsof "${dm_device}" 2>/dev/null || true
        fi

        # Clean up metadata and data devices
        sudo dmsetup remove "${dm_device}_tdata" 2>/dev/null || true
        sudo dmsetup remove "${dm_device}_tmeta" 2>/dev/null || true
        
        # Finally remove the logical volume
        sudo lvremove -f "$dm_device" 2>/dev/null || true
    }

    pool_reset() {
        if [ -e "${dm_device}" ]; then
            echo "Starting pool reset for: ${dm_device}"
            
            # PHASE 1: Containerd cleanup (always try, ignore errors)
            echo "=== Phase 1: Containerd snapshot cleanup ==="
            if command -v ctr >/dev/null 2>&1; then
                echo "Cleaning up containerd snapshots..."
                for snap in $(ctr --address /run/firecracker-containerd/containerd.sock snapshots list 2>/dev/null | tail -n +2 | awk '{print $1}' || true); do
                    if [ -n "$snap" ] && [ "$snap" != "KEY" ]; then
                        echo "Removing containerd snapshot: $snap"
                        ctr --address /run/firecracker-containerd/containerd.sock snapshots remove "$snap" 2>/dev/null || true
                    fi
                done
                echo "Waiting for containerd to release device references..."
                sleep 5
            else
                echo "containerd client not available, skipping containerd cleanup"
            fi
            
            # PHASE 2: Force cleanup all device mapper snapshots by name
            echo "=== Phase 2: Device mapper snapshot cleanup ==="
            echo "Removing all snapshots for pool $(basename ${dm_device})..."
            
            # Get all snapshots for this pool and remove them aggressively
            for snapshot in $(sudo dmsetup ls 2>/dev/null | grep "^$(basename ${dm_device})-snap-" | awk '{print $1}' | sort -r || true); do
                echo "Force removing snapshot: $snapshot"
                sudo dmsetup remove --force "$snapshot" 2>/dev/null || true
            done
            
            # PHASE 3: Try to delete thin devices by ID (more aggressive approach)
            echo "=== Phase 3: Thin device cleanup by ID ==="
            # The thin pool can have devices 1-50, try to delete them all
            for dev_id in {1..50}; do
                # Don't let dmsetup message failures stop the script
                { sudo dmsetup message "${dm_device}" 0 "delete $dev_id" 2>/dev/null || true; } || true
            done
            
            # PHASE 4: Suspend/resume pool to force state cleanup
            echo "=== Phase 4: Force pool suspend/resume ==="
            if sudo dmsetup info "${dm_device}" >/dev/null 2>&1; then
                echo "Suspending pool..."
                { sudo dmsetup suspend "${dm_device}" 2>/dev/null || true; } || true
                sleep 3
                echo "Resuming pool..."  
                { sudo dmsetup resume "${dm_device}" 2>/dev/null || true; } || true
                sleep 2
            else
                echo "Pool device not found during suspend/resume phase"
            fi
            
            # PHASE 5: System cache cleanup
            echo "=== Phase 5: System cache cleanup ==="
            sync
            { sudo bash -c 'echo 3 > /proc/sys/vm/drop_caches' 2>/dev/null || true; } || true
            sync
            sleep 3
            
            # PHASE 6: Pool removal (this should now work)
            echo "=== Phase 6: Pool removal ==="
            pool_remove || {
                echo "Warning: pool_remove failed, but continuing..."
                # Last resort: try to remove pool components individually
                { sudo dmsetup remove --force "${dm_device}" 2>/dev/null || true; } || true
                { sudo dmsetup remove --force "${dm_device}_tdata" 2>/dev/null || true; } || true  
                { sudo dmsetup remove --force "${dm_device}_tmeta" 2>/dev/null || true; } || true
                { sudo lvremove -f "$dm_device" 2>/dev/null || true; } || true
            }
            
            echo "Pool reset cleanup completed"
        else
            echo "Pool device ${dm_device} does not exist, skipping cleanup"
        fi
        
        # PHASE 7: Create new pool
        echo "=== Phase 7: Creating new pool ==="
        pool_create
        echo "Pool reset completed successfully"
    }
fi

case "$subcommand" in
    'create')
        pool_create
        ;;
    'remove')
        pool_remove
        ;;
    'reset')
        pool_reset
        ;;
    *)
        echo "This script doesn't support $subcommand"
        exit 1
esac
