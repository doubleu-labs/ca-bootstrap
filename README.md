# Root Certificate Authority (CA) - Bootstrap

This repository automates the process of creating a Root CA and deploying assets
to a Github repository to leverage Github Pages to publish the Certificate and
Certificate Revocation List (CRL).

The Root CA private key is stored on a YubiKey and uses OpenSSL's `pkcs11`
engine for CA operation.

All secrets are stored in KeePassXC KDBX databases for security and ease of
storage.

## TL;DR

To create a Root CA, complete the following steps:

1.  Run `./scripts/setup.sh`
2.  Copy App private key to `./secrets` directory
3.  Fill in all values in 'ca.env'
4.  Optionally modify `[match_pol]` in `openssl.template.cnf`
5.  Run `./scripts/initialize.sh`
6.  Modify security settings of both secrets databases
7.  Run `./scripts/deploy.sh`
8.  Run `./scripts/archive.sh`
9.  Store `./kdbx/rootca.kdbx` in a secure location

## Security of Secrets Databases

During initialization, two databases are created in the `./kdbx` directory:
`rootca.kdbx` and `yk-pin.kdbx`.

`rootca.kdbx` stores a backup of the unencrypted CA private key, public key,
CSR, and certificate. It also stores backups of the YubiKey `ManagementKey`,
`PINUnlockKey`, and PIV `PIN`. A copy of the Github App's private key used to
communicate with the Github API is also stored. Essentially, every bit of
information needed to operate and publish the CA.

`yk-pin.kdbx` only contains the YubiKey PIV `PIN`, which when performing CA
operations is loaded into a secure Kernel Keyring and is used to provide the PIN
to OpenSSL. This database is included in the Root CA archive for operational
use.

**A 1MiB keyfile is created alongside each database and is the *only*
credential by default.**

After initialization, it is ***STRONGLY RECOMMENDED*** to modify the encryption
settings, add a password, and remove the keyfile from each database.
Unfortunately at this time, this is not possible to do from the CLI and must be
done within the KeePassXC GUI application.

For both databases, ensure that the KDBX4 format is used so that modern
encryption is available. Use `argon2id` for the Key Dirivation Function (KDF).

For `rootca.kdbx`, set an ***extremely strong*** passphrase and store a backup
of the passphrase in a secure location separate from the `rootca.kdbx` file. For
encryption settings, use a very high Memory Usage (>=1024 MiB) and tweak the 
Transform Rounds until it feels excessive. Speed should not be desired for
decryption of this database as it should only really be used for disaster
recovery.

For `yk-pin.kdbx`, set a ***strong but memorable*** passphrase. For enryption
settings, speed can be a consideration here. Use a moderate amount for Memory
Usage (>=512 MiB) and a lower amout of Transform Rounds. Using the
`Benchmark 1.0 s delay` feature is acceptable to configure Transform Rounds.

## Scripts

Here is a brief explaination of each script, what it does, and when to use it.

### `archive.sh`

Creates a timestamped `tar` archive of the CA directory structure and relevant
operational scripts and databases. Store this in a USB drive (or two), or on a
secure Cloud storage service. It is recommended to sign the file using PGP/GPG
so that integrity and authenticity can be verified before the CA needs to be
used.

This archive will be all that's needed to operate the Root CA. This script,
alongside `deploy.sh`, `revoke.sh`, `sign.sh`, and `update_crl.sh` are included
in the archive.

Run this script whenever you sign a Certificate Signing Request (CSR), revoke a
certificate, or modify the database.

### `deploy.sh`

Uses the Github App configured in `ca.env` to publish the CA Certificate, CRL,
or both to the configured Github repository. The App then creates a Pull Request
to merge the new or modified files into the branch monitored by Github Pages.

Run this script whenever a new Certificate Revocation List (CRL) is generated.

### `initialize.sh`

Creates the Root CA using the information configured in `ca.env`. The
environment is validated and the YubiKey is verified ready before anything is
generated.

Only run this script when you want to create a Root CA. It ***will*** fail if
***any*** CA files exist in the `$CADATAPATH` directory. Be sure to run
`deploy.sh -all` to publish the CA certificate and initial CRL.

### `purge.sh`

Deletes ***ALL*** CA data from `$CADATAPATH` and resets any changes made to
`openssl.template.cnf`.

By default, only files used in the setup and initialization of the CA are
removed. Any CA archives made are preserved, but if you want to delete these as
well, then:

```sh
./scripts/purge.sh -archives
```

Only run this script if you've make a mistake generating the Root CA or
otherwise need to clean up the boostrap environment.

### `revoke.sh`

Sets a certificate as `REVOKED` in the CA database and generates a new CRL.
Certificates can be revoked using the certificate file or serial. Without
additional arguments, the reason for revocation is `unspecified` by default. If
you need to specify a revocation reason, run this script with no arguments to
display all options.

Only run this script when a certificate needs to be revoked. Be sure to run
`deploy.sh -crl` afterwards to publish the newly updated CRL.

### `setup.sh`

Checks that no CA directories exist before creating them. The `ca.template.env`
file is copied to `ca.env` and ready to be configured.

Only run this script when preparing to initialize a new Root CA.

### `sign.sh`

Signs a Certificate Signing Request (CSR). Outputs the signed certificate to the
terminal by default. Use the `-out <FILE>` option to write it to a file instead.
The `-chain` option is also available to include the Root CA certificate with
the signed certificate.

Use this script when a CSR needs to be signed.

### `update_crl.sh`

Force generates a CRL. The CRL serial is ***always*** incremented.

Use this script if the CA database (`./db/ca.db`) required manual editing, such
as un-revoking a certificate. This script is not needed if using `revoke.sh`. Be
sure to run `deploy.sh -crl` afterwards to deploy the updated CRL.
