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

import (
	"strings"
	"testing"
)

// The manager's run skips its linking and decommission steps
// when it has no spare node, and a skipped step shows green. With a spare
// configured, a skip is a failure: it is how linking a node to the manager
// stayed untested until v0.1.0-rc.2 shipped with it broken.
func TestRequireSpareRows(t *testing.T) {
	ok := func(name string) managerResult { return managerResult{Name: name, Status: "ok"} }
	all := []managerResult{
		ok("fleet/list-nodes"),
		ok(managerLinkRow), ok(managerDecommissionRow),
	}
	if err := requireSpareRows(all); err != nil {
		t.Fatalf("every spare row ok: want no error, got %v", err)
	}

	for _, row := range []string{managerLinkRow, managerDecommissionRow} {
		var skipped, failed, missing []managerResult
		for _, r := range all {
			switch {
			case r.Name != row:
				skipped, failed, missing = append(skipped, r), append(failed, r), append(missing, r)
			default:
				skipped = append(skipped, managerResult{Name: r.Name, Status: "skip", Detail: "no spare node configured to link"})
				failed = append(failed, managerResult{Name: r.Name, Status: "FAIL", Detail: "boom"})
			}
		}
		for what, results := range map[string][]managerResult{"skipped": skipped, "absent": missing} {
			err := requireSpareRows(results)
			if err == nil || !strings.Contains(err.Error(), row) {
				t.Errorf("%s %s: want an error naming the row, got %v", row, what, err)
			}
		}
		// A failing row already fails its own suite row; this check is only
		// about the rows that did not run.
		if err := requireSpareRows(failed); err != nil {
			t.Errorf("%s failed: the row reports itself, want no error here, got %v", row, err)
		}
	}
}
