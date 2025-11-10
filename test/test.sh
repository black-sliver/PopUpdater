#!/bin/env bash

set -e

BIN_DIR=$(realpath "$(dirname "${BASH_SOURCE[0]}")/../zig-out/bin/")
UPDATER=$(find "$BIN_DIR" -depth -maxdepth 1 -type f ! -name '.*' -print -quit)

EXE=app.sh
if [ "$OSTYPE" == "msys" ] || [ "$OSTYPE" == "win32" ]; then
  EXE=app.bat
fi

if [ ! -d tmp ]; then
  echo "Creating working dir: ./tmp"
  mkdir tmp
fi
pushd tmp > /dev/null

# create two private-public key pair we'll use to sign
minisign -G -f -p key1.pub -s key1.key -W >/dev/null
minisign -G -f -p key2.pub -s key2.key -W >/dev/null
ID1=$(sed -nE 's/^.* public key ([0-9A-F]+).*$/\1/p' < key1.pub)
ID2=$(sed -nE 's/^.* public key ([0-9A-F]+).*$/\1/p' < key2.pub)
echo "generated keys $ID1 and $ID2"

mkdir -p ext-key
cp key1.pub "ext-key/$ID1.pub"

# create zip file that we'll sign and validate
echo "Creating update ..."
if [ -d test ]; then rm -r test ; fi
mkdir -p test/subdir
mkdir -p test/key
cp key1.pub "test/key/$ID1.pub"
cp "$UPDATER" test/PopUpdater.exe
pushd test > /dev/null
echo "1" > subdir/a
echo "2" > b
cat >app.sh <<EOL
#!/bin/env bash
if [ "$1" == "update" ]; then
  # $(dirname "${BASH_SOURCE[0]}")/PopUpdater.exe ...
  echo "$0 $1 not implemented"
  exit 1
else
  echo "App started :party:"
fi
EOL
chmod a+rx app.sh
cat >app.bat <<EOL
echo "BAT started"
bash %~dp0\app.sh %*
EOL
popd > /dev/null
if [ -f test.zip ]; then rm test.zip; fi
zip -r test.zip test

# remember checksums of all files
# shellcheck disable=SC2046
ORIGINAL_SUMS=$(sha256sum -- $(find test -type f -print))

# sign with key1
minisign -S -s key1.key -m test.zip

# extract into fresh dir
echo "Testing update ..."
rm -r test/*
"$UPDATER" -s "$EXE" test/ test.zip test.zip.minisig ext-key
echo "$ORIGINAL_SUMS" | sha256sum -c --quiet

# extract again into same dir
chmod a+rx ./test/PopUpdater.exe
"./test/PopUpdater.exe" -s "$EXE" test/ test.zip test.zip.minisig
echo "$ORIGINAL_SUMS" | sha256sum -c --quiet

# check that updater was put into new file
cmp test/PopUpdater.exe test/PopUpdater.new.exe

# check tat missing pub key fails
rm test/key/*
set +e
if "./test/PopUpdater.exe" test/ test.zip test.zip.minisig; then
  echo "Unexpected success!"
  exit 1
else
  echo "Expected failure OK"
fi
set -e

# check that wrong pub key fails
cp key2.pub "test/key/$ID1.pub"
set +e
if "./test/PopUpdater.exe" test/ test.zip test.zip.minisig; then
  echo "Unexpected success!"
  exit 1
else
  echo "Expected failure OK"
fi
set -e

# remove temp files
rm -- *.key *.pub *.minisig
rm -r ext-key

popd > /dev/null
