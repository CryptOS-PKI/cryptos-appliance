# cryptos-appliance 🐹

> 🧭 The signed OS image, installer and A/B image upgrades for CryptOS nodes.

CryptOS ships source only: no prebuilt image, signed or unsigned. Build the
bootable image yourself and sign it with your own Secure Boot key -- see
[`build/README.md`](build/README.md) for the pipeline and
[`docs/secure-boot.md`](docs/secure-boot.md) for generating the key.

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
