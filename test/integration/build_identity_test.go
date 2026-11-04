//go:build integration

package integration

/*
Copyright The CryptOS Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// The build identity check of the full-image suite: the suite's cryptosctl
// and the node it boots are both stamped with build/ci/buildinfo.sh, so
// neither may fall back to "dev" or an "unknown" commit. They needn't match:
// CI reuses a cached image when nothing that goes into it changed, so the
// node can carry an earlier commit's version than the cryptosctl built for
// the run. cryptosctl reads its version from
// github.com/Bugs5382/go-buildinfo, so this is what catches a build that
// stamps the wrong package.

import (
	"bytes"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
)

// checkBuildIdentity checks the output of `cryptosctl version -o json` run
// against a node.
func checkBuildIdentity(out []byte) error {
	var r struct {
		Client struct {
			Version string `json:"version"`
			Commit  string `json:"commit"`
		} `json:"client"`
		Node *struct {
			Version string `json:"version"`
		} `json:"node"`
	}
	// ctl appends stderr after stdout, so read only the first JSON value.
	if err := json.NewDecoder(bytes.NewReader(out)).Decode(&r); err != nil {
		return fmt.Errorf("parse cryptosctl version: %w\n%s", err, out)
	}
	unstamped := func(s string) bool { return s == "" || s == "dev" || s == "unknown" }
	if unstamped(r.Client.Version) {
		return fmt.Errorf("cryptosctl version is %q, want the stamped build version", r.Client.Version)
	}
	if unstamped(r.Client.Commit) {
		return fmt.Errorf("cryptosctl commit is %q, want the stamped commit", r.Client.Commit)
	}
	if r.Node == nil {
		return fmt.Errorf("no node version in the report:\n%s", out)
	}
	if unstamped(r.Node.Version) {
		return fmt.Errorf("node version is %q, want the stamped build version", r.Node.Version)
	}
	return nil
}

func TestCheckBuildIdentity(t *testing.T) {
	for _, tc := range []struct {
		name, out, wantErr string
	}{
		{
			name: "stamped client and node agree",
			out:  `{"client":{"version":"v0.1.0-rc.1-3-g854f3f8","commit":"854f3f8496383986fa3fe5a1e6b6eccb12be0acd","build_date":"2026-11-02T13:56:43Z","go_version":"go1.26.10"},"node":{"version":"v0.1.0-rc.1-3-g854f3f8"}}`,
		},
		{
			name: "stderr after the report",
			out:  `{"client":{"version":"v0.1.0","commit":"854f3f8","build_date":"x","go_version":"go1.26.10"},"node":{"version":"v0.1.0"}}` + "\nwarning: something on stderr\n",
		},
		{
			name:    "unstamped client",
			out:     `{"client":{"version":"dev","commit":"854f3f8","build_date":"unknown","go_version":"go1.26.10"},"node":{"version":"v0.1.0-rc.1-3-g854f3f8"}}`,
			wantErr: `cryptosctl version is "dev"`,
		},
		{
			name:    "unknown commit",
			out:     `{"client":{"version":"v0.1.0","commit":"unknown","build_date":"unknown","go_version":"go1.26.10"},"node":{"version":"v0.1.0"}}`,
			wantErr: `cryptosctl commit is "unknown"`,
		},
		{
			name:    "unstamped node",
			out:     `{"client":{"version":"v0.1.0","commit":"854f3f8","build_date":"x","go_version":"go1.26.10"},"node":{"version":"dev"}}`,
			wantErr: `node version is "dev"`,
		},
		{
			name: "a cached image's node version differs from the client's",
			out:  `{"client":{"version":"v0.1.0-rc.1-5-g6bdf5d2","commit":"6bdf5d2","build_date":"x","go_version":"go1.26.10"},"node":{"version":"v0.1.0-rc.1-4-gd18d19a"}}`,
		},
		{
			name:    "no node in the report",
			out:     `{"client":{"version":"v0.1.0","commit":"854f3f8","build_date":"x","go_version":"go1.26.10"}}`,
			wantErr: "no node version",
		},
		{
			name:    "not JSON",
			out:     "Client version:  v0.1.0\n",
			wantErr: "parse cryptosctl version",
		},
	} {
		t.Run(tc.name, func(t *testing.T) {
			err := checkBuildIdentity([]byte(tc.out))
			switch {
			case tc.wantErr == "" && err != nil:
				t.Fatalf("unexpected error: %v", err)
			case tc.wantErr != "" && err == nil:
				t.Fatalf("want an error containing %q, got none", tc.wantErr)
			case tc.wantErr != "" && !strings.Contains(err.Error(), tc.wantErr):
				t.Fatalf("want an error containing %q, got %v", tc.wantErr, err)
			}
		})
	}
}
