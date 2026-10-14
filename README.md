# cryptos-appliance 🐹

> 🧭 The signed OS image, installer and A/B image upgrades for CryptOS nodes.

Every image you run is signed by you. Each release attaches an unsigned image
-- the project never signs one -- so sign the downloaded image with your own
Secure Boot key, or build the bootable image yourself and sign it, your key
either way. See [`build/README.md`](build/README.md) for the build pipeline
and [`docs/secure-boot.md`](docs/secure-boot.md) for generating the key and
for the release asset list.

## 📦 Install

```bash
go get github.com/CryptOS-PKI/cryptos-appliance
```

## 🛠 Develop

```bash
task build    # go build ./...
task test     # go test ./...
task lint     # gofmt check + golangci-lint + yamllint
task license  # check license headers (golic)
```

## 🙏 Acknowledgements

CryptOS was originally written by [@Bugs5382](https://github.com/Bugs5382).

## 📄 License

[Apache License 2.0](LICENSE). Copyright The CryptOS Authors.
