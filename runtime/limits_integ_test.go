// Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License"). You may
// not use this file except in compliance with the License. A copy of the
// License is located at
//
//	http://aws.amazon.com/apache2.0/
//
// or in the "license" file accompanying this file. This file is distributed
// on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either
// express or implied. See the License for the specific language governing
// permissions and limitations under the License.
package main

import (
	"context"
	"regexp"
	"strconv"
	"testing"

	"github.com/containerd/containerd"
	"github.com/containerd/containerd/namespaces"
	"github.com/containerd/containerd/oci"
	"github.com/firecracker-microvm/firecracker-containerd/internal/integtest"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// extractWrittenMB extracts the number of megabytes written from dd output
func extractWrittenMB(output string) int {
	// Look for pattern like "912+0 records in" or "911+0 records out"
	re := regexp.MustCompile(`(\d+)\+0 records (?:in|out)`)
	matches := re.FindStringSubmatch(output)
	if len(matches) >= 2 {
		if blocks, err := strconv.Atoi(matches[1]); err == nil {
			return blocks // dd uses 1MB blocks with bs=1M
		}
	}

	// Fallback: look for byte count like "955949056 bytes"
	re2 := regexp.MustCompile(`(\d+) bytes`)
	matches2 := re2.FindStringSubmatch(output)
	if len(matches2) >= 2 {
		if bytes, err := strconv.ParseInt(matches2[1], 10, 64); err == nil {
			return int(bytes / (1024 * 1024)) // Convert bytes to MB
		}
	}

	return 0
}

func TestDiskLimit_Isolated(t *testing.T) {
	integtest.Prepare(t)

	ctx := namespaces.WithNamespace(context.Background(), "default")

	client, err := containerd.New(integtest.ContainerdSockPath, containerd.WithDefaultRuntime(firecrackerRuntime))
	require.NoError(t, err, "unable to create client to containerd service at %s, is containerd running?", integtest.ContainerdSockPath)
	defer client.Close()

	image, err := alpineImage(ctx, client, defaultSnapshotterName)
	require.NoError(t, err, "failed to get alpine image")

	// Right now, both naive snapshotter and devmapper snapshotter are configured to have 1024MB image size.
	// The former is hard-coded since the snapshotter is not for production. The latter is configured in tools/docker/entrypoint.sh.
	sh := containerd.WithNewSpec(
		oci.WithProcessArgs("dd", "if=/dev/zero", "of=/tmp/fill", "bs=1M", "count=2000"),
		oci.WithDefaultPathEnv,
	)

	container, err := client.NewContainer(ctx,
		"container",
		containerd.WithSnapshotter(defaultSnapshotterName),
		containerd.WithNewSnapshot("snapshot", image),
		sh,
	)
	defer func() {
		err = container.Delete(ctx, containerd.WithSnapshotCleanup)
		require.NoError(t, err, "failed to delete a container")
	}()

	result, err := integtest.RunTask(ctx, container)
	require.NoError(t, err, "failed to create a container")

	// Verify that writing 2GB fails due to disk space limitation
	assert.Equal(t, uint32(1), result.ExitCode, "writing 2GB must fail")

	// Extract the actual amount written and verify it's within expected range
	// The 1024MB base_image_size has filesystem overhead (metadata, reserved blocks, base image)
	// so we expect ~850-1000MB of usable space depending on filesystem implementation
	writtenMB := extractWrittenMB(result.Stderr)
	t.Logf("Container wrote %d MB before hitting disk limit", writtenMB)

	assert.GreaterOrEqual(t, writtenMB, 850, "should be able to write at least 850MB on 1024MB device")
	assert.LessOrEqual(t, writtenMB, 1000, "should not write more than 1000MB on 1024MB device")

	// Verify the output contains expected dd error message indicating disk full
	assert.Contains(t, result.Stderr, "No space left on device", "dd should fail with disk full error")
}
