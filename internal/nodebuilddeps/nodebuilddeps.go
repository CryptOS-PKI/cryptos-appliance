//go:build toolsdeps

// Package nodebuilddeps blank-imports packages that cryptos-node's cmd/init,
// cmd/cryptosctl and cmd/cryptos-console need (etcd, the TPM stack, YAML
// config parsing, Cobra, terminal handling) but that this module's own
// sources never import directly. go.sum only keeps entries for packages
// something in the main module imports, and those are leaf binaries this
// repo builds by path (build/squashfs/build.sh, test/image/build.sh), not a
// dependency of any package here. Without this file, `go mod tidy` prunes
// those entries and the image build fails with "missing go.sum entry". The
// toolsdeps build tag keeps this file out of every real build; nothing ever
// compiles it except `go mod tidy`/`go list all`, which read it regardless
// of build constraints.
package nodebuilddeps

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
	_ "github.com/google/go-tpm-tools/simulator"
	_ "github.com/google/go-tpm/tpm2"
	_ "github.com/google/go-tpm/tpm2/transport"
	_ "github.com/google/go-tpm/tpm2/transport/linuxtpm"
	_ "github.com/spf13/cobra"
	_ "go.etcd.io/etcd/client/v3"
	_ "go.etcd.io/etcd/server/v3/embed"
	_ "go.uber.org/zap"
	_ "golang.org/x/term"
	_ "gopkg.in/yaml.v3"
)
