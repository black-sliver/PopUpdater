# PopUpdater

Tool to verify and unpack (install) an already-downloaded update zip file.

Optionally uses GitHub attestation to verify timestamp.

Usage: `PopUpdater.exe [-h] [-a owner/repo] [-t timestamp] path/to/target update.zip update.minisig [path/to/key-dir]`

key-dir defaults to target/key if not provided.

## Concept

When creating a release, the release artifact (.zip) is checked and signed by a trusted person. The signature is
uploaded as another release artifact (.zip.minisig).

This makes it impossible for a compromised release pipeline to create a valid release without also compromising a
private key that lives on a different system, however it requires the (public key used for the) signature to be trusted,
which means this system is only suitable for updates.

## Public Keys

The keys are minisign public keys with an extra `not before <timestamp> not after <timestamp>` in the comment to allow
key rotation.

The keys' filenames have to be `<key_id>.pub` where the key_id is all upper case hexadecimal.

## Timestamps

To allow key rotation, the verification has to know when the file was signed. This information has to be provided out of
band.

You can pass a timestamp using `-t` or use GitHub attestation (`-a`) to fetch the timestamp.
If fetching the attestation fails due to a network error (Connect, Read, Write), it'll fall back to `-t`.
**If no `-t` was provided, this will skip the timestamp check!!**

To hard require the attestation timestamp, use `-t 1` and make sure no public key is valid for `1`.  Beware that an
outage, API change, TLS problem or rate-limiting will make it impossible to verify the update in that case.
See also TODO for a possible alternative.

## Usage as a library

Some of the code is in a zig library, so it can be used to create a customized binary with it. 

## License

For now, both library part and application are released under the terms of GPLv3. See [LICENSE](./LICENSE).

## TODO

* Could invoke an InnoSetup with `/SP- /SILENT /NOCANCEL /NORESTART /CLOSEAPPLICATIONS /NORESTARTAPPLICATIONS`.
* Could also support other platforms, not just Windows.
  * We could do the same for .tar.* archives of binaries on Linux.
  * We could invoke AppImageUpdater for AppImages.
  * We could update AppDirs on macOS (if it's not a read-only .dmg).
* Allow rekor as alternative/backup to GitHub attestation API.
